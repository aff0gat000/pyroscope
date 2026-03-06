# TLS Setup Guide

Pyroscope serves plain HTTP on port 4040. It does not handle TLS natively by default.
For HTTPS, TLS is terminated externally — by a load balancer (F5), a reverse proxy
(Nginx/Envoy), or via Pyroscope's built-in server TLS config. This guide covers all options.

For TLS architecture diagrams see [deployment-guide.md Section 16](deployment-guide.md#16-tls-architecture).

---

## Connectivity Modes

| Mode | TLS terminated at | Extra infra on VM | Pyroscope config changes | Agent URL example |
|------|-------------------|-------------------|--------------------------|-------------------|
| **HTTP (default)** | N/A | None | None | `http://10.1.2.3:4040` |
| **F5 VIP** | F5 load balancer | None | None | `https://pyroscope-dev.company.com` |
| **Pyroscope native TLS** | Pyroscope process | None | `pyroscope.yaml` update | `https://10.1.2.3:4040` |
| **Nginx proxy** | Nginx container | +1 container | None | `https://10.1.2.3:4443` |
| **Envoy proxy** | Envoy container | +1 container | None | `https://10.1.2.3:4443` |

---

## TLS Strategy by Environment

| Environment | Recommended mode | Certificate source | Notes |
|-------------|-----------------|-------------------|-------|
| Local / dev | HTTP or self-signed | N/A or `openssl req` | No TLS needed for local testing |
| Staging | Self-signed or internal CA | `openssl req` or PKI team | Mirror production topology for validation |
| Production | F5 VIP (recommended) or native TLS | Enterprise CA via PKI team | Auto-trusted by JVMs, centralized lifecycle |
| Regulated enterprise | F5 VIP + cert manager | PKI team / HashiCorp Vault | Auto-renewal, audit trail, compliance |

---

## Best Practices Approach

Enterprise CA certificates issued through your organization's PKI team, fronted by an
F5 VIP. Benefits:

- Certificates are automatically trusted by all corporate machines and JVMs (CA is in system truststore)
- Java agents need zero trust configuration — just change the URL to HTTPS
- Proper lifecycle: renewal, revocation, audit trail
- Compliance-friendly (SOC2, PCI-DSS, ISO 27001)

**Tradeoff:** Requires coordination with the network/security team. VIP and certificate
request lead time is typically days to weeks.

## Most Practical Approach

Start with HTTP, add TLS when the enterprise process completes:

1. **Day 1:** Deploy with HTTP on port 4040 (get it working, prove value)
2. **Week 1-2:** Submit F5 VIP request and certificate request to network/PKI team
3. **Week 2-4:** F5 VIP provisioned — switch agent config from `http://<VM_IP>:4040` to `https://pyroscope-dev.company.com`

If no F5 is available, use Pyroscope native TLS or a self-signed proxy as an interim solution
while the VIP request is in flight.

---

## Certificate Approach Comparison

| Approach | Setup time | Agent trust config needed | Renewal | Best for |
|----------|-----------|--------------------------|---------|----------|
| **Self-signed** | Minutes | Yes (`keytool` import) | Manual (365-day default) | Dev, staging, getting started |
| **Let's Encrypt / ACME** | Hours (first time) | No (public CA) | Automatic (`certbot`) | Internet-facing (rarely applicable for Pyroscope) |
| **Enterprise CA** | Days-weeks (request process) | No (CA already in JVM truststore) | Manual or automated | Production, enterprise |
| **Cloud provider** (ACM, GCP managed) | Minutes | No (managed) | Automatic | Cloud-native deployments |

---

## Option 1: F5 VIP (enterprise standard — recommended)

```
OCP Agents (HTTPS :443) ──→ F5 VIP (TLS termination) ──→ Pyroscope VM (HTTP :4040)
```

The simplest TLS option for enterprises. Pyroscope stays on plain HTTP. The F5 handles
all TLS and provides a DNS-friendly VIP like `pyroscope-dev.company.com`.

### What to request from the network team

| Item | Value | Notes |
|------|-------|-------|
| VIP FQDN | `pyroscope-dev.company.com` | Or follow your naming convention |
| VIP frontend port | `443` (HTTPS) | Standard HTTPS; or `4040` if preferred |
| Backend pool | `<VM_IP>:4040` (HTTP) | Single member for monolith |
| Health check | `GET /ready` (HTTP, port 4040) | Expect HTTP 200 |
| TLS certificate | Enterprise CA cert for the VIP FQDN | Issued by PKI team |
| Persistence | None required | Pyroscope is stateless for ingestion |

### Pyroscope VM changes

None. Keep the existing `docker run` with `--network host` on port 4040. No config changes.

### Agent configuration

```properties
# Before (direct HTTP to VM)
pyroscope.server.address=http://10.1.2.3:4040

# After (HTTPS via F5 VIP)
pyroscope.server.address=https://pyroscope-dev.company.com
```

Or via environment variable:

```bash
PYROSCOPE_SERVER_ADDRESS=https://pyroscope-dev.company.com
```

### Verification

```bash
# From any machine that can reach the VIP
curl -sf https://pyroscope-dev.company.com/ready && echo "OK"

# Check services are sending data
curl -s https://pyroscope-dev.company.com/pyroscope/label-values?label=service_name
```

### F5 with port 4040 (alternative)

If the network team prefers to keep port 4040:

| VIP frontend | Backend | Agent URL |
|-------------|---------|-----------|
| `4040` (HTTPS) | `4040` (HTTP) | `https://pyroscope-dev.company.com:4040` |

The agent URL must include the port since 4040 is non-standard for HTTPS.

---

## Option 2: Pyroscope Native TLS (simplest self-managed)

```
OCP Agents (HTTPS :4040) ──→ Pyroscope (TLS on :4040)
```

Pyroscope is built on Grafana Mimir, which supports TLS via the `server.http_tls_config`
configuration. No proxy container needed.

### Prerequisites

Certificate and key files available on the VM.

### 1. Stage certificate files

```bash
mkdir -p /opt/pyroscope/tls
cp /path/to/cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/key.pem  /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem
chmod 600 /opt/pyroscope/tls/key.pem
```

### 2. Update pyroscope.yaml

```yaml
# /opt/pyroscope/pyroscope.yaml
server:
  http_listen_port: 4040
  http_tls_config:
    cert_file: /etc/pyroscope/tls/cert.pem
    key_file: /etc/pyroscope/tls/key.pem

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
```

### 3. Restart with TLS directory mounted

```bash
docker rm -f pyroscope
docker run -d --name pyroscope --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v pyroscope-data:/data \
    -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \
    -v /opt/pyroscope/tls:/etc/pyroscope/tls:ro \
    grafana/pyroscope:1.18.0 \
    -config.file=/etc/pyroscope/config.yaml
```

### 4. Verify

```bash
sleep 20
curl -k https://localhost:4040/ready && echo "OK"
```

### Agent configuration

```bash
PYROSCOPE_SERVER_ADDRESS=https://<VM_IP>:4040
```

> **Note:** If using a self-signed cert, agents need trust configuration — see
> [Java Agent Trust Configuration](#java-agent-trust-configuration) below.

### Certificate renewal

```bash
# Replace cert files
cp /path/to/new-cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/new-key.pem  /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem
chmod 600 /opt/pyroscope/tls/key.pem

# Restart to pick up new certs
docker restart pyroscope
```

---

## Option 3: Nginx Reverse Proxy (lightweight)

```
OCP Agents (HTTPS :4443) ──→ Nginx (TLS termination) ──→ Pyroscope (HTTP :4040)
```

### 1. Stage certificate files

```bash
mkdir -p /opt/pyroscope/tls
cp /path/to/cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/key.pem  /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem
chmod 600 /opt/pyroscope/tls/key.pem
```

### 2. Write Nginx configuration

```bash
cat > /opt/pyroscope/tls/nginx.conf <<'EOF'
events { worker_connections 1024; }

http {
    server {
        listen 4443 ssl;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass http://127.0.0.1:4040;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 60s;
        }
    }
}
EOF
```

### 3. Deploy Nginx

```bash
docker run -d --name nginx-tls --restart unless-stopped \
    --network host \
    -v /opt/pyroscope/tls/nginx.conf:/etc/nginx/nginx.conf:ro \
    -v /opt/pyroscope/tls:/etc/nginx/tls:ro \
    nginx:1.27-alpine
```

### 4. Open firewall port

```bash
firewall-cmd --permanent --add-port=4443/tcp
firewall-cmd --reload
```

### 5. Verify

```bash
curl -k https://localhost:4443/ready && echo "OK"
```

### Certificate renewal

```bash
cp /path/to/new-cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/new-key.pem  /opt/pyroscope/tls/key.pem
docker restart nginx-tls
```

---

## Option 4: Envoy Reverse Proxy (Grafana's default)

```
OCP Agents (HTTPS :4443) ──→ Envoy (TLS termination) ──→ Pyroscope (HTTP :4040)
```

This is the approach used by Grafana Cloud and the project's deploy.sh / Ansible automation.

### 1. Stage certificate files

```bash
mkdir -p /opt/pyroscope/tls
cp /path/to/cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/key.pem  /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem
chmod 600 /opt/pyroscope/tls/key.pem
```

### 2. Write Envoy configuration

```bash
cat > /opt/pyroscope/tls/envoy.yaml <<'EOF'
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
    - name: pyroscope_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 4443
      filter_chains:
        - transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
              common_tls_context:
                tls_certificates:
                  - certificate_chain:
                      filename: /etc/envoy/tls/cert.pem
                    private_key:
                      filename: /etc/envoy/tls/key.pem
          filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: pyroscope
                route_config:
                  virtual_hosts:
                    - name: pyroscope
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route:
                            cluster: pyroscope_backend
                            timeout: 60s
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
    - name: pyroscope_backend
      connect_timeout: 5s
      type: STATIC
      load_assignment:
        cluster_name: pyroscope_backend
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 4040
EOF
```

### 3. Deploy Envoy

```bash
docker run -d --name envoy-proxy --restart unless-stopped \
    --network host \
    -v /opt/pyroscope/tls/envoy.yaml:/etc/envoy/envoy.yaml:ro \
    -v /opt/pyroscope/tls:/etc/envoy/tls:ro \
    envoyproxy/envoy:v1.31-latest
```

### 4. Open firewall port

```bash
firewall-cmd --permanent --add-port=4443/tcp
firewall-cmd --reload
```

### 5. Verify

```bash
curl -k https://localhost:4443/ready && echo "OK"
```

### Certificate renewal

```bash
cp /path/to/new-cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/new-key.pem  /opt/pyroscope/tls/key.pem
docker restart envoy-proxy
```

---

## Java Agent Trust Configuration

### Enterprise CA (F5 VIP) — no extra config

If the CA is already in the JVM's default truststore (typical for enterprise CAs),
agents just need the URL change:

```bash
PYROSCOPE_SERVER_ADDRESS=https://pyroscope-dev.company.com
```

No `keytool`, no custom truststore, no JVM flags.

### Self-signed certificate — keytool import required

**Option A: Import into the default JVM truststore**

```bash
keytool -importcert -noprompt -alias pyroscope \
    -file /path/to/cert.pem \
    -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit
```

**Option B: Use a custom truststore**

```bash
cp $JAVA_HOME/lib/security/cacerts /opt/pyroscope/custom-truststore.jks
keytool -importcert -noprompt -alias pyroscope \
    -file /path/to/cert.pem \
    -keystore /opt/pyroscope/custom-truststore.jks \
    -storepass changeit

# Set in agent startup
JAVA_TOOL_OPTIONS="-javaagent:/path/to/pyroscope.jar \
    -Djavax.net.ssl.trustStore=/opt/pyroscope/custom-truststore.jks"
```

### OCP pods — mount cert as ConfigMap or Secret

```bash
# Create the secret
oc create secret generic pyroscope-tls-cert \
    --from-file=cert.pem=/path/to/cert.pem

# Mount in pod spec and import at container startup via init script
```

See [deployment-guide.md Section 15d](deployment-guide.md#15d-https-with-self-signed-cert)
for the full init container pattern.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `PKIX path building failed` | Java agent doesn't trust the TLS cert | Import cert into JVM truststore (see above) |
| `curl: (60) SSL certificate problem: self-signed certificate` | Self-signed cert not trusted by curl | Use `curl -k` for testing, or add to system trust: `cp cert.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust` (RHEL) |
| `connection refused` on port 4443 | Proxy not running or firewall blocking | Check `docker ps \| grep envoy` or `nginx`, check `firewall-cmd --list-ports` |
| `upstream connect error or disconnect/reset before headers` | Proxy can't reach Pyroscope on 127.0.0.1:4040 | Verify Pyroscope is running: `curl http://localhost:4040/ready` |
| Certificate expired | Self-signed cert past 365-day validity | Replace cert/key files, restart proxy or Pyroscope |
| `SSL_ERROR_RX_RECORD_TOO_LONG` | Client using HTTPS against plain HTTP port | Use port 4443 (proxy) or verify native TLS is configured on 4040 |
| `No subject alternative names matching` / hostname mismatch | Cert CN/SAN doesn't match the hostname agents use | Regenerate cert with correct SAN entries (DNS + IP) |
| `SELinux: permission denied` on cert files | SELinux blocking container volume mounts | Run `restorecon -Rv /opt/pyroscope/tls` or add `:z` suffix to volume mounts |

---

## Cross-references

- [deployment-guide.md Section 7c-7d](deployment-guide.md#7c-https-with-self-signed-cert) — Manual TLS setup with Envoy
- [deployment-guide.md Section 15c-15d](deployment-guide.md#15c-https-with-ca-cert) — Agent HTTPS configuration
- [deployment-guide.md Section 16](deployment-guide.md#16-tls-architecture) — TLS architecture diagrams
- [deployment-guide.md Section 17b](deployment-guide.md#17b-monolith-https) — Firewall rules for HTTPS
- [security-model.md](security-model.md) — Encryption in transit overview
- [configuration-reference.md](configuration-reference.md) — Agent TLS-related properties
- `deploy.sh --tls` / `--tls-cert` / `--tls-key` — Full TLS automation via script
