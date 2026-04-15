"""Postgres-backed feature store. Single DSN, one connection-per-call for
simplicity; callers should batch writes inside a context manager.

Tables (see config/postgres/init.sql): function_features, integration_series,
fingerprints, incidents, anomalies, regressions.
"""
from __future__ import annotations
import os
import uuid
import datetime as dt
from contextlib import contextmanager
import psycopg
from pgvector.psycopg import register_vector
import numpy as np


def dsn() -> str:
    return os.getenv("POSTGRES_DSN", "postgresql://postgres:postgres@postgres:5432/ai")


@contextmanager
def connect():
    with psycopg.connect(dsn(), autocommit=False) as conn:
        register_vector(conn)
        yield conn


def insert_functions(conn, rows: list[dict], ts: dt.datetime) -> int:
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO function_features VALUES (%s, %s, %s, %s, %s, %s)",
            [(ts, r["service"], r["profile_type"], r["function"],
              float(r["self_value"]), float(r["total_value"])) for r in rows],
        )
    return len(rows)


def insert_series(conn, rows: list[dict]) -> int:
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO integration_series VALUES (%s, %s, %s, %s, %s)",
            [(dt.datetime.fromtimestamp(r["timestamp_ms"] / 1000.0, tz=dt.timezone.utc),
              r.get("service_name") or r.get("service", ""),
              r.get("integration", ""), r.get("profile_type", ""),
              float(r["value"])) for r in rows],
        )
    return len(rows)


def insert_fingerprint(conn, ts: dt.datetime, service: str,
                       profile_type: str, vec: np.ndarray) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO fingerprints VALUES (%s, %s, %s, %s)",
            (ts, service, profile_type, vec.astype(np.float32)),
        )


def record_incident(conn, kind: str, service: str,
                    start: dt.datetime, end: dt.datetime | None,
                    notes: str = "", fingerprint: np.ndarray | None = None) -> str:
    iid = str(uuid.uuid4())
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO incidents (id, kind, service, start_ts, end_ts, notes, fingerprint) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (iid, kind, service, start, end, notes,
             fingerprint.astype(np.float32) if fingerprint is not None else None),
        )
    return iid


def insert_anomaly(conn, ts: dt.datetime, service: str, metric: str,
                   score: float, w_start: dt.datetime, w_end: dt.datetime) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO anomalies VALUES (%s, %s, %s, %s, %s, %s)",
            (ts, service, metric, score, w_start, w_end),
        )


def insert_regression(conn, when: dt.datetime, service: str, function: str,
                      profile_type: str, before: float, after: float,
                      shift: float, summary: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO regressions VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
            (when, service, function, profile_type, before, after, shift, summary),
        )


def prune(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT prune_old_data()")
