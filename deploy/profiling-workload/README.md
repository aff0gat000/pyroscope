# Pyroscope Profiling Workload

Standalone Java app that generates CPU, allocation, and lock contention workloads on a
loop. Deploy it on the same VM where Pyroscope is running to verify the Pyroscope UI
shows flame graphs — no network changes, no external traffic, no OCP access needed.

The app starts generating profiling data immediately. Profiles appear in the Pyroscope
UI within 30 seconds.

---

## What it does

| Workload | Interval | What shows in Pyroscope |
|----------|:--------:|------------------------|
| SHA-256 hashing (5000 iterations) | Every 2s | CPU flame graph — `MessageDigest.digest()` hotspot |
| List allocation + sort (50k items) | Every 3s | Allocation flame graph — `ArrayList.add()`, `Collections.sort()` |
| Lock contention (4 threads, 1 lock) | Every 5s | Lock flame graph — `ReentrantLock.lock()` contention |

Built on Vert.x 4.5.8 with periodic timers — same event-driven pattern as the FaaS stack.

---

## Step-by-step deployment (enterprise VM)

### Prerequisites

- Pyroscope is already running on the VM (`docker ps | grep pyroscope`)
- Docker is installed on your workstation (for building the image)
- SSH access to the VM

### Step 1 — Build the image (on your workstation)

```bash
cd deploy/profiling-workload
docker build -t profiling-workload:1.0.0 .
```

### Step 2 — Save the image to a tar file

```bash
docker save profiling-workload:1.0.0 -o profiling-workload.tar
```

### Step 3 — Transfer to the VM

```bash
scp profiling-workload.tar operator@<vm-hostname>:/tmp/
```

### Step 4 — SSH to the VM and switch to root

```bash
ssh operator@<vm-hostname>
pbrun /bin/su -
```

### Step 5 — Load the image

```bash
docker load -i /tmp/profiling-workload.tar
```

Verify:

```bash
docker images | grep profiling-workload
```

### Step 6 — Find the Pyroscope container's network

The profiling workload needs to reach Pyroscope. Find which Docker network Pyroscope is on:

```bash
docker inspect pyroscope --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}'
```

If Pyroscope was started with `deploy.sh`, the network is typically `bridge` or a custom
network. Note the name for the next step.

### Step 7 — Start the profiling workload

**Option A — Same Docker network as Pyroscope (recommended):**

```bash
# Replace NETWORK_NAME with the output from Step 6
docker run -d \
  --name profiling-workload \
  --network NETWORK_NAME \
  -e PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040 \
  profiling-workload:1.0.0
```

**Option B — Host networking (if Pyroscope is on the default bridge):**

```bash
docker run -d \
  --name profiling-workload \
  --network host \
  -e PYROSCOPE_SERVER_ADDRESS=http://localhost:4040 \
  profiling-workload:1.0.0
```

### Step 8 — Verify profiles appear

Wait 30 seconds, then check:

```bash
# Check container is running
docker logs profiling-workload

# Expected output:
#   Profiling workload started — generating profiling data
#     CPU work:        every 2s (SHA-256 hashing)
#     Allocation work: every 3s (list sort)
#     Lock contention: every 5s (4 competing threads)

# Check profiles arrived in Pyroscope
curl -s http://localhost:4040/pyroscope/label-values?label=service_name | grep profiling-workload
```

Open the Pyroscope UI at `http://<vm-hostname>:4040`:
1. Select **profiling-workload** from the application dropdown
2. Select **process_cpu** profile type — you should see `MessageDigest.digest()` as a hotspot
3. Select **memory** profile type — you should see `ArrayList.add()` and `Collections.sort()`
4. Select **mutex** profile type — you should see `ReentrantLock.lock()` contention

### Step 9 — Tear down (when done testing)

```bash
docker stop profiling-workload
docker rm profiling-workload

# Optional: remove the image and tar file
docker rmi profiling-workload:1.0.0
rm /tmp/profiling-workload.tar
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Container exits immediately | Pyroscope agent can't resolve server address | Check `PYROSCOPE_SERVER_ADDRESS` and network connectivity |
| Container runs but no profiles in UI | Wrong Docker network — app can't reach Pyroscope | Use `--network` flag matching Pyroscope's network (Step 6-7) |
| `connection refused` in container logs | Pyroscope is not running or wrong port | Verify: `curl http://localhost:4040/ready` on the VM |
| Image build fails (no internet on workstation) | Gradle or agent JAR download fails | Build on a machine with internet, then `docker save/load` |

---

## Air-gapped build

If your build machine also has no internet, pre-download these files and place them
in the build context:

```bash
# On a machine with internet
curl -fSL "https://services.gradle.org/distributions/gradle-7.6.4-bin.zip" -o gradle-7.6.4-bin.zip
curl -fSL "https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar" -o pyroscope.jar

# Transfer to build machine, then modify the Dockerfile to COPY instead of curl
```
