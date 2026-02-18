ARG BASE_IMAGE=grafana/pyroscope:latest
FROM ${BASE_IMAGE}

LABEL maintainer="platform-team" \
      description="Pyroscope server in monolithic mode with baked-in config" \
      org.opencontainers.image.source="https://github.com/grafana/pyroscope"

COPY pyroscope.yaml /etc/pyroscope/config.yaml

# The official grafana/pyroscope image already runs as non-root user
# "pyroscope" (UID 10001, GID 10001) on a distroless base.
# No USER directive needed — it is inherited from the base image.

EXPOSE 4040

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD ["pyroscope", "admin", "ready"] || exit 1

ENTRYPOINT ["pyroscope"]
CMD ["-config.file=/etc/pyroscope/config.yaml"]
