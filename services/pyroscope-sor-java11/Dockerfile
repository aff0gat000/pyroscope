FROM eclipse-temurin:11-jre-alpine

RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

COPY build/libs/pyroscope-sor-java11-1.0.0-fat.jar /app/pyroscope-sor-java11.jar
RUN chown -R app:app /app

USER app

ENV DB_HOST=localhost
ENV DB_PORT=5432
ENV DB_NAME=pyroscope
ENV DB_USER=pyroscope
ENV DB_PASSWORD=pyroscope
ENV DB_POOL_SIZE=5
ENV FUNCTION=ReadPyroscopeBaseline.sor.v1
ENV PORT=8081

EXPOSE 8081

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8081/health || exit 1

ENTRYPOINT ["java", "-jar", "/app/pyroscope-sor-java11.jar"]
