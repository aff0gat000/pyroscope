# How-to — running on Apple Silicon (M-series Mac)

Both phases run on M1/M2/M3/M4 Macs with Docker Desktop. One image uses
emulation; everything else is native arm64.

## Prerequisites

- Docker Desktop 4.30+ with **Rosetta 2** enabled for x86/amd64 emulation.
- Settings → General → *"Use Rosetta for x86/amd64 emulation on Apple
  Silicon"* — turn **ON**. This dramatically speeds up the one emulated
  container (Couchbase).
- Memory: **at least 8 GB allocated to Docker** (Settings → Resources →
  Advanced). Phase 1 + Phase 2 together use roughly 6 GB.
- Disk: ~15 GB free for images (Ollama model alone is ~2 GB).
- Recommended: enable VirtioFS (default in recent Docker Desktop) for
  faster bind-mount reads.

## Native vs emulated containers

Everything runs arm64 **except** Couchbase CE 7.2, which is amd64-only.
The compose file explicitly pins `platform: linux/amd64` for that one
service, so Docker uses Rosetta without prompting.

| service         | arch    | notes                                      |
|-----------------|---------|--------------------------------------------|
| phase 1 all     | arm64   |                                            |
| **couchbase**   | amd64   | **runs under Rosetta 2**; ~30–60 s startup |
| phase 2 all     | arm64   | pgvector, MLflow, Airflow, Ollama, nginx   |
| demo-jvm21      | arm64   | virtual threads fully supported            |
| pyroscope-java  | arm64   | 0.14.0 bundles linux-arm64 async-profiler  |

## Ollama on Mac: native vs containerised

The `ai-ollama` container runs Ollama inside Docker. On Mac that means
**CPU-only inference** — Docker containers can't access Metal GPUs.
`llama3.2:3b` is small enough to stay responsive on CPU.

If you want GPU-accelerated inference, install Ollama **natively** on the
Mac and point the stack at the host:

```bash
# install & run on host
brew install ollama
ollama serve &
ollama pull llama3.2:3b

# then in local-demo/ai/.env:
# (host.docker.internal points at the Mac host from inside Docker)
OLLAMA_URL=http://host.docker.internal:11434

# disable the containerised Ollama:
docker compose stop ollama ollama-init
```

This uses Metal acceleration on the host for large latency wins on
bigger models (e.g., `llama3.1:8b`).

## Known quirks

- **First `up.sh` is slow** — pulling ~5 GB of images + Gradle building
  two JVM apps. Budget 10–15 min.
- **Couchbase startup** — the emulated container takes 30–60 s to be
  ready. `/couchbase/*` endpoints return 503 until init completes. Wait
  or tail `docker compose logs couchbase-init`.
- **VPN + `host.docker.internal`** — some corporate VPNs block
  host-gateway. If phase-2 Airflow can't reach phase-1 Pyroscope, either
  disable the VPN for localhost traffic or set `PYROSCOPE_URL` to a
  direct internal DNS name.
- **Node/npm on first web build** — Vite dev deps pull via npm inside
  the `node:20-alpine` image; ~200 MB, few minutes first time.

## Verifying architecture after `up.sh`

```bash
docker inspect --format '{{.Name}} {{.Architecture}}' $(docker ps -q) 2>/dev/null | column -t
```

Expect arm64 for everything except `demo-couchbase` (amd64).

## Fallback: force amd64 everywhere

Not recommended — slower and wastes the M1's performance. But if you hit
unexpected arm64 issues you can temporarily add to every service:

```yaml
platform: linux/amd64
```

or set `DOCKER_DEFAULT_PLATFORM=linux/amd64` in your shell before `up.sh`.
