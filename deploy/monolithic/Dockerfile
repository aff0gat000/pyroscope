FROM grafana/pyroscope:latest

COPY pyroscope.yaml /etc/pyroscope/config.yaml

EXPOSE 4040

ENTRYPOINT ["pyroscope"]
CMD ["-config.file=/etc/pyroscope/config.yaml"]
