# OpenRVDAS Ansible Playbook

Ansible replacement for `utils/install_openrvdas.sh`. Installs and configures
OpenRVDAS on Ubuntu, Debian, Raspberry Pi OS, CentOS, Rocky Linux, AlmaLinux,
Void Linux, or macOS.

## Quick Start

```bash
git clone https://github.com/davidpablocohn-claude-bot/openrvdas-ansible
cd openrvdas-ansible
./configure_and_install.sh
```

That's it. The script handles everything else automatically.

## What `configure_and_install.sh` Does

1. **Installs Ansible** if not already present (via Homebrew on macOS, `apt` on
   Debian/Ubuntu, `pip3` on other Linux)
2. **Installs required Ansible collections**
3. **Tests SSH connectivity** to the target host — tries key authentication
   first, then offers password authentication if keys aren't set up
4. **Detects the sudo password requirement** — if the connecting user is not
   root and passwordless sudo isn't configured, prompts once and passes it
   securely to Ansible
5. **Detects the target OS and hostname** automatically over SSH (or from the
   local system for `localhost` installs)
6. **Prompts for all configuration values**, showing previous answers as
   defaults so re-runs are quick
7. **Writes `inventory/host_vars/<host>.yml`** with non-secret config
8. **Encrypts `vault/secrets.yml`** with your passwords
9. **Updates `inventory/hosts.ini`**
10. **Runs `ansible-playbook site.yml`**
11. **Offers to run the smoke test** to verify the installation

Re-running the script on the same host is safe — all values from the previous
run are shown as defaults.

## Prerequisites

- SSH access to the target host (or use `localhost` to install on the current
  machine)
- Python 3 on your local machine
- The target host is reachable and has a supported OS

Ansible itself does **not** need to be pre-installed — `configure_and_install.sh`
will detect and install it automatically.

## Installing on localhost

To install OpenRVDAS on the machine you are currently sitting at:

```bash
./configure_and_install.sh
```

When prompted for the target host, enter `localhost`. The script will detect
your OS automatically. If your user account requires a sudo password, the
script will prompt for it.

## OS Support

| OS | Version | Notes |
|---|---|---|
| Ubuntu | 20.04, 22.04, 24.04 | Python 3.13 via deadsnakes PPA |
| Debian | 11, 12 | Python 3.13 via deadsnakes PPA |
| Raspberry Pi OS | Bookworm (12) | Python 3.11 (system) |
| Void Linux | current | Python 3.x (xbps), supervisor via pip |
| CentOS | 8, 9 | Python 3.12 from AppStream |
| Rocky Linux | 8, 9 | Python 3.12 from AppStream |
| AlmaLinux | 8, 9 | Python 3.12 from AppStream |
| macOS | 12+ (Intel & Apple Silicon) | Python 3.13 via Homebrew |

> **macOS notes:**
> - Set `install_root` to a user-writable path (e.g. `/usr/local`) — `/opt` requires root.
> - Add the host to the `[macos]` group in `hosts.ini`.
> - The `rvdas_user` is set to the connecting user; no new system user is created.

---

## Configuration

All non-secret configuration lives in `inventory/group_vars/all.yml`. The
interactive installer writes per-host overrides to
`inventory/host_vars/<host>.yml`.

| Variable | Default | Description |
|---|---|---|
| `install_root` | `/opt` | Base directory; repo goes to `install_root/openrvdas` |
| `rvdas_user` | `rvdas` | System user that runs all services (Linux only) |
| `openrvdas_repo` | upstream GitHub | Repository URL to clone from |
| `openrvdas_branch` | `master` | Branch to install |
| `http_proxy` | `""` | HTTP proxy for pip and git (empty = no proxy) |
| `nonssl_server_port` | `80` | HTTP port |
| `ssl_server_port` | `443` | HTTPS port (used when `use_ssl: true`) |
| `use_ssl` | `false` | Enable HTTPS |
| `have_ssl_certificate` | `false` | `true` = supply your own cert; `false` = generate self-signed |
| `ssl_crt_location` | `install_root/openrvdas/openrvdas.crt` | Path for the SSL certificate |
| `ssl_key_location` | `install_root/openrvdas/openrvdas.key` | Path for the SSL private key |
| `openrvdas_autostart` | `true` | Start services on boot |
| `install_gui` | `true` | Install nginx + uWSGI web interface |
| `install_firewalld` | `false` | Configure firewalld (CentOS/Rocky/Alma only) |
| `tcp_ports_to_open` | `[]` | Extra TCP ports to open in firewalld |
| `udp_ports_to_open` | `[]` | Extra UDP ports to open in firewalld |
| `install_simulate_nbp` | `true` | Install NBP1406 test data simulator |
| `run_simulate_nbp` | `true` | Autostart simulator on boot |
| `supervisord_webinterface` | `false` | Enable supervisord HTTP web interface |
| `supervisord_webinterface_auth` | `false` | Require login for supervisord web interface |
| `supervisord_webinterface_port` | `9001` | Port for supervisord web interface |

---

## Playbooks

### `site.yml` — Install

Full installation. Normally run via `configure_and_install.sh`, but can also
be invoked directly after configuration has been done once:

```bash
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass
```

The vault password is saved to `vault/.vault_pass` (mode 600, git-ignored) by
the installer, so you won't need to type it again.

Use `--tags` to run only part of the playbook:

| Tag | What it runs |
|---|---|
| `common` | User and directory setup |
| `packages` | System package installation |
| `openrvdas` | Git clone, venv, settings files, Django migrations |
| `django` | Django migrations, collectstatic, superuser creation |
| `nginx` | Nginx config and SSL certificates |
| `uwsgi` | uWSGI config |
| `supervisor` | Supervisor config files and service restart |
| `firewall` | firewalld ports and SELinux (CentOS/Rocky/Alma only) |

Examples:

```bash
# Re-apply only supervisor config changes
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --tags supervisor

# Re-run Django migrations after a code update
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --tags django

# Regenerate the nginx config (e.g. after changing SSL settings)
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --tags nginx,supervisor
```

---

### `update.yml` — Update OpenRVDAS Code

Pulls the latest code from the configured branch, updates Python requirements,
applies settings, runs migrations, and reloads services — without a full
reinstall.

```bash
ansible-playbook update.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass
```

To update to a specific branch:

```bash
ansible-playbook update.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass \
  -e "openrvdas_branch=dev"
```

---

### `backup.yml` — Backup

Creates a timestamped `.tar.gz` on the target host containing:
- Django database (portable JSON via `dumpdata`)
- Cruise and logger configuration files
- Site-specific `settings.py` files

```bash
ansible-playbook backup.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass
```

To also fetch the backup to `./backups/` on your local machine:

```bash
ansible-playbook backup.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass \
  -e "fetch_backup=true"
```

---

### `status.yml` — Health Check

Quick status report across all hosts: supervisor process state, disk usage,
current git branch and version, last log activity, and system uptime.

```bash
ansible-playbook status.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass
```

To check a single host:

```bash
ansible-playbook status.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --limit <host>
```

---

### `smoke-test.yml` — Post-Install Verification

Verifies the installation is working correctly. Run automatically by
`configure_and_install.sh` after installation, or at any time:

```bash
ansible-playbook smoke-test.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --limit <host>
```

Checks:
- All supervisord processes are running (none FATAL or EXITED)
- nginx is active (when GUI is installed)
- Web server responds to HTTP/HTTPS
- OpenRVDAS directory and `manage.py` are present
- Django migrations are fully applied
- Disk usage on the install root is under 85%

---

## Managing an Installed System

All services run under supervisord on the target host:

```bash
# Check status of all services
supervisorctl status

# Restart a specific service
supervisorctl restart logger_manager
supervisorctl restart cached_data_server
supervisorctl restart django

# View logs
tail -f /var/log/openrvdas/logger_manager.stderr
tail -f /var/log/openrvdas/nginx.stderr
tail -f /var/log/openrvdas/uwsgi.stderr
```

---

## Manual Setup (without the interactive installer)

### 1. Install Ansible and required collections

```bash
# macOS
brew install ansible

# Ubuntu/Debian
sudo apt install ansible

# Then install collections
ansible-galaxy collection install -r requirements.yml
```

### 2. Set up your secrets file

```bash
cp vault/secrets.yml.example vault/secrets.yml
```

Edit `vault/secrets.yml` and set real values, then encrypt it:

```bash
ansible-vault encrypt vault/secrets.yml
```

Save the vault password to a file for convenience:

```bash
echo 'your-vault-password' > vault/.vault_pass
chmod 600 vault/.vault_pass
```

### 3. Add your host to the inventory

Edit `inventory/hosts.ini`. The host must appear in **both** `[openrvdas]`
and the appropriate OS group so the correct OS-specific variables are applied.

**Remote Ubuntu host:**
```ini
[openrvdas]
my-vessel ansible_host=192.168.1.10 ansible_user=root ansible_python_interpreter=/usr/bin/python3

[ubuntu]
my-vessel
```

**Local install:**
```ini
[openrvdas]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[ubuntu]
localhost
```

### 4. Verify connectivity

```bash
ansible openrvdas -i inventory/hosts.ini -m ping
```

### 5. Run the playbook

```bash
ansible-playbook site.yml -i inventory/hosts.ini --vault-password-file vault/.vault_pass
```

If the connecting user needs a sudo password:

```bash
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --ask-become-pass
```

---

## SSL Configuration

### Self-signed certificate (default when `use_ssl: true`)

Ansible generates a certificate valid for 10 years with SANs for the hostname,
`localhost`, `127.0.0.1`, and the server's IP address.

```bash
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass \
  -e "use_ssl=true"
```

### Supplying your own certificate

```bash
ansible-playbook site.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass \
  -e "use_ssl=true have_ssl_certificate=true \
      ssl_crt_location=/path/to/your.crt \
      ssl_key_location=/path/to/your.key"
```

---

## Directory Structure

```
openrvdas-ansible/
├── configure_and_install.sh        # Interactive installer (start here)
├── site.yml                        # Full install playbook
├── update.yml                      # Update OpenRVDAS code and restart services
├── backup.yml                      # Backup database and config files
├── status.yml                      # Health check across hosts
├── smoke-test.yml                  # Post-install verification
├── requirements.yml                # Ansible Galaxy collection dependencies
├── inventory/
│   ├── hosts.ini                   # Target hosts
│   └── group_vars/
│       ├── all.yml                 # Shared defaults (edit this)
│       ├── ubuntu.yml              # Ubuntu OS settings
│       ├── debian.yml              # Debian OS settings
│       ├── raspbian.yml            # Raspberry Pi OS settings
│       ├── centos.yml              # CentOS OS settings
│       ├── rocky.yml               # Rocky Linux OS settings
│       ├── alma.yml                # AlmaLinux OS settings
│       ├── void.yml                # Void Linux OS settings
│       └── macos.yml               # macOS settings
├── vault/
│   ├── secrets.yml                 # Encrypted secrets (created by installer)
│   └── secrets.yml.example         # Template
└── roles/
    ├── common/                     # System user and directory creation
    ├── packages/                   # OS package installation
    ├── openrvdas/                  # Git clone, venv, settings, Django setup
    ├── nginx/                      # Nginx config and SSL
    ├── uwsgi/                      # uWSGI config
    ├── supervisor/                 # Supervisord config and service management
    └── firewall/                   # firewalld + SELinux (CentOS/RHEL only)
```
