import { useState, useRef } from 'react';
import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client';

export default function Chat() {
  const services = useQuery({ queryKey: ['services'], queryFn: () => api.services() });
  const cfg = useQuery({ queryKey: ['config'], queryFn: () => api.config() });
  const [service, setService] = useState<string>('');
  const [q, setQ] = useState('');
  const [log, setLog] = useState<{ role: 'user' | 'ai'; text: string }[]>([]);
  const cur = useRef('');

  function send() {
    if (!q.trim()) return;
    const prompt = q;
    setLog((l) => [...l, { role: 'user', text: prompt }, { role: 'ai', text: '' }]);
    setQ('');
    cur.current = '';
    api.chatStream(
      prompt,
      service || null,
      (tok) => {
        cur.current += tok;
        setLog((l) => {
          const copy = [...l];
          copy[copy.length - 1] = { role: 'ai', text: cur.current };
          return copy;
        });
      },
      () => {},
      (err) => {
        setLog((l) => [...l, { role: 'ai', text: `[error: ${err}]` }]);
      },
    );
  }

  return (
    <div className="flex flex-col h-full max-w-3xl mx-auto">
      <div className="flex justify-between items-center mb-2">
        <h1 className="text-2xl font-semibold">Chat with profiles</h1>
        <div className="text-xs text-neutral-500">llm: {cfg.data?.llm_provider ?? '…'}</div>
      </div>
      <div className="mb-2">
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1 text-sm"
                value={service} onChange={(e) => setService(e.target.value)}>
          <option value="">no service filter</option>
          {(services.data?.services ?? []).map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>
      <div className="flex-1 overflow-auto space-y-3 border border-neutral-800 rounded p-3 bg-neutral-900/40">
        {log.map((m, i) => (
          <div key={i} className={m.role === 'user' ? 'text-neutral-300' : 'text-green-300 whitespace-pre-wrap'}>
            <span className="text-xs text-neutral-500 mr-2">{m.role}</span>{m.text}
          </div>
        ))}
      </div>
      <div className="mt-3 flex gap-2">
        <textarea className="flex-1 bg-neutral-900 border border-neutral-800 rounded p-2 text-sm"
                  rows={2} placeholder="why did demo-jvm11 slow down in the last hour?"
                  value={q} onChange={(e) => setQ(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) send(); }} />
        <button onClick={send} className="px-4 rounded bg-blue-600 hover:bg-blue-500 text-white">Send</button>
      </div>
      <div className="text-xs text-neutral-500 mt-1">Cmd/Ctrl-Enter to send</div>
    </div>
  );
}
