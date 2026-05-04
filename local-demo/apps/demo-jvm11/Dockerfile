FROM eclipse-temurin:11-jdk AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends unzip curl && rm -rf /var/lib/apt/lists/* \
 && curl -fSL "https://services.gradle.org/distributions/gradle-7.6.4-bin.zip" -o /tmp/g.zip \
 && unzip -q /tmp/g.zip -d /opt && rm /tmp/g.zip
ENV PATH="/opt/gradle-7.6.4/bin:${PATH}"
COPY build.gradle settings.gradle ./
RUN gradle --no-daemon dependencies || true
COPY src/ src/
# Run tests + JaCoCo coverage report, then build the fat jar.
RUN gradle --no-daemon test jacocoTestReport shadowJar

FROM eclipse-temurin:11-jre
RUN mkdir -p /opt/pyroscope && \
    apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* && \
    curl -fSL "https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar" -o /opt/pyroscope/pyroscope.jar
COPY --from=builder /app/build/libs/demo-fat.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
