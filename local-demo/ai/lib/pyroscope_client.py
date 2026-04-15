"""Thin client for the Pyroscope Connect API (v1.8+).

Endpoints used:
  POST /querier.v1.QuerierService/LabelValues     {"name": "<label>"}
  POST /querier.v1.QuerierService/ProfileTypes    {}
  POST /querier.v1.QuerierService/SelectMergeStacktraces  (flamegraph)
  POST /querier.v1.QuerierService/SelectSeries    (time-series aggregation)
"""
from __future__ import annotations
import os
import time
from dataclasses import dataclass
from typing import Iterable
import httpx


@dataclass
class TimeRange:
    start_ms: int
    end_ms: int

    @classmethod
    def last(cls, seconds: int) -> "TimeRange":
        now = int(time.time() * 1000)
        return cls(now - seconds * 1000, now)


class PyroscopeClient:
    def __init__(self, url: str | None = None, timeout: float = 30.0):
        self.url = (url or os.getenv("PYROSCOPE_URL", "http://host.docker.internal:4041")).rstrip("/")
        self.http = httpx.Client(base_url=self.url, timeout=timeout,
                                 headers={"content-type": "application/json"})

    def _post(self, path: str, body: dict) -> dict:
        r = self.http.post(path, json=body)
        r.raise_for_status()
        return r.json()

    def label_values(self, name: str) -> list[str]:
        return self._post("/querier.v1.QuerierService/LabelValues", {"name": name}).get("names", [])

    def profile_types(self) -> list[dict]:
        return self._post("/querier.v1.QuerierService/ProfileTypes", {}).get("profileTypes", [])

    def select_merge_stacktraces(self, profile_type_id: str, label_selector: str,
                                 tr: TimeRange, max_nodes: int = 2048) -> dict:
        """Returns flamegraph tree structure."""
        return self._post("/querier.v1.QuerierService/SelectMergeStacktraces", {
            "profileTypeID": profile_type_id,
            "labelSelector": label_selector,
            "start": tr.start_ms,
            "end": tr.end_ms,
            "maxNodes": max_nodes,
        })

    def select_series(self, profile_type_id: str, label_selector: str,
                      tr: TimeRange, step_seconds: int = 15,
                      group_by: Iterable[str] = ()) -> dict:
        """Time-series of aggregated profile values."""
        return self._post("/querier.v1.QuerierService/SelectSeries", {
            "profileTypeID": profile_type_id,
            "labelSelector": label_selector,
            "start": tr.start_ms,
            "end": tr.end_ms,
            "step": step_seconds,
            "groupBy": list(group_by),
        })
