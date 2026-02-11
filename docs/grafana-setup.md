# Connecting Grafana to Pyroscope

Step-by-step guide for adding the Pyroscope datasource and pre-built dashboards to an existing Grafana instance using config-file provisioning. No manual UI configuration needed.

> **Don't have Grafana yet?** See [deploy/grafana/](../deploy/grafana/README.md) for a standalone Grafana deployment with Pyroscope datasource, dashboards, and provisioning baked in — follows the same patterns as the [Pyroscope deployment](../deploy/monolithic/README.md).

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Grafana 9.x or later | The Pyroscope datasource plugin requires Grafana 9+. Check with `grafana-server -v`. |
| Network access | Grafana must be able to reach the Pyroscope server on port 4040 (or your custom port). |
| Pyroscope running | Verify with `curl -s http://<PYROSCOPE_VM_IP>:4040/ready`. |
| Grafana provisioning directory | Typically `/etc/grafana/provisioning/` (default for package installs). |

## Step 1: Install the Pyroscope plugins

The Pyroscope datasource and app plugins must be installed in Grafana. Choose one method:

**Option A — Provisioning file (recommended for automation):**

Copy the plugin provisioning config to your Grafana server:

```bash
# On the Grafana server
mkdir -p /etc/grafana/provisioning/plugins

# From your workstation (where you have the repo cloned)
scp config/grafana/provisioning/plugins/plugins.yaml \
    operator@grafana-server:/etc/grafana/provisioning/plugins/
```

This enables the following plugins (from `config/grafana/provisioning/plugins/plugins.yaml`):

| Plugin | Purpose |
|--------|---------|
| `grafana-pyroscope-app` | Pyroscope application UI integration |
| `grafana-pyroscope-datasource` | Pyroscope datasource for querying profiles |

**Option B — CLI install:**

```bash
grafana-cli plugins install grafana-pyroscope-app
grafana-cli plugins install grafana-pyroscope-datasource
```

> **Note:** If Grafana is running in Docker, install plugins via the `GF_INSTALL_PLUGINS` environment variable:
> ```bash
> docker run -e GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource ...
> ```

## Step 2: Add the Pyroscope datasource

Copy the datasource provisioning file to your Grafana server and update the Pyroscope URL:

```bash
# On the Grafana server
mkdir -p /etc/grafana/provisioning/datasources

# From your workstation
scp config/grafana/provisioning/datasources/datasources.yaml \
    operator@grafana-server:/etc/grafana/provisioning/datasources/
```

Then edit the file on the Grafana server to set the correct Pyroscope URL:

```bash
vi /etc/grafana/provisioning/datasources/datasources.yaml
```

Change the Pyroscope datasource URL from `http://pyroscope:4040` to your Pyroscope VM's address:

```yaml
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope-ds
    access: proxy
    url: http://<PYROSCOPE_VM_IP>:4040    # <-- update this
    editable: true
```

> **Important:** The `uid: pyroscope-ds` value must not be changed. The pre-built dashboards reference this UID to connect panels to the Pyroscope datasource. If you change it, dashboards will show "datasource not found" errors.

The provisioning file also includes a Prometheus datasource. If you already have Prometheus configured in Grafana, remove or comment out the Prometheus block to avoid conflicts.

## Step 3: Import dashboards (optional)

The repo includes 6 pre-built dashboards. To provision them into Grafana:

**Copy the dashboard JSON files:**

```bash
# On the Grafana server
mkdir -p /var/lib/grafana/dashboards

# From your workstation
scp config/grafana/dashboards/*.json \
    operator@grafana-server:/var/lib/grafana/dashboards/
```

**Copy the dashboard provisioning config:**

```bash
# On the Grafana server
mkdir -p /etc/grafana/provisioning/dashboards

# From your workstation
scp config/grafana/provisioning/dashboards/dashboards.yaml \
    operator@grafana-server:/etc/grafana/provisioning/dashboards/
```

This provisions all JSON dashboards from `/var/lib/grafana/dashboards/` into a **"Pyroscope"** folder in Grafana.

> **Note:** If your Grafana stores dashboards in a different directory, edit `dashboards.yaml` and update the `path` value under `options`.

## Step 4: Restart Grafana

```bash
systemctl restart grafana-server
```

Or if Grafana is running in Docker:

```bash
docker restart grafana
```

## Step 5: Verify

1. **Check datasource health:** Open Grafana UI > **Configuration** > **Data Sources** > **Pyroscope** > **Test**. You should see "Data source is working".

2. **Open a dashboard:** Navigate to **Dashboards** > **Pyroscope** folder. Open any dashboard and confirm profile data loads.

3. **Check from the command line** (optional):

```bash
# Verify Grafana can reach Pyroscope (run on the Grafana server)
curl -s http://<PYROSCOPE_VM_IP>:4040/ready && echo " OK"
```

---

## Available Dashboards

| Dashboard | File | Description |
|-----------|------|-------------|
| Pyroscope Java Overview | `pyroscope-overview.json` | Top-level view of all profiled Java applications — CPU, memory, lock contention |
| HTTP Performance | `http-performance.json` | HTTP endpoint latency and throughput correlated with CPU/memory profiles |
| Service Performance | `verticle-performance.json` | Vert.x verticle-level profiling with service comparison |
| Before vs After Fix | `before-after-comparison.json` | Side-by-side flame graph comparison for validating performance fixes |
| FaaS Server | `faas-server.json` | Function-as-a-Service runtime: deploy/invoke/undeploy lifecycle, burst concurrency, warm pools |
| JVM Metrics Deep Dive | `jvm-metrics.json` | JVM internals: GC, heap, threads, class loading, JIT compilation |

---

## Troubleshooting

### Plugin not found after restart

Grafana may not have downloaded the plugin. Check the Grafana log:

```bash
journalctl -u grafana-server --since "5 minutes ago" | grep -i plugin
```

If the plugin is not available, install it manually with `grafana-cli`:

```bash
grafana-cli plugins install grafana-pyroscope-app
grafana-cli plugins install grafana-pyroscope-datasource
systemctl restart grafana-server
```

### Datasource test shows "connection refused"

Grafana cannot reach the Pyroscope server. Check:

1. **Pyroscope is running:** `curl -s http://<PYROSCOPE_VM_IP>:4040/ready` from the Grafana server.
2. **Firewall:** Port 4040 must be open between the Grafana server and the Pyroscope VM. Check with `ss -tlnp | grep :4040` on the Pyroscope VM.
3. **URL is correct:** Verify the `url` field in `datasources.yaml` matches the Pyroscope VM IP and port.

### Dashboards not appearing

1. **Check the provisioning config:** Verify `/etc/grafana/provisioning/dashboards/dashboards.yaml` exists and the `path` points to the directory containing the JSON files.
2. **Check file permissions:** Grafana must be able to read the dashboard JSON files. Run `ls -la /var/lib/grafana/dashboards/` and ensure the `grafana` user has read access.
3. **Check Grafana logs:** `journalctl -u grafana-server | grep -i dashboard`

### Dashboard panels show "datasource not found"

The dashboards reference the Pyroscope datasource by `uid: pyroscope-ds`. If your datasource was configured with a different UID, either:

- Update `datasources.yaml` to use `uid: pyroscope-ds`, or
- Find and replace the UID in each dashboard JSON file:
  ```bash
  sed -i 's/"uid": "pyroscope-ds"/"uid": "your-custom-uid"/g' /var/lib/grafana/dashboards/*.json
  ```

### Dashboards show "No data"

Profiles may not have been ingested yet. Verify:

1. **Java agents are sending data:** Check the Pyroscope UI at `http://<PYROSCOPE_VM_IP>:4040` — you should see application names listed.
2. **Time range:** Dashboards default to the last 1 hour. Adjust the time picker if profiles were ingested earlier or later.

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
