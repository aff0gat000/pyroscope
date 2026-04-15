"""Daily top-N hotspots + retention prune. Artifact: a markdown report
uploaded to MinIO + logged to MLflow as an artifact."""
from __future__ import annotations
import datetime as dt
import io
import logging

from airflow import DAG
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)


def run(**_):
    import boto3
    import mlflow
    import os
    from feature_store import connect, prune

    now = dt.datetime.now(tz=dt.timezone.utc)
    since = now - dt.timedelta(days=1)
    lines = [f"# Daily hotspot report — {now:%Y-%m-%d}"]
    with connect() as conn:
        with conn.cursor() as cur:
            for pt_label, pt in [
                ("CPU",         "process_cpu:cpu:nanoseconds:cpu:nanoseconds"),
                ("Allocations", "memory:alloc_in_new_tlab_bytes:bytes:space:bytes"),
                ("Lock",        "mutex:delay:nanoseconds:mutex:count"),
            ]:
                cur.execute(
                    "SELECT service, function, SUM(total_value) AS v "
                    "FROM function_features "
                    "WHERE profile_type = %s AND ts >= %s "
                    "GROUP BY 1,2 ORDER BY v DESC LIMIT 10",
                    (pt, since),
                )
                lines.append(f"\n## {pt_label} top-10")
                lines.append("| service | function | value |")
                lines.append("|---|---|---|")
                for svc, fn, v in cur.fetchall():
                    lines.append(f"| {svc} | `{fn[:80]}` | {v:,.0f} |")
        prune(conn)
        conn.commit()

    body = "\n".join(lines).encode()
    # MinIO (s3 compatible)
    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["MINIO_ENDPOINT"],
        aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
        aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
    )
    key = f"hotspot-reports/{now:%Y-%m-%d}.md"
    s3.put_object(Bucket="artifacts", Key=key, Body=body)
    log.info("uploaded s3://artifacts/%s (%d bytes)", key, len(body))

    # MLflow
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    mlflow.set_experiment("daily-hotspots")
    with mlflow.start_run(run_name=f"{now:%Y-%m-%d}"):
        mlflow.log_text("\n".join(lines), "report.md")


with DAG(
    dag_id="daily_hotspot_report",
    description="Daily top-10 hotspots + retention prune",
    schedule="0 2 * * *",
    start_date=dt.datetime(2024, 1, 1),
    catchup=False,
    tags=["report"],
) as dag:
    PythonOperator(task_id="report", python_callable=run)
