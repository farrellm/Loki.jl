import { Handle, Position, type NodeProps } from '@xyflow/react'
import type { GraphNode } from '../types'

// The node is where this interface spends its boldness; everything around it is
// quiet on purpose.
//
// Three things are encoded structurally rather than decoratively:
//
//   the left rail is status  — hairline idle, solid ok, red error, and *dashed*
//                              for blocked, so a chain broken upstream looks
//                              broken;
//   the hatch is acausality  — the fan-chart convention for "this is not what
//                              you know yet". A texture, not a hue, so it
//                              survives greyscale and colour blindness, and it
//                              spreads downstream exactly as the taint does;
//   the body is the script   — the node shows the line of Julia it exports, from
//                              its kind's `emit`. Reading the canvas is reading
//                              the script it becomes.
//
// The compact view drops the call and the row count for density. It is the same
// node, not a different one: the rail and the hatch still say everything.

export interface NodeCardData extends Record<string, unknown> {
  node: GraphNode
  compact: boolean
  selected: boolean
}

const STATUS_LABEL: Record<string, string> = {
  idle: 'Not run',
  running: 'Running',
  ok: 'Ready',
  error: 'Failed',
  blocked: 'Blocked upstream',
}

function rowcount(node: GraphNode): number | null {
  const shapes = Object.values(node.results)
  return shapes.length > 0 ? shapes[0].rows : null
}


export function NodeCard({ data }: NodeProps) {
  const { node, compact, selected } = data as NodeCardData
  const rows = rowcount(node)
  const call = node.calls[node.outputs[0]]
  const label = STATUS_LABEL[node.status] ?? node.status

  return (
    <div
      className={[
        'node',
        `node--${node.status}`,
        node.acausal ? 'node--ahead' : '',
        compact ? 'node--compact' : '',
        selected ? 'node--selected' : '',
        node.write ? 'node--write' : '',
      ]
        .filter(Boolean)
        .join(' ')}
      aria-label={`${node.kind} ${node.id}, ${label}${node.acausal ? ', looks ahead in time' : ''}`}
      data-testid={`node-${node.id}`}
      data-status={node.status}
      data-acausal={node.acausal}
    >
      {node.inputs.map((port, i) => (
        <Handle
          key={port.name}
          id={port.name}
          type="target"
          position={Position.Left}
          className="port port--in"
          style={{ top: portOffset(i, node.inputs.length) }}
          title={port.name}
        />
      ))}

      <span className="node__rail" aria-hidden="true" />

      <div className="node__body">
        <div className="node__head">
          <span className="node__kind">{node.kind}</span>
          <span className="node__id">{node.id}</span>
        </div>
        {!compact &&
          // A node with one output shows its line. A fit has two — the causal
          // model table and the acausal in-sample stream — and which is which
          // is the whole point of the node, so both are named.
          (node.outputs.length === 1
            ? call !== undefined && (
                <div className="node__call" title={call}>
                  {call}
                </div>
              )
            : node.outputs.map((port) => (
                <div key={port} className="node__call" title={node.calls[port]}>
                  <span className="node__callport mono">{port}</span>
                  {node.calls[port]}
                </div>
              )))}
        <div className="node__foot">
          <span className="node__status">{label}</span>
          {rows !== null && (
            <span className="node__rows">{rows.toLocaleString()} rows</span>
          )}
        </div>
      </div>

      {node.outputs.map((port, i) => (
        <Handle
          key={port}
          id={port}
          type="source"
          position={Position.Right}
          className={`port port--out${node.acausalports[port] ? ' port--ahead' : ''}`}
          style={{ top: portOffset(i, node.outputs.length) }}
          title={port}
        >
          {node.outputs.length > 1 && <span className="port__label">{port}</span>}
        </Handle>
      ))}
    </div>
  )
}

// Ports are drawn small and hit-tested large: the visible notch is 7px and the
// touch target around it is 44.
function portOffset(index: number, total: number): string {
  return total === 1 ? '50%' : `${((index + 1) / (total + 1)) * 100}%`
}
