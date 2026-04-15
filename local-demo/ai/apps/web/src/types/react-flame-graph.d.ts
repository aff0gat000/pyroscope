declare module 'react-flame-graph' {
  import { ComponentType } from 'react';
  export interface FlameGraphNode {
    name: string;
    value: number;
    children?: FlameGraphNode[];
    backgroundColor?: string;
    color?: string;
    tooltip?: string;
  }
  export interface FlameGraphProps {
    data: FlameGraphNode;
    height: number;
    width?: number;
    onChange?: (node: FlameGraphNode) => void;
  }
  export const FlameGraph: ComponentType<FlameGraphProps>;
}
