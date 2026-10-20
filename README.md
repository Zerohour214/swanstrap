# swanstrap

Bootstrap and manage a self-hosted **post-quantum IPsec VPN** (strongSwan 6, IKEv2,
hybrid X25519 + ML-KEM-768) across servers in different countries and with different cloud providers,
from one private Git repo.

---

## Contents

1. [Quick start: rebuild from scratch](#1-quick-start-rebuild-from-scratch)
2. [How it works](#2-how-it-works)
3. [bootstrap.sh: modes and settings](#3-bootstrapsh-modes-and-settings)
4. [The `swanstrap` command](#4-the-swanstrap-command)
5. [Adding more servers](#5-adding-more-servers)
6. [Connect from Windows](#6-connect-from-windows)
7. [Connect from iPhone / iPad](#7-connect-from-iphone--ipad)
8. [Giving a friend access](#8-giving-a-friend-access)
9. [Server administration](#9-server-administration)
10. [Troubleshooting](#10-troubleshooting)
11. [Security notes](#11-security-notes)
12. [Repository layout](#12-repository-layout)

---

## 1. Quick start: rebuild from scratch

You need a fresh **Debian 12+ or Ubuntu 22.04+** VPS (a full VM/KVM, not OpenVZ/LXC),
SSH access as a sudo user, and this repo.

```bash
# On the new VPS
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/swanstrap.git    # username + personal access token (see below)
sudo ./swanstrap/bootstrap.sh --quick
```

That's it. `--quick` detects the provider, region, city and public IP; installs strongSwan with ML-KEM;
restores your CA from `ca/` (asks for the **CA passphrase**) or creates a new one; sets up the firewall;
and creates your first login. It takes 2–15 minutes depending on whether strongSwan must be compiled.

Then:

1. **Open UDP 500 and UDP 4500** in the cloud provider's firewall (security list / security group).
2. **Save the CA and inventory** back to the repo (the command is printed at the end):
   ```bash
   cd swanstrap && git add ca && git commit -m "Bootstrap <server-id>" && git push
   ```
3. **Download your login files** to your computer and set up your devices ([section 6](#6-connect-from-windows), [section 7](#7-connect-from-iphone--ipad)):
   ```bash
   scp -r <user>@<server-ip>:~/vpn-clients .
   ```

> **Cloning a private repo:** GitHub doesn't accept account passwords for `git clone`. Create a
> **fine-grained personal access token** (GitHub → Settings → Developer settings → Fine-grained tokens)
> with access to **only this repository** and permission **Contents: Read-only** (or Read and write
> if you'll push from the server). Paste it when git asks for a password.

> **Kept your old devices?** If you restore the CA (same passphrase), devices that already trust
> **PQ-VPN Root CA** keep trusting it; they only need the new server's VPN file. With `--new-ca`,
> every device needs new files.

---

## 2. How it works

| Concept | Details |
|---|---|
| **Encryption** | The server offers hybrid post-quantum first (`X25519 + ML-KEM-768`). Clients that support it (strongSwan 6.x on Linux/Android/macOS) use it. Built-in Windows and iOS VPN clients don't support ML-KEM yet, so they use strong classical encryption (AES-256-GCM, SHA-384, ECP-384). |
| **One shared root CA** | `PQ-VPN Root CA` signs every server and device certificate. Install it once per device and it trusts all your servers. The CA key lives in the repo **encrypted** (AES-256) and on the **CA server** in `/root/vpn-ca/`. |
| **CA server** | The server made by `bootstrap.sh`. It can issue device certificates and prepare new servers. Other servers are VPN-only. |
| **Two ways to log in** | **Username + password** (`add-user`): for you, one login per person per server. **Device certificate** (`add-device`): for friends or temporary access, one file per device. |
| **IPv6** | IPv6 is tunneled too, so clients can't leak IPv6 traffic outside the VPN. If the server has IPv6, clients get IPv6 internet through it; otherwise their IPv6 is refused quickly and apps use IPv4 through the VPN. |
| **Naming scheme** | Server ID `<provider>-<country>-<city>-<nn>` (e.g. `oci-sg-sin-01`); display name `<PROVIDER>-PQ <City>` (e.g. **OCI-PQ Singapore**), shown in the device's VPN list. |

---

## 3. bootstrap.sh: modes and settings

### Modes

| Command | What happens |
|---|---|
| `sudo ./bootstrap.sh --quick` | Detects everything, falls back to defaults, asks no questions (except the CA passphrase when restoring) |
| `sudo ./bootstrap.sh` | **Guided**: shows each detected value; press Enter to accept or type a new one |
| `sudo ./bootstrap.sh --config my.env` | Settings from a file (copy `config.example.env`); combine with `--quick` for no questions |
| `./bootstrap.sh --dry-run [...]` | Shows the resolved settings and system checks; changes nothing (no sudo needed) |

**Always start with `--dry-run`** to see what will happen.

### How each setting is chosen

**Option > config file > detected > default.** Every setting can be overridden.

| Setting | Option | Detected from | Default |
|---|---|---|---|
| Provider | `--provider` | hardware info (OCI, AWS, GCP, Azure, DigitalOcean, Hetzner, Vultr, Linode) | `VPS` |
| Region | `--region` | the provider's metadata service | `unknown` |
| City, country | `--city`, `--country` | built-in region→city table, then geo-IP | `Server`, `XX` |
| Public IP | `--ip` | metadata → ipify / icanhazip → default route | none (required) |
| Server ID | `--id` | `<provider>-<cc>-<first 3 letters of city>-<next free nn>` | `vps-xx-ser-01` |
| Display name | `--name` | `<PROVIDER>-PQ <City>` | `VPS-PQ Server` |
| Client pool | `--pool` | next free `10.20.N.0/24` not used by another server or a local network | `10.20.20.0/24` |
| Client DNS | `--dns` | | `1.1.1.1, 9.9.9.9` |
| First login | `--user` | | `personal` |
| Owner of `~/vpn-clients` | `--client-user` | the user who ran sudo | `root` |
| strongSwan | `--strongswan auto\|package\|source\|source=VER` | | `auto` |
| CA | `--new-ca` | restore if `ca/` holds a valid CA | create new |

Other options: `--ca-passphrase-file FILE` (no prompt), `--offline` (no internet lookups),
`--no-detect` (only options/config/defaults), `--yes` (skip the confirmation). Run `./bootstrap.sh --help`.

**Examples**

```bash
./bootstrap.sh --dry-run --quick                                       # what would quickstart do?
sudo ./bootstrap.sh --quick --new-ca                                   # start over with a new CA
sudo ./bootstrap.sh --quick --name "Home-PQ Hanoi" --city Hanoi --country VN --provider home
sudo ./bootstrap.sh --quick --config frankfurt.env --dns "9.9.9.9"     # file + one override
```

### strongSwan install modes

| Mode | Behaviour |
|---|---|
| `auto` | Use the distro package if it is 6.x **and** offers ML-KEM; otherwise build the latest 6.x from source; if that fails or there's no internet, build the bundled 6.1.0 |
| `package` | Distro package only (fails if it lacks ML-KEM) |
| `source` / `source=6.1.0` | Build from source (latest, or a specific version) |

Source downloads are verified with the strongSwan release GPG key (bundled in `vendor/`).
Small servers get a temporary swap file during the build.

### Re-running

`bootstrap.sh` is safe to run again on the same server: it recognises the server by its IP in the
inventory and keeps its ID and pool. If the public IP changed, pass `--id <old-id>` to keep the ID;
the certificate is reissued for the new IP. Then rebuild the login files (`swanstrap add-user <name>`)
and reinstall them on your devices.

---

## 4. The `swanstrap` command

Run on a server with `sudo`. It acts on **that** server (`/etc/swanstrap/server.conf`).
`swanstrap` with no arguments shows help. (`pqvpn` is an alias.)

| Command | What it does | Where |
|---|---|---|
| `swanstrap add-user <name>` | Username/password login: creates the login, a strong password, and `<name>-<Server>.ps1` + `.mobileconfig`. Running it again rebuilds the files and keeps the password | any server |
| `swanstrap add-device <name> <windows\|ios> [days] [server-id]` | Certificate login for one device (asks the CA passphrase). Default 1825 days. `server-id` makes the file for another server | CA server |
| `swanstrap remove <name>` | Deletes a user (immediately locked out) or a device's record and files (its certificate still works until it expires) | any server |
| `swanstrap list` | Servers, users, devices with expiry, who is connected | any server |
| `swanstrap add-server <id> <City> <region> <ip>` | Registers a new server and builds its install bundle ([section 5](#5-adding-more-servers)) | CA server |
| `swanstrap sync-kit <repo-dir>` | Copies the CA (encrypted) and inventory into the repo's `ca/` for committing | CA server |
| `swanstrap upgrade-strongswan` | Updates strongSwan (rebuilds the latest source, or apt upgrade) | any server |
| `swanstrap firewall` | Shows the VPN firewall state | any server |

Names use lowercase letters, digits and `-` (e.g. `mom-ipad`, `alex-laptop`).
Install files go to `~/vpn-clients/<Server-Name>/users/` and `/devices/`; passwords are appended
to `~/vpn-clients/CREDENTIALS.txt`.

```bash
sudo swanstrap add-user alex
sudo swanstrap add-device alex-phone ios 30                     # 30-day certificate
sudo swanstrap add-device alex-phone-fra ios 30 aws-de-fra-01   # file for another server
sudo swanstrap remove alex-phone
```

---

## 5. Adding more servers

The **CA server** prepares the new server; the new server only needs the bundle.

```bash
# 1. On the CA server
sudo swanstrap add-server aws-de-fra-01 Frankfurt eu-central-1 203.0.113.20

# 2. Copy the bundle to the new VPS and install it
scp ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar ubuntu@203.0.113.20:
ssh ubuntu@203.0.113.20 'tar xf swanstrap-aws-de-fra-01.tar && sudo ./swanstrap/lib/install.sh && rm -r swanstrap-aws-de-fra-01.tar swanstrap'

# 3. Open UDP 500/4500 in that provider's firewall
# 4. On the CA server: delete the bundle (it contains the server's private key) and save the inventory
rm ~/vpn-clients/AWS-PQ-Frankfurt/swanstrap-aws-de-fra-01.tar
sudo swanstrap sync-kit ~/swanstrap && cd ~/swanstrap && git add ca && git commit -m "Add aws-de-fra-01" && git push
```

The new server creates its own `personal` login (password in its `~/vpn-clients/CREDENTIALS.txt`).
For device certificates on it, run `swanstrap add-device <name> <type> [days] aws-de-fra-01` on the CA server.

---

## 6. Connect from Windows

### Option A: setup script (recommended)

1. Copy the `.ps1` file to the PC: `users/<you>-<Server>.ps1` (username login) or `devices/<name>-<Server>.ps1` (certificate login).
2. In File Explorer open that folder, type `powershell` in the address bar and press Enter, then open an **Administrator** window in the same folder:
   ```powershell
   Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -Command cd '$PWD'"
   ```
3. In the Administrator window:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\personal-OCI-PQ-Singapore.ps1
   ```
   A device file asks for its **install password** (from `CREDENTIALS.txt`).
4. Connect: **Settings → Network & internet → VPN → <Server name> → Connect**.
   A username login asks for the username and password the first time.

### Option B: manual (username login)

1. Double-click `PQ-VPN-Root-CA.crt` → Install Certificate → **Local Machine** → *Trusted Root Certification Authorities*.
2. Settings → VPN → **Add VPN**: provider *Windows (built-in)*, name = server name, server = server IP, type **IKEv2**, sign-in **User name and password**.
3. Windows defaults to weak encryption that the server rejects. In an Administrator PowerShell:
   ```powershell
   Set-VpnConnectionIPsecConfiguration -ConnectionName '<Server name>' -Force `
     -EncryptionMethod AES256 -IntegrityCheckMethod SHA384 -DHGroup ECP384 `
     -CipherTransformConstants GCMAES256 -AuthenticationTransformConstants GCMAES256 -PfsGroup ECP384
   ```

**Remove:** `Remove-VpnConnection -Name '<Server name>' -Force` (add `-AllUserConnection` for device logins).

---

## 7. Connect from iPhone / iPad

### Option A: profile (recommended)

1. Send the `.mobileconfig` to the device (AirDrop, iCloud Drive → Files, or email).
2. **Settings → Profile Downloaded → Install**, enter the passcode, then the VPN password
   (username login) or the **install password** (device login).
3. **Once per device:** Settings → General → About → **Certificate Trust Settings** → turn on **PQ-VPN Root CA**.
4. Connect: **Settings → VPN → <Server name>**.

### Option B: manual (username login)

1. Install `PQ-VPN-Root-CA.pem` and trust it (step 3 above).
2. Settings → General → VPN & Device Management → VPN → **Add VPN Configuration**:
   Type **IKEv2**, Server and Remote ID = server IP, Local ID blank, User Authentication **Username**.

**Remove:** Settings → General → VPN & Device Management → the profile → Remove Profile.

---

## 8. Giving a friend access

```bash
sudo swanstrap add-device alex-phone ios 30        # on the CA server
```

Send `devices/alex-phone-<Server>.mobileconfig` (or `.ps1`), and send the **install password**
from `CREDENTIALS.txt` through a different channel. Remove later with `sudo swanstrap remove alex-phone`.
Certificates can't be revoked, so they keep working until they expire: give temporary devices short lifetimes.

---

## 9. Server administration

| Task | Command |
|---|---|
| Overview | `sudo swanstrap list` |
| Who is connected | `sudo swanctl --list-sas` |
| Disconnect a session | `sudo swanctl --terminate --ike-id <id>` |
| Live log | `sudo journalctl -u strongswan -f` |
| Restart the VPN | `sudo systemctl restart strongswan` |
| Reload config (no disconnect) | `sudo swanctl --load-all` |
| Check ML-KEM | `sudo swanctl --list-algs \| grep ML_KEM` |
| Firewall state | `sudo swanstrap firewall` |
| Re-apply firewall | `sudo systemctl restart swanstrap-firewall` |

**Files on a server**

| Path | Purpose |
|---|---|
| `/etc/swanstrap/server.conf` | This server's identity and settings |
| `/etc/swanctl/conf.d/pq-vpn.conf` | VPN connections (generated from `templates/pq-vpn.conf.tmpl`) |
| `/etc/swanctl/conf.d/pq-vpn-user-<name>.conf` | One username login per file (root only) |
| `/etc/swanctl/x509ca/`, `x509/`, `private/` | Root CA, server certificate, server key |
| `/root/vpn-ca/` | CA server only: encrypted CA key, inventory, issued certificates |
| `/usr/local/share/swanstrap/` | Installed copy of this kit; `swanstrap` command |
| `/usr/local/src/strongswan/` | Source build of strongSwan (source mode only) |
| `/etc/systemd/system/swanstrap-firewall.service` | Re-applies the firewall rules at boot |

**Automatic warnings** at SSH login: a certificate expiring within 60 days, or a new strongSwan
release (source builds only; `apt` updates distro packages).

**Firewall:** `swanstrap-firewall.service` opens UDP 500/4500 + ESP, forwards and NATs the client
pools, clamps TCP MSS, and blocks IPv6 leaks. If `ufw` is active, the rules are written into ufw's
`before.rules` instead. Your cloud provider's firewall still needs UDP 500 and 4500 open.

---

## 10. Troubleshooting

Watch the server log while the device connects: `sudo journalctl -u strongswan -f`

| Symptom | Likely cause | Fix |
|---|---|---|
| Device times out, nothing in the log | Cloud firewall blocks UDP 500/4500 | Open them in the provider console |
| `NO_PROPOSAL_CHOSEN` | Windows still on weak default encryption | Re-run the `.ps1`, or the command in section 6 |
| Windows error 13801 / "credentials unacceptable" | Root CA not in Local Machine → Trusted Root | Re-run the `.ps1` as Administrator |
| iPhone: "Unable to validate server certificate" | Root CA not trusted | Certificate Trust Settings → PQ-VPN Root CA on |
| `EAP-MSCHAPv2 failed` | Wrong username/password | Check `CREDENTIALS.txt` |
| Connected but no internet | Firewall rules missing | `sudo swanstrap firewall`, then `sudo systemctl restart swanstrap-firewall` |
| Some sites hang | MTU | MSS clamp: `sudo iptables -t mangle -S FORWARD` |
| Stopped working after the server restarted | Public IP changed (ephemeral IP) | Reserve a static IP; re-run `bootstrap.sh --id <id>` and reinstall the device files |
| bootstrap: "kernel lacks IPsec support" | OpenVZ/LXC or a stripped kernel | Use a KVM / full-VM VPS |
| bootstrap: "dpkg lock" / very slow start | First-boot updates running | It waits up to 10 min automatically |
| Build failed | New strongSwan needs new build deps | Log in `/usr/local/src/strongswan/build-*.log`; run with `--strongswan source=6.1.0` |
| "wrong CA passphrase" | Typo, or a different CA | Try again; if lost, `--new-ca` (devices need new files) |

---

## 11. Security notes

- **Post-quantum** protection applies only to clients that support ML-KEM; built-in Windows/iOS clients use strong classical crypto.
- **The repo holds the CA key encrypted with AES-256.** The CA passphrase is the only thing protecting it,
  so keep the repo **private** and store the passphrase in a password manager, never in the repo.
- `.gitignore` and a **pre-commit hook** (`hooks/`, enabled by bootstrap) block passwords, private keys and client files from being committed.
- Delete `~/vpn-clients/CREDENTIALS.txt` and bundles from servers once stored safely.
- One certificate per device; device certificates can't be revoked, so use short lifetimes for temporary access.
- The root CA is valid for 10 years. bootstrap warns when less than a year is left and refuses an expired CA (use `--new-ca`).

---

## 12. Repository layout

```
bootstrap.sh              fresh VPS -> CA server (--quick | guided | --config | --dry-run)
config.example.env        every setting, documented
lib/common.sh             shared helpers (validation, pools, inventory, certificates)
lib/detect.sh             provider / region / IP / city detection + region->city table
lib/install.sh            packages, strongSwan (package or source), files, firewall, service
lib/firewall.sh           iptables or ufw rules, IPv6 leak protection
bin/swanstrap             management command
templates/pq-vpn.conf.tmpl    strongSwan connection config
system/                   login warnings, release check, firewall unit, apt pin
vendor/                   strongSwan 6.1.0 source + signature + release key (offline fallback)
ca/                       pq-vpn-root-ca.crt, pq-vpn-root-ca.key.enc (encrypted), servers.tsv (inventory)
hooks/pre-commit          blocks secrets from being committed
```
