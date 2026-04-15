from fastapi import APIRouter, Query
from pyroscope_client import PyroscopeClient, TimeRange
from feature_extraction import functions_from_flamegraph

router = APIRouter()


def _client():
    return PyroscopeClient()


@router.get("/flamegraph")
def flamegraph(
    service: str,
    profile_type: str = "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
    seconds: int = Query(300, ge=60, le=86400),
    thread: str | None = None,
    integration: str | None = None,
):
    c = _client()
    tr = TimeRange.last(seconds)
    sel = [f'service_name="{service}"']
    if thread:
        sel.append(f'thread_name=~"{thread}"')
    if integration:
        sel.append(f'integration="{integration}"')
    label_selector = "{" + ", ".join(sel) + "}"
    tree = c.select_merge_stacktraces(profile_type, label_selector, tr)
    return tree


@router.get("/diff")
def diff(
    service: str,
    profile_type: str = "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
    before_seconds: int = 600,
    after_seconds: int = 300,
):
    """Two flame graphs + a per-function delta table for the SPA to render
    as side-by-side + a ranked diff list."""
    import time
    c = _client()
    now_ms = int(time.time() * 1000)
    after_tr = TimeRange(now_ms - after_seconds * 1000, now_ms)
    before_tr = TimeRange(now_ms - (after_seconds + before_seconds) * 1000,
                          now_ms - after_seconds * 1000)
    sel = f'{{service_name="{service}"}}'
    t_before = c.select_merge_stacktraces(profile_type, sel, before_tr)
    t_after = c.select_merge_stacktraces(profile_type, sel, after_tr)
    fn_before = {r.function: r for r in functions_from_flamegraph(t_before, service, profile_type)}
    fn_after = {r.function: r for r in functions_from_flamegraph(t_after, service, profile_type)}
    rows = []
    for fn in set(fn_before) | set(fn_after):
        b = fn_before.get(fn); a = fn_after.get(fn)
        b_v = b.total_value if b else 0.0
        a_v = a.total_value if a else 0.0
        if b_v == 0 and a_v == 0:
            continue
        rel = (a_v - b_v) / b_v if b_v else float("inf") if a_v else 0.0
        rows.append({"function": fn, "before": b_v, "after": a_v, "rel": rel})
    rows.sort(key=lambda r: -abs(r["rel"]) if r["rel"] != float("inf") else -1e18)
    return {"before": t_before, "after": t_after, "delta": rows[:50]}


@router.get("/services")
def services():
    c = _client()
    return {"services": c.label_values("service_name")}


@router.get("/profile-types")
def profile_types():
    return {"profileTypes": _client().profile_types()}
