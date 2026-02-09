FROM eclipse-temurin:21-jre-alpine

RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

COPY build/libs/pyroscope-bor-1.0.0-fat.jar /app/pyroscope-bor.jar
RUN chown -R app:app /app

USER app

ENV PYROSCOPE_URL=http://pyroscope:4040
ENV FUNCTION=ReadPyroscopeTriageAssessment.v1
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["java", "-jar", "/app/pyroscope-bor.jar"]
