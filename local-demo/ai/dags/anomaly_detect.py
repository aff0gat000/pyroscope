"""Rolling z-score anomaly detection on per-(service, integration) CPU series.
Writes high-|z| points into `anomalies` table."""
from __future__ import annotations
import datetime as dt
import logging
import numpy as np

from airflow import DAG
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)


def run(**_):
    from feature_store import connect, insert_anomaly
    from anomaly import zscore_anomalies

    now = dt.datetime.now(tz=dt.timezone.utc)
    since = now - dt.timedelta(hours=1)
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT service, integration, ts, value FROM integration_series "
                "WHERE ts >= %s ORDER BY service, integration, ts",
                (since,),
            )
            rows = cur.fetchall()

        buckets: dict[tuple[str, str], list[tuple[dt.datetime, float]]] = {}
        for svc, integ, ts, val in rows:
            buckets.setdefault((svc, integ), []).append((ts, float(val)))

        for (svc, integ), pts in buckets.items():
            if len(pts) < 30:
                continue
            vals = np.array([v for _, v in pts])
            hits = zscore_anomalies(vals, window=20, threshold=3.0)
            for i, z in hits:
                insert_anomaly(conn, pts[i][0], svc, f"cpu.{integ}", z,
                               pts[max(0, i - 20)][0], pts[i][0])
            if hits:
                log.info("%s/%s: %d anomalies", svc, integ, len(hits))
        conn.commit()


with DAG(
    dag_id="anomaly_detect",
    description="Per-integration z-score anomalies (every 5 min)",
    schedule="*/5 * * * *",
    start_date=dt.datetime(2024, 1, 1),
    catchup=False,
    tags=["anomaly"],
) as dag:
    PythonOperator(task_id="detect", python_callable=run)
