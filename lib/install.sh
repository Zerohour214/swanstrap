#!/bin/bash
# swanstrap installer: turns a Debian/Ubuntu machine into a PQ-VPN server.
#
#   install.sh [--site DIR]        full install from a site dir (server.conf, certs, key, pq-vpn.conf);
#                                  default DIR is <kit>/site (how 'swanstrap add-server' bundles ship)
#   install.sh --base              preflight and base packages only (used by bootstrap.sh)
#   install.sh --prepare           preflight, base packages and strongSwan only (used by bootstrap.sh)
#   install.sh --upgrade-strongswan
#
# STRONGSWAN=auto|package|source|source=<ver> (env or server.conf) picks how strongSwan is installed.
# Safe to re-run.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
. "$KIT/lib/common.sh"
SHARE=/usr/local/share/swanstrap SRC=/usr/local/src/strongswan STATE=/var/lib/swanstrap
VENDOR_VER=6.1.0

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT=(apt-get -o DPkg::Lock::Timeout=600 -y -qq)
has_systemd() { [ -d /run/systemd/system ]; }

# --- preflight ------------------------------------------------------------------
mod_ok() {
  [ -d "/sys/module/$1" ] || modprobe "$1" 2>/dev/null ||
    grep -q "/$1.ko" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null
}
preflight() {
  [ "$(id -u)" = 0 ] || die "run with sudo"
  command -v apt-get >/dev/null || die "needs Debian or Ubuntu (apt); this system isn't supported"
  . /etc/os-release
  case "$ID:${VERSION_ID%%.*}" in
    debian:1[2-9]|debian:[2-9][0-9]|ubuntu:2[2-9]|ubuntu:[3-9][0-9]) ;;
    *) warn "untested OS $PRETTY_NAME; supported: Debian 12+, Ubuntu 22.04+" ;;
  esac
  [ -e /proc/vz ] && [ ! -e /proc/bc ] && die "OpenVZ container detected: it can't run an IPsec server (no kernel IPsec)"
  local m missing=""
  for m in xfrm_user esp4; do mod_ok $m || missing+=" $m"; done
  [ -z "$missing" ] || die "kernel lacks IPsec support (missing:$missing). Use a KVM/full-VM VPS."
}

wait_for_apt() {
  # Fresh cloud servers run cloud-init / unattended-upgrades on first boot and hold the dpkg lock
  if command -v cloud-init >/dev/null; then
    echo "waiting for cloud-init to finish..."; timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
  fi
  "${APT[@]}" update
}

base_packages() {
  "${APT[@]}" install curl ca-certificates iproute2 kmod procps openssl gettext-base bzip2 gnupg \
    bsdextrautils iptables git >/dev/null
}

# --- strongSwan service ------------------------------------------------------------
svc_unit() {
  local u
  for u in strongswan strongswan-swanctl; do
    systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "^$u.service" && { echo $u; return; }
  done
  echo strongswan
}
start_charon() {
  if has_systemd; then
    systemctl daemon-reload
    local u; u=$(svc_unit)
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u" || return 1
  else  # containers without systemd
    pkill -x charon-systemd 2>/dev/null || true; sleep 1
    nohup "$(command -v charon-systemd || echo /usr/sbin/charon-systemd)" >/var/log/charon.log 2>&1 &
  fi
  local i; for i in $(seq 20); do swanctl --stats >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
# ML-KEM can come from the 'ml' plugin or from OpenSSL >= 3.5, so ask the running daemon
mlkem_ok() { command -v swanctl >/dev/null && start_charon >/dev/null 2>&1 && swanctl --list-algs 2>/dev/null | grep -q ML_KEM; }

# --- strongSwan from distro packages ------------------------------------------------
try_package() {
  local cand
  cand=$(apt-cache policy strongswan-swanctl 2>/dev/null | awk '/Candidate:/ {print $2}')
  [ -n "$cand" ] && [ "$cand" != "(none)" ] && dpkg --compare-versions "$cand" ge 6.0 || return 1
  echo "trying distro strongSwan $cand"
  # pki (certificates) and the EAP plugins (username login) are separate packages
  local p pkgs=()
  for p in charon-systemd strongswan-swanctl strongswan-pki libstrongswan-standard-plugins \
           libstrongswan-extra-plugins libcharon-extra-plugins; do
    apt-cache show "$p" >/dev/null 2>&1 && pkgs+=("$p")
  done
  "${APT[@]}" install "${pkgs[@]}" >/dev/null
}
purge_package() {
  "${APT[@]}" purge charon-systemd strongswan-swanctl strongswan-pki 'libstrongswan*' 'libcharon*' >/dev/null 2>&1 || true
}

# --- strongSwan from source ----------------------------------------------------------
latest_version() {
  curl -fsS -m 20 https://download.strongswan.org/ 2>/dev/null |
    grep -oE 'strongswan-6\.[0-9]+(\.[0-9]+)?\.tar\.bz2' | sed 's/strongswan-//; s/\.tar\.bz2//' | sort -uV | tail -1
}
# fetch <ver>: tarball + signature into $SRC, GPG-verified (vendored key, then the current key)
fetch() {
  local v=$1 t=$SRC/strongswan-$1.tar.bz2 g
  if [ "$v" = "$VENDOR_VER" ] && [ -f "$KIT/vendor/strongswan-$v.tar.bz2" ]; then
    cp "$KIT/vendor/strongswan-$v.tar.bz2" "$KIT/vendor/strongswan-$v.tar.bz2.sig" "$SRC/"
  else
    curl -fsS -m 300 -o "$t" "https://download.strongswan.org/strongswan-$v.tar.bz2" &&
      curl -fsS -m 60 -o "$t.sig" "https://download.strongswan.org/strongswan-$v.tar.bz2.sig" || return 1
  fi
  g=$(mktemp -d)
  gpg --homedir "$g" --import "$KIT/vendor/STRONGSWAN-RELEASE-PGP-KEY" >/dev/null 2>&1
  if ! gpg --homedir "$g" --verify "$t.sig" "$t" >/dev/null 2>&1; then
    warn "signature not made by the vendored key; trying the current strongSwan release key"
    curl -fsS -m 30 https://download.strongswan.org/STRONGSWAN-RELEASE-PGP-KEY | gpg --homedir "$g" --import >/dev/null 2>&1
    gpg --homedir "$g" --verify "$t.sig" "$t" >/dev/null 2>&1 || { rm -rf "$g"; warn "bad signature for $v"; return 1; }
  fi
  rm -rf "$g"
}
build() {
  local v=$1 log=$SRC/build-$1.log
  tar xjf "$SRC/strongswan-$v.tar.bz2" -C "$SRC"
  echo "building strongSwan $v with $JOBS job(s) (log: $log)"
  (cd "$SRC/strongswan-$v" && ./configure $(cat "$KIT/vendor/configure-options.txt") &&
     make -j"$JOBS" && make install) > "$log" 2>&1 || { warn "build of $v failed, see $log"; return 1; }
  ldconfig
}
build_source() {
  local want=${1:-} v versions=()
  "${APT[@]}" install systemd build-essential libgmp-dev libssl-dev libsystemd-dev pkg-config \
    libcurl4-openssl-dev libldap2-dev libpam0g-dev >/dev/null
  mkdir -p "$SRC"
  local free; free=$(df -Pm "$SRC" | awk 'NR == 2 {print $4}')
  ((free >= 1500)) || die "need 1.5 GB free disk in $SRC to build strongSwan (have ${free} MB)"
  # Memory: ~700 MB per compile job; add temporary swap on small servers
  local mem swap; mem=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo); swap=$(awk '/SwapTotal/ {print int($2 / 1024)}' /proc/meminfo)
  JOBS=$(( mem / 700 )); ((JOBS >= 1)) || JOBS=1; ((JOBS <= $(nproc))) || JOBS=$(nproc)
  local tmpswap=""
  if ((mem < 1500 && swap < 1024)); then
    tmpswap=/swapfile.swanstrap
    fallocate -l 1G $tmpswap 2>/dev/null || dd if=/dev/zero of=$tmpswap bs=1M count=1024 status=none
    chmod 600 $tmpswap && mkswap $tmpswap >/dev/null && swapon $tmpswap || { rm -f $tmpswap; tmpswap=""; warn "couldn't add swap"; }
  fi
  if [ -n "$want" ]; then versions=("$want")
  else v=$(latest_version || true); [ -n "$v" ] && versions+=("$v"); [ "$v" = "$VENDOR_VER" ] || versions+=("$VENDOR_VER"); fi
  local ok=""
  for v in "${versions[@]}"; do
    fetch "$v" && build "$v" && { ok=$v; break; }
  done
  [ -n "$tmpswap" ] && { swapoff $tmpswap; rm -f $tmpswap; }
  [ -n "$ok" ] || die "couldn't build strongSwan (tried: ${versions[*]})"
  cp "$KIT/vendor/configure-options.txt" "$SRC/"
  install -m 644 "$KIT/system/no-distro-strongswan" /etc/apt/preferences.d/no-distro-strongswan
  mkdir -p $STATE; echo "source $ok" > $STATE/strongswan
}

install_strongswan() {
  local mode=${STRONGSWAN:-auto}
  if mlkem_ok; then echo "strongSwan with ML-KEM already installed"; return; fi
  case $mode in
    auto|package)
      if try_package && mlkem_ok; then mkdir -p $STATE; echo "package" > $STATE/strongswan; return; fi
      [ "$mode" = package ] && die "distro strongSwan with ML-KEM isn't available here (use STRONGSWAN=auto or source)"
      echo "distro strongSwan unavailable or without ML-KEM; building from source"; purge_package
      build_source ;;
    source)   purge_package; build_source ;;
    source=*) purge_package; build_source "${mode#source=}" ;;
    *) die "STRONGSWAN must be auto, package, source or source=<version>" ;;
  esac
  mlkem_ok || die "strongSwan installed but ML-KEM is not available"
}

# --- server files ----------------------------------------------------------------------
install_kit() {
  if [ "$KIT" != "$SHARE" ]; then
    rm -rf "$SHARE"; mkdir -p "$SHARE"
    tar -C "$KIT" --exclude=./.git --exclude=./ca --exclude=./site -cf - . | tar -C "$SHARE" -xf -
  fi
  chmod 755 "$SHARE/bin/swanstrap" "$SHARE/lib/"*.sh "$SHARE/bootstrap.sh" 2>/dev/null || true
  ln -sf "$SHARE/bin/swanstrap" /usr/local/sbin/swanstrap
  ln -sf "$SHARE/bin/swanstrap" /usr/local/sbin/pqvpn          # old name
}
install_site() {
  local site=$1
  [ -f "$site/server.conf" ] || die "no server.conf in $site"
  . "$site/server.conf"
  install -d -m 755 /etc/swanstrap /etc/swanctl/x509ca /etc/swanctl/x509 /etc/swanctl/private /etc/swanctl/conf.d $STATE
  install -m 644 "$site/server.conf" /etc/swanstrap/server.conf
  # Bundles don't know the login user of the new server: use whoever ran sudo
  if [ "${CLIENT_USER:-auto}" = auto ] || ! getent passwd "$CLIENT_USER" >/dev/null; then
    CLIENT_USER=${SUDO_USER:-root}
    sed -i "s/^CLIENT_USER=.*/CLIENT_USER=$CLIENT_USER/" /etc/swanstrap/server.conf
  fi
  install -m 644 "$site/pq-vpn-root-ca.crt" /etc/swanctl/x509ca/
  install -m 644 "$site/$SERVER_ID.crt" /etc/swanctl/x509/
  install -m 600 "$site/$SERVER_ID.key" /etc/swanctl/private/
  install -m 644 "$site/pq-vpn.conf" /etc/swanctl/conf.d/
  [ -d /etc/update-motd.d ] && install -m 755 "$SHARE/system/90-swanstrap" /etc/update-motd.d/
  install -d /etc/cron.weekly && install -m 755 "$SHARE/system/swanstrap-check-release" /etc/cron.weekly/
  /etc/cron.weekly/swanstrap-check-release || true
}
setup_firewall() {
  if command -v nft >/dev/null && systemctl is-enabled nftables >/dev/null 2>&1; then
    warn "nftables.service is enabled; if its config flushes the ruleset, run 'systemctl restart swanstrap-firewall' after it"
  fi
  "$SHARE/lib/firewall.sh" apply
  if has_systemd; then
    install -m 644 "$SHARE/system/swanstrap-firewall.service" /etc/systemd/system/
    systemctl daemon-reload; systemctl enable swanstrap-firewall >/dev/null 2>&1
  fi
}
start_vpn() {
  start_charon || die "strongSwan didn't start (check: journalctl -u $(svc_unit))"
  swanctl --load-all >/dev/null
  swanctl --list-conns | grep -q '^pq-vpn:' || die "VPN connection didn't load (check /etc/swanctl/conf.d/pq-vpn.conf)"
  swanctl --list-certs 2>/dev/null | grep -q 'has private key' ||
    die "server private key didn't load (AppArmor or permissions on /etc/swanctl/private?)"
  swanctl --list-algs | grep -q ML_KEM || die "charon does not offer ML-KEM"
}

# --- main ----------------------------------------------------------------------------------
case ${1:-} in
--base)
  preflight; wait_for_apt; base_packages ;;
--prepare)
  preflight; wait_for_apt; base_packages
  step "strongSwan with ML-KEM (post-quantum)"; install_strongswan ;;
--upgrade-strongswan)
  preflight; . /etc/swanstrap/server.conf
  if [ "$(cut -d' ' -f1 $STATE/strongswan 2>/dev/null)" = package ]; then
    wait_for_apt; "${APT[@]}" install --only-upgrade charon-systemd strongswan-swanctl >/dev/null
  else
    wait_for_apt; build_source
  fi
  start_vpn; echo "strongSwan now $(swanctl --version | awk '{print $NF}')" ;;
""|--site)
  SITE=${2:-$KIT/site}; [ -f "$SITE/server.conf" ] || die "no site found at $SITE (did you run bootstrap.sh?)"
  . "$SITE/server.conf"; [ "${CLIENT_USER:-auto}" = auto ] && CLIENT_USER=${SUDO_USER:-root}
  step "Installing $SERVER_NAME ($SERVER_ID, $SERVER_ADDR)"
  preflight; wait_for_apt; base_packages
  pub=$(curl -fsS -4 -m 10 https://api.ipify.org 2>/dev/null || true)
  [ -z "$pub" ] || [ "$pub" = "$SERVER_ADDR" ] ||
    warn "this host's public IP is $pub but the certificate is for $SERVER_ADDR"
  step "strongSwan with ML-KEM (post-quantum)"; install_strongswan
  step "Configuration and certificates"; install_kit; install_site "$SITE"
  step "Firewall and routing"; setup_firewall
  step "Starting VPN"; start_vpn
  /usr/local/sbin/swanstrap add-user "${FIRST_USER:-personal}"
  home=$(getent passwd "${CLIENT_USER:-root}" | cut -d: -f6)
  install -m 600 -o "${CLIENT_USER:-root}" "$SHARE/README.md" "$home/vpn-clients/README.md"
  step "Done"
  echo "  $SERVER_NAME is running strongSwan $(swanctl --version | awk '{print $NF}') with ML-KEM"
  echo "  Login files and passwords: $home/vpn-clients/   (guide: $home/vpn-clients/README.md)"
  echo "  Manage logins:             sudo swanstrap"
  echo "  REQUIRED: allow inbound UDP 500 and UDP 4500 in your cloud provider's firewall."
  echo "  Tip: reserve a static public IP; the certificate is tied to $SERVER_ADDR." ;;
*) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
