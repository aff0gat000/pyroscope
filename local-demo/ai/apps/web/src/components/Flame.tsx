import { FlameGraph } from 'react-flame-graph';
import { useMemo } from 'react';

type Flamebearer = {
  flamebearer?: { names?: string[]; levels?: number[][] };
  names?: string[];
  levels?: number[][];
};

type Node = { name: string; value: number; children?: Node[] };

function toTree(fb: Flamebearer): Node | null {
  const names = fb.flamebearer?.names ?? fb.names ?? [];
  const levels = fb.flamebearer?.levels ?? fb.levels ?? [];
  if (!levels.length) return null;
  // Pyroscope flamebearer encodes levels as flat arrays of [offset, total, self, nameIdx].
  // We walk top→down and build a tree by matching each child's offset window to the parent.
  type Frame = { start: number; total: number; self: number; name: string; children: Frame[] };
  const levelFrames: Frame[][] = levels.map((row) => {
    const frames: Frame[] = [];
    let cursor = 0;
    for (let i = 0; i < row.length; i += 4) {
      const offset = row[i];
      const total = row[i + 1];
      const selfV = row[i + 2];
      const nameIdx = row[i + 3];
      cursor += offset;
      frames.push({ start: cursor, total, self: selfV, name: names[nameIdx] ?? '?', children: [] });
      cursor += total;
    }
    return frames;
  });
  for (let l = 1; l < levelFrames.length; l++) {
    const parents = levelFrames[l - 1];
    let pi = 0;
    for (const child of levelFrames[l]) {
      while (pi < parents.length && parents[pi].start + parents[pi].total <= child.start) pi++;
      if (pi < parents.length) parents[pi].children.push(child);
    }
  }
  if (!levelFrames[0].length) return null;
  const toNode = (f: Frame): Node => ({ name: f.name, value: f.total, children: f.children.map(toNode) });
  return toNode(levelFrames[0][0]);
}

export function Flame({ data, height = 400 }: { data: Flamebearer | null; height?: number }) {
  const tree = useMemo(() => (data ? toTree(data) : null), [data]);
  if (!tree) return <div className="text-neutral-500 italic">no data</div>;
  return (
    <div className="border border-neutral-800 rounded bg-neutral-900">
      <FlameGraph data={tree} height={height} width={1100} />
    </div>
  );
}
