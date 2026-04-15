"""SSE streaming chat endpoint. The prompt is enriched with a compact
snapshot of the most recent hotspots + active anomalies so the LLM has
real context about the user's system state."""
from __future__ import annotations
import json
from fastapi import APIRouter
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from feature_store import connect
from llm_gateway import from_env

router = APIRouter()

SYSTEM = (
    "You are a profiling co-pilot for a Vert.x system profiled by Pyroscope. "
    "Be direct and concise. When asked 'why', reason from the context table "
    "below. Cite function names and services. Avoid speculating beyond data."
)


class ChatRequest(BaseModel):
    question: str
    service: str | None = None


def _context_snapshot(service: str | None) -> str:
    with connect() as conn, conn.cursor() as cur:
        args: list = []
        svc_where = ""
        if service:
            svc_where = " AND service = %s"
            args.append(service)
        cur.execute(
            "SELECT service, function, SUM(total_value) AS total "
            "FROM function_features "
            "WHERE profile_type = 'process_cpu:cpu:nanoseconds:cpu:nanoseconds' "
            "  AND ts >= NOW() - INTERVAL '1 hour'" + svc_where + " "
            "GROUP BY 1,2 ORDER BY total DESC LIMIT 10",
            args,
        )
        hot = cur.fetchall()
        cur.execute(
            "SELECT service, metric, score FROM anomalies "
            "WHERE ts >= NOW() - INTERVAL '1 hour' "
            "ORDER BY ABS(score) DESC LIMIT 10"
        )
        ans = cur.fetchall()
    lines = ["RECENT CPU HOTSPOTS (service, function, total):"]
    for s, f, t in hot:
        lines.append(f"- {s} | {f[:100]} | {t:.0f}")
    lines.append("\nACTIVE ANOMALIES (service, metric, z-score):")
    for s, m, z in ans:
        lines.append(f"- {s} | {m} | {z:+.2f}")
    return "\n".join(lines)


@router.post("")
async def chat(req: ChatRequest):
    ctx = _context_snapshot(req.service)
    prompt = f"{ctx}\n\nQuestion: {req.question}"
    llm = from_env()

    async def events():
        # Non-streaming providers just yield the whole response.
        try:
            text = llm.complete(prompt, system=SYSTEM, max_tokens=600)
        except Exception as e:
            yield {"event": "error", "data": json.dumps({"error": str(e)})}
            return
        # Chunk by line so the UI can render progressively.
        for line in text.splitlines(keepends=True):
            yield {"event": "token", "data": line}
        yield {"event": "done", "data": ""}

    return EventSourceResponse(events())
