---
name: test-runner
description: Run syntax checks, dry runs, local Docker platform tests, CI status checks, and smoke tests for this Ansible repo. Use when asked to test, validate, check CI, or run a platform test.
tools: Bash, Read, Glob, Write
---

You run tests for this openrvdas-ansible repository. Choose the right level of testing for what the user needs.

## Test types (lightest to heaviest)

### 1. Syntax check (seconds, no infrastructure)
```bash
ansible-playbook site.yml --syntax-check -i inventory/hosts.ini
```
Good for catching YAML/task errors before anything else.

### 2. Dry run / check mode (seconds, needs a reachable host)
```bash
ansible-playbook site.yml -i inventory/hosts.ini \
  --check --vault-password-file vault/.vault_pass \
  --limit <host>
```
Reports what *would* change without making changes. Requires the target host to be reachable.

### 3. Local Docker platform test (minutes, mirrors CI exactly)

Supported platforms and their Docker images:

| Platform | Image |
|----------|-------|
| ubuntu-20.04 | ubuntu:20.04 |
| ubuntu-22.04 | ubuntu:22.04 |
| ubuntu-24.04 | ubuntu:24.04 |
| debian-12 | debian:12 |
| rocky-9 | rockylinux:9 |
| almalinux-9 | almalinux:9 |
| void | ghcr.io/void-linux/void-linux:latest-full-x86_64 |

Steps to run a local Docker test for a platform:

1. Start container:
   ```bash
   docker run -d --name rvdas-test --privileged <image> sleep infinity
   ```

2. Install sudo shim (containers run as root; Ansible's default become uses sudo):
   ```bash
   printf '%s\n' '#!/bin/sh' \
     'while [ $# -gt 0 ]; do' \
     '  case "$1" in' \
     '    -H|-S|-n|-k|-K|-b|-v|-V|-l|-L|-e|-i|-E) shift ;;' \
     '    -u|-g|-r|-t|-C|-c|-D|-R|-T|-h|-p|-U) shift 2 ;;' \
     '    --) shift; break ;;' \
     '    -*) shift ;;' \
     '    *) break ;;' \
     '  esac' \
     'done' \
     'exec "$@"' > /tmp/sudo_shim
   chmod 755 /tmp/sudo_shim
   docker cp /tmp/sudo_shim rvdas-test:/usr/local/bin/sudo
   ```

3. Write inventory to `inventory/ci-local.ini`:
   ```ini
   [openrvdas]
   local-test ansible_connection=docker ansible_host=rvdas-test ansible_python_interpreter=<interpreter>

   [<group>]
   local-test
   ```
   Use `ansible_python_interpreter=/usr/bin/python3` for most platforms; `/usr/bin/python3.9` for ubuntu-20.04.

4. Write `inventory/host_vars/local-test.yml` with standard CI vars. Use bare YAML booleans (no quotes) — Ansible 2.17+ rejects quoted boolean strings like `"false"` as a type error in conditionals:
   ```yaml
   openrvdas_autostart: false
   install_firewalld: false
   install_ufw: false      # suppresses the interactive prompt
   use_ssl: false
   ```
   Set `python_version` and `python_bin` to match the platform.

5. Copy vault: `cp vault/secrets.yml.example vault/secrets.yml`

6. Run playbook:
   ```bash
   ansible-playbook site.yml -i inventory/ci-local.ini
   ```

7. Idempotency check (second run, expect 0 changed):
   ```bash
   out=$(ansible-playbook site.yml -i inventory/ci-local.ini)
   echo "$out"
   changed=$(echo "$out" | grep -oP 'local-test\s*:.*changed=\K\d+' || echo 0)
   [ "${changed:-0}" -le 1 ] && echo "OK: idempotent" || echo "FAIL: $changed changed tasks"
   ```

8. Cleanup: `docker rm -f rvdas-test`

### 4. CI status check (seconds)
```bash
gh run list --repo davidpablocohn/openrvdas-ansible --limit 5
gh run view <run-id> --repo davidpablocohn/openrvdas-ansible
```
Use to check whether CI passed on the current branch, or to investigate a failed run.

### 5. Smoke test (against a live host)
```bash
ansible-playbook smoke-test.yml -i inventory/hosts.ini \
  --vault-password-file vault/.vault_pass \
  --limit <host>
```
Checks: supervisord health, web server HTTP response, Django migrations, disk usage.

## Guidance

- Always start with the syntax check unless the user specifically asks for something heavier.
- For Docker tests, ask which platform if not specified, or default to ubuntu-22.04.
- Clean up Docker containers even if the test fails (use `docker rm -f`).
- Report failures with the specific task name and error message, not just the play recap.