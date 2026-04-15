import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client';

export default function Incidents() {
  const list = useQuery({ queryKey: ['incidents'], queryFn: () => api.incidents() });
  const [selected, setSelected] = useState<string | null>(null);
  const detail = useQuery({
    queryKey: ['incident', selected],
    enabled: !!selected,
    queryFn: () => api.incident(selected!),
  });
  const sim = useQuery({
    queryKey: ['similar', selected],
    enabled: !!selected,
    queryFn: () => api.similar(selected!),
  });

  return (
    <div className="grid grid-cols-[360px_1fr] gap-4">
      <div>
        <h1 className="text-2xl font-semibold mb-3">Incidents</h1>
        <div className="space-y-1 text-sm">
          {(list.data?.rows ?? []).map((r: any) => (
            <button key={r.id}
                    onClick={() => setSelected(r.id)}
                    className={`w-full text-left p-2 rounded border border-neutral-800 hover:bg-neutral-900 ${selected === r.id ? 'bg-neutral-900' : ''}`}>
              <div className="font-medium">{r.kind} · {r.service}</div>
              <div className="text-xs text-neutral-500">{r.start_ts}</div>
            </button>
          ))}
          {list.data?.rows?.length === 0 && (
            <div className="text-neutral-500 italic">no incidents yet — try ./scripts/simulate-incident.sh blocker</div>
          )}
        </div>
      </div>
      <div>
        {selected && detail.data && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">{detail.data.kind} · {detail.data.service}</h2>
            <div className="text-sm text-neutral-400">{detail.data.start_ts} — {detail.data.end_ts ?? 'open'}</div>
            {detail.data.notes && <div className="text-sm">{detail.data.notes}</div>}
            <div>
              <h3 className="font-semibold mb-1">Similar past incidents</h3>
              <ul className="text-sm space-y-1">
                {(sim.data?.results ?? []).map((r: any) => (
                  <li key={r.id} className="border border-neutral-800 rounded p-2">
                    <span className="font-medium">{r.kind}</span>{' '}
                    <span className="text-neutral-400">{r.service}</span>{' '}
                    <span className="ml-2 text-xs text-neutral-500">sim={Number(r.similarity).toFixed(3)}</span>
                  </li>
                ))}
                {sim.data?.results?.length === 0 && <li className="text-neutral-500">no neighbours</li>}
              </ul>
            </div>
            <div>
              <h3 className="font-semibold mb-1">Anomalies in window</h3>
              <table className="w-full text-xs">
                <tbody>
                  {(detail.data.anomalies ?? []).map((a: any, i: number) => (
                    <tr key={i} className="border-b border-neutral-900">
                      <td className="py-1">{a.ts}</td>
                      <td>{a.service}</td>
                      <td>{a.metric}</td>
                      <td className={`text-right tabular-nums ${Math.abs(a.score) > 4 ? 'text-red-400' : ''}`}>{a.score.toFixed(2)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
        {!selected && <div className="text-neutral-500">pick an incident to view details + similarity</div>}
      </div>
    </div>
  );
}
