# Explanation — why Airflow (and when to pick something else)

The demo ships with Airflow. Here's the honest reasoning.

## Trade-off at a glance

| dimension                | Airflow               | Prefect 3            | Dagster               |
|--------------------------|-----------------------|----------------------|-----------------------|
| local footprint          | webserver + scheduler | single process       | webserver + daemon    |
| Python ergonomics        | DAG/Operator classes  | `@flow` / `@task`    | assets-first          |
| UI                       | functional, dated     | modern               | best-in-class         |
| enterprise familiarity   | **dominant**          | growing              | niche                 |
| lineage model            | task DAG              | results + artifacts  | assets                |
| fit for 4 small DAGs     | heavy                 | ideal                | overkill              |

## Why Airflow was chosen here

- **Audience overlap.** Enterprise platform teams — the target for the
  end-to-end demo — already run Airflow. Transferable skills matter more
  than per-DAG elegance.
- **One standard backend.** Airflow, MLflow, and the feature store share
  one Postgres. No new DB concepts.
- **Batch cadence is the right cadence.** Profile ETL, anomaly detection,
  daily reports — these are exactly what Airflow is best at.
- **Operators & sensors** are available if we need richer triggering
  later (e.g., `ExternalTaskSensor` between DAGs, `S3KeySensor` for
  report arrivals).

## When you should swap

Switch to **Prefect 3** if:
- You own the demo and want shorter boilerplate (~30-line DAGs vs 80).
- You don't have an Airflow install in your day-job — no transfer bonus.
- You value modern UI over enterprise familiarity.

Switch to **Dagster** if:
- Your story is "profiles are *assets* that ML models depend on" — the
  asset-graph UI sells that vision better than either alternative.
- You have a data team that already speaks assets.
- You're OK with the steepest learning curve of the three.

## What doesn't change when you swap

- `lib/` — all business logic is orchestrator-agnostic.
- Postgres schema.
- FastAPI BFF.
- React UI.
- Grafana dashboards (they read Postgres, not the orchestrator).

Swap cost is roughly: rewrite the four DAG files (4 × ~40 lines each)
and the Airflow container.
