# Connecting Grafana to Pyroscope

Step-by-step guide for adding the Pyroscope datasource and pre-built dashboards to an existing Grafana instance. Two methods: **API** (no restart, no file access needed) and **provisioning files** (file-based, requires restart).

> **Don't have Grafana yet?** See [deploy/observability/](../deploy/observability/README.md) for a full-stack deployment that includes Grafana with Pyroscope pre-configured.

> **Want to automate this?** Both methods are fully automated in `deploy.sh`:
> ```bash
> # API method (no restart)
> bash deploy/observability/deploy.sh add-to-existing \
>     --grafana-url http://grafana.corp:3000 \
>     --grafana-api-key eyJrIj... \
>     --pyroscope-url http://pyroscope.corp:4040
>
> # Provisioning method (requires restart)
> bash deploy/observability/deploy.sh add-to-existing \
>     --method provisioning \
>     --pyroscope-url http://pyroscope.corp:4040 \
>     --grafana-provisioning-dir /etc/grafana/provisioning \
>     --grafana-dashboard-dir /var/lib/grafana/dashboards
> ```
> The Ansible role provides the same functionality — see [ansible/README.md](../deploy/observability/ansible/README.md).

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Grafana 9.x or later | The Pyroscope datasource plugin requires Grafana 9+. Check with `grafana-server -v`. |
| Network access | Grafana must be able to reach the Pyroscope server on port 4040 (HTTP) or 4443 (HTTPS). |
| Pyroscope running | Verify with `curl -s http://<PYROSCOPE_IP>:4040/ready`. |

**Method-specific:**

| Requirement | API method | Provisioning method |
|-------------|-----------|-------------------|
| Grafana API key or admin credentials | Required | Not needed |
| SSH / file access to Grafana server | Not needed | Required |
| Grafana restart | Not needed | Required |

## Which method should I use?

| Scenario | Recommended method |
|----------|--------------------|
| You have a Grafana API key or admin password | **API** — no restart, no file access |
| You don't have an API key but have SSH access | **Provisioning** — file-based, one restart |
| Grafana is managed by another team | **API** — only needs an API key |
| You want config-as-code (GitOps) | **Provisioning** — files live in version control |
| CI/CD pipeline integration | **API** — REST calls, no file system access |

---

## Method 1: API (No Restart)

Uses the Grafana REST API to add the datasource and import dashboards. No file access or restart needed — changes take effect immediately.

### Step 1: Get a Grafana API key

You need either an API key or admin credentials. To create an API key:

```bash
# Using admin credentials (replace password as needed)
curl -s -X POST http://grafana.corp:3000/api/auth/keys \
    -H "Content-Type: application/json" \
    -u admin:admin \
    -d '{"name": "pyroscope-setup", "role": "Admin"}' | python3 -m json.tool
```

Save the returned `key` value. Alternatively, use basic auth with `admin:<password>` in the steps below.

### Step 2: Install Pyroscope plugins

```bash
GRAFANA_URL="http://grafana.corp:3000"
API_KEY="eyJrIj..."  # or use -u admin:password instead of -H Authorization

# Install datasource plugin
curl -s -X POST "${GRAFANA_URL}/api/plugins/grafana-pyroscope-datasource/install" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d '{}'

# Install app plugin
curl -s -X POST "${GRAFANA_URL}/api/plugins/grafana-pyroscope-app/install" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d '{}'
```

> **Note:** If plugins are managed via `GF_INSTALL_PLUGINS` or `grafana-cli`, skip this step — they're already installed.

### Step 3: Add the Pyroscope datasource

```bash
PYROSCOPE_URL="http://pyroscope.corp:4040"  # or https://... for TLS

curl -s -X POST "${GRAFANA_URL}/api/datasources" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "{
        \"name\": \"Pyroscope\",
        \"type\": \"grafana-pyroscope-datasource\",
        \"uid\": \"pyroscope-ds\",
        \"access\": \"proxy\",
        \"url\": \"${PYROSCOPE_URL}\",
        \"isDefault\": false,
        \"editable\": true
    }"
```

> **Important:** The `uid` value `pyroscope-ds` must match exactly. The pre-built dashboards reference this UID. If you change it, dashboards will show "datasource not found" errors.

**If the datasource already exists** (updating the URL):

```bash
# Get the datasource ID
DS_ID=$(curl -s "${GRAFANA_URL}/api/datasources/name/Pyroscope" \
    -H "Authorization: Bearer ${API_KEY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Update it
curl -s -X PUT "${GRAFANA_URL}/api/datasources/${DS_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "{
        \"name\": \"Pyroscope\",
        \"type\": \"grafana-pyroscope-datasource\",
        \"uid\": \"pyroscope-ds\",
        \"access\": \"proxy\",
        \"url\": \"${PYROSCOPE_URL}\",
        \"isDefault\": false,
        \"editable\": true
    }"
```

### Step 4: Create the dashboard folder

```bash
curl -s -X POST "${GRAFANA_URL}/api/folders" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d '{"title": "Pyroscope", "uid": "pyroscope-folder"}'
```

If the folder already exists, get its ID:

```bash
FOLDER_ID=$(curl -s "${GRAFANA_URL}/api/folders/pyroscope-folder" \
    -H "Authorization: Bearer ${API_KEY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
```

### Step 5: Import dashboards

Import each dashboard JSON file from the repo:

```bash
# From the root of the pyroscope repo
FOLDER_ID=<folder-id-from-step-4>

for f in config/grafana/dashboards/*.json; do
    name=$(basename "$f" .json)
    dashboard_json=$(cat "$f")

    curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "{
            \"dashboard\": ${dashboard_json},
            \"folderId\": ${FOLDER_ID},
            \"overwrite\": true,
            \"message\": \"Imported from pyroscope repo\"
        }"

    echo "  Imported: ${name}"
done
```

### Step 6: Verify

```bash
# Test datasource connectivity
curl -s "${GRAFANA_URL}/api/datasources/uid/pyroscope-ds" \
    -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool

# List dashboards in Pyroscope folder
curl -s "${GRAFANA_URL}/api/search?folderIds=${FOLDER_ID}" \
    -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool
```

Open Grafana UI > **Dashboards** > **Pyroscope** folder and confirm data loads.

---

## Method 2: Provisioning Files (Requires Restart)

Writes provisioning YAML and dashboard JSON files to the Grafana server. Grafana reads them on startup. Requires SSH/file access and a restart.

### Step 1: Install the Pyroscope plugins

Choose one method:

**Option A — Provisioning file (recommended for automation):**

```bash
# On the Grafana server
mkdir -p /etc/grafana/provisioning/plugins
cat > /etc/grafana/provisioning/plugins/pyroscope.yaml <<'EOF'
apiVersion: 1

apps:
  - type: grafana-pyroscope-app
    org_id: 1
    disabled: false
  - type: grafana-pyroscope-datasource
    org_id: 1
    disabled: false
EOF
```

Or copy from the repo:

```bash
scp config/grafana/provisioning/plugins/plugins.yaml \
    operator@grafana-server:/etc/grafana/provisioning/plugins/
```

**Option B — CLI install:**

```bash
grafana-cli plugins install grafana-pyroscope-app
grafana-cli plugins install grafana-pyroscope-datasource
```

**Option C — Docker env var:**

```bash
docker run -e GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource ...
```

### Step 2: Add the Pyroscope datasource

Create the datasource provisioning file on the Grafana server:

```bash
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/pyroscope.yaml <<EOF
apiVersion: 1

datasources:
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope-ds
    access: proxy
    url: http://<PYROSCOPE_IP>:4040
    editable: true
EOF
```

Replace `<PYROSCOPE_IP>` with the actual Pyroscope server address. For HTTPS deployments, use `https://<PYROSCOPE_IP>:4443`.

> **Important:** The `uid: pyroscope-ds` value must not be changed. The pre-built dashboards reference this UID.

Or copy from the repo and update the URL:

```bash
scp config/grafana/provisioning/datasources/datasources.yaml \
    operator@grafana-server:/etc/grafana/provisioning/datasources/

# Then update the Pyroscope URL
ssh operator@grafana-server \
    "sed -i 's|http://pyroscope:4040|http://<PYROSCOPE_IP>:4040|g' \
    /etc/grafana/provisioning/datasources/datasources.yaml"
```

> The repo provisioning file also includes a Prometheus datasource. If you already have Prometheus configured, remove or comment out the Prometheus block to avoid conflicts.

### Step 3: Import dashboards

Copy the dashboard JSON files and create a dashboard provider config:

```bash
# Create dashboard directory
ssh operator@grafana-server "mkdir -p /var/lib/grafana/dashboards/pyroscope"

# Copy dashboard JSON files
scp config/grafana/dashboards/*.json \
    operator@grafana-server:/var/lib/grafana/dashboards/pyroscope/

# Create the dashboard provider config
ssh operator@grafana-server 'cat > /etc/grafana/provisioning/dashboards/pyroscope.yaml <<EOF
apiVersion: 1

providers:
  - name: "pyroscope"
    orgId: 1
    folder: "Pyroscope"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards/pyroscope
      foldersFromFilesStructure: false
EOF'
```

### Step 4: Restart Grafana

```bash
# Package install
systemctl restart grafana-server

# Docker
docker restart grafana
```

### Step 5: Verify

1. **Check datasource health:** Open Grafana UI > **Configuration** > **Data Sources** > **Pyroscope** > **Test**. You should see "Data source is working".

2. **Open a dashboard:** Navigate to **Dashboards** > **Pyroscope** folder. Open any dashboard and confirm profile data loads.

3. **Check from the command line:**

```bash
# Verify Grafana can reach Pyroscope
curl -s http://<PYROSCOPE_IP>:4040/ready && echo " OK"

# Check Grafana logs for provisioning errors
journalctl -u grafana-server --since "5 minutes ago" | grep -iE "provision|pyroscope|error"
```

---

## Ansible Integration

Both methods are available in the Ansible role:

```bash
cd deploy/observability/ansible

# API method
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_mode=add-to-existing \
    -e grafana_url=http://grafana.corp:3000 \
    -e grafana_api_key=eyJrIj... \
    -e pyroscope_url=http://pyroscope.corp:4040

# Provisioning method
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_mode=add-to-existing \
    -e grafana_method=provisioning \
    -e pyroscope_url=http://pyroscope.corp:4040
```

Or configure per-host in the inventory:

```yaml
# inventory/hosts.yml
pyroscope_add_to_existing:
  hosts:
    grafana01.corp.example.com:
      grafana_url: http://localhost:3000
      grafana_api_key: "{{ vault_grafana_api_key }}"
      pyroscope_url: http://pyroscope.corp:4040
```

---

## Available Dashboards

| Dashboard | File | Description |
|-----------|------|-------------|
| Pyroscope Java Overview | `pyroscope-overview.json` | Top-level view of all profiled Java applications — CPU, memory, lock contention |
| HTTP Performance | `http-performance.json` | HTTP endpoint latency and throughput correlated with CPU/memory profiles |
| Service Performance | `verticle-performance.json` | Vert.x verticle-level profiling with service comparison |
| Before vs After Fix | `before-after-comparison.json` | Side-by-side flame graph comparison for validating performance fixes |
| FaaS Server | `faas-server.json` | Function-as-a-Service runtime: deploy/invoke/undeploy lifecycle |
| JVM Metrics Deep Dive | `jvm-metrics.json` | JVM internals: GC, heap, threads, class loading, JIT compilation |

---

## Troubleshooting

### Plugin not found after restart

Grafana may not have downloaded the plugin. Check the Grafana log:

```bash
journalctl -u grafana-server --since "5 minutes ago" | grep -i plugin
```

If the plugin is not available, install it manually:

```bash
grafana-cli plugins install grafana-pyroscope-app
grafana-cli plugins install grafana-pyroscope-datasource
systemctl restart grafana-server
```

### Datasource test shows "connection refused"

Grafana cannot reach the Pyroscope server. Check:

1. **Pyroscope is running:** `curl -s http://<PYROSCOPE_IP>:4040/ready` from the Grafana server.
2. **Firewall:** Port 4040 (HTTP) or 4443 (HTTPS) must be open between the Grafana server and the Pyroscope VM. Check with `ss -tlnp | grep :4040` on the Pyroscope VM.
3. **URL is correct:** Verify the `url` field in the datasource config matches the Pyroscope VM IP and port.
4. **TLS:** If Pyroscope uses self-signed certs, Grafana may need `tlsSkipVerify: true` in the datasource config.

### Dashboards not appearing

1. **Check the provisioning config:** Verify `/etc/grafana/provisioning/dashboards/pyroscope.yaml` exists and the `path` points to the directory containing the JSON files.
2. **Check file permissions:** Grafana must be able to read the dashboard JSON files. Run `ls -la /var/lib/grafana/dashboards/pyroscope/` and ensure the `grafana` user has read access.
3. **Check Grafana logs:** `journalctl -u grafana-server | grep -i dashboard`

### Dashboard panels show "datasource not found"

The dashboards reference the Pyroscope datasource by `uid: pyroscope-ds`. If your datasource was configured with a different UID, either:

- Update the datasource config to use `uid: pyroscope-ds`, or
- Find and replace the UID in each dashboard JSON file:
  ```bash
  sed -i 's/"uid": "pyroscope-ds"/"uid": "your-custom-uid"/g' \
      /var/lib/grafana/dashboards/pyroscope/*.json
  ```

### Dashboards show "No data"

Profiles may not have been ingested yet. Verify:

1. **Java agents are sending data:** Check the Pyroscope UI at `http://<PYROSCOPE_IP>:4040` — you should see application names listed.
2. **Time range:** Dashboards default to the last 1 hour. Adjust the time picker if profiles were ingested earlier or later.

### API method: "Unauthorized" or 401 errors

1. **Check API key:** Ensure the key has `Admin` role (not `Viewer` or `Editor`).
2. **Check basic auth:** If using basic auth instead of an API key, verify the password: `curl -u admin:password http://grafana:3000/api/org`.
3. **API key expired:** Grafana API keys can have expiration dates. Create a new one if needed.

---

## Reference Files

All Grafana configuration files are in the repository under `config/grafana/`:

```
config/grafana/
├── dashboards/
│   ├── before-after-comparison.json
│   ├── faas-server.json
│   ├── http-performance.json
│   ├── jvm-metrics.json
│   ├── pyroscope-overview.json
│   └── verticle-performance.json
└── provisioning/
    ├── dashboards/
    │   └── dashboards.yaml
    ├── datasources/
    │   └── datasources.yaml
    └── plugins/
        └── plugins.yaml
```
