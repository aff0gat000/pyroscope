# Troubleshooting Guide

Consolidated troubleshooting reference for Pyroscope, Java agents, Grafana integration,
and deployment issues. Organized by symptom.

> **Diataxis category:** How-to guide — task-oriented, assumes you have a running deployment.

---

## Quick diagnostic

Run this from any machine that can reach the Pyroscope server:

```bash
PYROSCOPE_HOST="PYROSCOPE_VM_IP"   # or localhost, or service DNS
PYROSCOPE_PORT=4040

echo "=== 1. Server health ==="
curl -sf http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/ready && echo " OK" || echo " FAIL"

echo "=== 2. Known applications ==="
curl -sf "http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/pyroscope/label-values?label=service_name"
echo

echo "=== 3. Profile types ==="
curl -sf -X POST "http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/querier.v1.QuerierService/ProfileTypes" \
    -H "Content-Type: application/json" -d '{}'
echo

echo "=== 4. Port reachable ==="
nc -zv ${PYROSCOPE_HOST} ${PYROSCOPE_PORT} 2>&1
```

If step 1 fails, start with [Server not running](#server-not-running).
If step 2 returns `[]` (empty), start with [No data in Pyroscope UI](#no-data-in-pyroscope-ui).

---

## No data in Pyroscope UI

The most common issue. Work through these steps in order.

### Step 1: Is the server running?

```bash
# VM deployment
curl -sv http://PYROSCOPE_VM_IP:4040/ready
docker ps | grep pyroscope
docker logs pyroscope

# OCP deployment
oc get pods -n <namespace> -l app.kubernetes.io/name=pyroscope
oc logs -n <namespace> <pyroscope-pod>
```

Expected: HTTP 200 with body `ready`.

### Step 2: Can the agent reach the server?

```bash
# From inside an OCP pod
oc exec -it <pod-name> -n <namespace> -- curl -sv http://PYROSCOPE_VM_IP:4040/ready

# If curl isn't in the image
oc exec -it <pod-name> -n <namespace> -- nc -zv PYROSCOPE_VM_IP 4040

# Or use a debug pod
oc run debug-net --rm -it --image=registry.access.redhat.com/ubi8/ubi-minimal \
    -- curl -sv http://PYROSCOPE_VM_IP:4040/ready
```

**If this fails, traffic is blocked.** Check:

1. **OCP egress policies:**
   ```bash
   oc get networkpolicy -n <namespace>
   oc get egressnetworkpolicy -n <namespace>
   oc get egressfirewall -n <namespace>
   ```

2. **VM firewall:**
   ```bash
   # On the Pyroscope VM
   ss -tlnp | grep 4040
   firewall-cmd --list-ports        # firewalld
   iptables -L -n | grep 4040      # iptables
   ```

3. **Corporate firewall** between OCP and VM — work with your network team to
   allow TCP 4040 from OCP worker node IPs to the Pyroscope VM.

4. **HTTP proxy:** Check if `HTTP_PROXY` / `NO_PROXY` in the pod are routing
   traffic through a proxy that blocks non-HTTP traffic or internal IPs.

### Step 3: Is the Java agent loaded?

```bash
# Check pod logs for agent startup
oc logs <pod-name> -n <namespace> | grep -i "pyroscope\|async-profiler"

# Docker Compose
docker logs <container> 2>&1 | grep -i "pyroscope\|async-profiler"
```

Expected output:
```
[pyroscope] INFO  io.pyroscope.javaagent.PyroscopeAgent - starting profiling...
[pyroscope] INFO  io.pyroscope.javaagent.PyroscopeAgent - server address: http://...
```

If missing:
- Verify `JAVA_TOOL_OPTIONS` includes `-javaagent:/path/to/pyroscope.jar`
- Verify the JAR exists: `oc exec <pod> -- ls -la /path/to/pyroscope.jar`
- Check if another `-javaagent` flag is overriding

### Step 4: Is the agent sending data?

Enable debug logging:
```bash
# Environment variable
PYROSCOPE_LOG_LEVEL=debug

# Or in pyroscope.properties
pyroscope.log.level=debug
```

Check logs:
```bash
oc logs <pod-name> | grep -i "upload\|ingest\|push\|error\|fail"
```

| Log message | Meaning |
|------------|---------|
| `uploaded profile` | Agent is successfully sending data |
| `connection refused` | Server unreachable (go to Step 2) |
| `timeout` | Firewall silently dropping packets |
| `401` / `403` | Auth issue (basic auth or tenant ID mismatch) |

### Step 5: Is the server address correct?

```bash
# Check what the agent is configured with
oc exec <pod-name> -- env | grep -i pyroscope

# Properties file
oc exec <pod-name> -- cat /path/to/pyroscope.properties
```

Common mistakes:
- `localhost:4040` — only works if Pyroscope is in the same pod
- Kubernetes DNS for a VM Pyroscope (`pyroscope.monitoring.svc`)
- Missing port (`http://10.0.0.5` instead of `http://10.0.0.5:4040`)

### Step 6: Does the server have data?

```bash
curl -s 'http://PYROSCOPE_HOST:4040/pyroscope/label-values?label=service_name'
```

If applications appear but the UI shows nothing:
- Check **time range** — profiles only appear after at least one upload (10s default)
- Check **application name filter** matches what the agent sends
- Try a direct render query:
  ```bash
  curl -s "http://PYROSCOPE_HOST:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name=\"my-app\"}&from=now-1h&until=now&format=json"
  ```

---

## Grafana shows "No data"

### Datasource not working

```bash
# Test from Grafana VM
curl -sv http://PYROSCOPE_HOST:4040/ready

# Test a query (same as Grafana would)
curl -s -X POST http://PYROSCOPE_HOST:4040/querier.v1.QuerierService/ProfileTypes \
    -H "Content-Type: application/json" -d '{}'
```

In Grafana: **Connections → Data sources → Pyroscope → Test**

Check the datasource URL matches `http://PYROSCOPE_HOST:4040`.

### Plugin not installed

```bash
# Check plugin status (Docker Compose)
curl -sf -u admin:admin 'http://localhost:3000/api/plugins/grafana-pyroscope-app/settings'

# Install via environment variable
GF_INSTALL_PLUGINS=grafana-pyroscope-app
```

### Stale dashboard state

Grafana caches dashboard state in its volume. After modifying dashboard JSON files:

```bash
# Docker Compose
docker compose restart grafana

# Or full teardown + redeploy to clear the volume
bash scripts/run.sh teardown && bash scripts/run.sh
```

### Wrong time range

Profiles only appear for time windows when the agent was actively pushing.
Set the time picker to "Last 15 minutes" and verify load is running.

---

## Flame graph is empty for a profile type

| Profile type | Empty because | Fix |
|-------------|--------------|-----|
| **CPU** | Service is idle (no active threads on CPU) | Generate load first |
| **Allocation** | Threshold too high | Lower `pyroscope.profiler.alloc` (e.g., `256k`) |
| **Mutex** | No lock contention above threshold | Lower `pyroscope.profiler.lock` (e.g., `1ms`) |
| **Wall clock** | No active threads | Same as CPU — requires running threads |

---

## Server not running

### Docker container

```bash
docker ps -a | grep pyroscope          # check status
docker logs pyroscope                   # check logs
docker inspect pyroscope | grep -i oom  # check for OOM kill
```

Common causes:
- **OOM killed:** Increase memory limit to 2 GB
- **Port conflict:** `ss -tlnp | grep 4040`
- **Storage full:** `docker exec pyroscope df -h /data`
- **Config error:** Check pyroscope.yaml syntax

### OCP pod

```bash
oc get pods -n <namespace> -l app.kubernetes.io/name=pyroscope
oc describe pod <pyroscope-pod> -n <namespace>  # events, OOM, scheduling failures
oc logs <pyroscope-pod> -n <namespace>
```

---

## Build failures (Docker Compose demo)

```bash
docker builder prune -f
docker compose build --no-cache
docker system info | grep -E "Memory|CPUs"
```

Minimum 8 GB RAM to build and run all services.

---

## Port conflicts

```bash
ss -tlnp | grep -E '3000|4040|8080|8081|8082|8083|8084|8085|8086|9090'
```

Change port mappings in `docker-compose.yaml` or stop the conflicting process.

---

## High profiling overhead

Expected: 3-8% combined CPU for all 4 profile types.

If overhead is higher:

| Action | Configuration |
|--------|--------------|
| Switch CPU event | `pyroscope.profiler.event=cpu` (Linux perf_events, lower overhead) |
| Raise allocation threshold | `pyroscope.profiler.alloc=1m` (sample less frequently) |
| Disable mutex profiling | Remove `pyroscope.profiler.lock` setting |
| Reduce upload frequency | `pyroscope.upload.interval=30s` (default 10s) |
| CPU-only profiling | Only set `pyroscope.profiler.event=itimer`, remove alloc/lock |

Measure overhead:
```bash
# Compare with and without profiling
docker compose -f docker-compose.yaml -f docker-compose.no-pyroscope.yaml up -d  # without
docker compose up -d                                                               # with
bash scripts/benchmark.sh                                                          # compare
```

---

## Common root causes summary

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `curl: connection refused` from OCP pod | Firewall blocking TCP 4040 | Open firewall from OCP workers to VM:4040 |
| `curl: connection timed out` from OCP pod | Silent firewall drop | Same — check corporate firewall |
| Agent logs show no pyroscope messages | JAR not loaded | Verify `-javaagent` in `JAVA_TOOL_OPTIONS` |
| Agent logs show `connection refused` | Wrong server address or server down | Fix `PYROSCOPE_SERVER_ADDRESS`; verify server running |
| Server running, label-values returns `[]` | Agent not pushing | Enable `PYROSCOPE_LOG_LEVEL=debug` |
| Label-values returns apps, UI shows no data | Wrong time range | Select "Last 15 minutes" |
| Grafana "No data" | Datasource URL wrong | Test datasource in Grafana settings |
| Grafana "Plugin not found" | Plugin not installed | Add `GF_INSTALL_PLUGINS=grafana-pyroscope-app` |
| Flame graph empty for mutex | No lock contention | Lower `pyroscope.profiler.lock` threshold |
| OOM kill on Pyroscope container | Insufficient memory | Increase to 2 GB |
