import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client';

const METRICS = ['cpu', 'alloc', 'lock', 'block'] as const;

export default function Hotspots() {
  const [metric, setMetric] = useState<(typeof METRICS)[number]>('cpu');
  const [hours, setHours] = useState(1);
  const [service, setService] = useState<string>('');
  const services = useQuery({ queryKey: ['services'], queryFn: () => api.services() });
  const q = useQuery({
    queryKey: ['hotspots', metric, hours, service],
    queryFn: () => {
      const p = new URLSearchParams({ metric, hours: String(hours), limit: '30' });
      if (service) p.set('service', service);
      return api.hotspots(p);
    },
  });

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Hotspot leaderboard</h1>
      <div className="flex gap-2 flex-wrap text-sm">
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1"
                value={metric} onChange={(e) => setMetric(e.target.value as any)}>
          {METRICS.map((m) => <option key={m} value={m}>{m}</option>)}
        </select>
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1"
                value={hours} onChange={(e) => setHours(Number(e.target.value))}>
          {[1, 6, 24, 168].map((h) => <option key={h} value={h}>{h}h</option>)}
        </select>
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1"
                value={service} onChange={(e) => setService(e.target.value)}>
          <option value="">all services</option>
          {(services.data?.services ?? []).map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>
      {q.isLoading && <div className="text-neutral-500">loading…</div>}
      {q.error && <div className="text-red-400">{String(q.error)}</div>}
      {q.data && (
        <table className="w-full text-sm border-collapse">
          <thead>
            <tr className="text-left text-neutral-400 border-b border-neutral-800">
              <th className="py-2">#</th><th>service</th><th>function</th><th className="text-right">total</th>
            </tr>
          </thead>
          <tbody>
            {q.data.rows.map((r: any, i: number) => (
              <tr key={i} className="border-b border-neutral-900 hover:bg-neutral-900/60">
                <td className="py-1 pr-2 text-neutral-500">{i + 1}</td>
                <td className="pr-4">{r.service}</td>
                <td className="pr-4 font-mono text-xs truncate max-w-[600px]">{r.function}</td>
                <td className="text-right tabular-nums">{Number(r.total).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
