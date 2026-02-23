# Security Model

Security posture of the Pyroscope continuous profiling deployment. Covers data classification,
authentication, authorization, encryption, secrets management, network security, and compliance.

---

## Data Classification

Profiling data contains:

- Function names and class names
- Call stacks (full stack traces)
- Sample counts (CPU time, allocations, etc.)
- Thread names
- Label metadata (service name, namespace, pod name)

Profiling data does **not** contain:

- Variable values or object state
- Method arguments or return values
- Request/response payloads
- Database queries or result sets
- PII (names, emails, SSNs)
- Business data (transactions, account numbers)

Recommended classification: **Internal** — non-sensitive technical telemetry. Profiling data
reveals code structure and performance characteristics but not business data.

Cross-ref: [faq.md](faq.md) for profiling data content details.

---

## Authentication Model

### Default Mode: No Authentication

The Pyroscope HTTP API (port 4040) has no authentication in default mode. Any client with
network access can:

- Push profiles (write data)
- Query profiles (read data)
- Access the web UI

This is the most critical security gap to address in any deployment.

### Mitigation Strategies

| Strategy | Implementation | Effort | When to Use |
|----------|----------------|--------|-------------|
| Network isolation | Firewall rules limiting port 4040 to trusted subnets (OCP workers, Grafana VM, admin workstations) | Low | Phase 1 (default) |
| Reverse proxy auth | Envoy or nginx with basic auth or OIDC in front of Pyroscope | Medium | When multiple teams share the Pyroscope instance |
| OCP Route auth | OpenShift Route with OAuth proxy sidecar | Medium | OCP-native deployments (Phase 2) |
| Helm NetworkPolicy | Set `networkPolicy.enabled: true` in Helm values | Low | K8s/OCP deployments |
| Multi-tenancy | `X-Scope-OrgID` header for tenant isolation | Low | When isolating teams' profiling data |

Cross-ref: [deployment-guide.md](deployment-guide.md) for firewall rules and Envoy TLS setup.

---

## Authorization

Pyroscope has no role-based access control (RBAC) in default mode. All clients with network
access have full read/write access. Multi-tenancy via the `X-Scope-OrgID` HTTP header provides
tenant-level data isolation but not fine-grained permissions.

Phase 2 consideration: If deploying on OCP with multiple teams, use the OAuth proxy sidecar
pattern for per-user authentication and namespace-level NetworkPolicy for pod-level isolation.

---

## Encryption in Transit

Pyroscope serves plain HTTP on port 4040 internally. TLS is terminated by an Envoy reverse
proxy when enabled.

### Traffic Paths

- **Agent to Pyroscope:** HTTP by default, HTTPS via Envoy with `--tls` flag
- **Grafana to Pyroscope:** HTTP on same host, HTTPS when cross-host
- **Prometheus to Pyroscope:** HTTP scrape of `/metrics`

Cross-ref: [deployment-guide.md](deployment-guide.md) for complete TLS architecture diagrams
and setup procedures.

---

## Encryption at Rest

Default: **no encryption at rest**. Profiling data is stored in a Docker volume (`/data`) on
the local filesystem without encryption.

### Mitigations

- **OS-level encryption:** LUKS full-disk encryption on the VM (RHEL/CentOS: `cryptsetup luksFormat`)
- **OCP storage encryption:** Use a StorageClass that supports encryption at rest (e.g., ODF/Ceph with encryption enabled)
- **Object storage encryption:** S3 server-side encryption (SSE-S3 or SSE-KMS) when using object storage backend

For most deployments, OS-level encryption is sufficient since profiling data is classified as
internal (non-sensitive) telemetry.

---

## Secrets Management

The Pyroscope deployment involves two categories of secrets.

### Grafana Credentials

- `GRAFANA_API_KEY` — API key for datasource provisioning
- `GRAFANA_ADMIN_PASSWORD` — Grafana admin password

Best practices:

- Use environment variables, not CLI flags (flags are visible in `ps` output and shell history)
- Use `ansible-vault` for Ansible deployments
- Use Kubernetes Secrets for OCP/K8s deployments

Cross-ref: [deploy/monolith/ansible/README.md](../deploy/monolith/ansible/README.md) for
ansible-vault usage.

### Pyroscope Secrets

The Pyroscope server itself has no API keys, tokens, or passwords in default mode. The agent
pushes over unauthenticated HTTP.

---

## Network Security

Pyroscope uses a single port (TCP 4040) for all traffic: agent ingestion, Grafana queries,
Prometheus scrape, and UI access. The server never initiates outbound connections.

Cross-ref: [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) for the
complete firewall rules table.

Cross-ref: [architecture.md](architecture.md) for network boundary diagrams.

For K8s/OCP deployments, enable NetworkPolicy to restrict which namespaces can reach port 4040:

```yaml
# In deploy/helm/pyroscope/values.yaml
networkPolicy:
  enabled: true
  allowedNamespaces:
    - kubernetes.io/metadata.name: my-app-namespace
```

---

## FIPS Compliance

Three strategies for FIPS 140-2 / 140-3 compliance:

| Strategy | Go Version | Crypto Library |
|----------|------------|----------------|
| BoringCrypto | 1.19+ | BoringSSL (FIPS 140-2 #4407) |
| Red Hat Go Toolset | Any | System OpenSSL (FIPS 140-2 #4282) |
| Go native FIPS | 1.24+ | Go stdlib (FIPS 140-3, pending) |

TLS termination at the load balancer or Envoy proxy can also satisfy FIPS requirements without
custom Pyroscope builds.

Cross-ref: [deployment-guide.md](deployment-guide.md) for complete FIPS build instructions and
Dockerfile examples.

---

## Audit Logging

**Gap:** Pyroscope does not produce an audit log. There is no record of who queried which
profiles, when data was ingested, or which clients accessed the UI.

Mitigation: Deploy an Envoy or nginx reverse proxy in front of Pyroscope and enable access
logging. Proxy access logs capture: source IP, timestamp, HTTP method, endpoint, and response
code. This provides a basic audit trail for compliance purposes.

```bash
# Example: Envoy access log entry
[2026-02-23T10:15:30.123Z] "GET /pyroscope/render?query=..." 200 - 0 1234 45 - "10.0.1.50" "curl/7.88.1"
```

---

## Compliance Checklist

| Control | Status | Notes |
|---------|--------|-------|
| Data classification | Done | Internal — no PII, no business data |
| Authentication | Gap | No auth by default; mitigated by network isolation |
| Authorization (RBAC) | Gap | No RBAC; all authenticated clients have full access |
| Encryption in transit (TLS) | Available | Envoy proxy terminates TLS; opt-in via `--tls` flag |
| Encryption at rest | Gap | No default; mitigated by OS-level or storage-class encryption |
| Secrets management | Documented | Use env vars or ansible-vault; never CLI flags |
| Network isolation | Documented | Firewall rules + NetworkPolicy |
| FIPS compliance | Available | BoringCrypto, Red Hat Go Toolset, or TLS termination |
| Audit logging | Gap | No native audit; mitigated by proxy access logs |
| Air-gap capable | Yes | No outbound connections; offline image loading supported |
| Data sovereignty | Yes | All data on-premise; no SaaS dependency |
