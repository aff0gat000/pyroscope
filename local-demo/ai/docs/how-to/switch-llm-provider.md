# How-to — switch LLM provider

Four supported: `ollama` (default, local) | `claude` | `openai` | `gemini`.
Switch by editing `.env` and recreating the api container.

## Ollama (default)

```bash
# .env
LLM_PROVIDER=ollama
OLLAMA_MODEL=llama3.2:3b
```

Model is pulled on first boot by `ai-ollama-init`. To change models:

```bash
docker compose exec ollama ollama pull llama3.1:8b
# then update OLLAMA_MODEL=llama3.1:8b and:
docker compose up -d api
```

## Claude

```bash
# .env
LLM_PROVIDER=claude
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_MODEL=claude-sonnet-4-6
```

```bash
docker compose up -d api
```

## OpenAI

```bash
LLM_PROVIDER=openai
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini
```

## Gemini

```bash
LLM_PROVIDER=gemini
GOOGLE_API_KEY=...
GEMINI_MODEL=gemini-2.0-flash
```

## Verifying

```bash
source .env
curl -s localhost:$API_PORT/config | jq .llm_provider
```

The web UI's Chat page also shows the active provider in the header.

## How the gateway works

`lib/llm_gateway.py` reads `LLM_PROVIDER` at every call. No restart needed
for the gateway itself to see a changed env var — but the api container's
env is set at container start, so you do need `docker compose up -d api`
(or `docker compose restart api`) after editing `.env`.
