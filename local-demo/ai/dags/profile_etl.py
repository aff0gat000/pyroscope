"""Pull recent profiles from Pyroscope, normalise into features, persist to Postgres.
Runs every 5 minutes. Also writes a fingerprint per (service, profile_type)
so similarity search has something to retrieve."""
from __future__ import annotations
import datetime as dt
import logging

from airflow import DAG
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)


def run(**_):
    from pyroscope_client import PyroscopeClient, TimeRange
    from feature_extraction import functions_from_flamegraph, series_points, fingerprint
    from feature_store import connect, insert_functions, insert_series, insert_fingerprint

    pyr = PyroscopeClient()
    services = pyr.label_values("service_name")
    if not services:
        log.warning("no service_name labels in Pyroscope yet; skipping")
        return

    tr = TimeRange.last(300)
    now = dt.datetime.now(tz=dt.timezone.utc)
    profile_types = [
        "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
        "memory:alloc_in_new_tlab_bytes:bytes:space:bytes",
        "mutex:delay:nanoseconds:mutex:count",
        "block:delay:nanoseconds:block:count",
    ]

    with connect() as conn:
        for svc in services:
            for pt in profile_types:
                try:
                    tree = pyr.select_merge_stacktraces(pt, f'{{service_name="{svc}"}}', tr)
                except Exception as e:
                    log.warning("flamegraph %s/%s failed: %s", svc, pt, e)
                    continue
                rows = functions_from_flamegraph(tree, svc, pt)
                insert_functions(conn, [r.__dict__ for r in rows], now)

                try:
                    insert_fingerprint(conn, now, svc, pt, fingerprint(tree))
                except Exception as e:
                    log.warning("fingerprint %s/%s failed: %s", svc, pt, e)

            # integration time-series (CPU only, grouped by integration label)
            try:
                series = pyr.select_series(
                    "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
                    f'{{service_name="{svc}"}}',
                    tr, step_seconds=15, group_by=["integration"],
                )
                rows = series_points(series)
                for r in rows:
                    r["service"] = svc
                    r["profile_type"] = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
                insert_series(conn, rows)
            except Exception as e:
                log.warning("series %s failed: %s", svc, e)

        conn.commit()
    log.info("profile_etl complete")


with DAG(
    dag_id="profile_etl",
    description="Pyroscope -> features -> Postgres (every 5 min)",
    schedule="*/5 * * * *",
    start_date=dt.datetime(2024, 1, 1),
    catchup=False,
    tags=["pyroscope", "etl"],
) as dag:
    PythonOperator(task_id="etl", python_callable=run)
