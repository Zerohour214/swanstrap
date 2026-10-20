# swanstrap

Bootstrap and operate a multi-region **IKEv2/IPsec remote-access VPN** with a **hybrid post-quantum key exchange**
(X25519 + ML-KEM-768, RFC 9370 / FIPS 203) on strongSwan 6, from a single Git repository.

```bash
git clone https://github.com/<you>/swanstrap.git
sudo ./swanstrap/bootstrap.sh --quick          # fresh Debian/Ubuntu VPS -> running VPN + CA in minutes
```

- **Idempotent bash.** No agents, no external control plane. State lives in this repo (`ca/`) and on each server.
- **Self-contained PKI.** One offline-able root CA. Its key is committed **encrypted** (PKCS#8, PBKDF2 + AES-256-CBC).
- **Full tunnel, dual stack.** `0.0.0.0/0` and `::/0`, with IPv6 leak protection. Policy-based IPsec (xfrm) with NAT-T, MOBIKE and IKE fragmentation.
- **Provider-agnostic.** Auto-detects OCI, AWS, GCP, Azure, DigitalOcean, Hetzner, Vultr and Linode. Anything else falls back to defaults.

---

## Table of contents

1. [Flow](#1-flow)
2. [Definitions](#2-definitions)
3. [Requirements and compatibility](#3-requirements-and-compatibility)
4. [Deploy](#4-deploy)
5. [Bootstrap internals](#5-bootstrap-internals)
6. [IKE / IPsec design](#6-ike--ipsec-design)
7. [PKI](#7-pki)
8. [Network design](#8-network-design)
9. [Multi-server operation](#9-multi-server-operation)
10. [Client provisioning](#10-client-provisioning)
11. [CLI reference](#11-cli-reference)
12. [Configuration reference](#12-configuration-reference)
13. [Security model](#13-security-model)
14. [Server layout](#14-server-layout)
15. [Operations](#15-operations)
16. [Troubleshooting](#16-troubleshooting)
17. [Code map and testing](#17-code-map-and-testing)

---

## 1. Flow

### Control plane (provisioning)

```
             ┌─────────────────────────────────────────────┐
             │ Git repo (private)                          │
             │  scripts · templates · vendor/strongSwan    │
             │  ca/ : root cert, ENCRYPTED root key,       │
             │        servers.tsv (inventory)              │
             └───────────────┬─────────────────────────────┘
                git clone    │                 ▲ git push (sync-kit)
                             ▼                 │
             ┌─────────────────────────────────────────────┐   swanstrap add-server
             │ CA server (first bootstrapped node)         │ ─────────────────────────┐
             │  /root/vpn-ca : CA key (encrypted), issued/ │   tar bundle:            │
             │  issues server + device certificates        │   kit + site/{conf,      │
             └─────────────────────────────────────────────┘        cert,key}          ▼
                                                             ┌──────────────────────────────┐
                                                             │ Member server (no CA key)    │
                                                             │  lib/install.sh              │
                                                             └──────────────────────────────┘
```

### Data plane (per client)

```
 client                                     VPN server (charon)                         Internet
   │ IKE_SA_INIT  UDP/500  KE=x25519 (+ADDKE1=mlkem768 offered)   │
   │────────────────────────────────────────────────────────────▶ │
   │ IKE_INTERMEDIATE      ML-KEM-768 exchange (RFC 9242/9370)    │   only if the client supports ML-KEM
   │◀────────────────────────────────────────────────────────────▶│
   │ IKE_AUTH     UDP/4500 server: RSA cert (SAN=IP)              │
   │                       client: EAP-MSCHAPv2 | RSA cert        │
   │                       CP: IPv4 + IPv6 virtual IP, DNS        │
   │ CHILD_SA  ESP-in-UDP/4500, TS 0.0.0.0/0, ::/0                │
   │═════════════════════════════════════════════════════════════▶│ xfrm decap → FORWARD → SNAT ──▶
```

### Bootstrap pipeline

```
 bootstrap.sh
  ├─ install.sh --base       preflight (OS, root, kernel xfrm/esp4), cloud-init wait, apt lock wait, base pkgs
  ├─ resolve settings        option > --config > detect (DMI → metadata → region table → geo-IP) > default
  ├─ validate                all inputs, before any further change
  ├─ CA                      restore: decrypt ca/*.key.enc (fail fast) | new: RSA-4096 root
  ├─ install.sh --prepare    strongSwan: distro pkg w/ ML-KEM → latest 6.x source (GPG) → vendored 6.1.0
  ├─ site/                   server cert, server.conf, pq-vpn.conf (from template)
  ├─ install.sh --site       kit → /usr/local/share/swanstrap, swanctl files, firewall, start, verify, first user
  └─ write back              ca/{crt,key.enc,servers.tsv} → commit + push (manual)
```

---

## 2. Definitions

| Term | Meaning |
|---|---|
| **Kit** | This repository. Installed on every server at `/usr/local/share/swanstrap` (without `.git` and `ca/`). |
| **CA server** | The node created by `bootstrap.sh`. Holds `/root/vpn-ca` and is the only node that can sign certificates (`add-device`, `add-server`). |
| **Member server** | A node installed from an `add-server` bundle. It has the root cert and its own leaf key, never the CA key. |
| **Site** | The per-server input to `install.sh`: `server.conf`, `pq-vpn-root-ca.crt`, `<id>.crt`, `<id>.key`, `pq-vpn.conf`. |
| **Inventory** | `servers.tsv`, the authoritative list of servers. Used for ID numbering, pool allocation and re-IP detection. |
| **Server ID** | `<provider>-<cc>-<city3>-<nn>` (regex `^[a-z0-9]+-[a-z]{2}-[a-z]{3}-[0-9]{2}$`), e.g. `oci-sg-sin-01`. Used for file names and certificate names. |
| **Display name** | `<PROVIDER>-PQ <City>`, e.g. `OCI-PQ Singapore`. The certificate CN and the VPN name on clients. |
| **User login** | EAP-MSCHAPv2 credential, scoped to **one server** (`/etc/swanctl/conf.d/pq-vpn-user-<name>.conf`). |
| **Device login** | Client certificate (`clientAuth`, SAN `<name>@pqvpn`). Valid on **all** servers. No CRL, so revocation means expiry. |
| **Hybrid PQ** | IKEv2 multiple key exchanges (RFC 9370): classical KE (X25519) + additional KE (ML-KEM-768). The keys are combined, so security is at least that of the stronger one. |

---

## 3. Requirements and compatibility

### Server

| Requirement | Detail |
|---|---|
| OS | Debian 12+, Ubuntu 22.04+ (apt). Others are refused in preflight. |
| Virtualization | KVM / full VM. OpenVZ is refused. LXC works only if the host provides xfrm. |
| Kernel | `xfrm_user`, `esp4`, `xt_policy` (checked via `/sys/module`, `modprobe`, `modules.builtin`) |
| Resources | Package install: trivial. Source build: ≥ 1.5 GB free disk; RAM-aware `make -j` (~700 MB/job); 1 GB temporary swap if RAM < 1.5 GB |
| Inbound | UDP 500, UDP 4500 (ESP/50 optional, only for clients not behind NAT) |
| Firewall | iptables (nft or legacy backend) or an active `ufw` |

**Tested** (fresh containers, `--privileged`):

| Image | strongSwan path | ML-KEM provider |
|---|---|---|
| Ubuntu 22.04 | source (latest 6.x) | `ml` plugin |
| Ubuntu 24.04 (strongswan.org blocked) | vendored 6.1.0 | `ml` plugin |
| Ubuntu 26.04 | distro 6.0.4 | `openssl` (OpenSSL 3.5) |
| Debian 12 + ufw active | source | `ml` plugin |
| Fedora 40 | refused in preflight | n/a |

### Clients

| Client | KE negotiated | IKE / ESP | Auth |
|---|---|---|---|
| strongSwan 6.x (Linux, Android app, macOS app) | **X25519 + ML-KEM-768** | AES-256-GCM / PRF-SHA384 | EAP or cert |
| Windows 10/11 built-in (after `.ps1`) | ECP-384 | AES-256 + SHA-384 / AES-256-GCM | EAP-MSCHAPv2 or machine cert |
| iOS / iPadOS / macOS built-in (`.mobileconfig`) | ECP-384 (group 20) | AES-256-GCM + SHA2-384 | EAP or cert |
| iOS manual setup | MODP-2048 (group 14) | AES-256 + SHA2-256 | EAP |

Windows and Apple native IKEv2 stacks don't implement RFC 9370 / ML-KEM. They get classical-only key exchange.

---

## 4. Deploy

### First node (CA server)

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/swanstrap.git          # fine-grained PAT, Contents: read
./swanstrap/bootstrap.sh --quick --dry-run                  # resolved settings + preflight; no changes, no root
sudo ./swanstrap/bootstrap.sh --quick                       # prompts for the CA passphrase if ca/ exists
```

Then:

1. Allow inbound **UDP 500/4500** in the provider's security list / security group.
2. Persist the CA and inventory: `cd swanstrap && git add ca && git commit -m "Bootstrap <id>" && git push`.
3. Fetch the client artifacts: `scp -r <user>@<ip>:~/vpn-clients .` (see [§10](#10-client-provisioning)).

### Modes

| Mode | Invocation | Interaction |
|---|---|---|
| Quick | `--quick` | None (only the CA passphrase prompt when restoring; avoid it with `--ca-passphrase-file`) |
| Guided | *(no mode flag)* | TTY prompts per value, with dependent values (ID, name, pool) re-derived after edits |
| Declarative | `--config file.env` (+ `--quick`) | None; fully reproducible |
| Plan | `--dry-run` | Prints the resolution table with each value's source, plus preflight. Exits without changes |

### Additional nodes

See [§9](#9-multi-server-operation).

---

## 5. Bootstrap internals

### Settings resolution

`option > --config > detected > default`, resolved per key. Each value's source is shown in the plan table
(`option`, `config`, `detected`, `derived`, `inventory`, `default`, `you`).

| Source | Mechanism |
|---|---|
| **Provider** | DMI (`/sys/class/dmi/id/{sys_vendor,chassis_asset_tag,bios_vendor,bios_version,product_name,board_vendor}`). Metadata alone is ambiguous because every cloud answers on `169.254.169.254`. |
| **Region** | Only the detected provider's endpoint is queried (OCI `/opc/v2/instance/` + `Authorization: Bearer Oracle`, AWS IMDSv2, GCP `Metadata-Flavor`, Azure `Metadata: true`, DO, Hetzner, Vultr). 2 s timeout each. |
| **City / country** | Built-in `provider\|region → City\|CC` table (~150 regions), then geo-IP (ip-api.com → ipinfo.io). Geo-IP often returns suburbs, so it's only the fallback. Values are transliterated to ASCII. |
| **Public IPv4** | Provider metadata (AWS, GCP, DO, Hetzner) → api.ipify.org → icanhazip.com → `ip route get` source address |
| **ID** | `<provider>-<cc>-<city3>-<next free nn in inventory>` |
| **Pool** | Next free `10.20.N.0/24` (N ≥ 20) that is not in the inventory **and** doesn't overlap any local route (VPC, Docker bridges) |
| **Re-run** | An inventory row matching the public IP (or `--id`) → reuse its ID and pool. A different IP → re-IP (certificate reissued). |

`--offline` disables internet lookups (metadata still used). `--no-detect` disables all detection.

### CA handling

| Condition | Action |
|---|---|
| `ca/` valid, `CA_MODE=auto\|restore` | Restore. The passphrase is verified **before** strongSwan is installed. The `.key.enc` is copied byte-for-byte, never re-encrypted, so no git churn. |
| `ca/` expired, `auto` | New CA (noted in the output). `restore` aborts. |
| `ca/` < 1 year left | Warning |
| `ca/` unreadable | Abort. Never silently treated as expired. |
| `--new-ca` | New RSA-4096 root. The old `ca/` is moved to `ca.old-<ts>/`. Passphrase: prompted twice (guided), `--ca-passphrase-file`, or generated (`--quick`, printed once and written to `CREDENTIALS.txt`). |

### strongSwan acquisition (`STRONGSWAN=auto`)

1. Distro candidate ≥ 6.0 → install `charon-systemd strongswan-swanctl strongswan-pki libstrongswan-{standard,extra}-plugins libcharon-extra-plugins`.
   It's accepted only if the **running** daemon lists `ML_KEM_*` (`swanctl --list-algs`), since ML-KEM may come from the `ml` plugin or from OpenSSL ≥ 3.5.
2. Otherwise, purge it and build the **latest 6.x** from download.strongswan.org. The tarball is GPG-verified against `vendor/STRONGSWAN-RELEASE-PGP-KEY` (falling back to the published key, with a warning).
3. If that fails or there's no network, use **`vendor/strongswan-6.1.0.tar.bz2`**.
4. Source installs are pinned against distro packages (`/etc/apt/preferences.d/no-distro-strongswan`). The mode is recorded in `/var/lib/swanstrap/strongswan`.

Configure flags: `vendor/configure-options.txt`
(`--enable-ml --enable-openssl --enable-systemd --enable-swanctl --enable-eap-{identity,mschapv2,tls,dynamic} --enable-farp --enable-dhcp --enable-curl --disable-stroke`).

### Robustness measures

`cloud-init status --wait`, `DPkg::Lock::Timeout=600`, `NEEDRESTART_SUSPEND=1`, `DEBIAN_FRONTEND=noninteractive`,
secrets only in tmpfs (`/run`), shredded on exit. Every step is idempotent: firewall rules are checked with `-C` before insertion, and re-runs overwrite generated files.

---

## 6. IKE / IPsec design

Generated from `templates/pq-vpn.conf.tmpl` into `/etc/swanctl/conf.d/pq-vpn.conf`.

### Proposals (server preference order)

| SA | Proposals |
|---|---|
| IKE | `aes256gcm16-prfsha384-x25519-ke1_mlkem768`, `aes256gcm16-prfsha384-ecp384`, `aes256-sha384-ecp384`, `aes256-sha256-ecp384`, `aes256-sha256-modp2048` |
| ESP | `aes256gcm16-x25519-ke1_mlkem768`, `aes256gcm16-ecp384`, `aes256gcm16`, `aes256-sha256` |

`ke1_mlkem768` = additional key exchange #1 (RFC 9370). Peers that don't support it match the next proposal.
No 3DES, SHA-1, MODP-1024 or other weak algorithms are accepted.

### Connections

| Name | Remote auth | Notes |
|---|---|---|
| `pq-vpn` | `pubkey` (cert chaining to `pq-vpn-root-ca.crt`) | Device logins |
| `pq-vpn-eap` | `eap-mschapv2`, `eap_id=%any` | Inherits `pq-vpn`; user logins |

charon chooses the connection during IKE_AUTH: if the client omits the AUTH payload, it selects the EAP connection.

### Parameters

| Parameter | Value |
|---|---|
| Local auth | `pubkey`, `id = <public IP>`, `send_cert = always` |
| Traffic selectors | local `0.0.0.0/0, ::/0` (full tunnel) |
| Virtual IPs | `pq-pool` (IPv4 /24) + `pq-pool6` (IPv6 /64), assigned via a CP payload, plus DNS |
| Rekey | IKE 4 h, CHILD 1 h; `reauth_time = 0` (no reauthentication) |
| DPD | 30 s, CHILD `dpd_action = clear` |
| `unique` | `replace` (a reconnect from the same identity replaces the old SA) |
| Fragmentation | `yes` (RFC 7383; needed for large certificate chains through UDP) |
| NAT-T / MOBIKE | strongSwan defaults (on) |
| Mode | Tunnel, policy-based (xfrm policies; no xfrm interfaces / route-based) |

---

## 7. PKI

| Object | Key | Validity | Subject / SAN | EKU / flags |
|---|---|---|---|---|
| Root CA | RSA-4096 | 10 y | `O=PQ-VPN, CN=PQ-VPN Root CA` | `CA:TRUE` |
| Server | RSA-3072 | 5 y | `C=<cc>, O=PQ-VPN, OU=<PROVIDER>, L=<City>, CN=<display name>`; SAN `IP:<addr>`, `DNS:<addr>` | `serverAuth`, `ikeIntermediate` (1.3.6.1.5.5.8.2.2, required by Windows) |
| Device | RSA-3072 | `days` (default 1825) | `O=PQ-VPN, OU=device, CN=<name>@pqvpn`; SAN `email:<name>@pqvpn` | `clientAuth` |

- Signatures: SHA-384 with RSA. All certificates are back-dated 24 h (`notBefore`) to tolerate client clock skew.
- The CA key at rest is PKCS#8 `ENCRYPTED PRIVATE KEY` (PBKDF2-HMAC-SHA256 + AES-256-CBC). It's decrypted only into `/run` (tmpfs) for signing, then shredded.
- Device bundles are PKCS#12 with `PBE-SHA1-3DES` / MAC SHA-1. That's a deliberate compatibility choice: it's the format both the Windows and iOS importers accept. The `.p12` is only a transport container, protected by a random install password.
- RSA is used rather than ECDSA for maximum native-client compatibility (Windows machine-cert auth, iOS `CertificateType`).
- No CRL/OCSP. Revocation equals expiry, so use short lifetimes for temporary devices.

---

## 8. Network design

### Addressing plan

| Item | Scheme | Example (`oci-sg-sin-01`) |
|---|---|---|
| Client IPv4 pool | `10.20.N.0/24`, N = 20, 21, … per server | `10.20.20.0/24` |
| Client IPv6 pool | `fd20:A:B::/64` derived from pool `10.A.B.0/24` (ULA) | `fd20:20:20::/64` |
| Client DNS | `DNS` setting | `1.1.1.1, 9.9.9.9` |
| Egress | SNAT (MASQUERADE) to the uplink address | `eth0` → `198.51.100.10` |

Pools are unique across servers (inventory) and are checked against local routes, so they don't collide with VPC or Docker ranges.

### Firewall (`lib/firewall.sh`)

**iptables mode** (default). Applied at boot by `swanstrap-firewall.service`
(`After=netfilter-persistent ufw docker`, `Before=strongswan`). ACCEPT rules are inserted **before** the first
REJECT/DROP in the chain (e.g. OCI's default `REJECT all`):

```
filter INPUT    -p udp -m multiport --dports 500,4500 -j ACCEPT
filter INPUT    -p esp -j ACCEPT
filter FORWARD  -s $POOL -m policy --dir in  --pol ipsec --proto esp -j ACCEPT
filter FORWARD  -d $POOL -m policy --dir out --pol ipsec --proto esp -j ACCEPT
nat    POSTROUTING -s $POOL -o $IF -m policy --dir out --pol none -j MASQUERADE
mangle FORWARD  -s $POOL -o $IF -m policy --dir in  --pol ipsec -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
mangle FORWARD  -d $POOL        -m policy --dir out --pol ipsec -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
```

- `--pol none` on MASQUERADE keeps traffic that is itself IPsec from being NAT'd.
- `xt_policy` binds FORWARD acceptance to packets that actually arrived through or leave via an SA.

**IPv6:**

| Server has global IPv6 + default route | Rules |
|---|---|
| Yes | ip6tables FORWARD policy accepts for `$POOL6` + NAT66 MASQUERADE out the v6 uplink; `net.ipv6.conf.all.forwarding=1` and `accept_ra=2` on the uplink (otherwise enabling forwarding drops SLAAC/RA routes) |
| No | `ip6tables -I FORWARD 1 -s $POOL6 -j REJECT --reject-with icmp6-adm-prohibited`. Clients receive a v6 address, so IPv6 can't leak around the tunnel, and the immediate reject makes Happy Eyeballs fall back to IPv4 |

**ufw mode** (ufw active): the same rules go into `/etc/ufw/before.rules` and `before6.rules` (`*nat` / `*mangle`
blocks at the top, `ufw-before-forward` / `ufw6-before-forward` rules after `# End required lines`), between
`# swanstrap BEGIN/END <tag>` markers, then `ufw reload`. No `iptables-persistent`, so ufw is never removed.

**sysctl:** `/etc/sysctl.d/99-swanstrap.conf` (`net.ipv4.ip_forward=1`, plus the IPv6 settings above).

---

## 9. Multi-server operation

### Inventory schema (`ca/servers.tsv`, TSV with header)

```
id  name  provider  country  city  region  address  pool  added
oci-sg-sin-01  OCI-PQ Singapore  OCI  SG  Singapore  ap-singapore-1  198.51.100.10  10.20.20.0/24  2026-10-20
```

### Adding a member server

```bash
# CA server: validates the ID/name/IP are unique, allocates the next pool, signs the server cert, updates the inventory
sudo swanstrap add-server aws-de-fra-01 Frankfurt eu-central-1 203.0.113.20
#   -> ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar   (kit + site/, contains the leaf private key)

scp ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar ubuntu@203.0.113.20:
ssh ubuntu@203.0.113.20 'tar xf swanstrap-aws-de-fra-01.tar && sudo ./swanstrap/lib/install.sh && rm -r swanstrap-aws-de-fra-01.tar swanstrap'

rm ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar           # the bundle holds a private key
sudo swanstrap sync-kit ~/swanstrap && (cd ~/swanstrap && git add ca && git commit -m "Add aws-de-fra-01" && git push)
```

| Concern | Behaviour |
|---|---|
| Trust | Every server presents a certificate under the same root, so clients trust all servers once the root is installed |
| Device certs | Valid on every server; `add-device … <server-id>` renders the client profile for a specific server |
| User logins | Per server (`add-user` on each) |
| Shared state | None at runtime. Servers are independent; the inventory matters only for provisioning |
| Replacing the CA server | `bootstrap.sh` on a new node with the same `ca/` and passphrase. Any node can become the CA server |

---

## 10. Client provisioning

`swanstrap add-user` / `add-device` write one self-contained artifact per platform to `~/vpn-clients/<Server-Name>/{users,devices}/`.

| Artifact | Contents | Effect on the client |
|---|---|---|
| `<name>-<Server>.ps1` (user) | Root cert (base64 DER) | Imports the root into `LocalMachine\Root`; `Add-VpnConnection -TunnelType Ikev2 -AuthenticationMethod Eap`; `Set-VpnConnectionIPsecConfiguration` AES256/SHA384/ECP384 + GCMAES256/ECP384 PFS |
| `<name>-<Server>.ps1` (device) | Root + PKCS#12 | As above, plus imports into `LocalMachine\My`; `-AuthenticationMethod MachineCertificate -AllUserConnection` |
| `<name>-<Server>.mobileconfig` (user) | `com.apple.security.root` + `com.apple.vpn.managed` | IKEv2, `AuthenticationMethod=None` + `ExtendedAuthEnabled=1` (EAP), IKE/Child SA AES-256-GCM / SHA2-384 / DH 20, PFS |
| `<name>-<Server>.mobileconfig` (device) | Root + `com.apple.security.pkcs12` + VPN | `AuthenticationMethod=Certificate`, `LocalIdentifier=<name>@pqvpn` |

Credentials are appended to `~/vpn-clients/CREDENTIALS.txt`.

**Windows:** `Set-ExecutionPolicy -Scope Process Bypass; .\<file>.ps1` in an elevated PowerShell. Windows' default
IKEv2 policy (3DES/SHA-1/DH2) is rejected by the server, so the `.ps1` (or the `Set-VpnConnectionIPsecConfiguration` call) is mandatory.

**iOS/macOS:** install the profile, then enable full trust for **PQ-VPN Root CA** (Settings → General → About → Certificate Trust Settings).

**strongSwan clients (PQ):** IKEv2, server = IP, remote ID = IP, CA = `ca/pq-vpn-root-ca.crt`, EAP or certificate.
They negotiate `ke1_mlkem768` automatically.

---

## 11. CLI reference

`swanstrap` (alias `pqvpn`) runs as root on a server and acts on that server (`/etc/swanstrap/server.conf`).

| Command | Node | Description |
|---|---|---|
| `add-user <name>` | any | Create an EAP user (random ~24-char secret) and render the artifacts. Idempotent: rebuilds the files and keeps the secret |
| `add-device <name> <windows\|ios> [days] [server-id]` | CA | Issue a client cert (prompts for the CA passphrase) and render the artifact for this or another inventory server |
| `remove <name>` | any | Delete a user (`swanctl --load-creds --clear`) or a device record and artifacts on all servers. The cert stays valid until expiry |
| `list` | any | Inventory, users, devices with expiry, active IKE SAs |
| `add-server <id> <City> <region> <ipv4>` | CA | Register, allocate a pool, sign, and build the bundle |
| `sync-kit <repo-dir>` | CA | Copy `/root/vpn-ca/{crt,key.enc,servers.tsv}` into `<repo>/ca/` |
| `upgrade-strongswan` | any | Source: rebuild the latest 6.x. Package: `apt --only-upgrade`. Then restart and verify ML-KEM |
| `firewall` | any | Show the uplink, IPv6 and ufw state and the relevant rules |

Names match `^[a-z0-9-]+$`.

---

## 12. Configuration reference

`bootstrap.sh --config FILE` takes `KEY=value` lines (shell-style quotes allowed, `#` comments, unknown keys rejected).
Template: `config.example.env`.

| Key | Option | Default | Validation |
|---|---|---|---|
| `SERVER_ADDR` | `--ip` | detected | IPv4 |
| `PROVIDER` | `--provider` | detected / `VPS` | `[A-Z0-9]+` |
| `REGION` | `--region` | detected / `unknown` | `[A-Za-z0-9._-]+` |
| `CITY` | `--city` | detected / `Server` | ASCII after transliteration |
| `COUNTRY` | `--country` | detected / `XX` | ISO 3166 alpha-2 |
| `SERVER_ID` | `--id` | derived | see §2 |
| `SERVER_NAME` | `--name` | `<PROVIDER>-PQ <City>` | ASCII, no quotes or commas |
| `POOL` | `--pool` | next free `10.20.N.0/24` | `10.X.Y.0/24` |
| `DNS` | `--dns` | `1.1.1.1, 9.9.9.9` | comma-separated IPs |
| `FIRST_USER` | `--user` | `personal` | `[a-z0-9-]+` |
| `CLIENT_USER` | `--client-user` | `$SUDO_USER` / `root` | existing user |
| `STRONGSWAN` | `--strongswan` | `auto` | `auto\|package\|source\|source=X.Y.Z` |
| `CA_MODE` | `--new-ca` | `auto` | `auto\|restore\|new` |
| `OFFLINE` | `--offline` | `0` | `1` disables internet lookups |

Flags without a key: `--quick`, `--dry-run`, `--yes`, `--no-detect`, `--ca-passphrase-file FILE`.

---

## 13. Security model

| Asset | Protection | Location | Compromise impact |
|---|---|---|---|
| CA passphrase | Never written to the repo or to disk (except `CREDENTIALS.txt` in `--quick` new-CA mode) | Operator | Together with the repo: issue arbitrary server/device certs |
| CA private key | PKCS#8 AES-256 + PBKDF2 | `ca/`, `/root/vpn-ca` (0600) | Useless without the passphrase |
| Server leaf key | 0600 root | `/etc/swanctl/private/` on that node | Impersonation of that server only |
| EAP secrets | 0600 root | `/etc/swanctl/conf.d/pq-vpn-user-*.conf` | That user, that server |
| Device `.p12` | Random install password | Artifact only (key not kept on the server) | That device until expiry |
| Bundles | Contain a leaf key | Transient, on the CA server | Delete after install |

Controls:

- `.gitignore`, plus a **pre-commit hook** (`hooks/pre-commit`, enabled via `core.hooksPath`) that rejects `*.key`, `*.p12`,
  `*.ps1`, `*.mobileconfig`, `*.tar`, `*.env`, `CREDENTIALS*` and any staged unencrypted PEM key or literal `secret = "…"`.
- Secrets are handled only in tmpfs, shredded on exit, and passed to `openssl` via environment variables (`env:`), never on the
  command line (which any local user can read from the process list).
- Downloads are GPG-verified. The vendored source is verified at bootstrap time too.
- **Known limits:** no revocation (CRL/OCSP); EAP-MSCHAPv2 relies on the outer IKE SA (server-authenticated) for protection;
  native Windows/iOS clients get no PQ protection; anyone with repo access and the passphrase controls the PKI.

---

## 14. Server layout

| Path | Purpose |
|---|---|
| `/etc/swanstrap/server.conf` | Node identity + settings (sourced by every tool) |
| `/etc/swanctl/conf.d/pq-vpn.conf` | Rendered connection config |
| `/etc/swanctl/conf.d/pq-vpn-user-<name>.conf` | One EAP secret per file (0600) |
| `/etc/swanctl/{x509ca,x509,private}/` | Root cert, leaf cert, leaf key |
| `/root/vpn-ca/` | CA server only: `pq-vpn-root-ca.{crt,key.enc}`, `servers.tsv`, `issued/{servers,devices}/` |
| `/usr/local/share/swanstrap/` | Installed kit; `/usr/local/sbin/{swanstrap,pqvpn}` symlink here |
| `/usr/local/src/strongswan/` | Source tree, tarballs, `build-<ver>.log` (source mode) |
| `/var/lib/swanstrap/` | `strongswan` (install mode + version), `latest-version` |
| `/etc/systemd/system/swanstrap-firewall.service` | Firewall at boot (iptables mode) |
| `/etc/sysctl.d/99-swanstrap.conf` | Forwarding sysctls |
| `/etc/update-motd.d/90-swanstrap` | Login warnings: certs expiring < 60 days, newer strongSwan (source mode) |
| `/etc/cron.weekly/swanstrap-check-release` | Polls download.strongswan.org |
| `/etc/apt/preferences.d/no-distro-strongswan` | Pin (source mode) |
| `~<CLIENT_USER>/vpn-clients/` | Artifacts, `CREDENTIALS.txt`, `ca-backup/`, README |

Services: `strongswan` (or `strongswan-swanctl` with distro packages; detected) and `swanstrap-firewall`.

---

## 15. Operations

| Task | Procedure |
|---|---|
| Status | `sudo swanstrap list`; `sudo swanctl --list-sas`; `sudo swanctl --list-pools` |
| Logs | `journalctl -u strongswan -f` |
| Reload config / creds | `sudo swanctl --load-all` (no SA teardown) |
| Kick a session | `sudo swanctl --terminate --ike-id <id>` |
| Verify PQ is offered | `sudo swanctl --list-algs \| grep ML_KEM` |
| Verify a PQ SA | `sudo swanctl --list-sas`: the IKE SA's key exchange line lists ML-KEM-768 in addition to X25519 |
| Upgrade strongSwan | `sudo swanstrap upgrade-strongswan` |
| Re-apply the firewall | `sudo systemctl restart swanstrap-firewall` |
| Public IP changed | CA server: `sudo ./bootstrap.sh --quick --id <id>` (reissues the cert for the new IP). Member: `add-server` again. Then re-render client artifacts (`add-user`) |
| Leaf certificates expiring | The login banner warns 60 days ahead. Re-run bootstrap / add-server (servers); issue new device certs (devices) |
| Root CA rotation | `bootstrap.sh --new-ca`; redeploy artifacts to every client and rebuild member servers |
| Keep the repo authoritative | `sudo swanstrap sync-kit ~/swanstrap`, then commit and push after `add-server` / `add-device` |

---

## 16. Troubleshooting

| Symptom (client / `journalctl -u strongswan`) | Cause | Fix |
|---|---|---|
| Timeout, nothing logged | UDP 500/4500 blocked upstream | Cloud firewall / security group |
| `NO_PROPOSAL_CHOSEN` | Client proposals outside the accepted set (Windows defaults) | Run the `.ps1` / `Set-VpnConnectionIPsecConfiguration` |
| `AUTH_FAILED`, Windows 13801 | Root not in `LocalMachine\Root`, or SAN/EKU mismatch | Re-run the `.ps1` elevated; the server cert must have SAN = the connect address |
| iOS "Unable to validate server certificate" | Root not fully trusted | Certificate Trust Settings |
| `EAP_MSCHAPV2 failed` | Wrong secret | `CREDENTIALS.txt`; `add-user` re-renders the files |
| SA up, no traffic | FORWARD/NAT rules missing, or `ip_forward=0` | `swanstrap firewall`; `sysctl net.ipv4.ip_forward`; restart `swanstrap-firewall` |
| Large transfers stall | PMTU / MSS | Check the mangle TCPMSS rules |
| No IPv6 on the client | Server has no v6 uplink (by design: reject) | Expected; IPv4 is used through the tunnel |
| Bootstrap: kernel lacks IPsec | OpenVZ / LXC / stripped kernel | Use a KVM instance |
| Bootstrap: build failed | New upstream build deps | `build-<ver>.log`; `--strongswan source=6.1.0` |
| Bootstrap: wrong CA passphrase | Mismatch | Retry; if lost, use `--new-ca` (PKI rotation) |

---

## 17. Code map and testing

```
bootstrap.sh                  entry point: arg/config parsing, resolution, validation, CA, orchestration
lib/common.sh                 die/warn/step, validators, IPv4 CIDR math, pool allocator, inventory (TSV upsert),
                              issue_server_cert, new_ca, write_server_conf, render_conf
lib/detect.sh                 detect_provider (DMI), detect_region / detect_public_ip (per-provider metadata),
                              region_city (static table), geo_city, ascii (iconv translit)
lib/install.sh                --base | --prepare | --site DIR | --upgrade-strongswan:
                              preflight, apt hygiene, strongSwan (package/source), install_kit, install_site,
                              setup_firewall, start_vpn (verifies conn, key, ML-KEM)
lib/firewall.sh               apply | status : iptables or ufw, IPv4 + IPv6, sysctls
bin/swanstrap                 operator CLI; renders .ps1/.mobileconfig; add-server bundling
templates/pq-vpn.conf.tmpl    swanctl config (@SERVER_ID@ @SERVER_ADDR@ @SERVER_NAME@ @POOL@ @POOL6@ @DNS@)
system/                       motd, weekly release check, firewall unit, apt pin
vendor/                       strongSwan 6.1.0 tarball + .sig + release key + configure flags
ca/                           root cert, encrypted root key, inventory
hooks/pre-commit              secret scanner
```

**Conventions:** `set -euo pipefail`; all mutating operations are idempotent; validation happens before mutation; temp secrets in
`/run`; no Python or other runtime dependencies beyond coreutils, iproute2, openssl, curl and gettext.

**Testing:** each change is exercised in fresh `--privileged` containers (Ubuntu 22.04/24.04/26.04, Debian 12 with ufw,
Fedora for refusal), covering new-CA, restore, wrong passphrase, offline build, guided mode (expect), bundle install
and device issuance. Containers lack systemd, so `install.sh` starts `charon-systemd` directly there.
Use `--dry-run` for quick plan checks without root.
