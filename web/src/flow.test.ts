import { describe, expect, it } from 'vitest'
import type { Node } from '@xyflow/react'
import { mergenodes } from './flow'

const node = (id: string, x: number, data: Record<string, unknown> = {}): Node => ({
  id,
  type: 'loki',
  position: { x, y: 0 },
  data,
})

describe('mergenodes', () => {
  it('keeps what React Flow measured, so a refetch never hides a node', () => {
    const drawn = {
      ...node('n1', 0),
      measured: { width: 180, height: 52 },
      selected: true,
    }
    const [merged] = mergenodes([drawn], [node('n1', 0)])
    expect(merged.measured).toEqual({ width: 180, height: 52 })
    expect(merged.selected).toBe(true)
  })

  it('takes position and data from the session', () => {
    const drawn = {
      ...node('n1', 0, { status: 'stale' }),
      measured: { width: 1, height: 1 },
    }
    const [merged] = mergenodes([drawn], [node('n1', 40, { status: 'done' })])
    expect(merged.position).toEqual({ x: 40, y: 0 })
    expect(merged.data).toEqual({ status: 'done' })
  })

  it('leaves a node being dragged where the finger has it', () => {
    const drawn = { ...node('n1', 99), dragging: true }
    const [merged] = mergenodes([drawn], [node('n1', 0)])
    expect(merged.position).toEqual({ x: 99, y: 0 })
    expect(merged.dragging).toBe(true)
  })

  it('lets the session add and remove nodes', () => {
    const merged = mergenodes(
      [node('n1', 0), node('n2', 0)],
      [node('n1', 0), node('n3', 0)],
    )
    expect(merged.map((n) => n.id)).toEqual(['n1', 'n3'])
    expect(merged[1]).toEqual(node('n3', 0))
  })
})
