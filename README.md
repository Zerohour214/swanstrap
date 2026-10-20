# swanstrap

Your own **post-quantum VPN** (strongSwan 6, IKEv2/IPsec, hybrid X25519 + ML-KEM-768), set up on any
Debian/Ubuntu server with one command and rebuilt from this repository whenever you need it.

| Part | For | Read when |
|---|---|---|
| **[Part 1: User guide](#part-1-user-guide)** | Anyone | You want the VPN running and your devices connected |
| **[Part 2: Technical reference](#part-2-technical-reference)** | Software / network engineers | You want to know how it works, change it, or debug it |

---

# Part 1: User guide

1. [Before you start](#1-before-you-start)
2. [Set up the server](#2-set-up-the-server)
3. [Open the firewall](#3-open-the-firewall)
4. [Get your login files](#4-get-your-login-files)
5. [Connect your devices](#5-connect-your-devices)
6. [Check that it works](#6-check-that-it-works)
7. [Everyday tasks](#7-everyday-tasks)
8. [Keep these safe](#8-keep-these-safe)
9. [Quick fixes](#9-quick-fixes)

## 1. Before you start

You need:

| ✔ | What | Notes |
|---|---|---|
| ☐ | A **VPS** running **Ubuntu 22.04+** or **Debian 12+** | Any provider. Must be a full VM (KVM). OpenVZ/LXC won't work. 1 vCPU / 1 GB RAM is enough. |
| ☐ | **SSH access** with `sudo` (or as root) | |
| ☐ | Access to your **cloud provider's firewall** | To open 2 UDP ports ([step 3](#3-open-the-firewall)) |
| ☐ | A **GitHub token** to clone this private repo | GitHub → Settings → Developer settings → **Fine-grained tokens** → *Only select repositories: swanstrap* → *Contents: Read and write* |
| ☐ | Your **CA passphrase** (if you already have one) | Lets devices you set up before keep working. No passphrase? Add `--new-ca` in step 2. |

> **Tip:** reserve a **static public IP** for the server at your provider. The VPN is tied to the server's IP.

## 2. Set up the server

SSH into the server and run:

```bash
# 1. Get the kit (password prompt = paste your GitHub token)
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Zerohour214/swanstrap.git
git config --global user.name  "Your Name"                                     # needed to save
git config --global user.email "<id>+<username>@users.noreply.github.com"      # (step 4)

# 2. Preview what will happen (changes nothing)
./swanstrap/bootstrap.sh --quick --dry-run

# 3. Install (asks for the CA passphrase)
sudo ./swanstrap/bootstrap.sh --quick
#    first time / no passphrase:  sudo ./swanstrap/bootstrap.sh --quick --new-ca

# 4. Save the result back to GitHub (asks for your GitHub token)
sudo swanstrap sync-kit ~/swanstrap --push
```

Step 3 takes **2–15 minutes**. It detects the provider, location and IP, installs strongSwan with post-quantum
support, sets up the server's own firewall, and creates a login called **`personal`**.
When it finishes it prints the server's name (for example **OCI-PQ Singapore**).

> Your GitHub no-reply email is under GitHub → Settings → Emails. To skip the token prompt next time:
> `git config --global credential.helper store` (stores the token in plain text on the server).

> With `--new-ca` it prints a **NEW CA PASSPHRASE**. Write it down now; see [section 8](#8-keep-these-safe).

Want different names or settings? Run `sudo ./swanstrap/bootstrap.sh` without `--quick` and it asks about each value,
or see [Configuration reference](#21-configuration-reference).

## 3. Open the firewall

The server's own firewall is configured automatically. **Your cloud provider's firewall is not**, so open these:

| Direction | Protocol | Port | Source | Why |
|---|---|---|---|---|
| Inbound | **UDP** | **500** | `0.0.0.0/0` | VPN handshake (IKE) |
| Inbound | **UDP** | **4500** | `0.0.0.0/0` | VPN traffic (works through home routers / NAT) |
| Inbound | ESP (IP protocol 50) | – | `0.0.0.0/0` | *Optional*: only used by devices **not** behind NAT |

Nothing else needs to be opened. Outbound traffic must be allowed (it is by default everywhere).

| Provider | Where | Command-line alternative |
|---|---|---|
| **Oracle (OCI)** | Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → **Add Ingress Rules** (Source CIDR `0.0.0.0/0`, IP Protocol **UDP**, Destination Port `500`, then again for `4500`) | |
| **AWS** | EC2 → Security Groups → the instance's group → **Edit inbound rules** → Custom UDP 500 and 4500 | `aws ec2 authorize-security-group-ingress --group-id <sg-id> --ip-permissions 'IpProtocol=udp,FromPort=500,ToPort=500,IpRanges=[{CidrIp=0.0.0.0/0}]' 'IpProtocol=udp,FromPort=4500,ToPort=4500,IpRanges=[{CidrIp=0.0.0.0/0}]'` |
| **Google Cloud** | VPC network → Firewall → **Create rule** → Ingress, targets: all instances, UDP 500, 4500 | `gcloud compute firewall-rules create swanstrap-ike --direction=INGRESS --allow=udp:500,udp:4500 --source-ranges=0.0.0.0/0` |
| **Azure** | VM → Networking → **Add inbound port rule** → UDP, ports `500,4500` | `az network nsg rule create -g <rg> --nsg-name <nsg> -n swanstrap-ike --priority 1000 --protocol Udp --destination-port-ranges 500 4500 --access Allow` |
| **DigitalOcean** | Networking → Firewalls → your firewall → Inbound → **Custom UDP** 500 and 4500 | |
| **Hetzner** | Firewalls → your firewall → **Add rule** → UDP 500 and 4500 | |
| **No cloud firewall** | Nothing to do | |

## 4. Get your login files

On **your computer** (not the server):

```bash
scp -r <user>@<server-ip>:~/vpn-clients .
```

You get:

```
vpn-clients/
├── CREDENTIALS.txt                              ← your VPN password (and the CA passphrase if --new-ca)
├── README.md                                    ← this guide
└── OCI-PQ-Singapore/                            ← one folder per server
    └── users/
        ├── personal-OCI-PQ-Singapore.ps1        ← for Windows
        └── personal-OCI-PQ-Singapore.mobileconfig  ← for iPhone, iPad, Mac
```

Your **username** is `personal`. The **password** is in `CREDENTIALS.txt`.

## 5. Connect your devices

### Windows 10 / 11

1. Copy `personal-<Server>.ps1` to the PC and open its folder in File Explorer.
2. Click the address bar, type `powershell`, press **Enter**. In that window run (opens an **Administrator** window in the same folder):
   ```powershell
   Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -Command cd '$PWD'"
   ```
3. In the **Administrator** window:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\personal-OCI-PQ-Singapore.ps1
   ```
4. **Settings → Network & internet → VPN → OCI-PQ Singapore → Connect.** Sign in with `personal` and your password.

### iPhone / iPad

1. Send `personal-<Server>.mobileconfig` to the phone (**AirDrop**, save to **iCloud Drive** and open in **Files**, or **email** it) and open it.
2. **Settings → Profile Downloaded → Install**, then enter your passcode and your **VPN password**.
3. **Settings → General → About → Certificate Trust Settings** → turn on **PQ-VPN Root CA** (only once per device).
4. **Settings → VPN** → turn on **OCI-PQ Singapore**.

### Mac

1. Double-click `personal-<Server>.mobileconfig`.
2. **System Settings → Privacy & Security → Profiles** (or **General → Device Management**) → double-click the profile → **Install**, enter your VPN password.
3. **System Settings → VPN** → turn on **OCI-PQ Singapore**.

### Android

Use the free **strongSwan VPN Client** app (Google Play / F-Droid). Builds based on strongSwan 6 use post-quantum encryption.

1. Copy `ca/pq-vpn-root-ca.crt` from this repo to the phone. In the app: **⋮ → CA certificates → ⋮ → Import certificate**.
2. **Add VPN profile**: Server = the server's IP, VPN type = **IKEv2 EAP (Username/Password)**, username `personal` + password.
   Under **Server identity** enter the server's IP. Save, then tap the profile to connect.

### Linux (post-quantum, strongSwan 6)

```bash
sudo apt-get install -y strongswan-swanctl charon-systemd libcharon-extra-plugins   # strongSwan >= 6.0; extra-plugins = EAP login
sudo cp pq-vpn-root-ca.crt /etc/swanctl/x509ca/              # from this repo's ca/ folder
sudo tee /etc/swanctl/conf.d/swanstrap.conf >/dev/null <<'EOF'
connections {
  swanstrap {
    version = 2
    remote_addrs = <server-ip>
    vips = 0.0.0.0, ::
    proposals = aes256gcm16-prfsha384-x25519-ke1_mlkem768
    local {
      auth = eap-mschapv2
      eap_id = personal
    }
    remote {
      auth = pubkey
      id = <server-ip>
    }
    children {
      swanstrap {
        remote_ts = 0.0.0.0/0, ::/0
        esp_proposals = aes256gcm16-x25519-ke1_mlkem768
      }
    }
  }
}
secrets {
  eap-personal {
    id = personal
    id-server = <server-ip>        # ties this password to this server (needed with several servers)
    secret = "<your password>"
  }
}
EOF
sudo swanctl --load-all && sudo swanctl --initiate --child swanstrap
sudo swanctl --list-sas            # look for CURVE_25519/KE1_ML_KEM_768 = post-quantum
```

More servers: add one `.conf` per server with its own connection/child name (e.g. `frankfurt`) and its own
`eap-…` secret block with that server's IP as `id-server` (each server has its own `personal` password).

> **Which devices get post-quantum?** Linux and Android with strongSwan 6. The VPN built into **Windows,
> iPhone and Mac** doesn't support ML-KEM yet; those devices use strong classical encryption (AES-256-GCM, ECP-384).

## 6. Check that it works

- On the device: search **"what is my IP"** in a browser. It should show the **server's IP**.
- On the server: `sudo swanstrap list` shows your device under **Connected now**.

## 7. Everyday tasks

Run on the server:

| I want to… | Command |
|---|---|
| See servers, logins, who's connected | `sudo swanstrap list` |
| Add a login for someone | `sudo swanstrap add-user alex` (password → `~/vpn-clients/CREDENTIALS.txt`) |
| Give a friend's phone access for 30 days | `sudo swanstrap add-device alex-phone ios 30` (or `windows`) |
| Remove a login | `sudo swanstrap remove alex` |
| Add a server in another country | [Adding a server](#18-multi-server-operation) |
| Update strongSwan | `sudo swanstrap upgrade-strongswan` |
| Help | `sudo swanstrap` |

After `add-user` / `add-device`, copy the new file from `~/vpn-clients/<Server>/` to the device and follow [step 5](#5-connect-your-devices).
`add-device` asks for the CA passphrase. Send a friend the **file** and the **install password** (in `CREDENTIALS.txt`) through
different channels.

## 8. Keep these safe

| What | Why | Where to keep it |
|---|---|---|
| **CA passphrase** | Needed to rebuild with the same CA, add devices, add servers. If lost: `--new-ca`, and every device needs new files | Password manager / written down offline. **Never in the repo** |
| **GitHub account** (+ 2FA recovery codes) | The repo is your backup | Password manager |
| `CREDENTIALS.txt` | Contains your passwords | Copy to your password manager, then **delete it on the server**: `rm ~/vpn-clients/CREDENTIALS.txt` |

After adding servers or devices, save the CA and inventory to GitHub:
`sudo swanstrap sync-kit ~/swanstrap --push` (commits only if something changed).

## 9. Quick fixes

| Problem | Fix |
|---|---|
| Device can't connect at all (times out) | UDP 500/4500 not open at your provider ([step 3](#3-open-the-firewall)) |
| Windows: error 13801, or "policy match error" | Re-run the `.ps1` in an **Administrator** PowerShell |
| iPhone: "Unable to validate server certificate" | Turn on **PQ-VPN Root CA** in Certificate Trust Settings |
| Wrong username / password | Username is `personal` (or the name you used); password in `CREDENTIALS.txt` |
| Connected, but no internet | On the server: `sudo systemctl restart swanstrap-firewall` |
| Stopped working after the server restarted | The public IP changed; reserve a static IP, then see [Operations](#24-operations) |
| Linux client: `EAP_IDENTITY not supported` | `sudo apt-get install -y libcharon-extra-plugins`, then restart strongSwan |
| `sync-kit --push` says git has no identity | Run the two `git config --global` lines from [step 2](#2-set-up-the-server) |
| `bootstrap.sh` says "kernel lacks IPsec support" | The VPS is OpenVZ/LXC; use a KVM VPS |
| `bootstrap.sh` says "wrong CA passphrase" | Retry. If lost: `--new-ca` |

More: [Troubleshooting (technical)](#25-troubleshooting).

---

# Part 2: Technical reference

10. [Flow](#10-flow)
11. [Definitions](#11-definitions)
12. [Requirements and compatibility](#12-requirements-and-compatibility)
13. [Bootstrap internals](#13-bootstrap-internals)
14. [IKE / IPsec design](#14-ike--ipsec-design)
15. [PKI](#15-pki)
16. [Network design](#16-network-design)
17. [Client artifacts](#17-client-artifacts)
18. [Multi-server operation](#18-multi-server-operation)
19. [CLI reference](#19-cli-reference)
20. [Bootstrap modes](#20-bootstrap-modes)
21. [Configuration reference](#21-configuration-reference)
22. [Security model](#22-security-model)
23. [Server layout](#23-server-layout)
24. [Operations](#24-operations)
25. [Troubleshooting](#25-troubleshooting)
26. [Code map and testing](#26-code-map-and-testing)

## 10. Flow

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

## 11. Definitions

| Term | Meaning |
|---|---|
| **Kit** | This repository. Installed on every server at `/usr/local/share/swanstrap` (without `.git` and `ca/`). |
| **CA server** | The node created by `bootstrap.sh`. Holds `/root/vpn-ca`; the only node that can sign certificates (`add-device`, `add-server`). |
| **Member server** | A node installed from an `add-server` bundle: has the root cert and its own leaf key, never the CA key. |
| **Site** | Per-server input to `install.sh`: `server.conf`, `pq-vpn-root-ca.crt`, `<id>.crt`, `<id>.key`, `pq-vpn.conf`. |
| **Inventory** | `servers.tsv`, the authoritative list of servers. Used for ID numbering, pool allocation and re-IP detection. Full copy (with IPs) on the CA server; the repo copy omits addresses ([§18](#18-multi-server-operation)). |
| **Server ID** | `<provider>-<cc>-<city3>-<nn>` (regex `^[a-z0-9]+-[a-z]{2}-[a-z]{3}-[0-9]{2}$`), e.g. `oci-sg-sin-01`. Used for file names and certificate names. |
| **Display name** | `<PROVIDER>-PQ <City>`, e.g. `OCI-PQ Singapore`. Certificate CN and the VPN name on clients. |
| **User login** | EAP-MSCHAPv2 credential, scoped to **one server** (`/etc/swanctl/conf.d/pq-vpn-user-<name>.conf`). |
| **Device login** | Client certificate (`clientAuth`, SAN `<name>@pqvpn`), valid on **all** servers. No CRL, so revocation means expiry. |
| **Hybrid PQ** | IKEv2 multiple key exchanges (RFC 9370): classical KE (X25519) + additional KE (ML-KEM-768). The derived keys depend on both, so security is at least that of the stronger one. |

## 12. Requirements and compatibility

### Server

| Requirement | Detail |
|---|---|
| OS | Debian 12+, Ubuntu 22.04+ (apt). Others are refused in preflight. |
| Virtualization | KVM / full VM. OpenVZ is refused. LXC works only if the host provides xfrm. |
| Kernel | `xfrm_user`, `esp4`, `xt_policy` (checked via `/sys/module`, `modprobe`, `modules.builtin`) |
| Resources | Package install: trivial. Source build: ≥ 1.5 GB free disk; RAM-aware `make -j` (~700 MB/job); temporary 1 GB swap if RAM < 1.5 GB |
| Inbound | UDP 500, UDP 4500 (ESP/50 optional, only for clients not behind NAT) |
| Host firewall | iptables (nft or legacy backend) or an active `ufw` |

**Tested** (fresh containers, `--privileged`):

| Image | strongSwan path | ML-KEM provider |
|---|---|---|
| Ubuntu 22.04 | source (latest 6.x) | `ml` plugin |
| Ubuntu 24.04 (strongswan.org blocked) | vendored 6.1.0 | `ml` plugin |
| Ubuntu 26.04 | distro 6.0.4 | `openssl` (OpenSSL 3.5) |
| Debian 12 + ufw active | source | `ml` plugin |
| Fedora 40 | refused in preflight | n/a |

**End-to-end** (3 containers on one network, every Part 1 command run as written): a Linux strongSwan 6.0.4 client
connected to a CA server (source 6.1.0) and a member server (distro 6.0.4) at the same time. Both negotiated
`CURVE_25519/KE1_ML_KEM_768` with EAP-MSCHAPv2 login and IPv4 + IPv6 virtual IPs; traffic was NAT'd out and client
IPv6 was refused through the tunnel. Generated `.ps1` files pass the PowerShell parser; `.mobileconfig` files parse as plists.

### Clients

| Client | KE negotiated | IKE / ESP | Auth |
|---|---|---|---|
| strongSwan 6.x (Linux; Android/macOS apps based on 6.x) | **X25519 + ML-KEM-768** | AES-256-GCM / PRF-SHA384 | EAP or cert |
| Windows 10/11 built-in (after `.ps1`) | ECP-384 | AES-256 + SHA-384 / AES-256-GCM | EAP-MSCHAPv2 or machine cert |
| iOS / iPadOS / macOS built-in (`.mobileconfig`) | ECP-384 (group 20) | AES-256-GCM + SHA2-384 | EAP or cert |
| iOS manual setup | MODP-2048 (group 14) | AES-256 + SHA2-256 | EAP |

Windows and Apple native IKEv2 stacks don't implement RFC 9370 / ML-KEM; they get classical-only key exchange.

## 13. Bootstrap internals

### Settings resolution

`option > --config > detected > default`, per key. The plan table (`--dry-run`) shows each value's source
(`option`, `config`, `detected`, `derived`, `inventory`, `default`, `you`).

| Value | Mechanism |
|---|---|
| **Provider** | DMI (`/sys/class/dmi/id/{sys_vendor,chassis_asset_tag,bios_vendor,bios_version,product_name,board_vendor}`). Metadata alone is ambiguous because every cloud answers on `169.254.169.254`. |
| **Region** | Only the detected provider's endpoint is queried (OCI `/opc/v2/instance/` + `Authorization: Bearer Oracle`, AWS IMDSv2, GCP `Metadata-Flavor`, Azure `Metadata: true`, DO, Hetzner, Vultr), 2 s timeout each. |
| **City / country** | Built-in `provider\|region → City\|CC` table (~150 regions), then geo-IP (ip-api.com → ipinfo.io). Geo-IP often returns suburbs, so it's only the fallback. Values are transliterated to ASCII. |
| **Public IPv4** | Provider metadata (AWS, GCP, DO, Hetzner) → api.ipify.org → icanhazip.com → `ip route get` source address |
| **ID** | `<provider>-<cc>-<city3>-<next free nn in inventory>` |
| **Pool** | Next free `10.20.N.0/24` (N ≥ 20) not in the inventory **and** not overlapping any local route (VPC, Docker bridges) |
| **Re-run** | An inventory row matching the public IP (or `--id`) → reuse its ID and pool. A different IP → re-IP (certificate reissued). |

`--offline` disables internet lookups (metadata still used). `--no-detect` disables all detection.

### CA handling

| Condition | Action |
|---|---|
| `ca/` valid, `CA_MODE=auto\|restore` | Restore. The passphrase is verified **before** strongSwan is installed. The `.key.enc` is copied byte-for-byte, never re-encrypted, so no git churn. |
| `ca/` expired, `auto` | New CA (noted in the output). `restore` aborts. |
| `ca/` < 1 year left | Warning |
| `ca/` unreadable | Abort. Never silently treated as expired. |
| `--new-ca` | New RSA-4096 root, overwriting `ca/` (the old CA stays in git history). Passphrase: prompted twice (guided), `--ca-passphrase-file`, or generated (`--quick`, printed once and written to `CREDENTIALS.txt`). |

### strongSwan acquisition (`STRONGSWAN=auto`)

1. Distro candidate ≥ 6.0 → install `charon-systemd strongswan-swanctl strongswan-pki libstrongswan-{standard,extra}-plugins libcharon-extra-plugins`.
   It's accepted only if the **running** daemon lists `ML_KEM_*` (`swanctl --list-algs`), since ML-KEM may come from the `ml` plugin or from OpenSSL ≥ 3.5.
2. Otherwise, purge it and build the **latest 6.x** from download.strongswan.org. The tarball is GPG-verified against `vendor/STRONGSWAN-RELEASE-PGP-KEY` (falling back to the published key, with a warning).
3. If that fails or there's no network, use **`vendor/strongswan-6.1.0.tar.bz2`**.
4. Source installs are pinned against distro packages (`/etc/apt/preferences.d/no-distro-strongswan`). The mode is recorded in `/var/lib/swanstrap/strongswan`.

Configure flags (`vendor/configure-options.txt`):
`--enable-ml --enable-openssl --enable-systemd --enable-swanctl --enable-eap-{identity,mschapv2,tls,dynamic} --enable-farp --enable-dhcp --enable-curl --disable-stroke`.

### Robustness

`cloud-init status --wait`, `DPkg::Lock::Timeout=600`, `NEEDRESTART_SUSPEND=1`, `DEBIAN_FRONTEND=noninteractive`.
Secrets live only in tmpfs (`/run`) and are shredded on exit. Every step is idempotent: firewall rules are checked with
`-C` before insertion, and re-runs overwrite generated files.

## 14. IKE / IPsec design

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
| Virtual IPs | `pq-pool` (IPv4 /24) + `pq-pool6` (IPv6 /64) via a CP payload, plus DNS |
| Rekey | IKE 4 h, CHILD 1 h; `reauth_time = 0` |
| DPD | 30 s; CHILD `dpd_action = clear` |
| `unique` | `replace` |
| Fragmentation | `yes` (RFC 7383) |
| NAT-T / MOBIKE | strongSwan defaults (on) |
| Mode | Tunnel, policy-based (xfrm policies; no xfrm interfaces) |

## 15. PKI

| Object | Key | Validity | Subject / SAN | EKU / flags |
|---|---|---|---|---|
| Root CA | RSA-4096 | 10 y | `O=PQ-VPN, CN=PQ-VPN Root CA` | `CA:TRUE` |
| Server | RSA-3072 | 5 y | `C=<cc>, O=PQ-VPN, OU=<PROVIDER>, L=<City>, CN=<display name>`; SAN `IP:<addr>`, `DNS:<addr>` | `serverAuth`, `ikeIntermediate` (1.3.6.1.5.5.8.2.2, required by Windows) |
| Device | RSA-3072 | `days` (default 1825) | `O=PQ-VPN, OU=device, CN=<name>@pqvpn`; SAN `email:<name>@pqvpn` | `clientAuth` |

- Signatures: SHA-384 with RSA. `notBefore` is back-dated 24 h to tolerate client clock skew.
- The CA key at rest is PKCS#8 `ENCRYPTED PRIVATE KEY` (PBKDF2-HMAC-SHA256 + AES-256-CBC). It's decrypted only into tmpfs for signing, then shredded.
  Passphrases reach `openssl` via `env:`, never argv.
- Device bundles are PKCS#12 with `PBE-SHA1-3DES` / MAC SHA-1. That's a deliberate compatibility choice: the format both the Windows and iOS importers accept.
  It's only a transport container, protected by a random install password.
- RSA rather than ECDSA, for maximum native-client compatibility.
- No CRL/OCSP. Revocation equals expiry, so use short lifetimes for temporary devices.

## 16. Network design

### Addressing plan

| Item | Scheme | Example |
|---|---|---|
| Client IPv4 pool | `10.20.N.0/24`, N = 20, 21, … per server | `10.20.20.0/24` |
| Client IPv6 pool | `fd20:A:B::/64` derived from `10.A.B.0/24` (ULA) | `fd20:20:20::/64` |
| Client DNS | `DNS` setting | `1.1.1.1, 9.9.9.9` |
| Egress | SNAT (MASQUERADE) to the uplink address | `eth0` → `198.51.100.10` |

Pools are unique across servers (inventory) and checked against local routes, so they don't collide with VPC or Docker ranges.

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
- `xt_policy` binds FORWARD acceptance to packets that actually traversed an SA.

**IPv6:**

| Server has global IPv6 + default route | Rules |
|---|---|
| Yes | ip6tables FORWARD policy accepts for `$POOL6` + NAT66 MASQUERADE out the v6 uplink; `net.ipv6.conf.all.forwarding=1` and `accept_ra=2` on the uplink (otherwise enabling forwarding drops SLAAC/RA routes) |
| No | IPv6 forwarding stays enabled (`accept_ra=2`) and `$POOL6` is routed to the uplink, so the kernel answers client IPv6 immediately with ICMPv6 *unreachable* (≈5 ms, verified), sent back through the tunnel; `ip6tables -I FORWARD 1 -s $POOL6 -j REJECT --reject-with icmp6-adm-prohibited` is the backstop. Clients receive a v6 address, so IPv6 can't leak around the tunnel, and apps fall back to IPv4 at once |

**ufw mode** (ufw active): the same rules go into `/etc/ufw/before.rules` / `before6.rules` (`*nat` / `*mangle` blocks at the top,
`ufw-before-forward` / `ufw6-before-forward` rules after `# End required lines`), between `# swanstrap BEGIN/END <tag>`
markers, then `ufw reload`. No `iptables-persistent`, so ufw is never removed.

**sysctl:** `/etc/sysctl.d/99-swanstrap.conf` (`net.ipv4.ip_forward=1`, plus the IPv6 settings above).

## 17. Client artifacts

`swanstrap add-user` / `add-device` write one self-contained artifact per platform to `~/vpn-clients/<Server-Name>/{users,devices}/`.

| Artifact | Contents | Effect on the client |
|---|---|---|
| `<name>-<Server>.ps1` (user) | Root cert (base64 DER) | Imports the root into `LocalMachine\Root`; `Add-VpnConnection -TunnelType Ikev2 -AuthenticationMethod Eap`; `Set-VpnConnectionIPsecConfiguration` AES256/SHA384/ECP384 + GCMAES256/ECP384 PFS |
| `<name>-<Server>.ps1` (device) | Root + PKCS#12 | As above, plus imports into `LocalMachine\My`; `-AuthenticationMethod MachineCertificate -AllUserConnection` |
| `<name>-<Server>.mobileconfig` (user) | `com.apple.security.root` + `com.apple.vpn.managed` | IKEv2, `AuthenticationMethod=None` + `ExtendedAuthEnabled=1` (EAP); IKE/Child SA AES-256-GCM / SHA2-384 / DH 20; PFS |
| `<name>-<Server>.mobileconfig` (device) | Root + `com.apple.security.pkcs12` + VPN | `AuthenticationMethod=Certificate`, `LocalIdentifier=<name>@pqvpn` |

Windows' default IKEv2 policy (3DES/SHA-1/DH2) is rejected by the server, so the `.ps1` or an equivalent
`Set-VpnConnectionIPsecConfiguration` call is mandatory on Windows.

## 18. Multi-server operation

### Inventory schema (`servers.tsv`, TSV with header)

```
id  name  provider  country  city  region  address  pool  added
oci-sg-sin-01  OCI-PQ Singapore  OCI  SG  Singapore  ap-singapore-1  198.51.100.10  10.20.20.0/24  2026-10-20
```

**Server addresses are not published.** The CA server keeps the full inventory in `/root/vpn-ca/servers.tsv`;
the repo copy (`ca/servers.tsv`, written by `bootstrap` and `sync-kit`) has `-` in the `address` column.
A re-run of bootstrap on the CA server uses the local copy, so it still recognises itself by IP. After rebuilding
the CA from the repo, `add-device … <server-id>` asks once for that server's IP and stores it locally.

### Adding a member server

```bash
# CA server: validates that the ID/name/IP are unique, allocates the next pool, signs the server cert, updates the inventory
sudo swanstrap add-server aws-de-fra-01 Frankfurt eu-central-1 203.0.113.20
#   -> ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar   (kit + site/, contains the leaf private key)

scp ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar ubuntu@203.0.113.20:
ssh ubuntu@203.0.113.20 'tar xf swanstrap-aws-de-fra-01.tar && sudo ./swanstrap/lib/install.sh && rm -r swanstrap-aws-de-fra-01.tar swanstrap'
# open UDP 500/4500 at that provider (Part 1, step 3)

rm ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar          # the bundle holds a private key
sudo swanstrap sync-kit ~/swanstrap --push
```

| Concern | Behaviour |
|---|---|
| Trust | Every server presents a cert under the same root; clients trust all servers once the root is installed |
| Device certs | Valid on every server; `add-device … <server-id>` renders the client profile for a specific server |
| User logins | Per server (`add-user` on each); the member's `personal` password is in its own `CREDENTIALS.txt` |
| Shared state | None at runtime; servers are independent. The inventory matters only for provisioning |
| Replacing the CA server | `bootstrap.sh` on a new node with the same `ca/` and passphrase; any node can become the CA server |

## 19. CLI reference

`swanstrap` (alias `pqvpn`) runs as root on a server and acts on that server (`/etc/swanstrap/server.conf`).

| Command | Node | Description |
|---|---|---|
| `add-user <name>` | any | Create an EAP user (random ~24-char secret) and render the artifacts. Idempotent: rebuilds the files, keeps the secret |
| `add-device <name> <windows\|ios> [days] [server-id]` | CA | Issue a client cert (prompts for the CA passphrase); render the artifact for this or another inventory server |
| `remove <name>` | any | Delete a user (`swanctl --load-creds --clear`) or a device record + artifacts on all servers. The cert stays valid until expiry |
| `list` | any | Inventory, users, devices with expiry, active IKE SAs |
| `add-server <id> <City> <region> <ipv4>` | CA | Register, allocate a pool, sign, build the bundle |
| `sync-kit <repo-dir> [--push]` | CA | Copy `/root/vpn-ca/{crt,key.enc}` and the inventory **without server addresses** into `<repo>/ca/`. `--push`: commit (only if changed) and push as the repo owner, with their git identity and credentials |
| `upgrade-strongswan` | any | Source: rebuild the latest 6.x; package: `apt --only-upgrade`. Then restart and verify ML-KEM |
| `firewall` | any | Uplink / IPv6 / ufw state and the relevant rules |

Names match `^[a-z0-9-]+$`.

## 20. Bootstrap modes

| Mode | Invocation | Interaction |
|---|---|---|
| Quick | `--quick` | None (CA passphrase prompt only when restoring; avoid it with `--ca-passphrase-file`) |
| Guided | *(no mode flag)* | TTY prompts per value; dependent values (ID, name, pool) are re-derived after edits |
| Declarative | `--config file.env` (+ `--quick`) | None; reproducible |
| Plan | `--dry-run` | Prints the resolution table + preflight; no changes, no root needed |

```bash
./bootstrap.sh --quick --dry-run
sudo ./bootstrap.sh --quick --new-ca
sudo ./bootstrap.sh --quick --city Hanoi --country VN --provider home --ip 203.0.113.10
sudo ./bootstrap.sh --quick --config frankfurt.env --dns 9.9.9.9
```

## 21. Configuration reference

`bootstrap.sh --config FILE` takes `KEY=value` lines (shell-style quotes, `#` comments; unknown keys are rejected).
Template: `config.example.env`.

| Key | Option | Default | Validation |
|---|---|---|---|
| `SERVER_ADDR` | `--ip` | detected | IPv4 |
| `PROVIDER` | `--provider` | detected / `VPS` | `[A-Z0-9]+` |
| `REGION` | `--region` | detected / `unknown` | `[A-Za-z0-9._-]+` |
| `CITY` | `--city` | detected / `Server` | ASCII after transliteration |
| `COUNTRY` | `--country` | detected / `XX` | ISO 3166 alpha-2 |
| `SERVER_ID` | `--id` | derived | see §11 |
| `SERVER_NAME` | `--name` | `<PROVIDER>-PQ <City>` | ASCII, no quotes or commas |
| `POOL` | `--pool` | next free `10.20.N.0/24` | `10.X.Y.0/24` |
| `DNS` | `--dns` | `1.1.1.1, 9.9.9.9` | comma-separated IPs |
| `FIRST_USER` | `--user` | `personal` | `[a-z0-9-]+` |
| `CLIENT_USER` | `--client-user` | `$SUDO_USER` / `root` | existing user |
| `STRONGSWAN` | `--strongswan` | `auto` | `auto\|package\|source\|source=X.Y.Z` |
| `CA_MODE` | `--new-ca` | `auto` | `auto\|restore\|new` |
| `OFFLINE` | `--offline` | `0` | `1` disables internet lookups |

Flags without a key: `--quick`, `--dry-run`, `--yes`, `--no-detect`, `--ca-passphrase-file FILE`.

## 22. Security model

| Asset | Protection | Location | Compromise impact |
|---|---|---|---|
| CA passphrase | Never written to the repo or disk (except `CREDENTIALS.txt` in `--quick --new-ca`) | Operator | With the repo: issue arbitrary server/device certs |
| CA private key | PKCS#8 AES-256 + PBKDF2 | `ca/`, `/root/vpn-ca` (0600) | Useless without the passphrase |
| Server leaf key | 0600 root | `/etc/swanctl/private/` on that node | Impersonation of that server only |
| EAP secrets | 0600 root | `/etc/swanctl/conf.d/pq-vpn-user-*.conf` | That user, that server |
| Device `.p12` | Random install password | Artifact only (key not kept on the server) | That device until expiry |
| Bundles | Contain a leaf key | Transient, on the CA server | Delete after install |

**Controls:**

- `.gitignore`, plus a **pre-commit hook** (`hooks/pre-commit`, enabled via `core.hooksPath`) that rejects `*.key`, `*.p12`, `*.ps1`,
  `*.mobileconfig`, `*.tar`, `*.env`, `CREDENTIALS*`, and any staged unencrypted PEM key or literal `secret = "…"`.
- Secrets are handled only in tmpfs, shredded on exit, and passed to `openssl` via environment variables (`env:`), never on the
  command line, which any local user can read from the process list.
- Downloads are GPG-verified.

**Known limits:** no revocation (CRL/OCSP); EAP-MSCHAPv2 relies on the server-authenticated outer IKE SA for protection;
native Windows/Apple clients get no PQ protection; anyone with repo access **and** the passphrase controls the PKI.

## 23. Server layout

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

## 24. Operations

| Task | Procedure |
|---|---|
| Status | `sudo swanstrap list`; `sudo swanctl --list-sas`; `sudo swanctl --list-pools` |
| Logs | `journalctl -u strongswan -f` |
| Reload config / creds | `sudo swanctl --load-all` (no SA teardown) |
| Kick a session | `sudo swanctl --terminate --ike-id <id>` |
| Verify PQ is offered | `sudo swanctl --list-algs \| grep ML_KEM` |
| Verify a PQ SA | `sudo swanctl --list-sas`: the IKE SA shows `AES_GCM_16-256/PRF_HMAC_SHA2_384/CURVE_25519/KE1_ML_KEM_768` |
| Upgrade strongSwan | `sudo swanstrap upgrade-strongswan` |
| Re-apply the firewall | `sudo systemctl restart swanstrap-firewall` |
| Public IP changed | CA server: `sudo ./bootstrap.sh --quick --id <id>` (reissues the cert for the new IP). Member: `add-server` again. Then re-render artifacts (`add-user`) |
| Leaf certs expiring | The login banner warns 60 days ahead. Re-run bootstrap / add-server (servers); issue new device certs |
| Root CA rotation | `bootstrap.sh --new-ca`; redeploy artifacts to every client; rebuild member servers |
| Keep the repo authoritative | `sudo swanstrap sync-kit ~/swanstrap --push` after `bootstrap` / `add-server` |

## 25. Troubleshooting

| Symptom (client / `journalctl -u strongswan`) | Cause | Fix |
|---|---|---|
| Timeout, nothing logged | UDP 500/4500 blocked upstream | Cloud firewall / security group |
| `NO_PROPOSAL_CHOSEN` | Client proposals outside the accepted set (Windows defaults) | Run the `.ps1` / `Set-VpnConnectionIPsecConfiguration` |
| `AUTH_FAILED`, Windows 13801 | Root not in `LocalMachine\Root`, or SAN/EKU mismatch | Re-run the `.ps1` elevated; the server cert must have SAN = the connect address |
| iOS "Unable to validate server certificate" | Root not fully trusted | Certificate Trust Settings |
| `EAP_MSCHAPV2 failed` | Wrong secret | `CREDENTIALS.txt`; `add-user` re-renders the files |
| SA up, no traffic | FORWARD/NAT rules missing or `ip_forward=0` | `swanstrap firewall`; `sysctl net.ipv4.ip_forward`; restart `swanstrap-firewall` |
| Large transfers stall | PMTU / MSS | Check the mangle TCPMSS rules |
| No IPv6 on the client | Server has no v6 uplink (reject by design) | Expected; IPv4 goes through the tunnel |
| Bootstrap: kernel lacks IPsec | OpenVZ / LXC / stripped kernel | Use a KVM instance |
| Bootstrap: build failed | New upstream build deps | `build-<ver>.log`; `--strongswan source=6.1.0` |
| Bootstrap: wrong CA passphrase | Mismatch | Retry; if lost, `--new-ca` (PKI rotation) |

## 26. Code map and testing

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

**Conventions:** `set -euo pipefail`; idempotent mutations; validation before mutation; secrets only in `/run` and passed via `env:`;
no runtime dependencies beyond coreutils, iproute2, openssl, curl and gettext.

**Testing:** changes are exercised in fresh `--privileged` containers (Ubuntu 22.04/24.04/26.04, Debian 12 with ufw, Fedora for refusal),
covering new CA, restore, wrong passphrase, offline build, guided mode (expect), bundle install and device issuance.
Containers lack systemd, so `install.sh` starts `charon-systemd` directly there. `--dry-run` gives quick plan checks without root.
