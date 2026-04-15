from fastapi import APIRouter
from feature_store import connect

router = APIRouter()


@router.get("")
def list_regressions(limit: int = 50, service: str | None = None):
    sql = (
        "SELECT detected_at, service, function, profile_type, "
        "       before_value, after_value, shift, llm_summary "
        "FROM regressions "
    )
    params: list = []
    if service:
        sql += "WHERE service = %s "
        params.append(service)
    sql += "ORDER BY detected_at DESC LIMIT %s"
    params.append(limit)
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d[0] for d in cur.description]
        return {"rows": [dict(zip(cols, r)) for r in cur.fetchall()]}
