ARG BASE_IMAGE=grafana/grafana:11.5.2
FROM ${BASE_IMAGE}

LABEL maintainer="platform-team" \
      description="Grafana with baked-in Pyroscope datasource, dashboards, and provisioning" \
      org.opencontainers.image.source="https://github.com/grafana/grafana"

COPY grafana.ini /etc/grafana/grafana.ini
COPY provisioning/ /etc/grafana/provisioning/
COPY dashboards/ /var/lib/grafana/dashboards/

ENV GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource

# The official grafana/grafana image already runs as non-root user
# "grafana" (UID 472, GID 0) on an Alpine base.
# No USER directive needed — it is inherited from the base image.

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD wget --spider -q http://localhost:3000/api/health || exit 1
