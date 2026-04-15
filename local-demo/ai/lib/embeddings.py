"""pgvector-backed similarity search over incident fingerprints."""
from __future__ import annotations
import numpy as np


def nearest_incidents(conn, query_vec: np.ndarray, k: int = 5,
                      exclude_kind: str | None = None) -> list[dict]:
    """Cosine-similarity nearest-neighbour search."""
    sql = (
        "SELECT id, kind, service, start_ts, end_ts, notes, "
        "       1 - (fingerprint <=> %s) AS similarity "
        "FROM incidents WHERE fingerprint IS NOT NULL "
    )
    params: list = [query_vec.astype(np.float32)]
    if exclude_kind:
        sql += "AND kind <> %s "
        params.append(exclude_kind)
    sql += "ORDER BY fingerprint <=> %s LIMIT %s"
    params.extend([query_vec.astype(np.float32), k])
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]
