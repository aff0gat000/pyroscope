from fastapi import APIRouter, Query
from feature_store import connect

router = APIRouter()

PT_MAP = {
    "cpu": "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
    "alloc": "memory:alloc_in_new_tlab_bytes:bytes:space:bytes",
    "lock": "mutex:delay:nanoseconds:mutex:count",
    "block": "block:delay:nanoseconds:block:count",
}


@router.get("/leaderboard")
def leaderboard(
    metric: str = Query("cpu", enum=list(PT_MAP)),
    hours: int = Query(1, ge=1, le=168),
    service: str | None = None,
    limit: int = Query(20, ge=1, le=200),
):
    pt = PT_MAP[metric]
    sql = (
        "SELECT service, function, SUM(total_value) AS total "
        "FROM function_features "
        "WHERE profile_type = %s AND ts >= NOW() - make_interval(hours => %s) "
    )
    params: list = [pt, hours]
    if service:
        sql += "AND service = %s "
        params.append(service)
    sql += "GROUP BY service, function ORDER BY total DESC LIMIT %s"
    params.append(limit)
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [d[0] for d in cur.description]
            return {"rows": [dict(zip(cols, r)) for r in cur.fetchall()],
                    "metric": metric, "profile_type": pt}
