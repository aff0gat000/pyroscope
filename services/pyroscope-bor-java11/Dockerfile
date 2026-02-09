FROM eclipse-temurin:11-jre-alpine

COPY build/libs/pyroscope-bor-java11-1.0.0-fat.jar /app/pyroscope-bor-java11.jar

ENV PYROSCOPE_URL=http://pyroscope:4040
ENV FUNCTION=ReadPyroscopeTriageAssessment.v1
ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/pyroscope-bor-java11.jar"]
