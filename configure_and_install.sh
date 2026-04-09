#!/usr/bin/env bash
# configure_and_install.sh
#
# Interactive configuration script for OpenRVDAS Ansible installation.
# Prompts for all settings, writes inventory/host_vars/<host>.yml and an
# encrypted vault/secrets.yml, updates hosts.ini, then runs the playbook.
#
# Re-running this script on the same host is safe — values from the previous
# run are shown as defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFS_FILE="$SCRIPT_DIR/.configure_preferences"
VAULT_PASS_FILE="$SCRIPT_DIR/vault/.vault_pass"

# ── Ansible installation check ────────────────────────────────────────────────

install_ansible() {
    echo "  Ansible not found. Installing..."
    case "$(uname -s)" in
        Darwin)
            if command -v brew &>/dev/null; then
                brew install ansible
            else
                echo "  Homebrew not found. Installing Ansible via pip3..."
                pip3 install --user ansible
            fi
            ;;
        Linux)
            # On Debian/Ubuntu, prefer apt — avoids PEP 668 externally-managed-environment errors
            if command -v apt-get &>/dev/null; then
                echo "  Installing Ansible via apt..."
                sudo apt-get update -qq && sudo apt-get install -y ansible && return
                echo "  apt install failed, falling back to pip3..."
            fi
            # On RHEL/CentOS/Rocky, use dnf/pip
            if command -v dnf &>/dev/null; then
                echo "  Installing Ansible via pip3..."
                if ! command -v pip3 &>/dev/null; then
                    sudo dnf install -y python3-pip
                fi
                pip3 install --user ansible || pip3 install --user --break-system-packages ansible
                export PATH="$HOME/.local/bin:$PATH"
                return
            fi
            # Generic Linux fallback
            if ! command -v pip3 &>/dev/null; then
                echo "  ERROR: Cannot find apt-get, dnf, or pip3 to install Ansible." >&2
                echo "  Please install Ansible manually: https://docs.ansible.com/ansible/latest/installation_guide/" >&2
                exit 1
            fi
            pip3 install --user ansible || pip3 install --user --break-system-packages ansible
            export PATH="$HOME/.local/bin:$PATH"
            ;;
        *)
            echo "  ERROR: Unsupported OS '$(uname -s)'." >&2
            echo "  Please install Ansible manually: https://docs.ansible.com/ansible/latest/installation_guide/" >&2
            exit 1
            ;;
    esac
}

check_ansible() {
    echo ""
    echo "Checking prerequisites..."

    if command -v ansible-playbook &>/dev/null; then
        echo "  Ansible found: $(ansible --version | head -1)"
    else
        install_ansible
        if ! command -v ansible-playbook &>/dev/null; then
            echo "  ERROR: Ansible installation succeeded but 'ansible-playbook' is still not in PATH." >&2
            echo "  Try opening a new shell or adding $(python3 -m site --user-base)/bin to your PATH." >&2
            exit 1
        fi
        echo "  Ansible installed: $(ansible --version | head -1)"
    fi

    if ! command -v ansible-galaxy &>/dev/null; then
        echo "  ERROR: 'ansible-galaxy' not found. Something went wrong with the Ansible install." >&2
        exit 1
    fi

    echo "  Installing required Ansible collections..."
    ansible-galaxy collection install -r "$SCRIPT_DIR/requirements.yml" --upgrade
    echo "  Collections ready."
}

check_ansible

# ── Helpers ───────────────────────────────────────────────────────────────────

section() {
    echo ""
    echo "###########################################################################"
    echo "# $1"
    echo "###########################################################################"
}

# Prompt with a default value. Usage: ask VARNAME "Prompt text" "default"
ask() {
    local varname="$1" prompt="$2" default="$3" value
    read -rp "  $prompt [$default]: " value
    printf -v "$varname" '%s' "${value:-$default}"
}

# Prompt yes/no. Usage: ask_yn VARNAME "Prompt text" "yes|no"
ask_yn() {
    local varname="$1" prompt="$2" default="$3" value
    while true; do
        read -rp "  $prompt (yes/no) [$default]: " value
        value="${value:-$default}"
        case "$value" in
            yes|YES|y|Y) printf -v "$varname" '%s' "yes"; return ;;
            no|NO|n|N)   printf -v "$varname" '%s' "no";  return ;;
            *) echo "    Please enter 'yes' or 'no'." ;;
        esac
    done
}

# Prompt for a password (no echo, confirmation). Usage: ask_password VARNAME "Prompt"
ask_password() {
    local varname="$1" prompt="$2" value confirm
    while true; do
        read -rsp "  $prompt: " value; echo
        read -rsp "  Confirm: " confirm; echo
        if [ "$value" = "$confirm" ]; then
            printf -v "$varname" '%s' "$value"
            return
        fi
        echo "    Passwords do not match, please try again."
    done
}

yn_to_bool() { [ "$1" = "yes" ] && echo "true" || echo "false"; }

# Returns true if argument looks like an IPv4 address
is_ip_address() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Map /etc/os-release ID value to our OS type names
parse_os_id() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        ubuntu)             echo "ubuntu"   ;;
        debian)             echo "debian"   ;;
        raspbian|raspios)   echo "raspbian" ;;
        centos|rhel)        echo "centos"   ;;
        rocky)              echo "rocky"    ;;
        almalinux|alma)     echo "alma"     ;;
        void)               echo "void"     ;;
        *)                  echo ""         ;;
    esac
}

# Detect hostname and OS from the target. Sets DETECTED_HOSTNAME and DETECTED_OS.
detect_remote_info() {
    local host="$1" user="$2"
    DETECTED_HOSTNAME="" DETECTED_OS=""

    if [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ] || [ "$host" = "::1" ]; then
        DETECTED_HOSTNAME="$(hostname)"
        if [ "$(uname -s)" = "Darwin" ]; then
            DETECTED_OS="macos"
        else
            local id
            id=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
            DETECTED_OS="$(parse_os_id "$id")"
        fi
        return 0
    fi

    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    local output
    if [ "${USE_SSH_PASSWORD:-no}" = "yes" ] && command -v sshpass &>/dev/null && [ -n "${ANSIBLE_SSH_PASSWORD:-}" ]; then
        output=$(SSHPASS="$ANSIBLE_SSH_PASSWORD" sshpass -e ssh $ssh_opts "${user}@${host}" \
            'echo "HOSTNAME=$(hostname)"; grep "^ID=" /etc/os-release 2>/dev/null || true' 2>/dev/null) || return 1
    else
        output=$(ssh $ssh_opts "${user}@${host}" \
            'echo "HOSTNAME=$(hostname)"; grep "^ID=" /etc/os-release 2>/dev/null || true' 2>/dev/null) || return 1
    fi

    DETECTED_HOSTNAME=$(echo "$output" | grep '^HOSTNAME=' | cut -d= -f2)
    local raw_id
    raw_id=$(echo "$output" | grep '^ID=' | cut -d= -f2 | tr -d '"')
    DETECTED_OS="$(parse_os_id "$raw_id")"
    return 0
}

# ── Load saved preferences ────────────────────────────────────────────────────

load_prefs() {
    [ -f "$PREFS_FILE" ] && source "$PREFS_FILE" || true
}

save_prefs() {
    cat > "$PREFS_FILE" <<EOF
# OpenRVDAS configure preferences — $(date)
PREF_TARGET_HOST='${TARGET_HOST}'
PREF_RVDAS_HOSTNAME='${RVDAS_HOSTNAME}'
PREF_ANSIBLE_USER='${ANSIBLE_USER}'
PREF_OS_TYPE='${OS_TYPE}'
PREF_INSTALL_ROOT='${INSTALL_ROOT}'
PREF_RVDAS_USER='${RVDAS_USER}'
PREF_OPENRVDAS_REPO='${OPENRVDAS_REPO}'
PREF_OPENRVDAS_BRANCH='${OPENRVDAS_BRANCH}'
PREF_HTTP_PROXY='${HTTP_PROXY}'
PREF_NONSSL_SERVER_PORT='${NONSSL_SERVER_PORT}'
PREF_SSL_SERVER_PORT='${SSL_SERVER_PORT}'
PREF_USE_SSL='${USE_SSL}'
PREF_HAVE_SSL_CERTIFICATE='${HAVE_SSL_CERTIFICATE}'
PREF_SSL_CRT_LOCATION='${SSL_CRT_LOCATION}'
PREF_SSL_KEY_LOCATION='${SSL_KEY_LOCATION}'
PREF_OPENRVDAS_AUTOSTART='${OPENRVDAS_AUTOSTART}'
PREF_INSTALL_GUI='${INSTALL_GUI}'
PREF_INSTALL_FIREWALLD='${INSTALL_FIREWALLD}'
PREF_TCP_PORTS_TO_OPEN='${TCP_PORTS_TO_OPEN}'
PREF_UDP_PORTS_TO_OPEN='${UDP_PORTS_TO_OPEN}'
PREF_INSTALL_SIMULATE_NBP='${INSTALL_SIMULATE_NBP}'
PREF_RUN_SIMULATE_NBP='${RUN_SIMULATE_NBP}'
PREF_SUPERVISORD_WEBINTERFACE='${SUPERVISORD_WEBINTERFACE}'
PREF_SUPERVISORD_WEBINTERFACE_AUTH='${SUPERVISORD_WEBINTERFACE_AUTH}'
PREF_SUPERVISORD_WEBINTERFACE_PORT='${SUPERVISORD_WEBINTERFACE_PORT}'
PREF_SUPERVISORD_WEBINTERFACE_USER='${SUPERVISORD_WEBINTERFACE_USER}'
PREF_SUPERVISORD_WEBINTERFACE_BIND='${SUPERVISORD_WEBINTERFACE_BIND}'
PREF_USE_SSH_PASSWORD='${USE_SSH_PASSWORD}'
EOF
    chmod 600 "$PREFS_FILE"
}

# ── Update hosts.ini ──────────────────────────────────────────────────────────

python_bin_for_os() {
    case "$1" in
        ubuntu|debian)          echo "/usr/bin/python3.9" ;;
        raspbian)               echo "/usr/bin/python3.11" ;;
        centos|rocky|alma)      echo "/usr/bin/python3.12" ;;
        void)                   echo "auto_silent" ;;
        macos)                  echo "/usr/bin/python3" ;;
        *)                      echo "/usr/bin/python3" ;;
    esac
}

update_hosts_ini() {
    local python_bin
    python_bin="$(python_bin_for_os "$OS_TYPE")"
    python3 - "$SCRIPT_DIR/inventory/hosts.ini" "$TARGET_HOST" "$ANSIBLE_USER" "$OS_TYPE" "$python_bin" <<'PYEOF'
import sys, re

hosts_file, host, user, os_type, python_bin = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

with open(hosts_file) as f:
    content = f.read()

if host in ('localhost', '127.0.0.1', '::1'):
    host_entry = f"{host} ansible_connection=local ansible_python_interpreter={python_bin}"
else:
    host_entry = f"{host} ansible_user={user} ansible_python_interpreter={python_bin}"

def ensure_host_in_section(text, section, entry):
    """Add or update host entry under [section]."""
    hostname = entry.split()[0]
    section_pattern = re.compile(rf'^\[{re.escape(section)}\]', re.MULTILINE)
    if not section_pattern.search(text):
        text = text.rstrip('\n') + f'\n\n[{section}]\n{entry}\n'
        return text
    # Replace existing entry if hostname already appears in this section
    lines = text.splitlines(keepends=True)
    in_section = False
    for i, line in enumerate(lines):
        if re.match(rf'^\[{re.escape(section)}\]', line):
            in_section = True
            continue
        if in_section:
            if line.startswith('['):
                break  # next section, host not found
            if line.strip() and line.split()[0] == hostname:
                lines[i] = entry + '\n'
                return ''.join(lines)
    # Host not found in section — insert after section header
    text = section_pattern.sub(f'[{section}]\n{entry}', text, count=1)
    return text

content = ensure_host_in_section(content, 'openrvdas', host_entry)
content = ensure_host_in_section(content, os_type, host)

with open(hosts_file, 'w') as f:
    f.write(content)
print(f"  Updated {hosts_file}")
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

load_prefs

echo ""
echo "==========================================="
echo "  OpenRVDAS Interactive Installer"
echo "==========================================="
echo "  Press Enter to accept the value shown in [brackets]."

# ── Target host ───────────────────────────────────────────────────────────────
section "Target Host"

echo "  (Use 'localhost' to install on this machine)"
ask TARGET_HOST "Hostname or IP of target" "${PREF_TARGET_HOST:-}"
ask ANSIBLE_USER "SSH user on target" "${PREF_ANSIBLE_USER:-root}"

# Verify SSH connectivity before proceeding — try key auth first, fall back to password
USE_SSH_PASSWORD="no"
ANSIBLE_SSH_PASSWORD=""
ANSIBLE_SSH_EXTRA_ARGS=()

if [ "$TARGET_HOST" != "localhost" ] && [ "$TARGET_HOST" != "127.0.0.1" ] && [ "$TARGET_HOST" != "::1" ]; then
    echo "  Checking SSH connectivity to ${ANSIBLE_USER}@${TARGET_HOST}..."
    ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    while true; do
        # Always try key auth first
        SSH_OK=$(ssh $ssh_opts -o BatchMode=yes "${ANSIBLE_USER}@${TARGET_HOST}" true 2>/dev/null && echo yes || echo no)
        if [ "$SSH_OK" = "yes" ]; then
            echo "  SSH connection successful (key authentication)."
            USE_SSH_PASSWORD="no"
            break
        fi

        # Key auth failed — offer password fallback
        echo ""
        echo "  SSH key authentication failed for ${ANSIBLE_USER}@${TARGET_HOST}."
        ask_yn TRY_PASSWORD "Try password authentication?" "${PREF_USE_SSH_PASSWORD:-no}"
        if [ "$TRY_PASSWORD" = "yes" ]; then
            read -rsp "  SSH password: " ANSIBLE_SSH_PASSWORD; echo
            if command -v sshpass &>/dev/null; then
                SSH_OK=$(SSHPASS="$ANSIBLE_SSH_PASSWORD" sshpass -e ssh $ssh_opts "${ANSIBLE_USER}@${TARGET_HOST}" true 2>/dev/null && echo yes || echo no)
            else
                echo "  (sshpass not found — skipping password verification; Ansible will use the password directly)"
                SSH_OK="yes"
            fi
            if [ "$SSH_OK" = "yes" ]; then
                echo "  SSH connection successful (password authentication)."
                USE_SSH_PASSWORD="yes"
                break
            else
                echo "  Password authentication also failed."
                ANSIBLE_SSH_PASSWORD=""
            fi
        fi

        ask_yn RETRY_SSH "Retry with different credentials?" "yes"
        if [ "$RETRY_SSH" = "yes" ]; then
            ask ANSIBLE_USER "SSH user on target" "$ANSIBLE_USER"
        else
            echo "  Aborting."
            exit 1
        fi
    done
fi

# Check if become (sudo) password is needed
ANSIBLE_BECOME_PASS=""
if [ "$ANSIBLE_USER" != "root" ]; then
    echo "  Checking sudo access for ${ANSIBLE_USER}..."
    SUDO_OK=no
    if [ "$TARGET_HOST" = "localhost" ] || [ "$TARGET_HOST" = "127.0.0.1" ] || [ "$TARGET_HOST" = "::1" ]; then
        sudo -n true 2>/dev/null && SUDO_OK=yes || true
    else
        ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
        if [ "$USE_SSH_PASSWORD" = "yes" ] && command -v sshpass &>/dev/null; then
            SSHPASS="$ANSIBLE_SSH_PASSWORD" sshpass -e ssh $ssh_opts \
                "${ANSIBLE_USER}@${TARGET_HOST}" "sudo -n true" 2>/dev/null && SUDO_OK=yes || true
        else
            ssh $ssh_opts "${ANSIBLE_USER}@${TARGET_HOST}" "sudo -n true" 2>/dev/null && SUDO_OK=yes || true
        fi
    fi
    if [ "$SUDO_OK" = "no" ]; then
        echo "  Passwordless sudo not available — a sudo password is required."
        read -rsp "  Sudo (become) password: " ANSIBLE_BECOME_PASS; echo
    else
        echo "  Passwordless sudo available."
    fi
fi

# Detect hostname and OS from the target machine
echo "  Connecting to ${TARGET_HOST} to detect system info..."
detect_remote_info "$TARGET_HOST" "$ANSIBLE_USER" || true

# Suggest the detected hostname, or fall back sensibly.
# Only use saved preference if we're re-running against the same host.
SAME_HOST="$( [ "$TARGET_HOST" = "${PREF_TARGET_HOST:-}" ] && echo yes || echo no )"
if [ -n "$DETECTED_HOSTNAME" ]; then
    DEFAULT_HOSTNAME="$DETECTED_HOSTNAME"
elif is_ip_address "$TARGET_HOST"; then
    # IP, detection failed: use saved pref only if same host, else blank
    DEFAULT_HOSTNAME="$( [ "$SAME_HOST" = yes ] && echo "${PREF_RVDAS_HOSTNAME:-}" || echo "" )"
else
    # Hostname given, detection failed: use saved pref if same host, else use the hostname itself
    DEFAULT_HOSTNAME="$( [ "$SAME_HOST" = yes ] && echo "${PREF_RVDAS_HOSTNAME:-$TARGET_HOST}" || echo "$TARGET_HOST" )"
fi
ask RVDAS_HOSTNAME "Hostname to set on target" "$DEFAULT_HOSTNAME"

# Use detected OS type, or prompt if detection failed
if [ -n "$DETECTED_OS" ]; then
    OS_TYPE="$DETECTED_OS"
    echo "  Detected OS: $OS_TYPE"
else
    echo "  Could not detect OS type (SSH may not be available yet)."
    VALID_OS_TYPES="ubuntu debian raspbian centos rocky alma void macos"
    while true; do
        DEFAULT_OS="$( [ "$SAME_HOST" = yes ] && echo "${PREF_OS_TYPE:-ubuntu}" || echo "ubuntu" )"
        ask OS_TYPE "OS type (ubuntu / debian / raspbian / centos / rocky / alma / void / macos)" "$DEFAULT_OS"
        if echo "$VALID_OS_TYPES" | grep -qw "$OS_TYPE"; then
            break
        fi
        echo "    Invalid OS type '$OS_TYPE'. Please enter one of: $VALID_OS_TYPES"
    done
fi

# ── Installation paths ────────────────────────────────────────────────────────
section "Installation"

ask INSTALL_ROOT "Installation root directory" "${PREF_INSTALL_ROOT:-/opt}"
ask RVDAS_USER "OpenRVDAS service user (Linux only)" "${PREF_RVDAS_USER:-rvdas}"
ask OPENRVDAS_REPO "Repository URL" "${PREF_OPENRVDAS_REPO:-https://github.com/oceandatatools/openrvdas}"
ask OPENRVDAS_BRANCH "Branch to install" "${PREF_OPENRVDAS_BRANCH:-master}"
ask HTTP_PROXY "HTTP proxy URL (blank for none)" "${PREF_HTTP_PROXY:-}"

# ── Web server ────────────────────────────────────────────────────────────────
section "Web Server"

ask_yn USE_SSL "Enable SSL/HTTPS?" "${PREF_USE_SSL:-no}"

if [ "$USE_SSL" = "yes" ]; then
    ask SSL_SERVER_PORT "HTTPS port" "${PREF_SSL_SERVER_PORT:-443}"
    ask_yn HAVE_SSL_CERTIFICATE "Supply your own SSL certificate?" "${PREF_HAVE_SSL_CERTIFICATE:-no}"
    if [ "$HAVE_SSL_CERTIFICATE" = "yes" ]; then
        ask SSL_CRT_LOCATION "Path to certificate (.crt) on the target host" "${PREF_SSL_CRT_LOCATION:-}"
        ask SSL_KEY_LOCATION "Path to private key (.key) on the target host" "${PREF_SSL_KEY_LOCATION:-}"
    else
        SSL_CRT_LOCATION="${INSTALL_ROOT}/openrvdas/openrvdas.crt"
        SSL_KEY_LOCATION="${INSTALL_ROOT}/openrvdas/openrvdas.key"
        echo "  A self-signed certificate will be generated automatically."
    fi
    NONSSL_SERVER_PORT="${PREF_NONSSL_SERVER_PORT:-80}"
else
    ask NONSSL_SERVER_PORT "HTTP port" "${PREF_NONSSL_SERVER_PORT:-80}"
    SSL_SERVER_PORT="${PREF_SSL_SERVER_PORT:-443}"
    HAVE_SSL_CERTIFICATE="${PREF_HAVE_SSL_CERTIFICATE:-no}"
    SSL_CRT_LOCATION="${PREF_SSL_CRT_LOCATION:-${INSTALL_ROOT}/openrvdas/openrvdas.crt}"
    SSL_KEY_LOCATION="${PREF_SSL_KEY_LOCATION:-${INSTALL_ROOT}/openrvdas/openrvdas.key}"
fi

# ── Features ──────────────────────────────────────────────────────────────────
section "Features"

ask_yn OPENRVDAS_AUTOSTART "Start services automatically on boot?" "${PREF_OPENRVDAS_AUTOSTART:-yes}"
ask_yn INSTALL_GUI "Install nginx + uWSGI web interface?" "${PREF_INSTALL_GUI:-yes}"

if [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rocky" ] || [ "$OS_TYPE" = "alma" ]; then
    ask_yn INSTALL_FIREWALLD "Configure firewalld?" "${PREF_INSTALL_FIREWALLD:-no}"
    if [ "$INSTALL_FIREWALLD" = "yes" ]; then
        ask TCP_PORTS_TO_OPEN "Extra TCP ports to open (space-separated, blank for none)" "${PREF_TCP_PORTS_TO_OPEN:-}"
        ask UDP_PORTS_TO_OPEN "Extra UDP ports to open (space-separated, blank for none)" "${PREF_UDP_PORTS_TO_OPEN:-}"
    else
        TCP_PORTS_TO_OPEN="${PREF_TCP_PORTS_TO_OPEN:-}"
        UDP_PORTS_TO_OPEN="${PREF_UDP_PORTS_TO_OPEN:-}"
    fi
else
    INSTALL_FIREWALLD="no"
    TCP_PORTS_TO_OPEN="${PREF_TCP_PORTS_TO_OPEN:-}"
    UDP_PORTS_TO_OPEN="${PREF_UDP_PORTS_TO_OPEN:-}"
fi

# ── Simulator ─────────────────────────────────────────────────────────────────
section "NBP Simulator"

ask_yn INSTALL_SIMULATE_NBP "Install NBP1406 test data simulator?" "${PREF_INSTALL_SIMULATE_NBP:-no}"
if [ "$INSTALL_SIMULATE_NBP" = "yes" ]; then
    ask_yn RUN_SIMULATE_NBP "Autostart simulator on boot?" "${PREF_RUN_SIMULATE_NBP:-no}"
else
    RUN_SIMULATE_NBP="no"
fi

# ── Supervisord web interface ──────────────────────────────────────────────────
section "Supervisord Web Interface"

ask_yn SUPERVISORD_WEBINTERFACE "Enable supervisord web interface?" "${PREF_SUPERVISORD_WEBINTERFACE:-no}"
if [ "$SUPERVISORD_WEBINTERFACE" = "yes" ]; then
    ask SUPERVISORD_WEBINTERFACE_PORT "Supervisord web interface port" "${PREF_SUPERVISORD_WEBINTERFACE_PORT:-9001}"
    ask SUPERVISORD_WEBINTERFACE_BIND "Bind address (127.0.0.1=local only, 0.0.0.0=remote access)" "${PREF_SUPERVISORD_WEBINTERFACE_BIND:-127.0.0.1}"
    ask_yn SUPERVISORD_WEBINTERFACE_AUTH "Require authentication?" "${PREF_SUPERVISORD_WEBINTERFACE_AUTH:-no}"
    if [ "$SUPERVISORD_WEBINTERFACE_AUTH" = "yes" ]; then
        ask SUPERVISORD_WEBINTERFACE_USER "Supervisord web interface username" "${PREF_SUPERVISORD_WEBINTERFACE_USER:-${RVDAS_USER}}"
    else
        SUPERVISORD_WEBINTERFACE_USER="${PREF_SUPERVISORD_WEBINTERFACE_USER:-${RVDAS_USER}}"
    fi
else
    SUPERVISORD_WEBINTERFACE_PORT="${PREF_SUPERVISORD_WEBINTERFACE_PORT:-9001}"
    SUPERVISORD_WEBINTERFACE_BIND="${PREF_SUPERVISORD_WEBINTERFACE_BIND:-127.0.0.1}"
    SUPERVISORD_WEBINTERFACE_AUTH="${PREF_SUPERVISORD_WEBINTERFACE_AUTH:-no}"
    SUPERVISORD_WEBINTERFACE_USER="${PREF_SUPERVISORD_WEBINTERFACE_USER:-${RVDAS_USER}}"
fi

# ── Secrets ───────────────────────────────────────────────────────────────────
section "Passwords"

echo "  These will be stored encrypted in vault/secrets.yml."
echo ""
ask_password RVDAS_DATABASE_PASSWORD "OpenRVDAS/Django password"

if [ "$SUPERVISORD_WEBINTERFACE_AUTH" = "yes" ]; then
    ask_password SUPERVISORD_WEBINTERFACE_PASS "Supervisord web interface password"
else
    SUPERVISORD_WEBINTERFACE_PASS=""
fi

# ── Vault password ────────────────────────────────────────────────────────────
section "Vault Password"

echo "  The vault password protects vault/secrets.yml."
echo ""
if [ -f "$VAULT_PASS_FILE" ]; then
    ask_yn USE_EXISTING_VAULT_PASS "Use existing vault password (from vault/.vault_pass)?" "yes"
    if [ "$USE_EXISTING_VAULT_PASS" = "no" ]; then
        ask_password NEW_VAULT_PASS "New vault password"
        printf '%s' "$NEW_VAULT_PASS" > "$VAULT_PASS_FILE"
        chmod 600 "$VAULT_PASS_FILE"
        echo "  Vault password updated."
    fi
else
    ask_password NEW_VAULT_PASS "Set a vault password"
    printf '%s' "$NEW_VAULT_PASS" > "$VAULT_PASS_FILE"
    chmod 600 "$VAULT_PASS_FILE"
    echo "  Vault password saved to vault/.vault_pass (chmod 600)."
fi

# ── Write host_vars ───────────────────────────────────────────────────────────
section "Writing Configuration"

mkdir -p "$SCRIPT_DIR/inventory/host_vars"
HOST_VARS_FILE="$SCRIPT_DIR/inventory/host_vars/${TARGET_HOST}.yml"

# Format a space-separated list as a YAML inline array of strings
yaml_str_array() {
    local items="$1"
    if [ -z "$items" ]; then echo "[]"; return; fi
    local out="["; local first=true
    for item in $items; do
        [ "$first" = "true" ] || out+=", "
        out+="\"$item\""
        first=false
    done
    echo "${out}]"
}

cat > "$HOST_VARS_FILE" <<EOF
---
# Host configuration for ${TARGET_HOST}
# Generated by configure_and_install.sh on $(date)
# Re-run configure_and_install.sh to update these values.

rvdas_hostname: ${RVDAS_HOSTNAME}

install_root: ${INSTALL_ROOT}
rvdas_user: ${RVDAS_USER}
rvdas_group: ${RVDAS_USER}

openrvdas_repo: ${OPENRVDAS_REPO}
openrvdas_branch: ${OPENRVDAS_BRANCH}
http_proxy: "${HTTP_PROXY}"

nonssl_server_port: ${NONSSL_SERVER_PORT}
ssl_server_port: ${SSL_SERVER_PORT}
use_ssl: $(yn_to_bool "$USE_SSL")
have_ssl_certificate: $(yn_to_bool "$HAVE_SSL_CERTIFICATE")
ssl_crt_location: ${SSL_CRT_LOCATION}
ssl_key_location: ${SSL_KEY_LOCATION}

openrvdas_autostart: $(yn_to_bool "$OPENRVDAS_AUTOSTART")
install_gui: $(yn_to_bool "$INSTALL_GUI")
install_firewalld: $(yn_to_bool "$INSTALL_FIREWALLD")
tcp_ports_to_open: $(yaml_str_array "$TCP_PORTS_TO_OPEN")
udp_ports_to_open: $(yaml_str_array "$UDP_PORTS_TO_OPEN")

install_simulate_nbp: $(yn_to_bool "$INSTALL_SIMULATE_NBP")
run_simulate_nbp: $(yn_to_bool "$RUN_SIMULATE_NBP")

supervisord_webinterface: $(yn_to_bool "$SUPERVISORD_WEBINTERFACE")
supervisord_webinterface_auth: $(yn_to_bool "$SUPERVISORD_WEBINTERFACE_AUTH")
supervisord_webinterface_port: ${SUPERVISORD_WEBINTERFACE_PORT}
supervisord_webinterface_bind: "${SUPERVISORD_WEBINTERFACE_BIND}"
supervisord_webinterface_user: ${SUPERVISORD_WEBINTERFACE_USER}
EOF
echo "  Wrote $HOST_VARS_FILE"

# ── Write and encrypt vault/secrets.yml ───────────────────────────────────────
SECRETS_TMP="$(mktemp)"
EXTRA_VARS_TMP=""
cleanup_tmps() { rm -f "$SECRETS_TMP" ${EXTRA_VARS_TMP:+"$EXTRA_VARS_TMP"}; }
trap cleanup_tmps EXIT

cat > "$SECRETS_TMP" <<EOF
---
# OpenRVDAS secrets — $(date)
rvdas_database_password: ${RVDAS_DATABASE_PASSWORD}
supervisord_webinterface_pass: "${SUPERVISORD_WEBINTERFACE_PASS}"
EOF

ansible-vault encrypt \
    --vault-password-file "$VAULT_PASS_FILE" \
    --output "$SCRIPT_DIR/vault/secrets.yml" \
    "$SECRETS_TMP"
echo "  Wrote and encrypted vault/secrets.yml"

# ── Update hosts.ini ──────────────────────────────────────────────────────────
save_prefs
update_hosts_ini
echo "  Preferences saved to $PREFS_FILE"

# ── Build extra-vars file for sensitive connection vars ───────────────────────
ANSIBLE_EXTRA_ARGS=()
if { [ "$USE_SSH_PASSWORD" = "yes" ] && [ -n "$ANSIBLE_SSH_PASSWORD" ]; } || [ -n "$ANSIBLE_BECOME_PASS" ]; then
    EXTRA_VARS_TMP="$(mktemp)"
    chmod 600 "$EXTRA_VARS_TMP"
    [ "$USE_SSH_PASSWORD" = "yes" ] && [ -n "$ANSIBLE_SSH_PASSWORD" ] && \
        printf 'ansible_ssh_pass: %s\n' "$ANSIBLE_SSH_PASSWORD" >> "$EXTRA_VARS_TMP"
    [ -n "$ANSIBLE_BECOME_PASS" ] && \
        printf 'ansible_become_pass: %s\n' "$ANSIBLE_BECOME_PASS" >> "$EXTRA_VARS_TMP"
    ANSIBLE_EXTRA_ARGS=("-e" "@${EXTRA_VARS_TMP}")
fi

# ── Run playbook ──────────────────────────────────────────────────────────────
section "Running Ansible Playbook"
echo ""

cd "$SCRIPT_DIR"
ansible-playbook site.yml \
    -i inventory/hosts.ini \
    --vault-password-file "$VAULT_PASS_FILE" \
    --limit "$TARGET_HOST" \
    ${ANSIBLE_EXTRA_ARGS[@]+"${ANSIBLE_EXTRA_ARGS[@]}"}

# ── Smoke test ────────────────────────────────────────────────────────────────
echo ""
ask_yn RUN_SMOKE_TEST "Run smoke test to verify the installation?" "yes"
if [ "$RUN_SMOKE_TEST" = "yes" ]; then
    section "Running Smoke Test"
    echo ""
    ansible-playbook smoke-test.yml \
        -i inventory/hosts.ini \
        --vault-password-file "$VAULT_PASS_FILE" \
        --limit "$TARGET_HOST" \
        ${ANSIBLE_EXTRA_ARGS[@]+"${ANSIBLE_EXTRA_ARGS[@]}"}
fi
