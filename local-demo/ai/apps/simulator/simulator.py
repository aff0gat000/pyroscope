"""Traffic and incident simulator. Two modes:

  python simulator.py loop                   # steady background traffic + random incidents
  python simulator.py incident --kind blocker  # one-shot, records to incidents table

Incident kinds exercise specific Vert.x pathologies on phase-1 apps:
  blocker     — hammer /blocking/on-eventloop to pin event-loop threads
  leak        — /leak/start repeatedly; threads climb
  gc          — large allocation-heavy responses via /postgres/query + /mongo/*
  contention  — oversubscribe Postgres pool past MaxSize=4
"""
from __future__ import annotations
import argparse
import datetime as dt
import os
import random
import sys
import time
import httpx

J11 = os.environ.get("JVM11_URL", "http://host.docker.internal:18080")
J21 = os.environ.get("JVM21_URL", "http://host.docker.internal:18081")


def hit(url: str, timeout: float = 4.0) -> bool:
    try:
        r = httpx.get(url, timeout=timeout)
        return r.status_code < 500
    except Exception:
        return False


def baseline():
    for base in (J11, J21):
        hit(f"{base}/health")
        hit(f"{base}/redis/get?k=demo")
        hit(f"{base}/postgres/query")
        hit(f"{base}/f2f/call?p=sim-{random.randint(0,9999)}")


# ---- incident patterns ----

def incident_blocker(duration_s: int = 120):
    # The endpoint blocks the event loop for 400ms on purpose, so back-to-back
    # requests queue behind each other. Use hit() (catches timeouts) and a
    # generous timeout so queued requests still complete instead of aborting.
    end = time.time() + duration_s
    while time.time() < end:
        hit(f"{J11}/blocking/on-eventloop?ms=400", timeout=30.0)


def incident_leak():
    for _ in range(8):
        hit(f"{J11}/leak/start?n=25", timeout=2.0)


def incident_gc(duration_s: int = 90):
    end = time.time() + duration_s
    while time.time() < end:
        for _ in range(20):
            hit(f"{J11}/mongo/insert?msg={'x' * 1024}")
            hit(f"{J11}/postgres/query")


def incident_contention(duration_s: int = 90):
    import threading
    end = time.time() + duration_s
    def worker():
        while time.time() < end:
            hit(f"{J11}/postgres/query", timeout=8.0)
    threads = [threading.Thread(target=worker) for _ in range(30)]
    for t in threads: t.start()
    for t in threads: t.join()


KINDS = {
    "blocker": incident_blocker,
    "leak": incident_leak,
    "gc": incident_gc,
    "contention": incident_contention,
}


def record_incident(kind: str, start: dt.datetime, end: dt.datetime, notes: str):
    # Lazy import so simulator.py doesn't need lib when called in isolation
    sys.path.insert(0, "/app/lib")
    from feature_store import connect, record_incident as store
    import numpy as np
    with connect() as conn:
        # Placeholder fingerprint: random normal. The profile_etl DAG writes
        # proper fingerprints; for incident similarity we just want a vector.
        fp = np.random.default_rng().normal(0, 1, 128).astype("float32")
        fp /= (np.linalg.norm(fp) or 1.0)
        iid = store(conn, kind, "demo-jvm11", start, end, notes, fingerprint=fp)
        conn.commit()
    print(f"recorded incident {iid} ({kind})")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("loop")
    pi = sub.add_parser("incident")
    pi.add_argument("--kind", required=True, choices=list(KINDS))
    args = ap.parse_args()

    if args.cmd == "loop":
        print("simulator: steady baseline + random incidents every 10 min")
        next_incident = time.time() + 600
        while True:
            baseline()
            time.sleep(0.3)
            if time.time() >= next_incident:
                kind = random.choice(list(KINDS))
                start = dt.datetime.now(tz=dt.timezone.utc)
                KINDS[kind]()
                end = dt.datetime.now(tz=dt.timezone.utc)
                try:
                    record_incident(kind, start, end, "auto-injected by simulator loop")
                except Exception as e:
                    print(f"record_incident failed: {e}")
                next_incident = time.time() + 600
    else:
        kind = args.kind
        start = dt.datetime.now(tz=dt.timezone.utc)
        KINDS[kind]()
        end = dt.datetime.now(tz=dt.timezone.utc)
        record_incident(kind, start, end, f"manual: simulate-incident.sh {kind}")


if __name__ == "__main__":
    main()
