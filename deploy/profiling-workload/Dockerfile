# ---------------------------------------------------------------------------
# Pyroscope Profiling Workload
# ---------------------------------------------------------------------------
# Standalone Vert.x app that generates CPU, allocation, and lock contention
# workloads on a loop. No external invocation needed — profiles appear in
# Pyroscope automatically within 30 seconds of starting the container.
#
# Build:
#   docker build -t profiling-workload:1.0.0 .
#
# Run (point at existing Pyroscope on same VM):
#   docker run -d --name profiling-workload \
#     -e PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040 \
#     profiling-workload:1.0.0
# ---------------------------------------------------------------------------

FROM eclipse-temurin:11-jdk AS builder

WORKDIR /app

COPY build.gradle settings.gradle ./

# Download Gradle and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/* && \
    curl -fSL "https://services.gradle.org/distributions/gradle-7.6.4-bin.zip" -o /tmp/gradle.zip && \
    unzip -q /tmp/gradle.zip -d /opt && \
    rm /tmp/gradle.zip

ENV PATH="/opt/gradle-7.6.4/bin:${PATH}"

RUN gradle --no-daemon dependencies || true

COPY src/ src/
RUN gradle --no-daemon shadowJar

# ---------------------------------------------------------------------------
FROM eclipse-temurin:11-jre

WORKDIR /app

# Download Pyroscope Java agent
RUN mkdir -p /opt/pyroscope && \
    curl -fSL "https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar" \
         -o /opt/pyroscope/pyroscope.jar

COPY --from=builder /app/build/libs/profiling-workload-1.0.0-fat.jar /app/app.jar

# Agent configuration via environment variables (overridable at docker run)
ENV PYROSCOPE_APPLICATION_NAME=profiling-workload
ENV PYROSCOPE_SERVER_ADDRESS=http://host.docker.internal:4040
ENV PYROSCOPE_FORMAT=jfr
ENV PYROSCOPE_PROFILER_EVENT=itimer
ENV PYROSCOPE_PROFILER_ALLOC=512k
ENV PYROSCOPE_PROFILER_LOCK=10ms
ENV PYROSCOPE_LABELS="env=profiling-workload"
ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/pyroscope/pyroscope.jar"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
