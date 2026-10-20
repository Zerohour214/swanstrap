# swanstrap auto-detection: provider, region, public IP, city/country.
# Every lookup has a short timeout and fails silently; callers fall back to defaults.
# Set OFFLINE=1 to skip internet services (metadata and hardware info are still used).
# shellcheck shell=bash

MD=169.254.169.254
md() { curl -fsS -m 2 "$@" 2>/dev/null; }           # metadata / lookup request
json_field() { grep -o "\"$1\" *: *\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"$//'; }

# Provider from hardware (DMI) info. All clouds share 169.254.169.254, so the metadata
# service alone can't tell them apart (e.g. OCI answers AWS's token request with 405).
detect_provider() {
  local d=/sys/class/dmi/id f all=""
  for f in sys_vendor chassis_asset_tag bios_vendor bios_version product_name board_vendor; do
    all+=" $(cat "$d/$f" 2>/dev/null)"
  done
  case "${all,,}" in
    *oraclecloud*)                       echo OCI ;;
    *amazon*)                            echo AWS ;;
    *google*)                            echo GCP ;;
    *7783-7084-3265-9085-8269-3286-77*|*microsoft*) echo AZURE ;;
    *digitalocean*)                      echo DO ;;
    *hetzner*)                           echo HETZNER ;;
    *vultr*)                             echo VULTR ;;
    *linode*|*akamai*)                   echo LINODE ;;
  esac
}

aws_token() { md -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "http://$MD/latest/api/token"; }

detect_region() {
  local t
  case $1 in
    OCI)     md -H 'Authorization: Bearer Oracle' "http://$MD/opc/v2/instance/" | json_field canonicalRegionName ;;
    AWS)     t=$(aws_token) && md -H "X-aws-ec2-metadata-token: $t" "http://$MD/latest/meta-data/placement/region" ;;
    GCP)     md -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/zone" |
               sed 's|.*/||; s/-[a-z]$//' ;;
    AZURE)   md -H 'Metadata: true' "http://$MD/metadata/instance/compute/location?api-version=2021-02-01&format=text" ;;
    DO)      md "http://$MD/metadata/v1/region" ;;
    HETZNER) md "http://$MD/hetzner/v1/metadata/availability-zone" | sed 's/-dc[0-9]*$//' ;;
    VULTR)   md "http://$MD/v1.json" | json_field regioncode | tr 'A-Z' 'a-z' ;;
  esac
}

detect_public_ip() {
  local ip="" t
  case $1 in
    AWS)     t=$(aws_token) && ip=$(md -H "X-aws-ec2-metadata-token: $t" "http://$MD/latest/meta-data/public-ipv4") ;;
    GCP)     ip=$(md -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip") ;;
    DO)      ip=$(md "http://$MD/metadata/v1/interfaces/public/0/ipv4/address") ;;
    HETZNER) ip=$(md "http://$MD/hetzner/v1/metadata/public-ipv4") ;;
  esac
  valid_ipv4 "$ip" || ip=""
  if [ -z "$ip" ] && [ "${OFFLINE:-0}" != 1 ]; then
    ip=$(md -4 https://api.ipify.org) ; valid_ipv4 "$ip" || ip=$(md -4 https://icanhazip.com | tr -d '[:space:]')
    valid_ipv4 "$ip" || ip=""
  fi
  # Last resort: the address on the default route (correct on servers without NAT)
  [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2)
  echo "$ip"
}

# City/country for well-known cloud regions: "City|CC". Geo-IP is only a fallback,
# because it often returns suburbs or the provider's registered office.
region_city() {
  awk -F'|' -v p="$1" -v r="$2" '$1 == p && $2 == r {print $3 "|" $4; exit}' <<'EOF'
OCI|ap-singapore-1|Singapore|SG
OCI|ap-singapore-2|Singapore|SG
OCI|ap-tokyo-1|Tokyo|JP
OCI|ap-osaka-1|Osaka|JP
OCI|ap-seoul-1|Seoul|KR
OCI|ap-chuncheon-1|Chuncheon|KR
OCI|ap-mumbai-1|Mumbai|IN
OCI|ap-hyderabad-1|Hyderabad|IN
OCI|ap-sydney-1|Sydney|AU
OCI|ap-melbourne-1|Melbourne|AU
OCI|eu-frankfurt-1|Frankfurt|DE
OCI|eu-amsterdam-1|Amsterdam|NL
OCI|eu-zurich-1|Zurich|CH
OCI|eu-milan-1|Milan|IT
OCI|eu-paris-1|Paris|FR
OCI|eu-marseille-1|Marseille|FR
OCI|eu-madrid-1|Madrid|ES
OCI|eu-stockholm-1|Stockholm|SE
OCI|uk-london-1|London|GB
OCI|uk-cardiff-1|Cardiff|GB
OCI|us-ashburn-1|Ashburn|US
OCI|us-phoenix-1|Phoenix|US
OCI|us-sanjose-1|San Jose|US
OCI|us-chicago-1|Chicago|US
OCI|ca-toronto-1|Toronto|CA
OCI|ca-montreal-1|Montreal|CA
OCI|sa-saopaulo-1|Sao Paulo|BR
OCI|sa-vinhedo-1|Vinhedo|BR
OCI|sa-santiago-1|Santiago|CL
OCI|sa-bogota-1|Bogota|CO
OCI|mx-queretaro-1|Queretaro|MX
OCI|mx-monterrey-1|Monterrey|MX
OCI|me-dubai-1|Dubai|AE
OCI|me-abudhabi-1|Abu Dhabi|AE
OCI|me-jeddah-1|Jeddah|SA
OCI|il-jerusalem-1|Jerusalem|IL
OCI|af-johannesburg-1|Johannesburg|ZA
AWS|us-east-1|Ashburn|US
AWS|us-east-2|Columbus|US
AWS|us-west-1|San Francisco|US
AWS|us-west-2|Portland|US
AWS|ca-central-1|Montreal|CA
AWS|ca-west-1|Calgary|CA
AWS|sa-east-1|Sao Paulo|BR
AWS|mx-central-1|Queretaro|MX
AWS|eu-west-1|Dublin|IE
AWS|eu-west-2|London|GB
AWS|eu-west-3|Paris|FR
AWS|eu-central-1|Frankfurt|DE
AWS|eu-central-2|Zurich|CH
AWS|eu-north-1|Stockholm|SE
AWS|eu-south-1|Milan|IT
AWS|eu-south-2|Zaragoza|ES
AWS|ap-south-1|Mumbai|IN
AWS|ap-south-2|Hyderabad|IN
AWS|ap-southeast-1|Singapore|SG
AWS|ap-southeast-2|Sydney|AU
AWS|ap-southeast-3|Jakarta|ID
AWS|ap-southeast-4|Melbourne|AU
AWS|ap-southeast-5|Kuala Lumpur|MY
AWS|ap-southeast-7|Bangkok|TH
AWS|ap-northeast-1|Tokyo|JP
AWS|ap-northeast-2|Seoul|KR
AWS|ap-northeast-3|Osaka|JP
AWS|ap-east-1|Hong Kong|HK
AWS|me-south-1|Manama|BH
AWS|me-central-1|Dubai|AE
AWS|il-central-1|Tel Aviv|IL
AWS|af-south-1|Cape Town|ZA
GCP|asia-southeast1|Singapore|SG
GCP|asia-southeast2|Jakarta|ID
GCP|asia-east1|Changhua|TW
GCP|asia-east2|Hong Kong|HK
GCP|asia-northeast1|Tokyo|JP
GCP|asia-northeast2|Osaka|JP
GCP|asia-northeast3|Seoul|KR
GCP|asia-south1|Mumbai|IN
GCP|asia-south2|Delhi|IN
GCP|australia-southeast1|Sydney|AU
GCP|australia-southeast2|Melbourne|AU
GCP|europe-west1|Saint-Ghislain|BE
GCP|europe-west2|London|GB
GCP|europe-west3|Frankfurt|DE
GCP|europe-west4|Eemshaven|NL
GCP|europe-west6|Zurich|CH
GCP|europe-west8|Milan|IT
GCP|europe-west9|Paris|FR
GCP|europe-west10|Berlin|DE
GCP|europe-west12|Turin|IT
GCP|europe-north1|Hamina|FI
GCP|europe-central2|Warsaw|PL
GCP|europe-southwest1|Madrid|ES
GCP|us-central1|Council Bluffs|US
GCP|us-east1|Moncks Corner|US
GCP|us-east4|Ashburn|US
GCP|us-east5|Columbus|US
GCP|us-south1|Dallas|US
GCP|us-west1|The Dalles|US
GCP|us-west2|Los Angeles|US
GCP|us-west3|Salt Lake City|US
GCP|us-west4|Las Vegas|US
GCP|northamerica-northeast1|Montreal|CA
GCP|northamerica-northeast2|Toronto|CA
GCP|southamerica-east1|Sao Paulo|BR
GCP|southamerica-west1|Santiago|CL
GCP|me-west1|Tel Aviv|IL
GCP|me-central1|Doha|QA
GCP|me-central2|Dammam|SA
GCP|africa-south1|Johannesburg|ZA
AZURE|southeastasia|Singapore|SG
AZURE|eastasia|Hong Kong|HK
AZURE|japaneast|Tokyo|JP
AZURE|japanwest|Osaka|JP
AZURE|koreacentral|Seoul|KR
AZURE|australiaeast|Sydney|AU
AZURE|australiasoutheast|Melbourne|AU
AZURE|centralindia|Pune|IN
AZURE|southindia|Chennai|IN
AZURE|westeurope|Amsterdam|NL
AZURE|northeurope|Dublin|IE
AZURE|uksouth|London|GB
AZURE|ukwest|Cardiff|GB
AZURE|francecentral|Paris|FR
AZURE|germanywestcentral|Frankfurt|DE
AZURE|switzerlandnorth|Zurich|CH
AZURE|norwayeast|Oslo|NO
AZURE|polandcentral|Warsaw|PL
AZURE|italynorth|Milan|IT
AZURE|spaincentral|Madrid|ES
AZURE|canadacentral|Toronto|CA
AZURE|brazilsouth|Sao Paulo|BR
AZURE|uaenorth|Dubai|AE
AZURE|southafricanorth|Johannesburg|ZA
DO|nyc1|New York|US
DO|nyc2|New York|US
DO|nyc3|New York|US
DO|sfo2|San Francisco|US
DO|sfo3|San Francisco|US
DO|atl1|Atlanta|US
DO|tor1|Toronto|CA
DO|ams3|Amsterdam|NL
DO|lon1|London|GB
DO|fra1|Frankfurt|DE
DO|sgp1|Singapore|SG
DO|blr1|Bangalore|IN
DO|syd1|Sydney|AU
HETZNER|fsn1|Falkenstein|DE
HETZNER|nbg1|Nuremberg|DE
HETZNER|hel1|Helsinki|FI
HETZNER|ash|Ashburn|US
HETZNER|hil|Hillsboro|US
HETZNER|sin|Singapore|SG
EOF
}

# Geo-IP fallback: "City|CC" for an IP (ASCII city), empty if unknown or offline
geo_city() {
  [ "${OFFLINE:-0}" = 1 ] && return
  local j city cc
  j=$(md "http://ip-api.com/json/$1?fields=status,city,countryCode")
  city=$(json_field city <<< "$j"); cc=$(json_field countryCode <<< "$j")
  if [ -z "$city" ]; then
    j=$(md "https://ipinfo.io/$1/json"); city=$(json_field city <<< "$j"); cc=$(json_field country <<< "$j")
  fi
  [ -n "$city" ] && [ -n "$cc" ] && echo "$(ascii "$city")|$cc"
}

# ASCII-only text for IDs, DNs and file names ("São Paulo" -> "Sao Paulo")
ascii() { iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null <<< "$1" | tr -cd "A-Za-z0-9 .'-" ; }
