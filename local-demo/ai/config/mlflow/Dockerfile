FROM python:3.11-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    mlflow==2.17.0 \
    psycopg2-binary==2.9.9 \
    boto3==1.35.47
EXPOSE 5000
CMD ["mlflow", "server", \
     "--host=0.0.0.0", "--port=5000", \
     "--backend-store-uri=postgresql+psycopg2://postgres:postgres@postgres:5432/mlflow", \
     "--default-artifact-root=s3://mlflow/"]
