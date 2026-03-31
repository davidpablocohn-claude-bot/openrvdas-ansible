# OpenRVDAS Ansible Playbook

Ansible replacement for `utils/install_openrvdas.sh`. Installs and configures
OpenRVDAS on Ubuntu, Debian, Raspberry Pi OS, CentOS, Rocky Linux, AlmaLinux, or macOS.

## Prerequisites

- SSH access to the target host(s)
- Python 3 and pip3 on your local machine (used to install Ansible if needed)
- The target host is reachable and Python 3 is available on it

Ansible itself does **not** need to be pre-installed — `configure_and_install.sh`
will detect and install it automatically.

## Using This as a Standalone Repo

This directory is fully self-contained and can be used as its own repository,
independent of the main OpenRVDAS codebase. The playbook clones OpenRVDAS
itself during installation.

```bash
git clone https://github.com/your-org/openrvdas-ansible
cd openrvdas-ansible
./configure_and_install.sh
```

## Interactive Installer

`configure_and_install.sh` is the recommended entry point. It:

1. Checks for Ansible and **installs it automatically** if not present
   (via Homebrew on macOS, pip3 on Linux)
2. Installs required Ansible collections
3. Prompts for all configuration values, with previous answers shown as defaults
4. Writes `inventory/host_vars/<host>.yml` with non-secret config
5. Creates and encrypts `vault/secrets.yml`
6. Updates `hosts.ini`
7. Runs `ansible-playbook`

```bash
./configure_and_install.sh
```

The vault password is saved to `vault/.vault_pass` (mode 600, git-ignored) so
subsequent runs don't require re-entering it:

```bash
ansible-playbook site.yml -i inventory/hosts.ini --vault-password-file vault/.vault_pass
```

---

## Quick Start (manual)

### 1. Install Ansible and required collections

```bash
# macOS
brew install ansible

# Ubuntu/Debian
pip3 install --user ansible

# Then install collections
ansible-galaxy collection install -r requirements.yml
```

### 2. Set up your secrets file

```bash
cp vault/secrets.yml.example vault/secrets.yml
```

Edit `vault/secrets.yml` and set real values for:

| Variable | Description |
|---|---|
| `rvdas_database_password` | Password for the Django superuser and database |
| `supervisord_webinterface_pass` | Password for the supervisord web UI (only used if `supervisord_webinterface_auth: true`) |

Then encrypt it:

```bash
ansible-vault encrypt vault/secrets.yml
```

### 3. Add your host to the inventory

Edit `inventory/hosts.ini`. The host must appear in **both** `[openrvdas]` and
the appropriate OS group (`[ubuntu]`, `[debian]`, `[raspbian]`, `[centos]`,
`[rocky]`, `[alma]`, or `[macos]`) so that the correct OS-specific variables
are applied.

**Example — Ubuntu host over SSH as root:**
```ini
[openrvdas]
my-vessel ansible_host=192.168.1.10 ansible_user=root ansible_python_interpreter=/usr/bin/python3

[ubuntu]
my-vessel
```

**Example — local install:**
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

> **Host key verification:** `ansible.cfg` sets `host_key_checking = False`, so
> new hosts are accepted automatically without needing their keys pre-added to
> `~/.ssh/known_hosts`. If you prefer strict host key checking, remove that
> setting and run `ssh-keyscan <host> >> ~/.ssh/known_hosts` before the first
> connection.

### 5. Run the playbook

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass
```

If the connecting user needs a sudo password (not needed when connecting as root):

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass --ask-become-pass
```

## Configuration

All non-secret configuration lives in `inventory/group_vars/all.yml`.
Edit it before running the playbook, or override any variable at runtime with `-e`.

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

### Runtime overrides

Any variable can be overridden on the command line with `-e`:

```bash
# Install from the dev branch with SSL enabled
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass \
  -e "openrvdas_branch=dev use_ssl=true"

# Disable the web GUI
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass \
  -e "install_gui=false"
```

### Per-host overrides

To set variables for a specific host only, create a file in `inventory/host_vars/`:

```bash
mkdir -p inventory/host_vars
cat > inventory/host_vars/my-vessel.yml <<EOF
openrvdas_branch: dev
use_ssl: true
install_simulate_nbp: false
EOF
```

## OS Support

| OS | Version | Python |
|---|---|---|
| Ubuntu | 20.04, 22.04, 24.04 | 3.13 (via deadsnakes PPA) |
| Debian | 11, 12 | 3.13 (via deadsnakes PPA) |
| Raspberry Pi OS | Bookworm (12) | 3.11 (system) |
| CentOS | 8, 9 | 3.12 (from AppStream) |
| Rocky Linux | 8, 9 | 3.12 (from AppStream) |
| AlmaLinux | 8, 9 | 3.12 (from AppStream) |
| macOS | 12+ (Intel & Apple Silicon) | 3.13 (via Homebrew) |

> **macOS notes:**
> - Set `install_root` to a user-writable path (e.g. `/usr/local`) — `/opt` requires root.
> - Add the host to the `[macos]` group in `hosts.ini`.
> - The `rvdas_user` is set automatically to the connecting user; no new system user is created.

## Smoke Test

After installation, `configure_and_install.sh` will offer to run the smoke test
automatically. You can also run it at any time:

```bash
ansible-playbook smoke-test.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass --limit <host>
```

The smoke test checks:
- All supervisord processes are running (none FATAL or EXITED)
- nginx is active (when GUI is installed)
- Web server responds to HTTP/HTTPS
- OpenRVDAS directory and `manage.py` are present
- Django migrations are fully applied
- Disk usage on the install root is under 85%

## Re-running and Updates

The playbook is fully idempotent. Re-running it will:

- Pull the latest code from the configured branch
- Re-install any new Python requirements
- Re-apply any changed configuration files
- Reload supervisord if any service configs changed

To update OpenRVDAS after a new release:

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass
```

## Running Specific Roles

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
# Apply only supervisor config changes
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass --tags supervisor

# Re-run Django migrations after a code update
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass --tags django

# Regenerate the nginx config (e.g. after changing SSL settings)
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass --tags nginx,supervisor
```

## Dry Run

Check what would change without making any modifications:

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass --check
```

## SSL Configuration

### Self-signed certificate (default when `use_ssl: true`)

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass \
  -e "use_ssl=true"
```

Ansible will generate a certificate valid for 10 years with SANs for the
hostname, `localhost`, `127.0.0.1`, and the server's IP address.

### Supplying your own certificate

Place the certificate and key files somewhere accessible to Ansible, then:

```bash
ansible-playbook site.yml -i inventory/hosts.ini --ask-vault-pass \
  -e "use_ssl=true have_ssl_certificate=true ssl_crt_location=/path/to/your.crt ssl_key_location=/path/to/your.key"
```

## Services

All services run under supervisord. To manage them on the target host:

```bash
# Check status of all services
supervisorctl status

# Restart a specific service
supervisorctl restart logger_manager
supervisorctl restart cached_data_server

# Restart the web GUI
supervisorctl restart django

# View logs
tail -f /var/log/openrvdas/logger_manager.stderr
tail -f /var/log/openrvdas/nginx.stderr
tail -f /var/log/openrvdas/uwsgi.stderr
```

## Directory Structure

```
openrvdas-ansible/
├── site.yml                        # Top-level install playbook
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
│       └── macos.yml               # macOS settings
├── vault/
│   ├── secrets.yml                 # Encrypted secrets (created by you)
│   └── secrets.yml.example         # Template — copy to secrets.yml
└── roles/
    ├── common/                     # System user and directory creation
    ├── packages/                   # OS package installation
    ├── openrvdas/                  # Git clone, venv, settings, Django setup
    ├── nginx/                      # Nginx config and SSL
    ├── uwsgi/                      # uWSGI config
    ├── supervisor/                 # Supervisord config and service management
    └── firewall/                   # firewalld + SELinux (CentOS/RHEL only)
```
