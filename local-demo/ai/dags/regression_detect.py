"""Compare window-before vs window-after per function; flag shifts > threshold.
Generates an LLM summary for each batch of regressions. Runs hourly (or
manually after a simulator-injected incident)."""
from __future__ import annotations
import datetime as dt
import logging

from airflow import DAG
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)

SYSTEM = (
    "You are a senior performance engineer. Given a set of function-level "
    "profiling regressions, write a 3-bullet summary in plain English "
    "ranked by likely impact. Be terse. Do not speculate beyond the data."
)


def run(**_):
    from feature_store import connect, insert_regression
    from llm_gateway import from_env

    now = dt.datetime.now(tz=dt.timezone.utc)
    cut = now - dt.timedelta(minutes=30)
    past = now - dt.timedelta(minutes=60)

    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                WITH before AS (
                  SELECT service, profile_type, function, AVG(total_value) AS v
                  FROM function_features
                  WHERE ts BETWEEN %s AND %s GROUP BY 1,2,3
                ), after AS (
                  SELECT service, profile_type, function, AVG(total_value) AS v
                  FROM function_features
                  WHERE ts BETWEEN %s AND %s GROUP BY 1,2,3
                )
                SELECT b.service, b.profile_type, b.function, b.v, a.v,
                       (a.v - b.v) / NULLIF(b.v, 0) AS rel
                FROM before b JOIN after a USING (service, profile_type, function)
                WHERE b.v > 0 AND ABS((a.v - b.v) / NULLIF(b.v, 0)) > 0.5
                ORDER BY ABS((a.v - b.v) / NULLIF(b.v, 0)) DESC
                LIMIT 20
                """,
                (past, cut, cut, now),
            )
            regs = cur.fetchall()

        if not regs:
            log.info("no regressions above threshold")
            return

        prompt = "Regressions (function, profile_type, before, after, rel):\n" + \
                 "\n".join(f"- {svc}/{pt}/{fn}: {before:.1f} -> {after:.1f} ({rel:+.1%})"
                           for svc, pt, fn, before, after, rel in regs[:10])
        try:
            summary = from_env().complete(prompt, system=SYSTEM, max_tokens=400)
        except Exception as e:
            log.warning("LLM summary failed: %s", e)
            summary = f"(LLM unavailable: {e})"

        for svc, pt, fn, before, after, rel in regs:
            insert_regression(conn, now, svc, fn, pt, before, after, rel, summary)
        conn.commit()
        log.info("recorded %d regressions", len(regs))


with DAG(
    dag_id="regression_detect",
    description="Diff profile windows, flag regressions, summarise with LLM",
    schedule="@hourly",
    start_date=dt.datetime(2024, 1, 1),
    catchup=False,
    tags=["regression", "llm"],
) as dag:
    PythonOperator(task_id="detect", python_callable=run)
