# Ansible Deployment — Pyroscope + Grafana

Ansible role for deploying Pyroscope continuous profiling with Grafana on enterprise VMs. Designed to integrate into existing Ansible playbooks and supports VMware VM inventories.

Supports the same deployment stages as `deploy.sh`: Standalone HTTP, Standalone HTTPS (self-signed), and Enterprise-Integrated HTTPS (CA certs). Works for single-host and multi-host deployments — same playbook, just change the inventory.

For detailed decision flowcharts, see the [Deployment Guide](../../../docs/deployment-guide.md).

## Prerequisites

- Ansible 2.12+
- Collections: `community.docker`, `ansible.posix`
- Target hosts: Docker installed, SSH access configured

Install required collections:

```bash
ansible-galaxy collection install community.docker ansible.posix
```

## Quick Start

### 1. Configure inventory

Edit `inventory/hosts.yml` to add your VMs:

```yaml
all:
  children:
    pyroscope_full_stack:
      hosts:
        vm01.corp.example.com:
        vm02.corp.example.com:
```

### 2. Deploy

```bash
cd deploy/monolith/ansible

# Dry run (check mode)
ansible-playbook -i inventory playbooks/deploy.yml --check

# Deploy full stack
ansible-playbook -i inventory playbooks/deploy.yml

# Target specific host
ansible-playbook -i inventory playbooks/deploy.yml --limit vm01.corp.example.com
```

## Deployment Stages

### Standalone HTTP (first deployment)

Plain HTTP, no TLS. Optionally load images from tar (air-gapped).

```bash
# Direct pull (when registry is reachable)
ansible-playbook -i inventory playbooks/deploy.yml

# Air-gapped: load images from tar
ansible-playbook -i inventory playbooks/deploy.yml \
    -e docker_load_path=/tmp/pyroscope-stack-images.tar
```

### Standalone HTTPS (self-signed TLS)

Automated self-signed cert + Envoy reverse proxy. No CA knowledge needed.

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e tls_enabled=true \
    -e tls_self_signed=true

# Air-gapped + HTTPS
ansible-playbook -i inventory playbooks/deploy.yml \
    -e docker_load_path=/tmp/pyroscope-stack-images.tar \
    -e tls_enabled=true \
    -e tls_self_signed=true
```

This deploys:
- Pyroscope on `127.0.0.1:4040` (localhost only)
- Grafana on `127.0.0.1:3000` (localhost only)
- Envoy TLS proxy on `:4443` (Pyroscope) and `:443` (Grafana)
- Self-signed certificate at `/opt/pyroscope/tls/`

### Enterprise-Integrated HTTPS (CA certificates)

When enterprise CA certs are available, provide them from the Ansible control node:

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e tls_enabled=true \
    -e tls_cert_src=/path/to/cert.pem \
    -e tls_key_src=/path/to/key.pem
```

Certs are copied to the target host at `tls_cert_dir` (default: `/opt/pyroscope/tls/`).

## Pyroscope-Only Deployment (Skip Grafana)

When deploying to a dedicated Pyroscope VM, or when Grafana already exists elsewhere:

```bash
# Pyroscope-only (HTTP)
ansible-playbook -i inventory playbooks/deploy.yml \
    -e skip_grafana=true

# Pyroscope-only (HTTPS)
ansible-playbook -i inventory playbooks/deploy.yml \
    -e skip_grafana=true \
    -e tls_enabled=true \
    -e tls_self_signed=true
```

The existing Grafana connects via datasource URL (`http://pyro-vm:4040` or `https://pyro-vm:4443`).

## Split-VM Topology

For enterprise deployments, Pyroscope and Grafana can run on separate VMs:

```yaml
# inventory/hosts.yml
all:
  children:
    pyroscope_servers:
      hosts:
        pyro-vm01.corp.example.com:
      vars:
        skip_grafana: true
        tls_enabled: true
        tls_self_signed: true

    grafana_servers:
      hosts:
        grafana-vm01.corp.example.com:
      vars:
        pyroscope_mode: add-to-existing
        grafana_url: "http://localhost:3000"
        grafana_api_key: "{{ vault_grafana_api_key }}"
        pyroscope_url: "https://pyro-vm01.corp.example.com:4443"
```

```bash
ansible-playbook -i inventory playbooks/deploy.yml
```

## Deployment Modes

### Full-stack (default)

Deploys Pyroscope + Grafana as Docker containers on the target host.

```bash
ansible-playbook -i inventory playbooks/deploy.yml
```

Hosts in the `pyroscope_full_stack` group get full-stack mode automatically.

### Add to existing Grafana (API method)

Adds Pyroscope datasource and dashboards to an existing Grafana via API. No Grafana restart needed.

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e grafana_url=http://grafana.corp:3000 \
    -e grafana_api_key="{{ vault_grafana_api_key }}" \
    --ask-vault-pass
```

> **Security:** Never pass API keys as `-e grafana_api_key=<plaintext>` — they appear in process listings and Ansible logs. Use `ansible-vault` to encrypt secrets and reference them with `{{ vault_grafana_api_key }}`.

Or configure per-host in `inventory/hosts.yml`:

```yaml
pyroscope_add_to_existing:
  hosts:
    grafana01.corp.example.com:
      grafana_url: http://localhost:3000
      grafana_api_key: "{{ vault_grafana_api_key }}"
```

### Add to existing Grafana (provisioning method)

Writes provisioning files directly. Requires Grafana restart.

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_mode=add-to-existing \
    -e grafana_method=provisioning \
    -e pyroscope_url=http://pyroscope.corp:4040
```

## Day-2 Operations

```bash
# Check status
ansible-playbook -i inventory playbooks/status.yml

# Stop (preserve data)
ansible-playbook -i inventory playbooks/stop.yml

# Full cleanup (removes containers, volumes, images, certs)
ansible-playbook -i inventory playbooks/clean.yml
```

## Variables

Override in `inventory/group_vars/pyroscope.yml`, `host_vars/`, or via `-e`.

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `pyroscope_mode` | `full-stack` | `full-stack` or `add-to-existing` |
| `skip_grafana` | `false` | Deploy Pyroscope only (no Grafana container) |
| `docker_load_path` | - | Path to tar file to `docker load` before deploy |

### Pyroscope

| Variable | Default | Description |
|----------|---------|-------------|
| `pyroscope_image` | `grafana/pyroscope:latest` | Pyroscope Docker image |
| `pyroscope_port` | `4040` | Pyroscope host port |
| `pyroscope_url` | auto-detected | Pyroscope URL (for `add-to-existing`) |

### Grafana

| Variable | Default | Description |
|----------|---------|-------------|
| `grafana_image` | `grafana/grafana:11.5.2` | Grafana Docker image |
| `grafana_port` | `3000` | Grafana host port |
| `grafana_admin_password` | `admin` | Grafana admin password (**use ansible-vault**) |
| `grafana_url` | - | Existing Grafana URL |
| `grafana_api_key` | - | Grafana API key (**use ansible-vault**) |
| `grafana_method` | `api` | `api` or `provisioning` |
| `grafana_config_mode` | `mounted` | `baked` (custom image) or `mounted` (host volume mounts) |
| `grafana_config_dir` | `/opt/pyroscope/grafana` | Host directory for mounted config |

### TLS / HTTPS

| Variable | Default | Description |
|----------|---------|-------------|
| `tls_enabled` | `false` | Enable TLS with Envoy reverse proxy |
| `tls_self_signed` | `false` | Generate self-signed cert on target host |
| `tls_cert_src` | - | Cert file path on Ansible control node (PEM) |
| `tls_key_src` | - | Key file path on Ansible control node (PEM) |
| `tls_cert_dir` | `/opt/pyroscope/tls` | Cert directory on target host |
| `tls_port_pyroscope` | `4443` | HTTPS port for Pyroscope |
| `tls_port_grafana` | `443` | HTTPS port for Grafana |
| `envoy_image` | `envoyproxy/envoy:v1.31-latest` | Envoy Docker image |
| `envoy_container_name` | `envoy-proxy` | Envoy container name |

### Docker

| Variable | Default | Description |
|----------|---------|-------------|
| `docker_pull_retries` | `3` | Docker pull retry attempts |
| `docker_pull_delay` | `5` | Seconds between pull retries |

## Grafana Config Modes

| Mode | How it works | Config survives image upgrade? |
|------|-------------|-------------------------------|
| **`mounted`** (default) | Stock Grafana image, config bind-mounted from `grafana_config_dir` | Yes |
| **`baked`** | Builds custom `grafana-pyroscope` image with config built in | No — must re-deploy |

```bash
# Mounted mode (default — recommended)
ansible-playbook -i inventory playbooks/deploy.yml

# Baked mode
ansible-playbook -i inventory playbooks/deploy.yml -e grafana_config_mode=baked

# Mounted mode with custom directory
ansible-playbook -i inventory playbooks/deploy.yml -e grafana_config_dir=/etc/pyroscope
```

With mounted mode, to update dashboards or config after deployment:
1. Edit files on the host (default: `/opt/pyroscope/grafana/`)
2. Run `docker restart grafana` (or re-run the playbook to push new files from the repo)

## RHEL 8.10 Inventory Example

For enterprise RHEL VMs accessed via pbrun:

```yaml
# inventory/hosts.yml
all:
  children:
    pyroscope_full_stack:
      hosts:
        rhel-vm01.corp.example.com:
          ansible_user: operator
          ansible_become: true
          ansible_become_method: su
          ansible_become_exe: "pbrun /bin/su"
        rhel-vm02.corp.example.com:
          ansible_user: operator
          ansible_become: true
          ansible_become_method: su
          ansible_become_exe: "pbrun /bin/su"
      vars:
        # Pin versions for enterprise
        pyroscope_image: grafana/pyroscope:1.7.0
        grafana_image: grafana/grafana:11.5.2
        # Air-gapped image loading
        docker_load_path: /tmp/pyroscope-stack-images.tar
        # TLS (optional)
        tls_enabled: true
        tls_self_signed: true
```

The role auto-detects:
- **SELinux**: Adds `:z` to volume mounts when SELinux is enforcing
- **firewalld**: Opens ports (4040/3000 for HTTP, 4443/443 for HTTPS) when firewalld is active

## VMware Dynamic Inventory

Replace the static `inventory/hosts.yml` with VMware discovery:

```yaml
# inventory/vmware.yml
plugin: community.vmware.vmware_vm_inventory
hostname: vcenter.corp.example.com
username: "{{ lookup('env', 'VMWARE_USER') }}"
password: "{{ lookup('env', 'VMWARE_PASSWORD') }}"
validate_certs: false
groups:
  pyroscope_full_stack: "'pyroscope' in tags"
  pyroscope_add_to_existing: "'grafana' in tags"
```

Requires the `community.vmware` collection:

```bash
ansible-galaxy collection install community.vmware
```

## Enterprise VM Notes (RHEL)

The role handles common enterprise concerns:

- **SELinux**: Auto-detects enforcing mode and adds `:z` flag to Docker volume mounts
- **firewalld**: Opens ports 4040 and 3000 (HTTP) or 4443 and 443 (HTTPS) if firewalld is active
- **Privilege escalation**: Configure `ansible_become_method` in inventory (`su`, `pbrun`, `sudo`)
- **Idempotent**: Safe to re-run — every task checks current state before acting
- **Check mode**: Use `--check` for dry runs
- **Air-gapped**: Use `docker_load_path` to load images from tar (no Docker registry needed)
- **TLS cert idempotency**: Self-signed cert regenerated only if missing or expiring within 7 days

## Integrating into Existing Playbooks

The `pyroscope-stack` role is designed to drop into your existing Ansible automation. Below are the common integration patterns.

### Step 1: Make the role available

Copy or symlink the role into your playbook's `roles/` directory:

```bash
# Option A: Copy the role
cp -r deploy/monolith/ansible/roles/pyroscope-stack /path/to/your/playbook/roles/

# Option B: Symlink (keeps it in sync with this repo)
ln -s /path/to/pyroscope/deploy/monolith/ansible/roles/pyroscope-stack \
      /path/to/your/playbook/roles/pyroscope-stack

# Option C: Use roles_path in ansible.cfg
# ansible.cfg
# [defaults]
# roles_path = /path/to/pyroscope/deploy/monolith/ansible/roles
```

### Step 2: Add the role to your playbook

**Full stack on dedicated profiling VMs:**

```yaml
# site.yml — your existing playbook
- name: Base configuration
  hosts: all
  become: true
  roles:
    - role: common
    - role: security-baseline

- name: Deploy observability stack on profiling VMs
  hosts: profiling_servers
  become: true
  roles:
    - role: pyroscope-stack
```

**Full stack with TLS:**

```yaml
- name: Deploy observability with HTTPS
  hosts: profiling_servers
  become: true
  roles:
    - role: pyroscope-stack
      tls_enabled: true
      tls_self_signed: true
```

**Pyroscope-only on dedicated VMs, Grafana elsewhere:**

```yaml
- name: Deploy Pyroscope (no Grafana)
  hosts: pyroscope_servers
  become: true
  roles:
    - role: pyroscope-stack
      skip_grafana: true

- name: Add profiling to existing Grafana hosts
  hosts: grafana_servers
  become: true
  roles:
    - role: pyroscope-stack
      pyroscope_mode: add-to-existing
      grafana_url: "http://localhost:3000"
      grafana_api_key: "{{ vault_grafana_api_key }}"
      pyroscope_url: "http://pyroscope.corp:4040"
```

**Include specific tasks (no full role):**

```yaml
- name: Just deploy Pyroscope container
  hosts: profiling_servers
  become: true
  tasks:
    - ansible.builtin.include_role:
        name: pyroscope-stack
        tasks_from: full-stack.yml
      vars:
        pyroscope_port: 4040
        grafana_port: 3000
```

### Step 3: Configure per-environment

Use group_vars or host_vars for environment-specific settings:

```yaml
# group_vars/production.yml
grafana_admin_password: "{{ vault_grafana_password }}"
pyroscope_image: grafana/pyroscope:1.7.0   # pin version in prod
grafana_image: grafana/grafana:11.5.2
tls_enabled: true
tls_cert_src: files/certs/prod-cert.pem
tls_key_src: files/certs/prod-key.pem

# group_vars/staging.yml
grafana_admin_password: admin
pyroscope_image: grafana/pyroscope:latest   # latest in staging
tls_enabled: true
tls_self_signed: true
```

### Step 4: Run with your existing inventory

```bash
# Deploy to all profiling_servers in your inventory
ansible-playbook -i inventory/production site.yml --tags deploy --limit profiling_servers

# Check mode (dry run)
ansible-playbook -i inventory/production site.yml --tags deploy --limit profiling_servers --check
```

### Common integration patterns

| Pattern | How |
|---------|-----|
| Add to existing site.yml | Add a new play with `role: pyroscope-stack` |
| Secrets management | Use `ansible-vault` for `grafana_admin_password` and `grafana_api_key` |
| Pin versions in production | Set `pyroscope_image` and `grafana_image` in `group_vars/production.yml` |
| Different config per environment | Use `group_vars/` for env-specific variables |
| Gradual rollout | Use `--limit` to target specific hosts |
| CI/CD integration | `ansible-playbook -i inventory playbooks/deploy.yml --check` in pipeline |
| Air-gapped deployment | Set `docker_load_path` in group_vars or pass via `-e` |
| TLS per environment | Self-signed in staging (`tls_self_signed`), CA certs in production (`tls_cert_src`) |

## Directory Structure

```
ansible/
├── inventory/
│   ├── hosts.yml                       # Static inventory (edit this)
│   └── group_vars/
│       └── pyroscope.yml               # Shared variables
├── playbooks/
│   ├── deploy.yml                      # Deploy stack
│   ├── stop.yml                        # Stop (preserve data)
│   ├── clean.yml                       # Full cleanup
│   └── status.yml                      # Check status
├── roles/
│   └── pyroscope-stack/
│       ├── defaults/main.yml           # Default variables
│       ├── tasks/
│       │   ├── main.yml                # Entry point
│       │   ├── preflight.yml           # Pre-flight checks
│       │   ├── full-stack.yml          # Full stack deployment
│       │   ├── add-to-existing.yml     # Add to existing Grafana
│       │   ├── tls.yml                 # TLS cert management + Envoy
│       │   ├── stop.yml                # Stop containers
│       │   └── clean.yml              # Full cleanup
│       ├── templates/
│       │   ├── datasource.yaml.j2      # Pyroscope datasource
│       │   ├── dashboard-provider.yaml.j2
│       │   ├── plugins.yaml.j2         # Plugin provisioning
│       │   └── envoy.yaml.j2           # Envoy TLS proxy config
│       ├── handlers/main.yml           # Restart handlers
│       └── files/                      # Static files (if needed)
└── README.md                           # This file
```
