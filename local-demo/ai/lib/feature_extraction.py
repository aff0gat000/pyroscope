"""Extract tabular features from Pyroscope profiles for downstream ML.

Feature kinds produced:
  1. Per-function aggregates  (function, self_value, total_value, service, profile_type)
  2. Per-(service,integration) time series  (timestamp, service, integration, value)
  3. Stack-level fingerprint vectors  (hash-bag of top-N stack frames)
"""
from __future__ import annotations
import hashlib
from dataclasses import dataclass
from typing import Iterator
import numpy as np


@dataclass
class FunctionRow:
    service: str
    profile_type: str
    function: str
    self_value: float
    total_value: float


def _walk_flamebearer(tree: dict) -> Iterator[tuple[str, float, float]]:
    """Yield (function_name, self_value, total_value) from Pyroscope's
    flamebearer format. Pyroscope returns {'names': [...], 'levels': [[...]]}.
    levels[i] = [offset0, total0, self0, name_idx0, offset1, total1, ...]."""
    names = tree.get("flamebearer", {}).get("names") or tree.get("names", [])
    levels = tree.get("flamebearer", {}).get("levels") or tree.get("levels", [])
    for level in levels:
        for i in range(0, len(level), 4):
            _, total, self_val, name_idx = level[i], level[i + 1], level[i + 2], level[i + 3]
            if 0 <= name_idx < len(names):
                yield names[name_idx], float(self_val), float(total)


def functions_from_flamegraph(tree: dict, service: str, profile_type: str) -> list[FunctionRow]:
    """Aggregate per-function values across all stack positions."""
    acc: dict[str, list[float]] = {}
    for fn, self_v, total_v in _walk_flamebearer(tree):
        if fn not in acc:
            acc[fn] = [0.0, 0.0]
        acc[fn][0] += self_v
        acc[fn][1] += total_v
    return [FunctionRow(service, profile_type, fn, s, t) for fn, (s, t) in acc.items()]


def series_points(series_response: dict) -> list[dict]:
    """Flatten Pyroscope SelectSeries response to records."""
    out = []
    for s in series_response.get("series", []):
        labels = {lbl["name"]: lbl["value"] for lbl in s.get("labels", [])}
        for p in s.get("points", []):
            out.append({
                "timestamp_ms": int(p["timestamp"]),
                "value": float(p["value"]),
                **labels,
            })
    return out


def fingerprint(tree: dict, top_n: int = 256, dim: int = 128) -> np.ndarray:
    """Hash-bag vector for similarity search. Each top-N function name hashes
    into `dim` buckets; vector is L2-normalised."""
    rows = sorted(
        ((fn, s + t) for fn, s, t in _walk_flamebearer(tree) if fn),
        key=lambda r: -r[1],
    )[:top_n]
    v = np.zeros(dim, dtype=np.float32)
    for fn, w in rows:
        h = int(hashlib.blake2b(fn.encode(), digest_size=4).hexdigest(), 16)
        v[h % dim] += float(w)
    n = np.linalg.norm(v) or 1.0
    return v / n
