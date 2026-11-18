# passerel-wol-ssh

# Remote wake-up and SSH access through a Debian gateway

This project lets you power on a computer remotely (Wake-on-LAN), then open an SSH session on it, through a small Debian server acting as a gateway. The gateway is the only exposed machine: it filters connections, accepts SSH keys only, and can do nothing but send the wake-up signal and relay the session.

```
 [ CLIENT ]  ── Internet / network ──>  [ Debian GATEWAY ]  ── local network ──>  [ TARGET ]
 Linux laptop that                      filters, wakes,                          computer to power
 wants to connect                       relays the connection                    on and reach
```

The gateway and the target must be **on the same local network**: the wake-up signal is a broadcast, which does not cross routers.

---

## Contents

1. [Files](#1-files)
2. [Requirements](#2-requirements)
3. [Information to collect](#3-information-to-collect)
4. [Installation](#4-installation)
5. [Usage](#5-usage)
6. [Access from outside](#6-access-from-outside)
7. [Security: what protects what](#7-security-what-protects-what)
8. [Troubleshooting](#8-troubleshooting)
9. [Assembly module `wol.asm`](#9-assembly-module-wolasm)
10. [Rolling back](#10-rolling-back)

---

## 1. Files

| File | Goes on | Role |
|---|---|---|
| `secure_wol.sh` | Client | Requests the wake-up, waits for the boot, opens the SSH session through the gateway |
| `install_proxy_debian.sh` | Gateway | Allowlist firewall, key-only SSH, restricted jump account, fail2ban |
| `install_target.sh` | Target (in Linux) | SSH accepted from the gateway only, permanent Wake-on-LAN on the network card |
| `wol.asm` | Gateway (optional) | Small assembly program that sends the wake-up signal, an alternative to `wakeonlan` |

Each script starts with a **CONFIGURATION** block to fill in. As long as a required value is empty, the script stops and tells you which one.

---

## 2. Requirements

- **Client**: Linux with `ssh` (package `openssh-client`).
- **Gateway**: Debian 12 or 13, permanently connected to the target's local network, with a user account that has `sudo`. No graphical interface needed.
- **Target**: Linux using `apt` (Debian, Ubuntu, Kali, Mint…), connected to the router **with an Ethernet cable**. Wake-on-LAN does not work reliably over Wi-Fi.
- **Access to all three machines** during installation, ideally with a screen and keyboard on the gateway.

The gateway and target scripts need **Unix line endings**. If they were edited on Windows, convert them before running:

```bash
sed -i 's/\r$//' *.sh
```

---

## 3. Information to collect

Collect these values before you start. The addresses in this example are fictitious.

| Information | Where | Command | Variable(s) |
|---|---|---|---|
| Target local IP | On the target | `ip -4 addr` (`inet` line of the Ethernet card), or `ipconfig /all` on Windows | `TARGET_IP` (gateway and client) |
| MAC of the target's Ethernet card | On the target | `ip link` (after `link/ether`), or "Physical Address" on Windows | `TARGET_MAC` (gateway) |
| Name of the target's Ethernet card | On the target, in Linux | `ip link` (e.g. `eth0`, `enp3s0`) | `NIC` (target) |
| Network broadcast address | On the gateway | `ip -4 addr` (after `brd`, usually ending in `.255`) | `LAN_BROADCAST` (gateway) |
| Gateway local IP | On the gateway | `hostname -I` (**capital** I) | `PROXY_LAN_IP` (target), `PROXY_IP_LOCAL` (client) |
| Public IP of the gateway's router | On the gateway | `curl -4 ifconfig.me` or `wget -qO- -4 ifconfig.me` | `PROXY_IP` (client) |
| Your account on the gateway | On the gateway | `whoami` | `ADMIN_USER` (gateway) |
| Your account on the target | On the target, in Linux | `whoami` | `ADMIN_USER` (target), `TARGET_USER` (client) |
| Client IP as seen by the gateway | See below | `echo $SSH_CONNECTION` | `WHITELIST` (gateway) |

**Finding the client IP for the allowlist.** The most reliable way is to ask the gateway what it sees. From the client, connect to the gateway **before** installing the firewall, then type on the gateway:

```bash
echo $SSH_CONNECTION
```

The first number shown is the address to allow. A client connected **over both Wi-Fi and cable** has two addresses, and Linux prefers the cable: allow both. To see which one is actually used, type on the client `ip route get <gateway-ip>` and read the value after `src`.

**DHCP reservations.** In the router's interface, reserve a fixed address for the gateway, the target and each network card of the client. Otherwise an address may change after a reboot, and the firewall will block the connection.

---

## 4. Installation

Order matters: each step assumes the previous one succeeded.

### 4.1 On the client: create the SSH keys

Three keys, each with its own passphrase:

```bash
ssh-keygen -t ed25519                                    # gateway administration
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wol_proxy     # jump account (wake-up)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wol_target    # session on the target
```

For the first command, just press **Enter** when asked for the file location. The passphrase is not displayed while typing; that is normal.

### 4.2 On the Debian gateway

**a. Give your admin key to the gateway.** From the client:

```bash
ssh-copy-id <account>@<gateway-local-ip>
ssh <account>@<gateway-local-ip>      # should ask for the key's passphrase
```

If the connection is refused, install the SSH server on the gateway first: `sudo apt install openssh-server`.

**b. Copy the files to the gateway.** From the client:

```bash
scp install_proxy_debian.sh ~/.ssh/id_ed25519_wol_proxy.pub <account>@<gateway-local-ip>:~
```

A USB stick works too. On a gateway without a graphical interface, mount it by hand:

```bash
lsblk                              # find the stick (column RM = 1), e.g. sdb1
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb
cp /mnt/usb/install_proxy_debian.sh ~/
sudo umount /mnt/usb
```

**c. Fill in the CONFIGURATION block** with `nano install_proxy_debian.sh`:

```bash
ADMIN_USER="myaccount"
JUMP_USER="jumpuser"
SSH_PORT="22"
TARGET_IP="192.168.1.20"
TARGET_PORT="22"
TARGET_MAC="AA:BB:CC:DD:EE:FF"
LAN_BROADCAST="192.168.1.255"

WHITELIST=(
  "192.168.1.30"
  "192.168.1.31"
)

JUMP_PUBKEY_FILE="/home/myaccount/id_ed25519_wol_proxy.pub"
```

In `WHITELIST`: one address per line, in **straight** double quotes, with no empty `""` line and no character after the closing quote.

**d. Run the script**, preferably from the gateway's own screen and keyboard:

```bash
chmod +x install_proxy_debian.sh
sudo ./install_proxy_debian.sh
```

When it reaches the firewall, the script shows a box and asks **one** question. From the client, open a **new** connection `ssh <account>@<gateway-local-ip>`. If it works, type `y` then Enter within 60 seconds. With no answer, or any other answer, the old firewall is restored and nothing is saved: fix the allowlist and run again. The script can be run as many times as needed.

It should end with `[ok] Gateway configured`.

**e. Check**, on the gateway:

```bash
sudo iptables -S INPUT                              # starts with -P INPUT DROP, one line per allowed IP
sudo sshd -T | grep -i passwordauthentication       # passwordauthentication no
sudo fail2ban-client status sshd                    # Status for the jail: sshd
```

**f. If `JUMP_PUBKEY_FILE` was left empty**, add the jump key by hand. From the client:

```bash
scp ~/.ssh/id_ed25519_wol_proxy.pub <account>@<gateway-local-ip>:/tmp/
ssh -t <account>@<gateway-local-ip> "sudo sh -c 'cat /tmp/id_ed25519_wol_proxy.pub >> /home/jumpuser/.ssh/authorized_keys' && rm /tmp/id_ed25519_wol_proxy.pub"
```

The `-t` option is required: without it, `sudo` cannot ask for your password.

**g. Test the wake-up.** From the client:

```bash
ssh -i ~/.ssh/id_ed25519_wol_proxy -o IdentitiesOnly=yes -T jumpuser@<gateway-local-ip>
```

The expected answer is `Sending magic packet to …`. The jump account cannot do anything else.

### 4.3 On the target, booted into Linux

**a. Install the SSH server**, on the target:

```bash
sudo apt install openssh-server
sudo systemctl enable --now ssh
```

**b. Send the session key.** From the client, **before** running the target script, which will then block direct connections:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_wol_target.pub <account>@<target-ip>
```

**c. Fill in the CONFIGURATION block** of `install_target.sh`:

```bash
ADMIN_USER="myaccount"
PROXY_LAN_IP="192.168.1.10"
SSH_PORT="22"
NIC="eth0"
```

**d. Run the script:**

```bash
chmod +x install_target.sh
sudo ./install_target.sh
```

It should show `Wake-on: g` then `[ok] Target configured`.

After this script, the target refuses every incoming connection except SSH from the gateway. Services it offered on the network (file sharing, game server…) are no longer reachable. Outgoing connections are not affected.

**e. Manual settings on the target:**

- **BIOS/UEFI**: enable Wake-on-LAN. Depending on the vendor: "Wake on LAN", "Power On by PCI-E", "Resume by LAN". On some boards you also need to disable "ErP" or "Deep Sleep".
- **Default boot**: in a dual boot, Linux must start without intervention; otherwise the wake-up will start Windows and SSH will not answer. Check in Linux:
  ```bash
  sudo efibootmgr                                                  # BootOrder: the Linux entry first
  sudo grep -E "^(menuentry|submenu)" /boot/grub/grub.cfg | cut -d"'" -f2   # Linux on the first line
  ```
  `GRUB_DEFAULT=0` in `/etc/default/grub` boots the first line.
- **Windows** (dual boot): turn off Fast Startup (Control Panel, Power Options, "Choose what the power buttons do"). In Device Manager, properties of the Ethernet card, enable "Wake on Magic Packet" and tick "Allow this device to wake the computer".

### 4.4 On the client: configure `secure_wol.sh`

Fill in the CONFIGURATION block:

```bash
PROXY_IP="203.0.113.45"       # public IP of the gateway's router, or DynDNS name
PROXY_PORT="22"               # port forwarded by the router
PROXY_IP_LOCAL="192.168.1.10" # local IP of the gateway (optional)
PROXY_PORT_LOCAL="22"
PROXY_USER="jumpuser"
TARGET_IP="192.168.1.20"
TARGET_PORT="22"
TARGET_USER="myaccount"
```

If `PROXY_IP_LOCAL` is set and answers, the script uses it automatically: that is the case at home. Elsewhere, it uses `PROXY_IP`. If you only connect from home, simply put the gateway's local IP in `PROXY_IP` and leave `PROXY_IP_LOCAL` empty.

**First run**, with the target powered on:

```bash
chmod +x secure_wol.sh
HOSTKEY_POLICY=ask ./secure_wol.sh --connect
```

ssh shows the gateway's fingerprint, then the target's. Before answering `yes`, compare each one with what the machine concerned shows:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

This check guarantees you are talking to your own machines and not to someone in the middle. The fingerprints are stored under the names `wol-proxy` and `wol-target`, valid whether you go through the local or the public address.

---

## 5. Usage

Run as a normal user, **never with `sudo`**:

```bash
./secure_wol.sh             # wake-up, wait for boot, then session
./secure_wol.sh --wake      # wake-up only
./secure_wol.sh --connect   # session only (target already on)
./secure_wol.sh --help      # usage reminder
```

The key passphrases are asked only once, at the start. If the target is already on, the wait ends at the first check. Type `exit` to close the session.

---

## 6. Access from outside

**Port forwarding.** In the gateway's router interface, forward a TCP port (22, or another external port) to port 22 of the gateway's local IP. Put that external port in the client's `PROXY_PORT`.

**Public IP.** Check that the "WAN" address shown by the router matches the one returned by `curl -4 ifconfig.me`. If they differ, your provider shares your address (CGNAT) and port forwarding will not work: you then need to ask the provider for a public IP, or use a VPN. If the public address changes regularly, use a DynDNS name (DuckDNS, No-IP, or the router's own) in `PROXY_IP`.

**Allowlist and mobile networks.** The allowlist filters by IP address. It suits one or two locations with a fixed public IP. It does not suit a client on the move: on 4G/5G, the address is shared among many subscribers and changes often. Two options in that case:

1. **WireGuard VPN on the gateway** (recommended). The client authenticates with its key, from any network. SSH is accepted only through the tunnel, and the gateway answers no stranger, which makes it invisible to scans.
2. **No allowlist, key-only SSH**, with fail2ban and the rate limit already in place. Simpler. Without your private key, a brute-force attack has practically no chance of success, but the port stays visible on the Internet.

Both options require adapting `install_proxy_debian.sh`.

---

## 7. Security: what protects what

| Measure | Where | Effect |
|---|---|---|
| Allowlist firewall, IPv6 closed | Gateway | Only allowed IPs reach SSH. IPv6 cannot be used as a back door |
| Rate limit on new connections | Gateway | Slows down scans and brute force |
| Key-only SSH, root forbidden, `AllowUsers` | Gateway and target | No password to guess |
| fail2ban (systemd backend) | Gateway | Bans an IP after 3 failures, increasing up to one week |
| Jump account without shell (`ForceCommand`, `PermitOpen`) | Gateway | A stolen jump key can only wake the target and reach its SSH port |
| SSH accepted from the gateway only | Target | The target is never directly exposed |
| Separate keys with passphrases, strict fingerprint checking | Client | A stolen laptop gives no immediate access. A man in the middle is detected |

This project contains **no client-side access control**: such a check runs on the user's machine, which can modify it. All protection lives on the gateway and the target.

Keep all three machines up to date (`sudo apt update && sudo apt full-upgrade`), especially the gateway, which is exposed to the Internet.

---

## 8. Troubleshooting

### Script messages

| Message | Cause | Fix |
|---|---|---|
| `Fill in the CONFIGURATION block : …` | Required values are empty | Fill in the listed variables |
| `Invalid WHITELIST IP : ''` | Empty `""` line in the list | Delete the line (`Ctrl+K` in nano) |
| `Invalid WHITELIST IP : '…s'` | Character typed after the closing quote | Delete it |
| `… has no key in …/authorized_keys` | `ssh-copy-id` step not done | Run `ssh-copy-id` from the client |
| `Your current IP (…) is not in WHITELIST` | Connected from an address that is not allowed | Add that address to the list |
| `Firewall cancelled, old rules restored` | No confirmation within 60 s | Run again, test a new connection and type `y` |
| `apt-get update failed` | Misconfigured repositories | See "Repositories" below |

### Repositories (`apt update` errors)

| Error | Cause | Fix |
|---|---|---|
| `… deb.debian.org/debian bookworm-security Release does not have a Release file` | Security repository at the wrong address | The line must point to `…/debian-security`, not `…/debian` |
| `python3-systemd Depends python3 (< 3.12)` | Debian 13 system with Debian 12 repositories | Check `grep VERSION_CODENAME /etc/os-release`. If `trixie`, replace `bookworm` with `trixie` in `/etc/apt/sources.list`, then `apt update && apt full-upgrade` |
| `https://kali.download kali-rolling Release does not have a Release file` | `/kali` missing from the address | `deb https://kali.download/kali kali-rolling main contrib non-free non-free-firmware` |

Do not run `apt autoremove` while the repositories do not match the system: it would remove packages you need.

### Connection

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection timed out` to the gateway | Client IP missing from the allowlist | Compare with `ip route get <gateway-ip>` (`src` value). Client on Wi-Fi **and** cable: allow both addresses |
| `Connection timed out` to the public IP, from home | The router does not loop back to its own IP | Set `PROXY_IP_LOCAL` |
| `Connection timed out` from outside | No port forwarding, shared public IP | See section 6 |
| `Permission denied (publickey)` | Public key missing from the right account | Check `authorized_keys` of the account concerned |
| `Host key verification failed` | First run without `HOSTKEY_POLICY=ask`, or a different machine | First run: `HOSTKEY_POLICY=ask`. Otherwise, check the fingerprints **before** changing anything |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Machine reinstalled, or man in the middle | If the reinstall is certain: `ssh-keygen -R wol-proxy` (or `wol-target`), then run again with `HOSTKEY_POLICY=ask` |
| fail2ban banned the client | Too many attempts, or too many keys offered | On the gateway: `sudo fail2ban-client set sshd unbanip <ip>` |
| `sudo: a terminal is required` | `sudo` command passed through ssh without a terminal | Add the `-t` option to ssh |

### Wake-up

| Symptom | Likely cause | Fix |
|---|---|---|
| The target does not power on | WoL disabled in the BIOS, ErP enabled | BIOS/UEFI settings |
| Does not power on after a Windows shutdown | Fast Startup enabled | Turn it off, and enable "Wake on Magic Packet" |
| Does not power on after a power cut | Many cards lose WoL without power | Power on once manually |
| Powers on, but SSH does not answer | Windows booted instead of Linux | `sudo efibootmgr` in Linux: put the Linux entry back first with `sudo efibootmgr -o <order>` |
| `Wake-on: d` on the target | WoL mode disabled | `sudo systemctl restart wol@<card>` |

### Typing in the terminal

| Message | Cause |
|---|---|
| `bad interpreter` / `^M` | Windows line endings: `sed -i 's/\r$//' file.sh` |
| `command not found` on `sudo./…` or `cd~` | Missing space: `sudo ./…`, `cd ~` |
| `Bad configuration option: …` | Typo in the option (`IdentitiesOnly`, `BindAddress`) |
| `grep` prints nothing | Misspelled word (`WHITELIST`, `passwordauthentication`) |
| `127.0.1.1` instead of the local IP | Lowercase `hostname -i` instead of `hostname -I` |
| Strange behavior with quotes | Backtick `` ` `` typed instead of the apostrophe `'` |

To avoid typos, open this README on the machine concerned and copy-paste the commands (`Ctrl+Shift+V` in a terminal). The **Tab** key completes file names.

---

## 9. Assembly module `wol.asm`

Dependency-free x86-64 Linux program that sends the magic packet (6 × `0xFF` followed by the MAC 16 times, i.e. 102 bytes) as a UDP broadcast. It needs no root privileges and validates its arguments strictly.

```bash
sudo apt install nasm
nasm -f elf64 wol.asm -o wol.o && ld -o wol wol.o
./wol AA:BB:CC:DD:EE:FF                    # broadcast 255.255.255.255, port 9
./wol AA:BB:CC:DD:EE:FF 192.168.1.255      # local network broadcast
./wol AA:BB:CC:DD:EE:FF 192.168.1.255 7    # custom port
```

Exit codes: 0 success, 1 usage, 2 invalid MAC, 3 invalid IP, 4 invalid port, 5 socket error, 6 send failure.

To use it instead of `wakeonlan` on the gateway:

```bash
sudo install -m 755 wol /usr/local/bin/wol
```

Then, in `install_proxy_debian.sh`, enable the `WOL_CMD="/usr/local/bin/wol …"` line and run the script again.

---

## 10. Rolling back

**Gateway:**

```bash
sudo rm /etc/ssh/sshd_config.d/00-hardening.conf
sudo sed -i '/^# >>> wol-jump/,/^# <<< wol-jump/d' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
sudo rm /etc/fail2ban/jail.d/sshd-local.conf && sudo systemctl restart fail2ban
sudo rm /etc/sysctl.d/90-hardening.conf
sudo rm /etc/iptables/rules.v4 /etc/iptables/rules.v6
sudo iptables -P INPUT ACCEPT && sudo iptables -F INPUT
sudo ip6tables -P INPUT ACCEPT && sudo ip6tables -F INPUT
sudo deluser --remove-home jumpuser
```

A copy of `sshd_config` is kept as `/etc/ssh/sshd_config.bak.<date>` on every run.

**Target:**

```bash
sudo systemctl disable --now wol@<card>.service
sudo rm /etc/systemd/system/wol@.service
sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl reload ssh
sudo rm /etc/iptables/rules.v4 /etc/iptables/rules.v6
sudo iptables -P INPUT ACCEPT && sudo iptables -F INPUT
sudo ip6tables -P INPUT ACCEPT && sudo ip6tables -F INPUT
```
