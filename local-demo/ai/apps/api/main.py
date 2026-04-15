"""FastAPI BFF. Thin: orchestrates calls to lib/ and serves JSON/SSE.

Auth is intentionally absent; see docs/explanation/auth-strategy.md for the
layered plan (OIDC + JWT + per-route scopes) once we're ready to add it.
"""
from __future__ import annotations
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers import profiles, hotspots, incidents, similarity, chat, regressions, meta

app = FastAPI(title="Pyroscope local-demo AI", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)

app.include_router(meta.router)
app.include_router(profiles.router, prefix="/profiles", tags=["profiles"])
app.include_router(hotspots.router, prefix="/hotspots", tags=["hotspots"])
app.include_router(incidents.router, prefix="/incidents", tags=["incidents"])
app.include_router(similarity.router, prefix="/similarity", tags=["similarity"])
app.include_router(chat.router, prefix="/chat", tags=["chat"])
app.include_router(regressions.router, prefix="/regressions", tags=["regressions"])
