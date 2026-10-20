#!/bin/bash
# swanstrap bootstrap: turn a fresh Debian/Ubuntu VPS into a PQ-VPN server with its own CA.
#
#   sudo ./bootstrap.sh --quick           detect everything; no questions (except the CA passphrase when restoring)
#   sudo ./bootstrap.sh                   guided: review detected values, Enter accepts, type to change
#   sudo ./bootstrap.sh --config FILE     settings from a KEY=value file (see config.example.env)
#   ./bootstrap.sh --dry-run [options]    show resolved settings and checks; change nothing
#
# Options (override the config file and detection):
#   --id ID              server id, provider-country-city-nn (e.g. aws-de-fra-01)
#   --name NAME          name shown on devices (e.g. "AWS-PQ Frankfurt")
#   --provider P --country CC --city CITY --region R --ip IPV4
#   --pool 10.X.Y.0/24   client address pool          --dns "1.1.1.1, 9.9.9.9"
#   --user NAME          first username login          --client-user USER   owner of ~/vpn-clients
#   --strongswan auto|package|source|source=VERSION
#   --new-ca             create a new CA even if the kit has one (devices need new profiles)
#   --ca-passphrase-file FILE   CA passphrase from the first line of FILE
#   --offline            no internet lookups (IP / geo); cloud metadata is still used
#   --no-detect          no detection at all: only options, config file and defaults
#   --yes                skip the final confirmation
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
. "$KIT/lib/common.sh"; . "$KIT/lib/detect.sh"

KEYS=(PROVIDER COUNTRY CITY REGION SERVER_ADDR SERVER_ID SERVER_NAME POOL DNS FIRST_USER CLIENT_USER STRONGSWAN CA_MODE)
declare -A VAL=() SRC=() OPT=() CONF=()
MODE=guided DRY=0 YES=0 NODETECT=0 CONFIG="" PASSFILE=""; OFFLINE=0

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
need() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    --quick) MODE=quick ;;          --dry-run) DRY=1 ;;        --yes|-y) YES=1 ;;
    --offline) OFFLINE=1 ;;         --no-detect) NODETECT=1 ;; --new-ca) OPT[CA_MODE]=new ;;
    --config) need "$@"; CONFIG=$2; shift ;;
    --ca-passphrase-file) need "$@"; PASSFILE=$2; shift ;;
    --id) need "$@"; OPT[SERVER_ID]=$2; shift ;;        --name) need "$@"; OPT[SERVER_NAME]=$2; shift ;;
    --provider) need "$@"; OPT[PROVIDER]=$2; shift ;;   --country) need "$@"; OPT[COUNTRY]=$2; shift ;;
    --city) need "$@"; OPT[CITY]=$2; shift ;;           --region) need "$@"; OPT[REGION]=$2; shift ;;
    --ip) need "$@"; OPT[SERVER_ADDR]=$2; shift ;;      --pool) need "$@"; OPT[POOL]=$2; shift ;;
    --dns) need "$@"; OPT[DNS]=$2; shift ;;             --user) need "$@"; OPT[FIRST_USER]=$2; shift ;;
    --client-user) need "$@"; OPT[CLIENT_USER]=$2; shift ;;
    --strongswan) need "$@"; OPT[STRONGSWAN]=$2; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done
export OFFLINE

# --- config file: KEY=value lines (quotes optional); unknown keys are rejected -----------
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config file $CONFIG not found"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "bad line in $CONFIG: $line"
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}; v=${v%"${v##*[![:space:]]}"}
    [[ $v =~ ^\"(.*)\"$ || $v =~ ^\'(.*)\'$ ]] && v=${BASH_REMATCH[1]}
    case " ${KEYS[*]} OFFLINE " in *" $k "*) ;; *) die "unknown setting $k in $CONFIG (see config.example.env)" ;; esac
    if [ "$k" = OFFLINE ]; then [ "$v" = 1 ] && OFFLINE=1; continue; fi
    CONF[$k]=$v
  done < "$CONFIG"
fi

# set <key> <value> <source>: only if no higher-priority source already set it
given() {  # option > config
  local k=$1
  if [ -n "${OPT[$k]+x}" ]; then VAL[$k]=${OPT[$k]}; SRC[$k]=option; return 0; fi
  if [ -n "${CONF[$k]+x}" ]; then VAL[$k]=${CONF[$k]}; SRC[$k]=config; return 0; fi
  return 1
}
put() { if [ -n "$2" ]; then VAL[$1]=$2; SRC[$1]=$3; fi; }

# Real runs install the base tools (curl, openssl, iconv...) first: detection and the CA
# checks need them, and minimal images don't have them. Dry runs never change anything.
if [ $DRY = 0 ]; then
  [ "$(id -u)" = 0 ] || die "run with sudo (or use --dry-run)"
  "$KIT/lib/install.sh" --base
fi
for t in curl openssl; do command -v $t >/dev/null || warn "$t is not installed: detection/CA checks are limited (dry run)"; done

# --- CA mode and inventory ------------------------------------------------------------------
KCA=$KIT/ca
ca_end() {  # the kit CA's expiry date; an unreadable certificate is an error, never "expired"
  command -v openssl >/dev/null || die "openssl is needed to check the kit CA"
  openssl x509 -in "$KCA/pq-vpn-root-ca.crt" -noout -enddate 2>/dev/null | cut -d= -f2 | grep . ||
    die "can't read $KCA/pq-vpn-root-ca.crt (corrupt?); fix it or use --new-ca"
}
given CA_MODE || put CA_MODE auto default
CA_NOTE=""
if [ "${VAL[CA_MODE]}" != new ] && [ -f "$KCA/pq-vpn-root-ca.key.enc" ] && [ -f "$KCA/pq-vpn-root-ca.crt" ]; then
  CA_END=$(ca_end)
  if ! openssl x509 -in "$KCA/pq-vpn-root-ca.crt" -noout -checkend 0 >/dev/null 2>&1; then
    [ "${VAL[CA_MODE]}" = restore ] && die "the kit's CA expired on $CA_END; use --new-ca"
    put CA_MODE new detected; CA_NOTE="kit CA has expired; creating a new one"
  else
    put CA_MODE restore "${SRC[CA_MODE]/default/detected}"
    openssl x509 -in "$KCA/pq-vpn-root-ca.crt" -noout -checkend 31536000 >/dev/null 2>&1 ||
      CA_NOTE="kit CA expires $CA_END; plan a new CA within a year"
  fi
elif [ "${VAL[CA_MODE]}" = restore ]; then
  die "CA_MODE=restore but the kit has no ca/pq-vpn-root-ca.{crt,key.enc}"
else
  put CA_MODE new "${SRC[CA_MODE]/default/detected}"
fi
INV=$(mktemp); trap 'rm -f "$INV"' EXIT
[ "${VAL[CA_MODE]}" = restore ] && [ -f "$KCA/servers.tsv" ] && cp "$KCA/servers.tsv" "$INV"

# --- detection + defaults ---------------------------------------------------------------------
resolve_base() {
  local prov="" region="" ip="" rc="" city="" cc=""
  if [ $NODETECT = 0 ]; then
    prov=$(detect_provider || true)
    [ -n "$prov" ] && region=$(detect_region "$prov" || true)
    given SERVER_ADDR || ip=$(detect_public_ip "$prov" || true)
    [ -n "$region" ] && rc=$(region_city "$prov" "$region" || true)
    [ -z "$rc" ] && ! { given CITY && given COUNTRY; } && [ -n "${ip:-${VAL[SERVER_ADDR]:-}}" ] &&
      rc=$(geo_city "${ip:-${VAL[SERVER_ADDR]}}" || true)
    city=${rc%%|*}; cc=${rc##*|}
  fi
  given PROVIDER    || { put PROVIDER "$prov" detected;   [ -n "${VAL[PROVIDER]:-}" ] || put PROVIDER VPS default; }
  given REGION      || { put REGION "$region" detected;   [ -n "${VAL[REGION]:-}" ] || put REGION unknown default; }
  given SERVER_ADDR || put SERVER_ADDR "$ip" detected
  given CITY        || { put CITY "$city" detected;       [ -n "${VAL[CITY]:-}" ] || put CITY Server default; }
  given COUNTRY     || { put COUNTRY "$cc" detected;      [ -n "${VAL[COUNTRY]:-}" ] || put COUNTRY XX default; }
  given DNS         || put DNS "1.1.1.1, 9.9.9.9" default
  given FIRST_USER  || put FIRST_USER personal default
  given CLIENT_USER || { put CLIENT_USER "${SUDO_USER:-}" detected; [ -n "${VAL[CLIENT_USER]:-}" ] || put CLIENT_USER root default; }
  given STRONGSWAN  || put STRONGSWAN auto default
  VAL[PROVIDER]=${VAL[PROVIDER]^^}; VAL[COUNTRY]=${VAL[COUNTRY]^^}; VAL[CITY]=$(ascii "${VAL[CITY]}")
}
# ID, name and pool follow from the base values unless set explicitly
resolve_derived() {
  # The inventory row for this server: by explicit id (re-IP), else by address (re-run)
  local row="" a=${VAL[SERVER_ADDR]:-}
  given SERVER_ID && row=$(inv_get "$INV" "${VAL[SERVER_ID]}")
  [ -z "$row" ] && [ -n "$a" ] && row=$(awk -F'\t' -v a="$a" 'NR > 1 && $7 == a' "$INV" | head -1)
  if [ -n "$row" ] && [ "$(cut -f7 <<< "$row")" != "$a" ]; then
    CA_NOTE="${CA_NOTE:+$CA_NOTE; }server $(cut -f1 <<< "$row") moves from $(cut -f7 <<< "$row") to $a (certificate reissued)"
  fi
  local p c3 prefix
  p=$(tr -cd 'a-z0-9' <<< "${VAL[PROVIDER],,}"); c3=$(tr -cd 'a-z' <<< "${VAL[CITY],,}"); c3=${c3}xxx; c3=${c3:0:3}
  prefix=$p-${VAL[COUNTRY],,}-$c3
  if ! given SERVER_ID; then
    if [ -n "$row" ]; then put SERVER_ID "$(cut -f1 <<< "$row")" inventory
    else put SERVER_ID "$prefix-$(next_nn "$INV" "$prefix")" derived; fi
  fi
  given SERVER_NAME || put SERVER_NAME "${VAL[PROVIDER]}-PQ ${VAL[CITY]}" derived
  if ! given POOL; then
    if [ -n "$row" ]; then put POOL "$(cut -f8 <<< "$row")" inventory
    else put POOL "$(next_pool "$INV")" derived; fi
  fi
}
validate() {
  local e=()
  valid_ipv4 "${VAL[SERVER_ADDR]:-}"   || e+=("SERVER_ADDR '${VAL[SERVER_ADDR]:-}' is not an IPv4 address (use --ip)")
  valid_id "${VAL[SERVER_ID]}"         || e+=("SERVER_ID '${VAL[SERVER_ID]}' must look like aws-de-fra-01")
  valid_text "${VAL[SERVER_NAME]}"     || e+=("SERVER_NAME: ASCII letters, digits, spaces, . ' - only")
  valid_text "${VAL[CITY]}"            || e+=("CITY: ASCII letters, digits, spaces, . ' - only")
  [[ ${VAL[PROVIDER]} =~ ^[A-Z0-9]+$ ]] || e+=("PROVIDER: letters and digits only")
  valid_cc "${VAL[COUNTRY]}"           || e+=("COUNTRY: two letters (ISO code)")
  [[ ${VAL[REGION]} =~ ^[A-Za-z0-9._-]+$ ]] || e+=("REGION: letters, digits, . _ - only")
  valid_pool "${VAL[POOL]}"            || e+=("POOL must be 10.X.Y.0/24")
  valid_dns "${VAL[DNS]}"              || e+=("DNS: comma-separated IP addresses")
  [[ ${VAL[FIRST_USER]} =~ ^[a-z0-9-]+$ ]] || e+=("FIRST_USER: lowercase letters, digits, - only")
  [[ ${VAL[STRONGSWAN]} =~ ^(auto|package|source|source=[0-9.]+)$ ]] || e+=("STRONGSWAN: auto, package, source or source=VERSION")
  [[ ${VAL[CA_MODE]} =~ ^(auto|new|restore)$ ]] || e+=("CA_MODE: auto, new or restore")
  awk -F'\t' -v i="${VAL[SERVER_ID]}" -v a="${VAL[SERVER_ADDR]:-}" 'NR > 1 && $7 == a && $1 != i {f = 1} END {exit !f}' "$INV" &&
    e+=("address ${VAL[SERVER_ADDR]} already belongs to another server in the inventory")
  if ((${#e[@]})); then printf '  - %s\n' "${e[@]}" >&2; return 1; fi
}
show() {
  printf '\n  %-12s %-34s %s\n' SETTING VALUE SOURCE
  local k; for k in "${KEYS[@]}"; do printf '  %-12s %-34s %s\n' "$k" "${VAL[$k]:-<none>}" "${SRC[$k]:-}"; done
  [ -n "$CA_NOTE" ] && echo "  note: $CA_NOTE"
  echo
}

[ $NODETECT = 1 ] || echo "Detecting server details..."
resolve_base; resolve_derived

if [ "$MODE" = guided ] && [ $DRY = 0 ]; then
  [ -t 0 ] || die "guided mode needs a terminal; use --quick or --config"
  show
  echo "Press Enter to keep a value, or type a new one."
  for k in PROVIDER COUNTRY CITY REGION SERVER_ADDR; do
    read -rp "  $k [${VAL[$k]:-}]: " v; [ -n "$v" ] && { VAL[$k]=$v; SRC[$k]=you; OPT[$k]=$v; }
  done
  VAL[PROVIDER]=${VAL[PROVIDER]^^}; VAL[COUNTRY]=${VAL[COUNTRY]^^}
  for k in SERVER_ID SERVER_NAME POOL; do given $k || unset "VAL[$k]" "SRC[$k]"; done
  resolve_derived
  for k in SERVER_ID SERVER_NAME POOL DNS FIRST_USER; do
    read -rp "  $k [${VAL[$k]}]: " v; [ -n "$v" ] && { VAL[$k]=$v; SRC[$k]=you; }
  done
fi

show
validate || die "fix the settings above (options, --config file, or guided mode)"

# --- dry run: report checks and stop ------------------------------------------------------------
if [ $DRY = 1 ]; then
  echo "Checks (nothing changed):"
  . /etc/os-release; echo "  OS:        $PRETTY_NAME"
  for m in xfrm_user esp4 xt_policy; do
    { [ -d /sys/module/$m ] || modprobe -nq $m 2>/dev/null; } && s=ok || s=MISSING; echo "  kernel:    $m $s"
  done
  echo "  memory:    $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) MB   disk free: $(df -Pm / | awk 'NR==2 {print $4}') MB"
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' && echo "  firewall:  ufw active (rules go into ufw)" ||
    echo "  firewall:  iptables (+ swanstrap-firewall.service)"
  echo "  pool:      ${VAL[POOL]} (IPv6 $(pool6_for "${VAL[POOL]}"))$(route_overlaps "${VAL[POOL]}" && echo '  OVERLAPS A LOCAL ROUTE')"
  if [ "${VAL[CA_MODE]}" = restore ]; then
    echo "  CA:        restore from $KCA (valid until $CA_END)"
  else echo "  CA:        create new"; fi
  exit 0
fi

if [ "$MODE" = guided ] && [ $YES = 0 ]; then
  read -rp "Install $([ "${VAL[CA_MODE]}" = new ] && echo 'with a NEW CA' || echo 'restoring the kit CA') now? [Y/n] " a
  [[ ${a:-y} =~ ^[Yy] ]] || die "aborted"
fi
for k in "${KEYS[@]}"; do declare "$k=${VAL[$k]}"; done
export STRONGSWAN

# --- 2. CA: check a restored CA's passphrase before the (possibly long) strongSwan install -------
TMP=$(mktemp -d /run/swanstrap.XXXXXX)
trap 'find "$TMP" -type f -exec shred -u {} +; rm -rf "$TMP" "$INV"' EXIT
step "Certificate authority"
GENERATED_PW=""
read_pass() { if [ -n "$PASSFILE" ]; then head -n1 "$PASSFILE"; else read -rsp "$1" p; echo >&2; echo "$p"; fi; }
if [ "$CA_MODE" = restore ]; then
  [ -n "$PASSFILE" ] || [ -t 0 ] || die "restoring the CA needs its passphrase: run in a terminal or use --ca-passphrase-file"
  for try in 1 2 3; do
    CAPW=$(read_pass "CA passphrase: "); export CAPW   # openssl reads it via env:, never argv
    openssl pkey -in "$KCA/pq-vpn-root-ca.key.enc" -passin env:CAPW -out "$TMP/ca.key" 2>/dev/null && break
    [ -n "$PASSFILE" ] || [ $try = 3 ] && die "wrong CA passphrase (nothing was changed except base packages)"
    echo "wrong passphrase, try again"
  done
  cp "$KCA/pq-vpn-root-ca.crt" "$TMP/ca.crt"
  echo "restored CA: $(openssl x509 -in "$TMP/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
else
  if [ -n "$PASSFILE" ]; then CAPW=$(head -n1 "$PASSFILE")
  elif [ "$MODE" = quick ]; then CAPW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28); GENERATED_PW=$CAPW
  else
    while :; do
      CAPW=$(read_pass "New CA passphrase (12+ characters): "); p2=$(read_pass "Repeat: ")
      [ "$CAPW" = "$p2" ] && [ ${#CAPW} -ge 12 ] && break; echo "didn't match or too short"
    done
  fi
  [ ${#CAPW} -ge 12 ] || die "CA passphrase must be at least 12 characters"
  export CAPW
fi

# --- 3. strongSwan with ML-KEM (also provides 'pki' for certificates) ------------------------------
"$KIT/lib/install.sh" --prepare
if [ "$CA_MODE" = new ]; then
  new_ca "$TMP/ca.key" "$TMP/ca.crt"
  echo "created CA: $(openssl x509 -in "$TMP/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
  echo "$INV_HEADER" > "$INV"
fi

# /root/vpn-ca: the CA working copy on this server (a new CA replaces any old one)
CA=/root/vpn-ca
if [ -d $CA ] && ! cmp -s "$TMP/ca.crt" $CA/pq-vpn-root-ca.crt; then mv $CA "$CA.old-$(date +%Y%m%d%H%M%S)"; fi
install -d -m 700 $CA $CA/issued $CA/issued/servers $CA/issued/devices
install -m 600 "$TMP/ca.crt" $CA/pq-vpn-root-ca.crt
if [ "$CA_MODE" = restore ]; then   # keep the kit's file byte-identical (re-encrypting changes it)
  install -m 600 "$KCA/pq-vpn-root-ca.key.enc" $CA/pq-vpn-root-ca.key.enc
else
  openssl pkey -in "$TMP/ca.key" -aes256 -passout env:CAPW -out $CA/pq-vpn-root-ca.key.enc
fi
inv_upsert "$INV" "$SERVER_ID" "$SERVER_NAME" "$PROVIDER" "$COUNTRY" "$CITY" "$REGION" "$SERVER_ADDR" "$POOL"
install -m 600 "$INV" $CA/servers.tsv

# --- 4. this server's certificate + site files, then the full install ------------------------------
step "Server certificate for $SERVER_NAME ($SERVER_ADDR)"
SITE=$TMP/site; mkdir -p "$SITE"
issue_server_cert "$TMP/ca.key" "$TMP/ca.crt" "$SITE/$SERVER_ID.key" "$SITE/$SERVER_ID.crt"
install -m 600 "$SITE/$SERVER_ID.crt" $CA/issued/servers/
cp "$TMP/ca.crt" "$SITE/pq-vpn-root-ca.crt"
write_server_conf "$SITE/server.conf"
render_conf "$KIT/templates/pq-vpn.conf.tmpl" "$SITE/pq-vpn.conf"
"$KIT/lib/install.sh" --site "$SITE"

# --- 5. save the CA + inventory back into the kit ----------------------------------------------------
OWNER=$(stat -c %U "$KIT")
if [ "$CA_MODE" = new ] && [ -f "$KCA/pq-vpn-root-ca.crt" ]; then
  mv "$KCA" "$KIT/ca.old-$(date +%Y%m%d%H%M%S)"     # keep the replaced CA (still in git history too)
fi
install -d -o "$OWNER" "$KCA"
install -m 644 -o "$OWNER" $CA/pq-vpn-root-ca.crt $CA/pq-vpn-root-ca.key.enc $CA/servers.tsv "$KCA/"
[ -d "$KIT/.git" ] && runuser -u "$OWNER" -- git -C "$KIT" config core.hooksPath hooks

HOME_C=$(getent passwd "$CLIENT_USER" | cut -d: -f6)
if [ -n "$GENERATED_PW" ]; then
  echo "[CA] passphrase (needed for add-device, add-server, rebuilds): $GENERATED_PW" >> "$HOME_C/vpn-clients/CREDENTIALS.txt"
fi
mkdir -p "$HOME_C/vpn-clients/ca-backup"
cp $CA/pq-vpn-root-ca.key.enc $CA/servers.tsv "$HOME_C/vpn-clients/ca-backup/"
chown -R "$CLIENT_USER": "$HOME_C/vpn-clients"; chmod -R go-rwx "$HOME_C/vpn-clients"

step "Bootstrap complete: $SERVER_NAME ($SERVER_ID)"
[ -n "$CA_NOTE" ] && echo "  note: $CA_NOTE"
if [ -n "$GENERATED_PW" ]; then
  echo
  echo "  NEW CA PASSPHRASE: $GENERATED_PW"
  echo "  Store it in a password manager now. Without it you can't add devices, servers, or rebuild with this CA."
  echo "  (also saved in $HOME_C/vpn-clients/CREDENTIALS.txt; delete that file once stored)"
fi
cat <<EOF

  Save the CA (encrypted) + inventory to your repo:
    cd $KIT && git add ca && git commit -m "Bootstrap $SERVER_ID" && git push

  Then download your login files:  scp -r $CLIENT_USER@$SERVER_ADDR:~/vpn-clients .
EOF
