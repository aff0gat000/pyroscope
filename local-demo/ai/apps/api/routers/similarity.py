from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from feature_store import connect
from embeddings import nearest_incidents

router = APIRouter()


class SimilarityRequest(BaseModel):
    incident_id: str | None = None
    k: int = 5


@router.post("")
def similar(req: SimilarityRequest):
    if not req.incident_id:
        raise HTTPException(400, "incident_id required")
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT fingerprint FROM incidents WHERE id = %s", (req.incident_id,))
        row = cur.fetchone()
        if not row or row[0] is None:
            raise HTTPException(404, "no fingerprint for incident")
        query = row[0]
        results = nearest_incidents(conn, query, k=req.k + 1)
        return {"results": [r for r in results if r["id"] != req.incident_id][:req.k]}
