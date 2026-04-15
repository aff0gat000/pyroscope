"""Unified LLM interface. Provider selected via LLM_PROVIDER env var.

Supported: ollama (default, local) | claude | openai | gemini.
Only the provider chosen at runtime has its dependency exercised; others
fail lazily so missing optional libs don't break the process.
"""
from __future__ import annotations
import os
from abc import ABC, abstractmethod

import httpx


class LLM(ABC):
    @abstractmethod
    def complete(self, prompt: str, *, system: str | None = None,
                 max_tokens: int = 1024, temperature: float = 0.2) -> str: ...


class Ollama(LLM):
    def __init__(self, url: str, model: str):
        self.url, self.model = url.rstrip("/"), model

    def complete(self, prompt, *, system=None, max_tokens=1024, temperature=0.2):
        body = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": temperature, "num_predict": max_tokens},
        }
        if system:
            body["system"] = system
        r = httpx.post(f"{self.url}/api/generate", json=body, timeout=120.0)
        r.raise_for_status()
        return r.json().get("response", "")


class Claude(LLM):
    def __init__(self, api_key: str, model: str):
        self.api_key, self.model = api_key, model

    def complete(self, prompt, *, system=None, max_tokens=1024, temperature=0.2):
        body = {"model": self.model, "max_tokens": max_tokens, "temperature": temperature,
                "messages": [{"role": "user", "content": prompt}]}
        if system:
            body["system"] = system
        r = httpx.post("https://api.anthropic.com/v1/messages", json=body, timeout=120.0,
                       headers={"x-api-key": self.api_key, "anthropic-version": "2023-06-01",
                                "content-type": "application/json"})
        r.raise_for_status()
        return "".join(b.get("text", "") for b in r.json().get("content", []))


class OpenAI(LLM):
    def __init__(self, api_key: str, model: str):
        self.api_key, self.model = api_key, model

    def complete(self, prompt, *, system=None, max_tokens=1024, temperature=0.2):
        msgs = []
        if system:
            msgs.append({"role": "system", "content": system})
        msgs.append({"role": "user", "content": prompt})
        r = httpx.post("https://api.openai.com/v1/chat/completions",
                       json={"model": self.model, "messages": msgs,
                             "max_tokens": max_tokens, "temperature": temperature},
                       timeout=120.0,
                       headers={"authorization": f"Bearer {self.api_key}",
                                "content-type": "application/json"})
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]


class Gemini(LLM):
    def __init__(self, api_key: str, model: str):
        self.api_key, self.model = api_key, model

    def complete(self, prompt, *, system=None, max_tokens=1024, temperature=0.2):
        parts = []
        if system:
            parts.append({"text": f"(system) {system}\n\n"})
        parts.append({"text": prompt})
        r = httpx.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent",
            params={"key": self.api_key},
            json={"contents": [{"parts": parts}],
                  "generationConfig": {"temperature": temperature, "maxOutputTokens": max_tokens}},
            timeout=120.0,
        )
        r.raise_for_status()
        cands = r.json().get("candidates", [])
        return "".join(p.get("text", "") for p in (cands[0]["content"]["parts"] if cands else []))


def from_env() -> LLM:
    provider = os.getenv("LLM_PROVIDER", "ollama").lower()
    if provider == "ollama":
        return Ollama(os.getenv("OLLAMA_URL", "http://ollama:11434"),
                      os.getenv("OLLAMA_MODEL", "llama3.2:3b"))
    if provider == "claude":
        return Claude(os.environ["ANTHROPIC_API_KEY"],
                      os.getenv("ANTHROPIC_MODEL", "claude-sonnet-4-6"))
    if provider == "openai":
        return OpenAI(os.environ["OPENAI_API_KEY"],
                      os.getenv("OPENAI_MODEL", "gpt-4o-mini"))
    if provider == "gemini":
        return Gemini(os.environ["GOOGLE_API_KEY"],
                      os.getenv("GEMINI_MODEL", "gemini-2.0-flash"))
    raise ValueError(f"Unknown LLM_PROVIDER={provider!r}")
