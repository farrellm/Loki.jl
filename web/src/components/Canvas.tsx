import { useCallback, useMemo } from 'react'
import {
  Background,
  Controls,
  ReactFlow,
  type Connection,
  type Edge,
  type Node,
  type NodeChange,
} from '@xyflow/react'
import { NodeCard } from './NodeCard'
import { api } from '../api'
import type { SessionStore } from '../store'

const nodeTypes = { loki: NodeCard }

export function Canvas({
  store,
  compact,
  pendingKind,
  onPlaced,
}: {
  store: SessionStore
  compact: boolean
  pendingKind: string | null
  onPlaced: () => void
}) {
  const { graph, selected, setSelected, act } = store

  const nodes: Node[] = useMemo(
    () =>
      (graph?.nodes ?? []).map((node) => ({
        id: node.id,
        type: 'loki',
        position: { x: node.position[0], y: node.position[1] },
        data: { node, compact, selected: node.id === selected },
      })),
    [graph, compact, selected],
  )

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

  const onNodesChange = useCallback(
    (changes: NodeChange[]) => {
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
      const x = event.clientX - (bounds?.left ?? 0) - 90
      const y = event.clientY - (bounds?.top ?? 0) - 26
      void act('Could not add the node', async () => {
        const { id } = await api.addNode(pendingKind, {}, [x, y])
        setSelected(id)
      })
      onPlaced()
    },
    [pendingKind, act, setSelected, onPlaced],
  )

  const drop = useCallback(
    (event: React.DragEvent) => {
      event.preventDefault()
      const kind = event.dataTransfer.getData('application/loki-kind')
      if (!kind) return
      const bounds = event.currentTarget.getBoundingClientRect()
      void act('Could not add the node', async () => {
        const { id } = await api.addNode(kind, {}, [
          event.clientX - bounds.left - 90,
          event.clientY - bounds.top - 26,
        ])
        setSelected(id)
      })
    },
    [act, setSelected],
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
