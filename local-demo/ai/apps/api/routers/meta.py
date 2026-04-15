import os
from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
def health():
    return {"ok": True}


@router.get("/config")
def config():
    """Public runtime config surfaced to the SPA."""
    return {
        "llm_provider": os.getenv("LLM_PROVIDER", "ollama"),
        "pyroscope_url": os.getenv("PYROSCOPE_URL", ""),
        "mlflow_url": os.getenv("MLFLOW_TRACKING_URI", ""),
        "version": "0.1.0",
    }
