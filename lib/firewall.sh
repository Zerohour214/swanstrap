#!/bin/bash
# swanstrap firewall: open IKE/ESP, forward + NAT the client pools, clamp MSS, and stop
# IPv6 leaks. Idempotent; run at boot by swanstrap-firewall.service (iptables mode) and
# once by install.sh. If ufw is active, rules go into ufw's own files instead.
#   firewall.sh apply | status
set -euo pipefail
. /etc/swanstrap/server.conf
LIB=$(cd "$(dirname "$0")" && pwd); . "$LIB/common.sh"

IF=$(ip -4 route show default | awk '{print $5; exit}')
IF6=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
# Real IPv6 uplink: a default route plus a global address on that interface
HAS_V6=0
[ -n "$IF6" ] && ip -6 addr show dev "$IF6" scope global 2>/dev/null | grep -q inet6 && HAS_V6=1

ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

sysctls() {
  local ra_if=${IF6:-$IF}
  {
    echo "net.ipv4.ip_forward = 1"
    # IPv6 forwarding is needed either way: with an IPv6 uplink to route client traffic,
    # without one so the kernel refuses client IPv6 at once (ICMPv6 unreachable) instead
    # of silently dropping it (slow app timeouts). Forwarding makes Linux ignore router
    # advertisements unless accept_ra = 2, so keep the server's own IPv6 config working.
    if [ -d /proc/sys/net/ipv6 ]; then
      [ -e "/proc/sys/net/ipv6/conf/$ra_if/accept_ra" ] && echo "net.ipv6.conf.$ra_if.accept_ra = 2"
      echo "net.ipv6.conf.all.forwarding = 1"
    fi
  } > /etc/sysctl.d/99-swanstrap.conf
  sysctl -q -p /etc/sysctl.d/99-swanstrap.conf || warn "some sysctls couldn't be applied"
}
# Without an IPv6 uplink, replies to the client's IPv6 pool need a route to reach the
# IPsec policy (which then encrypts them); otherwise the refusal never gets back.
pool6_route() {
  [ $HAS_V6 = 1 ] && return
  ip -6 route replace "$POOL6" dev "$IF" 2>/dev/null ||
    warn "couldn't route $POOL6 (IPv6 disabled on $IF?); client IPv6 is still blocked, just not refused instantly"
}

# rule <iptables|ip6tables> <table> <chain> <rule...>: add once; ACCEPTs go before the
# chain's first REJECT/DROP (e.g. OCI's default "REJECT all" rules), others are appended.
rule() {
  local cmd=$1 t=$2 c=$3; shift 3
  $cmd -t "$t" -C "$c" "$@" >/dev/null 2>&1 && return
  local pos=""
  [[ " $* " == *" -j ACCEPT "* ]] &&
    pos=$($cmd -t "$t" -L "$c" --line-numbers -n | awk '$2 ~ /^(REJECT|DROP)$/ {print $1; exit}')
  if [ -n "$pos" ]; then $cmd -t "$t" -I "$c" "$pos" "$@"; else $cmd -t "$t" -A "$c" "$@"; fi
}

MSS=(-p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360)

apply_iptables() {
  rule iptables filter INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
  rule iptables filter INPUT -p esp -j ACCEPT
  rule iptables filter FORWARD -s "$POOL" -m policy --dir in --pol ipsec --proto esp -j ACCEPT
  rule iptables filter FORWARD -d "$POOL" -m policy --dir out --pol ipsec --proto esp -j ACCEPT
  rule iptables nat POSTROUTING -s "$POOL" -o "$IF" -m policy --dir out --pol none -j MASQUERADE
  rule iptables mangle FORWARD -s "$POOL" -o "$IF" -m policy --dir in --pol ipsec "${MSS[@]}"
  rule iptables mangle FORWARD -d "$POOL" -m policy --dir out --pol ipsec "${MSS[@]}"
  if [ $HAS_V6 = 1 ]; then
    rule ip6tables filter FORWARD -s "$POOL6" -m policy --dir in --pol ipsec --proto esp -j ACCEPT
    rule ip6tables filter FORWARD -d "$POOL6" -m policy --dir out --pol ipsec --proto esp -j ACCEPT
    rule ip6tables nat POSTROUTING -s "$POOL6" -o "$IF6" -m policy --dir out --pol none -j MASQUERADE
  else
    # No IPv6 uplink: refuse client IPv6 quickly so apps fall back to IPv4 inside the tunnel
    ip6tables -C FORWARD -s "$POOL6" -j REJECT --reject-with icmp6-adm-prohibited >/dev/null 2>&1 ||
      ip6tables -I FORWARD 1 -s "$POOL6" -j REJECT --reject-with icmp6-adm-prohibited
  fi
}

# Replace the text between "# swanstrap BEGIN <tag>" / "# swanstrap END <tag>" in a file,
# inserting it after the line matching <anchor> (or at the top if anchor is "TOP").
put_block() {
  local file=$1 tag=$2 anchor=$3 body=$4 tmp
  tmp=$(mktemp)
  sed "/^# swanstrap BEGIN $tag\$/,/^# swanstrap END $tag\$/d" "$file" > "$tmp"
  local block="# swanstrap BEGIN $tag"$'\n'"$body"$'\n'"# swanstrap END $tag"
  if [ "$anchor" = TOP ]; then
    { echo "$block"; cat "$tmp"; } > "$file"
  else
    grep -q "$anchor" "$tmp" || { rm -f "$tmp"; die "can't find '$anchor' in $file"; }
    awk -v a="$anchor" -v b="$block" '{print} !done && $0 ~ a {print b; done = 1}' "$tmp" > "$file"
  fi
  rm -f "$tmp"
}

apply_ufw() {
  ufw allow 500,4500/udp >/dev/null
  ufw allow proto esp from any to any >/dev/null 2>&1 || true   # older ufw lacks "esp"; NAT-T (4500) still works
  put_block /etc/ufw/before.rules nat TOP "*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s $POOL -o $IF -m policy --dir out --pol none -j MASQUERADE
COMMIT
*mangle
:FORWARD ACCEPT [0:0]
-A FORWARD -s $POOL -o $IF -m policy --dir in --pol ipsec ${MSS[*]}
-A FORWARD -d $POOL -m policy --dir out --pol ipsec ${MSS[*]}
COMMIT"
  put_block /etc/ufw/before.rules forward '^# End required lines' \
"-A ufw-before-forward -s $POOL -m policy --dir in --pol ipsec --proto esp -j ACCEPT
-A ufw-before-forward -d $POOL -m policy --dir out --pol ipsec --proto esp -j ACCEPT"
  if [ -f /etc/ufw/before6.rules ]; then
    if [ $HAS_V6 = 1 ]; then
      put_block /etc/ufw/before6.rules nat TOP "*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s $POOL6 -o $IF6 -m policy --dir out --pol none -j MASQUERADE
COMMIT"
      put_block /etc/ufw/before6.rules forward '^# End required lines' \
"-A ufw6-before-forward -s $POOL6 -m policy --dir in --pol ipsec --proto esp -j ACCEPT
-A ufw6-before-forward -d $POOL6 -m policy --dir out --pol ipsec --proto esp -j ACCEPT"
    else
      put_block /etc/ufw/before6.rules forward '^# End required lines' \
"-A ufw6-before-forward -s $POOL6 -j REJECT --reject-with icmp6-adm-prohibited"
    fi
  fi
  ufw reload >/dev/null
}

case ${1:-apply} in
apply)
  [ -n "$IF" ] || die "no IPv4 default route"
  iptables -m policy -h >/dev/null 2>&1 || modprobe xt_policy 2>/dev/null ||
    die "kernel lacks the iptables 'policy' match (xt_policy)"
  sysctls; pool6_route
  if ufw_active; then apply_ufw; echo "firewall: ufw rules updated (uplink $IF, IPv6 uplink: $HAS_V6)"
  else apply_iptables; echo "firewall: iptables rules applied (uplink $IF, IPv6 uplink: $HAS_V6)"; fi ;;
status)
  echo "uplink: $IF  ipv6 uplink: ${IF6:-none} ($HAS_V6)  ufw active: $(ufw_active && echo yes || echo no)"
  iptables -S | grep -E "500,4500|$POOL" || true; ip6tables -S 2>/dev/null | grep -F "$POOL6" || true ;;
*) die "usage: firewall.sh apply|status" ;;
esac
