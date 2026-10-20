# swanstrap shared helpers. Sourced by bootstrap.sh, lib/install.sh and bin/swanstrap.
# shellcheck shell=bash

die()  { echo "swanstrap: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
step() { echo; echo "==> $*"; }

INV_HEADER=$'id\tname\tprovider\tcountry\tcity\tregion\taddress\tpool\tadded'

# --- validation --------------------------------------------------------------
valid_id()   { [[ $1 =~ ^[a-z0-9]+-[a-z]{2}-[a-z]{3}-[0-9]{2}$ ]]; }
valid_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do ((o <= 255)) || return 1; done
}
# Client pool: a /24 inside 10.0.0.0/8 (keeps the IPv6 pool mapping simple)
valid_pool() { [[ $1 =~ ^10\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] && valid_ipv4 "${1%/24}"; }
valid_text() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9\ .\'-]*$ ]]; }   # names/cities: ASCII, no quotes/commas
valid_cc()   { [[ $1 =~ ^[A-Z]{2}$ ]]; }
valid_dns()  { [[ $1 =~ ^[0-9a-fA-F.:]+(,\ ?[0-9a-fA-F.:]+)*$ ]]; }

# IPv6 pool derived from the IPv4 pool: 10.A.B.0/24 -> fd20:A:B::/64 (unique per server)
pool6_for() { local a b; IFS=. read -r _ a b _ <<< "${1%/24}"; echo "fd20:$a:$b::/64"; }

# --- IPv4 range math (for avoiding pools that overlap local networks) --------
ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
cidr_range() {  # prints "first last"
  local ip=${1%/*} len=${1#*/}; [ "$len" = "$1" ] && len=32
  local n; n=$(ip2int "$ip"); local size=$(( 1 << (32 - len) ))
  local first=$(( n & ~(size - 1) & 0xFFFFFFFF )); echo "$first $(( first + size - 1 ))"
}
cidr_overlap() {
  local a1 a2 b1 b2; read -r a1 a2 <<< "$(cidr_range "$1")"; read -r b1 b2 <<< "$(cidr_range "$2")"
  (( a1 <= b2 && b1 <= a2 ))
}
# True if the pool overlaps any local IPv4 route except the default route
route_overlaps() {
  local net
  while read -r net _; do
    [ "$net" = default ] && continue
    [[ $net =~ ^[0-9.]+(/[0-9]+)?$ ]] || continue
    cidr_overlap "$1" "$net" && return 0
  done < <(ip -4 route show table all 2>/dev/null | awk '$1 != "broadcast" && $1 != "local" {print $1}'; \
           ip -4 route show table local 2>/dev/null | awk '$1 == "local" {print $2}')
  return 1
}

# --- inventory (servers.tsv) -------------------------------------------------
inv_pools() { [ -f "$1" ] && awk -F'\t' 'NR > 1 {print $8}' "$1"; }
# Next free 10.20.<n>.0/24 (n >= 20) not in the inventory and not overlapping local routes
next_pool() {
  local inv=$1 n p
  for ((n = 20; n <= 254; n++)); do
    p=10.20.$n.0/24
    inv_pools "$inv" | grep -qxF "$p" && continue
    route_overlaps "$p" && continue
    echo "$p"; return
  done
  die "no free client pool in 10.20.20-254.0/24"
}
# Next free two-digit number for an id prefix like oci-sg-sin
next_nn() {
  local inv=$1 prefix=$2 n id
  for ((n = 1; n <= 99; n++)); do
    printf -v id '%s-%02d' "$prefix" "$n"
    [ -f "$inv" ] && awk -F'\t' -v i="$id" 'NR > 1 && $1 == i {f = 1} END {exit !f}' "$inv" && continue
    printf '%02d\n' "$n"; return
  done
  die "no free number for $prefix"
}
inv_get() { [ -f "$1" ] && awk -F'\t' -v i="$2" 'NR > 1 && $1 == i' "$1"; }
# Insert or update a server row (keyed by id)
inv_upsert() {  # inv id name provider country city region address pool
  local inv=$1; shift
  [ -s "$inv" ] || echo "$INV_HEADER" > "$inv"
  local row; row=$(printf '%s\t' "$@" "$(date +%F)"); row=${row%$'\t'}
  awk -F'\t' -v i="$1" -v r="$row" 'BEGIN {OFS = FS} NR > 1 && $1 == i {print r; f = 1; next} {print} END {if (!f) print r}' \
    "$inv" > "$inv.new" && mv "$inv.new" "$inv"
}

# --- certificates --------------------------------------------------------------
# strongSwan's pki takes dates in local time, format "%d.%m.%y %T"; back-date 1 day
# so devices with a slightly slow clock don't reject a brand-new certificate.
not_before() { date -d '-1 day' '+%d.%m.%y %T'; }

# issue_server_cert <ca.key> <ca.crt> <out.key> <out.crt>   (uses SERVER_* vars)
issue_server_cert() {
  pki --gen --type rsa --size 3072 --outform pem > "$3"
  pki --req --type priv --in "$3" --dn "C=$COUNTRY, O=PQ-VPN, OU=$PROVIDER, L=$CITY, CN=$SERVER_NAME" \
      --san "$SERVER_ADDR" --san "@$SERVER_ADDR" --outform pem |
    pki --issue --cacert "$2" --cakey "$1" --type pkcs10 --not-before "$(not_before)" --lifetime 1825 \
      --flag serverAuth --flag ikeIntermediate --outform pem > "$4"
}

# Create a new root CA: new_ca <out.key> <out.crt>
new_ca() {
  pki --gen --type rsa --size 4096 --outform pem > "$1"
  pki --self --ca --lifetime 3650 --not-before "$(not_before)" --in "$1" --type rsa \
      --dn "O=PQ-VPN, CN=PQ-VPN Root CA" --outform pem > "$2"
}

# --- site files -----------------------------------------------------------------
# write_server_conf <file>   (uses SERVER_* / setting vars)
write_server_conf() {
  cat > "$1" <<EOF
# Identity of THIS VPN server (swanstrap). Naming scheme:
#   SERVER_ID   <provider>-<country ISO>-<city code>-<nn>   files, cert names
#   SERVER_NAME <PROVIDER>-PQ <City>                         name shown on devices
SERVER_ID=$SERVER_ID
SERVER_NAME="$SERVER_NAME"
PROVIDER="$PROVIDER"
COUNTRY=$COUNTRY
CITY="$CITY"
REGION="$REGION"
SERVER_ADDR=$SERVER_ADDR
POOL=$POOL
POOL6=$(pool6_for "$POOL")
DNS="$DNS"
CA_NAME="PQ-VPN Root CA"
FIRST_USER=$FIRST_USER
CLIENT_USER=$CLIENT_USER
STRONGSWAN=$STRONGSWAN
EOF
}

# render_conf <template> <out>
render_conf() {
  sed -e "s|@SERVER_ID@|$SERVER_ID|g" -e "s|@SERVER_NAME@|$SERVER_NAME|g" -e "s|@SERVER_ADDR@|$SERVER_ADDR|g" \
      -e "s|@POOL@|$POOL|g" -e "s|@POOL6@|$(pool6_for "$POOL")|g" -e "s|@DNS@|$DNS|g" "$1" > "$2"
  ! grep -q '@[A-Z0-9_]*@' "$2" || die "unfilled placeholder in $2"
}
