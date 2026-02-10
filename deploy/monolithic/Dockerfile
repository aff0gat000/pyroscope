ARG BASE_IMAGE=grafana/pyroscope:latest
FROM ${BASE_IMAGE}

COPY pyroscope.yaml /etc/pyroscope/config.yaml

EXPOSE 4040

ENTRYPOINT ["pyroscope"]
CMD ["-config.file=/etc/pyroscope/config.yaml"]
