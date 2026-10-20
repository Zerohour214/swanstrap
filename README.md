# swanstrap

**Your own post-quantum VPN, rebuilt on any server with one command.**

swanstrap sets up and manages a private VPN based on [strongSwan](https://strongswan.org) (IPsec / IKEv2).
It uses **post-quantum encryption** (ML-KEM) where your devices support it. Everything needed to rebuild
it lives in this repository, so even if every server is gone you can be back online in minutes:

```bash
git clone https://github.com/<you>/swanstrap.git
sudo ./swanstrap/bootstrap.sh --quick
```

---

## Table of contents

1. [The big picture](#1-the-big-picture)
2. [Key ideas in plain words](#2-key-ideas-in-plain-words)
3. [Quick start: build a VPN from nothing](#3-quick-start-build-a-vpn-from-nothing)
4. [How deployment works](#4-how-deployment-works)
5. [Adding more servers](#5-adding-more-servers)
6. [Connecting your devices](#6-connecting-your-devices)
7. [Everyday commands](#7-everyday-commands)
8. [Customizing the setup](#8-customizing-the-setup)
9. [Security: what is secret and where it lives](#9-security-what-is-secret-and-where-it-lives)
10. [Inside a server](#10-inside-a-server)
11. [Maintenance](#11-maintenance)
12. [Troubleshooting](#12-troubleshooting)
13. [Repository layout](#13-repository-layout)

---

## 1. The big picture

```
   ┌──────────────────────────────┐
   │  GitHub (private repo)       │   The "recipe": scripts + encrypted CA key
   │  swanstrap                   │   + list of all your servers.
   └──────────────┬───────────────┘   Nothing in here is usable without your passphrase.
                  │ git clone
                  ▼
   ┌──────────────────────────────┐        bundle (.tar)        ┌──────────────────────────────┐
   │  CA server                   │ ──────────────────────────▶ │  More VPN servers            │
   │  e.g. OCI-PQ Singapore       │   swanstrap add-server      │  e.g. AWS-PQ Frankfurt       │
   │                              │                             │                              │
   │  • runs the VPN              │                             │  • runs the VPN              │
   │  • holds the CA              │                             │  • no CA (can't issue        │
   │    (issues certificates)     │                             │    certificates)             │
   └──────────────┬───────────────┘                             └──────────────┬───────────────┘
                  │  IKEv2 / IPsec (UDP 500 + 4500)                            │
                  ▼                                                            ▼
   ┌──────────────────────────────────────────────────────────────────────────────────────────┐
   │  Your devices: Windows, iPhone, iPad, Mac, Android/Linux (strongSwan app)                │
   │  Each device trusts "PQ-VPN Root CA" once and can then connect to every server.         │
   └──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **One repo** holds everything needed to rebuild.
- **One CA server** (the first server you build) is the "office" that hands out certificates.
- **Any number of VPN servers** in different countries and with different providers. They all share one identity system, so
  a device set up once trusts all of them.

---

## 2. Key ideas in plain words

| Term | What it means here |
|---|---|
| **VPN server** | A cloud machine (VPS) that your devices connect to. Your internet traffic leaves from there. |
| **CA** (certificate authority) | Your own private "ID office" called **PQ-VPN Root CA**. It signs the certificates that prove a server (or device) is really yours. Devices install the CA **once**. |
| **CA server** | The server that holds the CA's private key and can therefore issue new certificates. It's the first server you bootstrap. |
| **CA passphrase** | The password that unlocks the CA key. **The single most important secret.** Never stored in the repo. |
| **Kit** | This repository: scripts, templates, the strongSwan source as a fallback, and the CA key **encrypted with the passphrase**. |
| **Inventory** | `ca/servers.tsv`: a list of every server (name, provider, country, IP, address pool). |
| **Username login** | A username and password. Simple; meant for you. Created per server. |
| **Device login** | A certificate made for one device (e.g. a friend's phone). Can have an expiry date. Works on every server. |
| **Post-quantum (ML-KEM)** | New encryption designed to resist future quantum computers. Used **together with** classical X25519 ("hybrid"), so it's never weaker than today's standard. |
| **Server ID / name** | e.g. `oci-sg-sin-01` / **OCI-PQ Singapore**: `<provider>-<country>-<city>-<number>`. The name is what shows in your device's VPN list. |

> **Which devices get post-quantum?** Devices running strongSwan 6.x (Linux, Android app, macOS app) negotiate ML-KEM.
> The VPN clients **built into Windows and iOS don't support ML-KEM yet**, so they use strong classical encryption
> (AES-256-GCM, SHA-384, ECP-384). The server offers post-quantum first and uses it whenever the device can.

---

## 3. Quick start: build a VPN from nothing

### What you need

- A fresh **Ubuntu 22.04+ or Debian 12+** VPS. It must be a full VM (KVM). OpenVZ/LXC containers can't run IPsec.
- SSH access as a user with `sudo`, or as root.
- Your GitHub login, to clone this private repo.
- Your **CA passphrase**, if you want devices set up earlier to keep working. Without it, use `--new-ca`.

### Steps

**1. Get the kit onto the server**

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/swanstrap.git
```

> GitHub doesn't accept your account password for `git clone`. Create a **fine-grained personal access token**:
> GitHub → Settings → Developer settings → Fine-grained tokens → *Only select repositories: swanstrap*,
> permission **Contents: Read-only** (or *Read and write* if you'll push from the server). Paste it as the password.

**2. Preview (optional, changes nothing)**

```bash
./swanstrap/bootstrap.sh --quick --dry-run
```

**3. Install**

```bash
sudo ./swanstrap/bootstrap.sh --quick
```

It asks for the CA passphrase, then works on its own for 2–15 minutes. It is slower when strongSwan has to be compiled.

**4. Open the firewall at your cloud provider**: allow inbound **UDP 500** and **UDP 4500**
(OCI: *Security List*; AWS: *Security Group*; GCP: *Firewall rule*; Hetzner/DO: *Cloud Firewall*).

**5. Save the updated inventory to GitHub** (bootstrap prints this command):

```bash
cd swanstrap && git add ca && git commit -m "Bootstrap <server-id>" && git push
```

**6. Set up your devices**: copy the login files to your computer, then follow [section 6](#6-connecting-your-devices):

```bash
scp -r <user>@<server-ip>:~/vpn-clients .
```

---

## 4. How deployment works

### What `bootstrap.sh` does, step by step

```
 sudo ./bootstrap.sh --quick
        │
        ▼
 ① Base tools ──────── preflight (Debian/Ubuntu? kernel has IPsec?), wait for first-boot
        │               updates to release apt, install curl/openssl/git/...
        ▼
 ② Detect settings ─── provider (hardware info) → region (provider metadata) → city/country
        │               (built-in region table, else geo-IP) → public IP → server ID, name, pool
        ▼
 ③ CA ──────────────── restore the CA from ca/ (asks passphrase, checked BEFORE anything big)
        │               or create a new one (--new-ca, or if the kit CA expired)
        ▼
 ④ strongSwan ──────── distro package if it supports ML-KEM, else build the latest 6.x from
        │               source (GPG-verified), else the bundled 6.1.0 (works offline)
        ▼
 ⑤ Server identity ─── issue this server's certificate, write /etc/swanstrap/server.conf,
        │               generate the strongSwan config from templates/pq-vpn.conf.tmpl
        ▼
 ⑥ Install ─────────── lib/install.sh: copy kit to /usr/local/share/swanstrap, firewall + NAT
        │               + IPv6 leak protection, start strongSwan, verify ML-KEM is offered
        ▼
 ⑦ First login ─────── create the "personal" username login + install files in ~/vpn-clients/
        │
        ▼
 ⑧ Save ────────────── copy CA (encrypted) + inventory back into the repo's ca/ → you commit & push
```

Every step checks itself and stops with a clear message if something is wrong. Running it again is safe.

### How settings are chosen

Each setting is taken from the first source that has it:

```
  command-line option   →   --config file   →   auto-detected   →   built-in default
  (--city Hanoi)            (CITY=Hanoi)        (cloud metadata)      (Server)
```

So `--quick` always works, even on an unknown provider with no internet lookups. You just get plain
default names like **VPS-PQ Server** (`vps-xx-ser-01`). See [section 8](#8-customizing-the-setup) for every setting.

### What a connection looks like

```
 Device                                   VPN server                                  Internet
   │  1. IKE_SA_INIT (UDP 500)               │
   │  ── offers: X25519 + ML-KEM-768 ──────▶ │  (Windows/iOS offer ECP-384 instead)
   │  2. IKE_AUTH (UDP 4500)                 │
   │  ── server proves itself with its ────▶ │  certificate signed by PQ-VPN Root CA
   │     certificate; device logs in with    │
   │     username/password or its own cert   │
   │  3. device gets 10.20.20.x (+ IPv6)     │
   │  ══ all traffic, encrypted (ESP) ═════▶ │ ── NAT ──▶  websites see the server's IP
```

---

## 5. Adding more servers

New servers are prepared **on the CA server**, because only it can issue their certificates. The new server only
receives a ready-made bundle; it never sees the CA key.

```
   CA server                                         new VPS (fresh)
 ┌──────────────────────────────┐   scp bundle    ┌──────────────────────────────┐
 │ swanstrap add-server …       │ ──────────────▶ │ tar xf swanstrap-<id>.tar    │
 │  • checks the ID is free     │                 │ sudo ./swanstrap/lib/        │
 │  • picks the next free pool  │                 │        install.sh            │
 │  • issues server certificate │                 │  • strongSwan + ML-KEM       │
 │  • adds it to the inventory  │                 │  • firewall, NAT, IPv6       │
 │  • builds swanstrap-<id>.tar │                 │  • "personal" login          │
 └──────────────────────────────┘                 └──────────────────────────────┘
```

```bash
# 1. On the CA server
sudo swanstrap add-server aws-de-fra-01 Frankfurt eu-central-1 203.0.113.20

# 2. Copy and install
scp ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar ubuntu@203.0.113.20:
ssh ubuntu@203.0.113.20 'tar xf swanstrap-aws-de-fra-01.tar && sudo ./swanstrap/lib/install.sh && rm -r swanstrap-aws-de-fra-01.tar swanstrap'

# 3. Open UDP 500 + 4500 in that provider's firewall

# 4. Back on the CA server: delete the bundle (it contains the new server's private key) and save the inventory
rm ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar
sudo swanstrap sync-kit ~/swanstrap
cd ~/swanstrap && git add ca && git commit -m "Add aws-de-fra-01" && git push
```

Each server gets its own address pool (`10.20.20.0/24`, `10.20.21.0/24`, …) and shows up as its own entry
on your devices (e.g. **AWS-PQ Frankfurt**).

---

## 6. Connecting your devices

Every login comes as **one self-contained file** in `~/vpn-clients/<Server-Name>/`:

| File | For | What it does |
|---|---|---|
| `users/<name>-<Server>.ps1` | Windows (username login) | Installs the CA, creates the VPN with strong settings |
| `users/<name>-<Server>.mobileconfig` | iPhone / iPad / Mac (username login) | Profile with the CA and VPN settings; asks for your password |
| `devices/<name>-<Server>.ps1` | Windows (device login) | Also installs the device certificate (asks its install password) |
| `devices/<name>-<Server>.mobileconfig` | iPhone / iPad / Mac (device login) | Also contains the device certificate (asks its install password) |

Passwords are in `~/vpn-clients/CREDENTIALS.txt`.

### Windows 10 / 11

1. Copy the `.ps1` file to the PC and open its folder in File Explorer.
2. Type `powershell` in the address bar and press Enter, then open an **Administrator** window in the same folder:
   ```powershell
   Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -Command cd '$PWD'"
   ```
3. In the Administrator window:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\personal-OCI-PQ-Singapore.ps1
   ```
4. **Settings → Network & internet → VPN → OCI-PQ Singapore → Connect.** Enter your username and password the first time.

### iPhone / iPad

1. Send the `.mobileconfig` to the phone (AirDrop, iCloud Drive → Files app, or email) and open it.
2. **Settings → Profile Downloaded → Install**, enter your passcode, then your VPN password (or the device's install password).
3. **Once per device:** Settings → General → About → **Certificate Trust Settings** → turn on **PQ-VPN Root CA**.
4. **Settings → VPN → OCI-PQ Singapore** → on.

### Check that it works

Search "what is my IP" in a browser: it should show the **server's** IP.

### Manual setup (without the files)

Install `PQ-VPN-Root-CA` (from `ca/pq-vpn-root-ca.crt`) as a trusted root, then add an **IKEv2** VPN with
server = remote ID = the server's IP and a username login. On Windows, also run:

```powershell
Set-VpnConnectionIPsecConfiguration -ConnectionName '<Server name>' -Force `
  -EncryptionMethod AES256 -IntegrityCheckMethod SHA384 -DHGroup ECP384 `
  -CipherTransformConstants GCMAES256 -AuthenticationTransformConstants GCMAES256 -PfsGroup ECP384
```

(Windows' default is weak 3DES/SHA-1, which the server refuses.)

---

## 7. Everyday commands

Run on a server with `sudo`. They act on **that** server. Run `swanstrap` alone for help.

| I want to… | Command | Where |
|---|---|---|
| See servers, users, devices, who's online | `sudo swanstrap list` | any server |
| Add a username login | `sudo swanstrap add-user alex` | any server |
| Rebuild someone's files (password kept) | `sudo swanstrap add-user alex` | any server |
| Give a device access for 30 days | `sudo swanstrap add-device alex-phone ios 30` | CA server |
| …for another server | `sudo swanstrap add-device alex-phone-fra ios 30 aws-de-fra-01` | CA server |
| Remove a login | `sudo swanstrap remove alex` | any server |
| Add a new server | `sudo swanstrap add-server <id> <City> <region> <ip>` | CA server |
| Save CA + inventory into the repo | `sudo swanstrap sync-kit ~/swanstrap` | CA server |
| Update strongSwan | `sudo swanstrap upgrade-strongswan` | any server |
| Check the firewall | `sudo swanstrap firewall` | any server |

- Names: lowercase letters, digits and `-` (e.g. `mom-ipad`).
- **Username logins** stop working the moment you remove them.
- **Device logins** can't be revoked: removing one deletes its files, but the certificate keeps working until it
  expires. Give temporary devices a short lifetime (`… ios 30`).

---

## 8. Customizing the setup

### Three ways to run bootstrap

| Mode | Command | Good for |
|---|---|---|
| **Quick** | `sudo ./bootstrap.sh --quick` | "Just make it work": detects everything, no questions except the CA passphrase |
| **Guided** | `sudo ./bootstrap.sh` | Review each detected value; press Enter to keep it or type a new one |
| **Config file** | `sudo ./bootstrap.sh --config my.env` | Repeatable, scripted setups. Start from `config.example.env` |

Add `--dry-run` to any of them to only **show** what would happen.

### All settings

| Setting | Option | If not given | Default |
|---|---|---|---|
| Public IP | `--ip` | cloud metadata → ipify / icanhazip → default route | *(required)* |
| Provider | `--provider` | hardware info (OCI, AWS, GCP, Azure, DigitalOcean, Hetzner, Vultr, Linode) | `VPS` |
| Region | `--region` | provider metadata | `unknown` |
| City / country | `--city` / `--country` | built-in region table, then geo-IP | `Server` / `XX` |
| Server ID | `--id` | `<provider>-<cc>-<city>-<next nn>` | `vps-xx-ser-01` |
| Display name | `--name` | `<PROVIDER>-PQ <City>` | `VPS-PQ Server` |
| Client address pool | `--pool` | next free `10.20.N.0/24` not used by another server or a local network | `10.20.20.0/24` |
| DNS for clients | `--dns` | | `1.1.1.1, 9.9.9.9` |
| First username | `--user` | | `personal` |
| Owner of `~/vpn-clients` | `--client-user` | the user who ran `sudo` | `root` |
| strongSwan source | `--strongswan auto\|package\|source\|source=6.1.0` | | `auto` |
| CA | `--new-ca` | restore from `ca/` if present and valid | create new |

Other switches: `--ca-passphrase-file FILE`, `--offline` (no internet lookups), `--no-detect` (defaults only),
`--yes` (skip confirmation).

```bash
./bootstrap.sh --quick --dry-run                                   # what would happen here?
sudo ./bootstrap.sh --quick --new-ca                               # fresh start with a brand-new CA
sudo ./bootstrap.sh --quick --city Hanoi --country VN --provider home --ip 203.0.113.10
sudo ./bootstrap.sh --quick --config frankfurt.env --dns 9.9.9.9   # file + one override
```

---

## 9. Security: what is secret and where it lives

| Item | Secret? | Where it lives | If lost |
|---|---|---|---|
| **CA passphrase** | 🔴 Yes, the master secret | **Only** in your head / password manager (and temporarily in `CREDENTIALS.txt`) | Can't use the CA again → `--new-ca`, re-set up all devices |
| CA private key | 🔴 Yes | Repo `ca/` and `/root/vpn-ca/`, **encrypted** with the passphrase (AES-256) | Restored from the repo |
| CA certificate | 🟢 No (public) | Repo, every server, every device | Restored from the repo |
| Server private key | 🔴 Yes | Only on that server (`/etc/swanctl/private/`) | Re-run bootstrap / add-server |
| Username passwords | 🔴 Yes | That server + `CREDENTIALS.txt` | `swanstrap remove` + `add-user` |
| Device install passwords | 🟠 Yes | `CREDENTIALS.txt` | Issue a new device |
| Inventory (`servers.tsv`) | 🟢 No | Repo + CA server | Rebuilt by bootstrap |

**Rules of thumb**

- Keep the repo **private**, and keep the passphrase **out of it**.
- After downloading, delete `~/vpn-clients/CREDENTIALS.txt` (and any bundle `.tar`) from servers.
- The repo has a **pre-commit hook** (`hooks/`) that refuses to commit passwords, private keys or client files.
- One device = one certificate. Never share a device file between people.
- The CA is valid for 10 years. bootstrap warns when less than a year is left and refuses an expired CA.

---

## 10. Inside a server

### Network

| What | Value |
|---|---|
| Ports | UDP **500** (IKE), UDP **4500** (IKE/ESP through NAT), ESP |
| Client addresses | IPv4 from the server's pool (e.g. `10.20.20.0/24`) and IPv6 from `fd20:20:20::/64` |
| Outgoing traffic | NAT'd to the server's public IP |
| IPv6 | Tunneled too, so there are no leaks. If the server has IPv6, clients use it; otherwise IPv6 is refused instantly and apps use IPv4 through the VPN |
| MTU | TCP MSS clamped to 1360 so large pages don't hang |

### Firewall

- **Normal servers:** `swanstrap-firewall.service` adds the rules at every boot (iptables), placing them before the provider's own
  "reject everything" rules (e.g. Oracle's).
- **If `ufw` is active:** the rules are written into ufw's `before.rules` / `before6.rules` instead.
- **Your cloud provider's firewall** still needs UDP 500/4500 open. swanstrap can't change that.

### Encryption offered by the server

| Phase | Offered, in order of preference |
|---|---|
| IKE (key exchange) | **AES-256-GCM + X25519 + ML-KEM-768** → AES-256-GCM + ECP-384 → AES-256 + SHA-384/256 + ECP-384 → AES-256 + SHA-256 + MODP-2048 (iOS manual setup) |
| ESP (your traffic) | **AES-256-GCM + X25519 + ML-KEM-768** → AES-256-GCM + ECP-384 → AES-256-GCM → AES-256 + SHA-256 |

### Files

| Path | Purpose |
|---|---|
| `/etc/swanstrap/server.conf` | This server's identity and settings |
| `/etc/swanctl/conf.d/pq-vpn.conf` | strongSwan connections (generated from the template) |
| `/etc/swanctl/conf.d/pq-vpn-user-<name>.conf` | One username login per file |
| `/etc/swanctl/{x509ca,x509,private}/` | CA certificate, server certificate, server key |
| `/root/vpn-ca/` | **CA server only**: encrypted CA key, inventory, every issued certificate |
| `/usr/local/share/swanstrap/` | Installed copy of this kit (the `swanstrap` command lives here) |
| `/usr/local/src/strongswan/` | strongSwan source build (only when built from source) |
| `~/vpn-clients/` | Login files, `CREDENTIALS.txt`, this README, `ca-backup/` |

### Services

| Service | Role |
|---|---|
| `strongswan` | The VPN daemon (charon) |
| `swanstrap-firewall` | Re-applies firewall/NAT rules at boot |
| Login message (`/etc/update-motd.d/90-swanstrap`) | Warns about certificates expiring within 60 days and new strongSwan releases |
| Weekly job (`/etc/cron.weekly/swanstrap-check-release`) | Checks for new strongSwan releases |

---

## 11. Maintenance

| Task | How |
|---|---|
| **Update strongSwan** | `sudo swanstrap upgrade-strongswan`. Source builds are rebuilt with the latest release; distro packages are updated through apt. The login message tells you when a new release exists. |
| **Server's public IP changed** | Re-run `sudo ./bootstrap.sh --quick --id <server-id>` (CA server) or redo `add-server` for others, then reinstall the device files. Reserve a **static IP** to avoid this. |
| **Certificates expiring** | The login message warns 60 days ahead. Servers: re-run bootstrap / add-server. Devices: issue new ones. |
| **CA expiring (10 years)** | `sudo ./bootstrap.sh --quick --new-ca`, then give every device its new files. |
| **Move the CA server** | Bootstrap the new machine from the repo (same passphrase). It becomes the CA server. |
| **After add-server / add-device** | `sudo swanstrap sync-kit ~/swanstrap`, then commit and push, so the repo stays the source of truth. |

---

## 12. Troubleshooting

First, watch the server log while the device connects:

```bash
sudo journalctl -u strongswan -f
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Device times out, nothing in the log | Cloud firewall blocks UDP 500/4500 | Open them in the provider's console |
| `NO_PROPOSAL_CHOSEN` | Windows still on its weak default encryption | Re-run the `.ps1` (or the command in section 6) |
| Windows error 13801 / "credentials unacceptable" | CA not in *Local Machine → Trusted Root* | Re-run the `.ps1` as Administrator |
| iPhone: "Unable to validate server certificate" | CA not trusted | Certificate Trust Settings → **PQ-VPN Root CA** on |
| `EAP-MSCHAPv2 failed` | Wrong username or password | Check `CREDENTIALS.txt` |
| Connected but no internet | Firewall/NAT rules missing | `sudo swanstrap firewall`, then `sudo systemctl restart swanstrap-firewall` |
| Some websites hang | MTU | Check the MSS rule: `sudo iptables -t mangle -S FORWARD` |
| Stopped working after a server restart | Public IP changed | Reserve a static IP; see Maintenance |
| bootstrap: "kernel lacks IPsec support" | OpenVZ/LXC or a stripped kernel | Use a KVM / full-VM VPS |
| bootstrap: "wrong CA passphrase" | Typo or a different CA | Retry; if truly lost, use `--new-ca` |
| bootstrap: build failed | A newer strongSwan needs new build tools | Log: `/usr/local/src/strongswan/build-*.log`; retry with `--strongswan source=6.1.0` |
| bootstrap waits at "cloud-init" | First-boot updates still running | Normal; it waits up to 10 minutes |

---

## 13. Repository layout

```
swanstrap/
├── bootstrap.sh              Start here: fresh VPS → CA server (--quick | guided | --config | --dry-run)
├── config.example.env        Every setting, documented
├── bin/swanstrap             The management command (add-user, add-device, add-server, …)
├── lib/
│   ├── common.sh             Shared helpers: validation, pools, inventory, certificates
│   ├── detect.sh             Provider / region / IP / city detection + region→city table
│   ├── install.sh            Packages, strongSwan (package or source), files, firewall, service
│   └── firewall.sh           iptables or ufw rules, NAT, MSS clamp, IPv6 leak protection
├── templates/
│   └── pq-vpn.conf.tmpl      The strongSwan connection config, filled in per server
├── system/                   Login message, release check, firewall service, apt pin
├── vendor/                   strongSwan 6.1.0 source + signature + release key (offline fallback)
├── ca/
│   ├── pq-vpn-root-ca.crt    CA certificate (public)
│   ├── pq-vpn-root-ca.key.enc CA private key, AES-256 encrypted with your passphrase
│   └── servers.tsv           Inventory of all servers
└── hooks/pre-commit          Blocks secrets from being committed
```
