// Runtime API base — we reverse-proxy /api/* in nginx, so this is always
// relative in production. In dev, vite rewrites via its proxy config.
const BASE = '/api';

async function json<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${BASE}${path}`, init);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.json();
}

export const api = {
  config:        () => json<{ llm_provider: string }>(`/config`),
  services:      () => json<{ services: string[] }>(`/profiles/services`),
  flamegraph:    (p: URLSearchParams) => json<any>(`/profiles/flamegraph?${p}`),
  diff:          (p: URLSearchParams) => json<any>(`/profiles/diff?${p}`),
  hotspots:      (p: URLSearchParams) => json<{ rows: any[]; metric: string }>(`/hotspots/leaderboard?${p}`),
  incidents:     () => json<{ rows: any[] }>(`/incidents`),
  incident:      (id: string) => json<any>(`/incidents/${id}`),
  similar:       (id: string, k = 5) =>
    json<{ results: any[] }>(`/similarity`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ incident_id: id, k }),
    }),
  regressions:   () => json<{ rows: any[] }>(`/regressions`),
  // SSE via EventSource
  chatStream: (question: string, service: string | null, onToken: (s: string) => void, onDone: () => void, onError: (e: string) => void) => {
    // EventSource is GET-only; we POST first to obtain a stream URL. To keep
    // things simple we tunnel the question through the SSE query string via
    // a fetch + reader instead.
    const ctrl = new AbortController();
    fetch(`${BASE}/chat`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'accept': 'text/event-stream' },
      body: JSON.stringify({ question, service }),
      signal: ctrl.signal,
    }).then(async (r) => {
      if (!r.body) return onError('no stream');
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const frames = buf.split('\n\n');
        buf = frames.pop() ?? '';
        for (const f of frames) {
          const ev = f.split('\n').reduce<Record<string, string>>((acc, line) => {
            const idx = line.indexOf(': ');
            if (idx === -1) return acc;
            acc[line.slice(0, idx)] = line.slice(idx + 2);
            return acc;
          }, {});
          if (ev.event === 'token') onToken(ev.data ?? '');
          else if (ev.event === 'done') onDone();
          else if (ev.event === 'error') onError(ev.data ?? 'error');
        }
      }
      onDone();
    }).catch((e) => onError(String(e)));
    return () => ctrl.abort();
  },
};
