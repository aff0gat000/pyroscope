import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client';
import { Flame } from '../components/Flame';

export default function Regression() {
  const services = useQuery({ queryKey: ['services'], queryFn: () => api.services() });
  const [service, setService] = useState<string>('demo-jvm11');
  const [profileType, setProfileType] = useState('process_cpu:cpu:nanoseconds:cpu:nanoseconds');
  const [beforeS, setBeforeS] = useState(600);
  const [afterS, setAfterS] = useState(300);
  const regs = useQuery({ queryKey: ['regressions'], queryFn: () => api.regressions() });

  const q = useQuery({
    queryKey: ['diff', service, profileType, beforeS, afterS],
    enabled: !!service,
    queryFn: () => {
      const p = new URLSearchParams({
        service, profile_type: profileType,
        before_seconds: String(beforeS), after_seconds: String(afterS),
      });
      return api.diff(p);
    },
  });

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Regression inspector</h1>
      <div className="flex gap-2 flex-wrap text-sm">
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1"
                value={service} onChange={(e) => setService(e.target.value)}>
          {(services.data?.services ?? []).map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <select className="bg-neutral-800 border border-neutral-700 rounded px-2 py-1"
                value={profileType} onChange={(e) => setProfileType(e.target.value)}>
          <option value="process_cpu:cpu:nanoseconds:cpu:nanoseconds">CPU</option>
          <option value="memory:alloc_in_new_tlab_bytes:bytes:space:bytes">Alloc</option>
          <option value="mutex:delay:nanoseconds:mutex:count">Lock</option>
          <option value="block:delay:nanoseconds:block:count">Block / I/O</option>
        </select>
        <label className="text-neutral-400">before (s)<input className="ml-1 w-16 bg-neutral-800 border border-neutral-700 rounded px-1" type="number" value={beforeS} onChange={(e) => setBeforeS(+e.target.value)} /></label>
        <label className="text-neutral-400">after (s)<input className="ml-1 w-16 bg-neutral-800 border border-neutral-700 rounded px-1" type="number" value={afterS} onChange={(e) => setAfterS(+e.target.value)} /></label>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <h2 className="text-lg mb-2">before</h2>
          <Flame data={q.data?.before ?? null} />
        </div>
        <div>
          <h2 className="text-lg mb-2">after</h2>
          <Flame data={q.data?.after ?? null} />
        </div>
      </div>
      <div>
        <h2 className="text-lg mb-2">Top delta (function, before → after, rel)</h2>
        <table className="w-full text-xs">
          <tbody>
            {(q.data?.delta ?? []).slice(0, 30).map((r: any, i: number) => (
              <tr key={i} className="border-b border-neutral-900">
                <td className="font-mono truncate max-w-[640px] py-1">{r.function}</td>
                <td className="text-right pr-2 tabular-nums">{Number(r.before).toFixed(0)}</td>
                <td className="text-right pr-2 tabular-nums">{Number(r.after).toFixed(0)}</td>
                <td className={`text-right tabular-nums ${r.rel > 0 ? 'text-red-400' : 'text-green-400'}`}>{(r.rel * 100).toFixed(1)}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {regs.data && regs.data.rows.length > 0 && (
        <div>
          <h2 className="text-lg mb-2">Most recent LLM-summarized regressions</h2>
          {regs.data.rows.slice(0, 3).map((r: any, i: number) => (
            <div key={i} className="border border-neutral-800 rounded p-3 mb-2">
              <div className="text-xs text-neutral-500">{r.detected_at}</div>
              <pre className="whitespace-pre-wrap text-sm">{r.llm_summary}</pre>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
