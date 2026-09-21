import type { Node } from '@xyflow/react'

// The session says which nodes exist, where they sit and what they show, but a
// node React Flow has drawn also carries fields only React Flow can fill in. The
// one that matters is `measured`: a node without it is drawn hidden until its
// ResizeObserver reports, and React Flow re-arms the observer only when the node
// goes from measured to unmeasured — so replacing a measured node with a fresh
// one twice before the report lands leaves it hidden until a reload. That is
// what a drop does: selection, the move and the refetch the move causes all
// arrive together. Carrying those fields over keeps every node measured, and
// keeping a dragged node's own position stops a refetch mid-drag from snapping
// it back under the finger.
export function mergenodes(current: Node[], next: Node[]): Node[] {
  const drawn = new Map(current.map((node) => [node.id, node]))
  return next.map((node) => {
    const prior = drawn.get(node.id)
    if (prior === undefined) return node
    return {
      ...node,
      measured: prior.measured,
      selected: prior.selected,
      dragging: prior.dragging,
      position: prior.dragging ? prior.position : node.position,
    }
  })
}
