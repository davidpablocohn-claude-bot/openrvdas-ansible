#!/usr/bin/env bash
# configure_and_install_influxdb.sh
#
# Interactive configuration script for InfluxDB / Grafana / Telegraf installation.
# Optionally also configures an OpenRVDAS installation to write data to InfluxDB.
#
# Re-running this script on the same host is safe — values from the previous
# run are shown as defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFS_FILE="$SCRIPT_DIR/.configure_influx_preferences"
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
            if command -v apt-get &>/dev/null; then
                echo "  Installing Ansible via apt..."
                sudo apt-get update -qq && sudo apt-get install -y ansible && return
            fi
            if command -v dnf &>/dev/null; then
                echo "  Installing Ansible via pip3..."
                if ! command -v pip3 &>/dev/null; then
                    sudo dnf install -y python3-pip
                fi
                pip3 install --user ansible || pip3 install --user --break-system-packages ansible
                export PATH="$HOME/.local/bin:$PATH"
                return
            fi
            if ! command -v pip3 &>/dev/null; then
                echo "  ERROR: Cannot find apt-get, dnf, or pip3 to install Ansible." >&2
                exit 1
            fi
            pip3 install --user ansible || pip3 install --user --break-system-packages ansible
            export PATH="$HOME/.local/bin:$PATH"
            ;;
        *)
            echo "  ERROR: Unsupported OS '$(uname -s)'." >&2
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
            exit 1
        fi
        echo "  Ansible installed: $(ansible --version | head -1)"
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

ask() {
    local varname="$1" prompt="$2" default="$3" value
    read -rp "  $prompt [$default]: " value
    printf -v "$varname" '%s' "${value:-$default}"
}

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

ask_secret() {
    # Like ask_password but single entry (for tokens, not passwords)
    local varname="$1" prompt="$2" value
    read -rsp "  $prompt: " value; echo
    printf -v "$varname" '%s' "$value"
}

yn_to_bool() { [ "$1" = "yes" ] && echo "true" || echo "false"; }
is_ip_address() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

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

update_hosts_ini_group() {
    # Add or update a host entry in hosts.ini under [group] and the OS sub-group
    local python_bin
    python_bin="$(python_bin_for_os "$OS_TYPE")"
    python3 - "$SCRIPT_DIR/inventory/hosts.ini" "$TARGET_HOST" "$ANSIBLE_USER" \
              "$OS_TYPE" "$python_bin" "$INVENTORY_GROUP" <<'PYEOF'
import sys, re

hosts_file, host, user, os_type, python_bin, group = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

with open(hosts_file) as f:
    content = f.read()

if host in ('localhost', '127.0.0.1', '::1'):
    host_entry = f"{host} ansible_connection=local ansible_python_interpreter={python_bin}"
else:
    host_entry = f"{host} ansible_user={user} ansible_python_interpreter={python_bin}"

def ensure_host_in_section(text, section, entry):
    hostname = entry.split()[0]
    section_pattern = re.compile(rf'^\[{re.escape(section)}\]', re.MULTILINE)
    if not section_pattern.search(text):
        text = text.rstrip('\n') + f'\n\n[{section}]\n{entry}\n'
        return text
    lines = text.splitlines(keepends=True)
    in_section = False
    for i, line in enumerate(lines):
        if re.match(rf'^\[{re.escape(section)}\]', line):
            in_section = True
            continue
        if in_section:
            if line.startswith('['):
                break
            if line.strip() and line.split()[0] == hostname:
                lines[i] = entry + '\n'
                return ''.join(lines)
    text = section_pattern.sub(f'[{section}]\n{entry}', text, count=1)
    return text

content = ensure_host_in_section(content, group, host_entry)
content = ensure_host_in_section(content, os_type, host)

with open(hosts_file, 'w') as f:
    f.write(content)
print(f"  Updated {hosts_file}")
PYEOF
}

# ── Load saved preferences ────────────────────────────────────────────────────

load_prefs() {
    [ -f "$PREFS_FILE" ] && source "$PREFS_FILE" || true
}

save_prefs() {
    cat > "$PREFS_FILE" <<EOF
# InfluxDB configure preferences — $(date)
PREF_TARGET_HOST='${TARGET_HOST}'
PREF_ANSIBLE_USER='${ANSIBLE_USER}'
PREF_OS_TYPE='${OS_TYPE}'
PREF_INFLUX_HOSTNAME='${INFLUX_HOSTNAME}'
PREF_INFLUXDB_VERSION='${INFLUXDB_VERSION}'
PREF_INFLUXDB_ORG='${INFLUXDB_ORG}'
PREF_INFLUXDB_BUCKET='${INFLUXDB_BUCKET}'
PREF_INFLUXDB_PORT='${INFLUXDB_PORT}'
PREF_INSTALL_GRAFANA='${INSTALL_GRAFANA}'
PREF_GRAFANA_PORT='${GRAFANA_PORT}'
PREF_INSTALL_TELEGRAF='${INSTALL_TELEGRAF}'
PREF_INFLUX_LOG_DIR='${INFLUX_LOG_DIR}'
PREF_CONFIGURE_OPENRVDAS='${CONFIGURE_OPENRVDAS}'
PREF_OPENRVDAS_HOST='${OPENRVDAS_HOST:-}'
PREF_USE_SSH_PASSWORD='${USE_SSH_PASSWORD}'
EOF
    chmod 600 "$PREFS_FILE"
}

load_prefs

# ── Banner ────────────────────────────────────────────────────────────────────

echo ""
echo "==========================================="
echo "  InfluxDB / Grafana / Telegraf Installer"
echo "==========================================="
echo "  Press Enter to accept the value shown in [brackets]."

# ── Target host ───────────────────────────────────────────────────────────────
section "Target Host (InfluxDB Server)"

echo "  (Use 'localhost' to install on this machine)"
ask TARGET_HOST "Hostname or IP of target" "${PREF_TARGET_HOST:-}"
ask ANSIBLE_USER "SSH user on target" "${PREF_ANSIBLE_USER:-root}"

INVENTORY_GROUP="influxdb"

# SSH connectivity check
USE_SSH_PASSWORD="${PREF_USE_SSH_PASSWORD:-no}"
ANSIBLE_SSH_PASSWORD=""
ANSIBLE_SSH_EXTRA_ARGS=()

if [ "$TARGET_HOST" != "localhost" ] && [ "$TARGET_HOST" != "127.0.0.1" ] && [ "$TARGET_HOST" != "::1" ]; then
    echo "  Checking SSH connectivity to ${ANSIBLE_USER}@${TARGET_HOST}..."
    ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    while true; do
        SSH_OK=$(ssh $ssh_opts -o BatchMode=yes "${ANSIBLE_USER}@${TARGET_HOST}" true 2>/dev/null && echo yes || echo no)
        if [ "$SSH_OK" = "yes" ]; then
            echo "  SSH connection successful (key authentication)."
            USE_SSH_PASSWORD="no"
            break
        fi
        echo ""
        echo "  SSH key authentication failed for ${ANSIBLE_USER}@${TARGET_HOST}."
        ask_yn TRY_PASSWORD "Try password authentication?" "${PREF_USE_SSH_PASSWORD:-no}"
        if [ "$TRY_PASSWORD" = "yes" ]; then
            read -rsp "  SSH password: " ANSIBLE_SSH_PASSWORD; echo
            if command -v sshpass &>/dev/null; then
                SSH_OK=$(SSHPASS="$ANSIBLE_SSH_PASSWORD" sshpass -e ssh $ssh_opts "${ANSIBLE_USER}@${TARGET_HOST}" true 2>/dev/null && echo yes || echo no)
            else
                SSH_OK="yes"
            fi
            if [ "$SSH_OK" = "yes" ]; then
                echo "  SSH connection successful (password authentication)."
                USE_SSH_PASSWORD="yes"
                break
            fi
            ANSIBLE_SSH_PASSWORD=""
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

# Sudo check
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

# Detect OS/hostname
echo "  Connecting to ${TARGET_HOST} to detect system info..."
DETECTED_HOSTNAME="" DETECTED_OS=""
detect_remote_info "$TARGET_HOST" "$ANSIBLE_USER" || true

SAME_HOST="$( [ "$TARGET_HOST" = "${PREF_TARGET_HOST:-}" ] && echo yes || echo no )"
if [ -n "$DETECTED_HOSTNAME" ]; then
    DEFAULT_HOSTNAME="$DETECTED_HOSTNAME"
elif is_ip_address "$TARGET_HOST"; then
    DEFAULT_HOSTNAME="$( [ "$SAME_HOST" = yes ] && echo "${PREF_INFLUX_HOSTNAME:-}" || echo "" )"
else
    DEFAULT_HOSTNAME="$( [ "$SAME_HOST" = yes ] && echo "${PREF_INFLUX_HOSTNAME:-$TARGET_HOST}" || echo "$TARGET_HOST" )"
fi
ask INFLUX_HOSTNAME "Hostname label for this server" "$DEFAULT_HOSTNAME"

if [ -n "$DETECTED_OS" ]; then
    OS_TYPE="$DETECTED_OS"
    echo "  Detected OS: $OS_TYPE"
else
    VALID_OS_TYPES="ubuntu debian raspbian centos rocky alma void macos"
    while true; do
        DEFAULT_OS="$( [ "$SAME_HOST" = yes ] && echo "${PREF_OS_TYPE:-ubuntu}" || echo "ubuntu" )"
        ask OS_TYPE "OS type (ubuntu / debian / raspbian / centos / rocky / alma / void / macos)" "$DEFAULT_OS"
        if echo "$VALID_OS_TYPES" | grep -qw "$OS_TYPE"; then break; fi
        echo "    Invalid OS type '$OS_TYPE'. Please enter one of: $VALID_OS_TYPES"
    done
fi

# ── InfluxDB Configuration ────────────────────────────────────────────────────
section "InfluxDB Configuration"

ask INFLUXDB_VERSION "InfluxDB version (2 or 3)" "${PREF_INFLUXDB_VERSION:-2}"
while [[ "$INFLUXDB_VERSION" != "2" && "$INFLUXDB_VERSION" != "3" ]]; do
    echo "    Please enter 2 or 3."
    ask INFLUXDB_VERSION "InfluxDB version (2 or 3)" "2"
done

if [ "$INFLUXDB_VERSION" = "3" ]; then
    echo "  NOTE: InfluxDB v3 support is planned but not yet fully implemented."
fi

ask INFLUXDB_ORG "InfluxDB organization name" "${PREF_INFLUXDB_ORG:-openrvdas}"
ask INFLUXDB_BUCKET "InfluxDB bucket name" "${PREF_INFLUXDB_BUCKET:-openrvdas}"
ask INFLUXDB_PORT "InfluxDB port" "${PREF_INFLUXDB_PORT:-8086}"
INFLUXDB_URL="http://localhost:${INFLUXDB_PORT}"

# ── Grafana ───────────────────────────────────────────────────────────────────
section "Grafana"

ask_yn INSTALL_GRAFANA "Install Grafana?" "${PREF_INSTALL_GRAFANA:-yes}"
if [ "$INSTALL_GRAFANA" = "yes" ]; then
    ask GRAFANA_PORT "Grafana port" "${PREF_GRAFANA_PORT:-3000}"
else
    GRAFANA_PORT="${PREF_GRAFANA_PORT:-3000}"
fi

# ── Telegraf ──────────────────────────────────────────────────────────────────
section "Telegraf"

ask_yn INSTALL_TELEGRAF "Install Telegraf (system metrics collector)?" "${PREF_INSTALL_TELEGRAF:-yes}"

# ── Logging ───────────────────────────────────────────────────────────────────
section "Logging"

ask INFLUX_LOG_DIR "Log directory for InfluxDB/Grafana/Telegraf" "${PREF_INFLUX_LOG_DIR:-/var/log/influx}"

# ── OpenRVDAS Integration ─────────────────────────────────────────────────────
section "OpenRVDAS Integration"

ask_yn CONFIGURE_OPENRVDAS "Configure an OpenRVDAS host to write data to this InfluxDB?" \
    "${PREF_CONFIGURE_OPENRVDAS:-no}"
OPENRVDAS_HOST=""
if [ "$CONFIGURE_OPENRVDAS" = "yes" ]; then
    ask OPENRVDAS_HOST "Hostname of the OpenRVDAS machine (must already be in inventory)" \
        "${PREF_OPENRVDAS_HOST:-localhost}"
fi

# ── Secrets ───────────────────────────────────────────────────────────────────
section "Passwords and Tokens"

echo "  These will be stored encrypted in vault/secrets.yml."
echo ""
ask_password INFLUXDB_PASSWORD "InfluxDB admin password"
echo ""
echo "  The InfluxDB API token is used by Telegraf, Grafana, and OpenRVDAS."
echo "  Use a long random string (e.g. output of: openssl rand -hex 32)"
ask_secret INFLUXDB_TOKEN "InfluxDB API token"
if [ "$INSTALL_GRAFANA" = "yes" ]; then
    echo ""
    ask_password GRAFANA_PASSWORD "Grafana admin password"
else
    GRAFANA_PASSWORD="changeme"
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

# ── Write configuration ───────────────────────────────────────────────────────
section "Writing Configuration"

mkdir -p "$SCRIPT_DIR/inventory/host_vars"
HOST_VARS_FILE="$SCRIPT_DIR/inventory/host_vars/${TARGET_HOST}.yml"

cat > "$HOST_VARS_FILE" <<EOF
---
# InfluxDB host configuration for ${TARGET_HOST}
# Generated by configure_and_install_influxdb.sh on $(date)

rvdas_hostname: ${INFLUX_HOSTNAME}

influxdb_version: ${INFLUXDB_VERSION}
influxdb_org: ${INFLUXDB_ORG}
influxdb_bucket: ${INFLUXDB_BUCKET}
influxdb_port: ${INFLUXDB_PORT}
influxdb_url: "http://localhost:${INFLUXDB_PORT}"

install_grafana: $(yn_to_bool "$INSTALL_GRAFANA")
grafana_port: ${GRAFANA_PORT}

install_telegraf: $(yn_to_bool "$INSTALL_TELEGRAF")

influx_log_dir: ${INFLUX_LOG_DIR}
EOF
echo "  Wrote $HOST_VARS_FILE"

# Update vault/secrets.yml — merge with any existing secrets
SECRETS_TMP="$(mktemp)"
EXTRA_VARS_TMP=""
cleanup_tmps() { rm -f "$SECRETS_TMP" ${EXTRA_VARS_TMP:+"$EXTRA_VARS_TMP"}; }
trap cleanup_tmps EXIT

# Decrypt existing secrets if present so we don't overwrite openrvdas secrets
EXISTING_SECRETS_TMP="$(mktemp)"
EXISTING_RVDAS_DB_PASS=""
EXISTING_SUPERVISORD_PASS=""
if [ -f "$SCRIPT_DIR/vault/secrets.yml" ]; then
    ansible-vault decrypt \
        --vault-password-file "$VAULT_PASS_FILE" \
        --output "$EXISTING_SECRETS_TMP" \
        "$SCRIPT_DIR/vault/secrets.yml" 2>/dev/null || true
    EXISTING_RVDAS_DB_PASS=$(grep '^rvdas_database_password:' "$EXISTING_SECRETS_TMP" | awk '{print $2}' || true)
    EXISTING_SUPERVISORD_PASS=$(grep '^supervisord_webinterface_pass:' "$EXISTING_SECRETS_TMP" | awk '{print $2}' || true)
fi
rm -f "$EXISTING_SECRETS_TMP"

cat > "$SECRETS_TMP" <<EOF
---
# Secrets — $(date)
$([ -n "$EXISTING_RVDAS_DB_PASS" ] && echo "rvdas_database_password: ${EXISTING_RVDAS_DB_PASS}" || echo "# rvdas_database_password: (not set)")
$([ -n "$EXISTING_SUPERVISORD_PASS" ] && echo "supervisord_webinterface_pass: \"${EXISTING_SUPERVISORD_PASS}\"" || echo "# supervisord_webinterface_pass: (not set)")
influxdb_password: ${INFLUXDB_PASSWORD}
influxdb_token: ${INFLUXDB_TOKEN}
grafana_password: ${GRAFANA_PASSWORD}
EOF

ansible-vault encrypt \
    --vault-password-file "$VAULT_PASS_FILE" \
    --output "$SCRIPT_DIR/vault/secrets.yml" \
    "$SECRETS_TMP"
echo "  Wrote and encrypted vault/secrets.yml"

# ── Update hosts.ini ──────────────────────────────────────────────────────────
save_prefs
update_hosts_ini_group
echo "  Preferences saved to $PREFS_FILE"

# ── Build Ansible extra-vars for connection secrets ───────────────────────────
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

# Build the --limit argument
if [ "$CONFIGURE_OPENRVDAS" = "yes" ] && [ -n "$OPENRVDAS_HOST" ]; then
    LIMIT_ARG="${TARGET_HOST},${OPENRVDAS_HOST}"
else
    LIMIT_ARG="${TARGET_HOST}"
fi

ansible-playbook influxdb.yml \
    -i inventory/hosts.ini \
    --vault-password-file "$VAULT_PASS_FILE" \
    --limit "$LIMIT_ARG" \
    ${ANSIBLE_EXTRA_ARGS[@]+"${ANSIBLE_EXTRA_ARGS[@]}"}

echo ""
echo "==========================================="
echo "  InfluxDB installation complete!"
echo ""
echo "  InfluxDB: http://${TARGET_HOST}:${INFLUXDB_PORT}"
if [ "$INSTALL_GRAFANA" = "yes" ]; then
    echo "  Grafana:  http://${TARGET_HOST}:${GRAFANA_PORT}"
fi
echo "==========================================="
