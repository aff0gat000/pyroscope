from fastapi import APIRouter, HTTPException
from feature_store import connect

router = APIRouter()


@router.get("")
def list_incidents(limit: int = 50):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, kind, service, start_ts, end_ts, notes "
            "FROM incidents ORDER BY start_ts DESC LIMIT %s", (limit,))
        cols = [d[0] for d in cur.description]
        return {"rows": [dict(zip(cols, r)) for r in cur.fetchall()]}


@router.get("/{incident_id}")
def detail(incident_id: str):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, kind, service, start_ts, end_ts, notes, postmortem_md "
            "FROM incidents WHERE id = %s", (incident_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "incident not found")
        cols = [d[0] for d in cur.description]
        inc = dict(zip(cols, row))
        # Related anomalies in the incident window
        cur.execute(
            "SELECT ts, service, metric, score FROM anomalies "
            "WHERE ts BETWEEN %s AND COALESCE(%s, NOW()) "
            "ORDER BY ts LIMIT 200",
            (inc["start_ts"], inc["end_ts"]))
        cols = [d[0] for d in cur.description]
        inc["anomalies"] = [dict(zip(cols, r)) for r in cur.fetchall()]
        return inc
