FROM eclipse-temurin:11-jdk AS builder

WORKDIR /app

# Copy Gradle wrapper and build config first for dependency caching
COPY gradlew ./
COPY gradle/ gradle/
RUN chmod +x gradlew

COPY build.gradle settings.gradle ./

# Download dependencies in a separate layer (cached unless build.gradle changes)
RUN ./gradlew --no-daemon dependencies

# Copy source and build
COPY src/ src/
RUN ./gradlew --no-daemon shadowJar

# ---------------------------------------------------------------------------
FROM eclipse-temurin:11-jre

WORKDIR /app

# Download the Pyroscope Java agent – profiling dependency (zero code changes).
# Shared config is mounted at runtime from config/pyroscope/pyroscope.properties;
# per-service overrides (application name, labels) use env vars in docker-compose.yaml.
RUN mkdir -p /opt/pyroscope && \
    curl -fSL "https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar" \
         -o /opt/pyroscope/pyroscope.jar

# Download the Prometheus JMX Exporter agent – exposes JVM metrics (heap, GC,
# threads, CPU) as Prometheus metrics on port 9404. Zero code changes required.
RUN mkdir -p /opt/jmx-exporter && \
    curl -fSL "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar" \
         -o /opt/jmx-exporter/jmx_prometheus_javaagent.jar
COPY jmx-exporter-config.yaml /opt/jmx-exporter/config.yaml

COPY --from=builder /app/build/libs/vertx-app-1.0.0-fat.jar /app/app.jar

EXPOSE 8080

# JAVA_TOOL_OPTIONS is set in docker-compose.yaml so the agent is attached
# without touching this entrypoint or application code.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
