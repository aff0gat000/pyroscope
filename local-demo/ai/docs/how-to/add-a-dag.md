# How-to — add a new DAG

Airflow container mounts `dags/` and `lib/` read-only. File drops are
picked up automatically (30 s scan).

## 1. Write the DAG

`dags/my_new_flow.py`:

```python
import datetime as dt
from airflow import DAG
from airflow.operators.python import PythonOperator

def run(**_):
    from feature_store import connect
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM function_features")
        print("rows:", cur.fetchone()[0])

with DAG(
    dag_id="my_new_flow",
    schedule="*/15 * * * *",
    start_date=dt.datetime(2024, 1, 1),
    catchup=False,
    tags=["custom"],
) as dag:
    PythonOperator(task_id="run", python_callable=run)
```

## 2. Verify

Airflow UI (`:AIRFLOW_PORT`) → DAGs list. New entry within 30 s.

```bash
docker compose exec -T airflow airflow dags trigger my_new_flow
docker compose logs airflow | grep my_new_flow
```

## 3. Use shared lib

Every function in `lib/` is importable — `PYTHONPATH=/opt/airflow/lib` is
set in the Airflow container.

```python
from pyroscope_client import PyroscopeClient, TimeRange
from feature_extraction import functions_from_flamegraph
from feature_store import connect, insert_anomaly
from llm_gateway import from_env
from anomaly import zscore_anomalies
from embeddings import nearest_incidents
```

## 4. Gotchas

- Don't open a DB connection at module import — the scheduler scans
  frequently; open inside `run()`.
- `from_env()` (LLM gateway) calls Ollama on import-free; add a timeout
  if you call it inside a task to avoid DAG parse failure when the
  provider is flaky.
- Big DataFrames / numpy allocations belong in a `PythonVirtualenvOperator`
  or `@task.docker` if they threaten the Airflow process memory.
