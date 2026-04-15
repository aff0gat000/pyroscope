# Explanation — LLM provider neutrality

Four providers, one abstraction.

## The shape

`lib/llm_gateway.py` exposes a single interface:

```python
class LLM:
    def complete(self, prompt: str, *, system: str | None,
                 max_tokens: int, temperature: float) -> str: ...
```

`from_env()` returns an `Ollama | Claude | OpenAI | Gemini` instance based
on the `LLM_PROVIDER` env var.

```mermaid
flowchart LR
    call["llm = from_env()<br/>llm.complete(prompt, system=..., max_tokens=...)"]
    call --> prov{LLM_PROVIDER?}
    prov -->|ollama| O[POST /api/generate]
    prov -->|claude| C[POST /v1/messages]
    prov -->|openai| P[POST /v1/chat/completions]
    prov -->|gemini| G[POST /v1beta/models/.../generateContent]
```

## Why this design

- **One env variable swaps providers.** No code changes in callers.
- **Lazy imports.** Each client uses stdlib `httpx`. No provider SDK is
  imported — no dependency on whichever optional package is installed.
- **Server-side keys.** The key lives only in the BFF container's env.
  The SPA never sees it.
- **Uniform error model.** Any HTTP failure becomes a Python exception
  the caller can catch; the chat endpoint surfaces it as an SSE `error`
  event.

## What breaks the abstraction

- **Streaming.** Each provider streams differently. The demo uses
  **non-streaming** completions internally and splits the response by
  line so the UI can render progressively. This keeps all four providers
  working through one code path. If you need true token-by-token
  streaming, each provider needs a dedicated streaming path.
- **Tool-use / function calling.** Each provider's schema differs
  non-trivially. Add a second method (e.g. `call_with_tools`) per
  provider only when needed.
- **Vision.** Same story: per-provider.

For this demo's goals (summarise regressions, answer prose questions over
profile context) the neutral interface is plenty.

## Default: Ollama local

Reason: reproducible, private, no quota. Quality is lower than hosted
models but acceptable for short summaries. `llama3.2:3b` fits on CPU;
`llama3.1:8b` is better if you have a GPU.

## Escape hatches for prod

If you adopt this shape in production, the plausible changes are:

1. Provider per use case — "classification calls Ollama, prose calls
   Claude" — a `role`→`LLM` map, not one global provider.
2. Rate-limit + retry wrapper around `complete()`.
3. Token + latency tracing per call, logged to MLflow.

All three are additive — no change to the caller sites.
