import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  applyNodeChanges,
  Background,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  type Connection,
  type Edge,
  type Node,
  type NodeChange,
} from '@xyflow/react'
import { NodeCard } from './NodeCard'
import { api } from '../api'
import type { SessionStore } from '../store'

const nodeTypes = { loki: NodeCard }

export interface CanvasProps {
  store: SessionStore
  compact: boolean
  pendingKind: string | null
  onPlaced: () => void
}

// The provider is what lets the canvas ask React Flow where a tap landed: the
// pane is panned and zoomed, so a pointer's screen coordinates are not a node's
// graph coordinates, and placing by the raw offset drops a node somewhere else
// entirely once the view has moved.
export function Canvas(props: CanvasProps) {
  return (
    <ReactFlowProvider>
      <CanvasSurface {...props} />
    </ReactFlowProvider>
  )
}

function CanvasSurface({ store, compact, pendingKind, onPlaced }: CanvasProps) {
  const { graph, selected, setSelected, act } = store
  const flow = useReactFlow()

  const fromgraph: Node[] = useMemo(
    () =>
      (graph?.nodes ?? []).map((node) => ({
        id: node.id,
        type: 'loki',
        position: { x: node.position[0], y: node.position[1] },
        data: { node, compact, selected: node.id === selected },
      })),
    [graph, compact, selected],
  )

  // The session is the source of truth for what is on the canvas, but React
  // Flow has to be answered as well as read: see `onNodesChange`.
  const [nodes, setNodes] = useState(fromgraph)
  useEffect(() => setNodes(fromgraph), [fromgraph])

  const edges: Edge[] = useMemo(
    () =>
      (graph?.edges ?? []).map((edge) => ({
        id: edge.id,
        source: edge.from[0],
        sourceHandle: edge.from[1],
        target: edge.to[0],
        targetHandle: edge.to[1],
        // An edge out of a tainted port carries the taint downstream, and is
        // drawn so you can see it travel.
        className: graph?.nodes.find((n) => n.id === edge.from[0])?.acausalports[
          edge.from[1]
        ]
          ? 'edge--ahead'
          : undefined,
      })),
    [graph],
  )

  // A change React Flow reports has to come back to it as a new `nodes` array,
  // or work it queued against that answer is dropped: `fitView` — the button in
  // the corner — only marks a fit as wanted and waits for the next `setNodes`,
  // so swallowing the changes leaves the fit pending forever and the button
  // does nothing. Which nodes exist is still the session's to say, so `add` and
  // `remove` are dropped and the rest applied.
  const onNodesChange = useCallback(
    (changes: NodeChange[]) => {
      setNodes((current) =>
        applyNodeChanges(
          changes.filter((c) => c.type !== 'add' && c.type !== 'remove'),
          current,
        ),
      )
      for (const change of changes) {
        if (change.type === 'position' && change.dragging === false) {
          const moved = graph?.nodes.find((n) => n.id === change.id)
          if (moved && change.position) {
            void api
              .moveNode(change.id, [change.position.x, change.position.y])
              .catch(() => undefined)
          }
        }
        if (change.type === 'select' && change.selected) setSelected(change.id)
      }
    },
    [graph, setSelected],
  )

  const onConnect = useCallback(
    (connection: Connection) => {
      if (!connection.source || !connection.target) return
      void act('Could not connect', () =>
        api.connect(
          [connection.source!, connection.sourceHandle ?? 'out'],
          [connection.target!, connection.targetHandle ?? 'in'],
        ),
      )
    },
    [act],
  )

  // Where a pointer landed, in graph coordinates, offset so the node is centred
  // under the finger. The empty canvas has no React Flow mounted and no
  // transform to undo, so it falls back to the container's own offset.
  const graphPoint = useCallback(
    (clientX: number, clientY: number, host: DOMRect | undefined): [number, number] => {
      if ((graph?.nodes.length ?? 0) > 0) {
        const p = flow.screenToFlowPosition({ x: clientX, y: clientY })
        return [p.x - 90, p.y - 26]
      }
      return [clientX - (host?.left ?? 0) - 90, clientY - (host?.top ?? 0) - 26]
    },
    [flow, graph],
  )

  // Every action has a tap path. A node is added by dragging a kind from the
  // palette *or* by tapping the kind and then the canvas — React Flow handles
  // the touch side of connecting handles itself.
  const place = useCallback(
    (event: React.MouseEvent) => {
      if (pendingKind === null) {
        setSelected(null)
        return
      }
      const bounds = (event.target as HTMLElement)
        .closest('.canvas')
        ?.getBoundingClientRect()
      const position = graphPoint(event.clientX, event.clientY, bounds)
      void act('Could not add the node', async () => {
        const { id } = await api.addNode(pendingKind, {}, position)
        setSelected(id)
      })
      onPlaced()
    },
    [pendingKind, act, setSelected, onPlaced, graphPoint],
  )

  const drop = useCallback(
    (event: React.DragEvent) => {
      event.preventDefault()
      const kind = event.dataTransfer.getData('application/loki-kind')
      if (!kind) return
      const position = graphPoint(
        event.clientX,
        event.clientY,
        event.currentTarget.getBoundingClientRect(),
      )
      void act('Could not add the node', async () => {
        const { id } = await api.addNode(kind, {}, position)
        setSelected(id)
      })
    },
    [act, setSelected, graphPoint],
  )

  if (graph !== null && graph.nodes.length === 0) {
    return (
      <div
        className={`canvas canvas--empty${pendingKind ? ' canvas--placing' : ''}`}
        onClick={place}
        onDragOver={(e) => e.preventDefault()}
        onDrop={drop}
      >
        <div className="empty">
          <h2>Nothing here yet</h2>
          <p>
            Pick a source from the palette to read your data in — a table you
            passed from the REPL, or a CSV on disk.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div
      className={`canvas${pendingKind ? ' canvas--placing' : ''}`}
      onDragOver={(e) => e.preventDefault()}
      onDrop={drop}
      data-testid="canvas"
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={onNodesChange}
        onConnect={onConnect}
        onPaneClick={place}
        onEdgeDoubleClick={(_, edge) =>
          void act('Could not disconnect', () => api.disconnect(edge.id))
        }
        fitView
        minZoom={0.2}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
      >
        <Background gap={24} size={1} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  )
}
