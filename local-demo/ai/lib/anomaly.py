"""Simple statistical anomaly + changepoint detection. No heavy ML deps.

- zscore_anomalies: rolling z-score on a time series; returns (index, z) pairs.
- changepoints: difference-of-means detector (Page-Hinkley-lite) that flags
  shifts between consecutive windows.
"""
from __future__ import annotations
import numpy as np


def zscore_anomalies(values: np.ndarray, window: int = 20, threshold: float = 3.0):
    out = []
    if len(values) < window + 1:
        return out
    for i in range(window, len(values)):
        w = values[i - window:i]
        mu, sigma = w.mean(), w.std() + 1e-9
        z = (values[i] - mu) / sigma
        if abs(z) > threshold:
            out.append((i, float(z)))
    return out


def changepoints(values: np.ndarray, window: int = 15, min_shift: float = 0.25):
    """Flag indices where the mean of the next `window` values differs from
    the previous window by more than `min_shift` (relative)."""
    out = []
    n = len(values)
    if n < 2 * window:
        return out
    for i in range(window, n - window):
        left = values[i - window:i].mean()
        right = values[i:i + window].mean()
        base = (abs(left) + abs(right)) / 2 + 1e-9
        rel = (right - left) / base
        if abs(rel) > min_shift:
            out.append((i, float(rel)))
    # suppress near-duplicates: keep only local maxima within `window`
    pruned, last_i = [], -10**9
    for i, r in sorted(out, key=lambda x: -abs(x[1])):
        if abs(i - last_i) > window:
            pruned.append((i, r)); last_i = i
    return sorted(pruned)
