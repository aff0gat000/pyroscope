FROM eclipse-temurin:11-jre-alpine

COPY build/libs/pyroscope-sor-java11-1.0.0-fat.jar /app/pyroscope-sor-java11.jar

ENV DB_HOST=localhost
ENV DB_PORT=5432
ENV DB_NAME=pyroscope
ENV DB_USER=pyroscope
ENV DB_PASSWORD=pyroscope
ENV DB_POOL_SIZE=5
ENV FUNCTION=ReadPyroscopeBaseline.sor.v1
ENV PORT=8081

EXPOSE 8081

ENTRYPOINT ["java", "-jar", "/app/pyroscope-sor-java11.jar"]
