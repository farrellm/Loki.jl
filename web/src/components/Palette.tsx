import { useMemo, useState } from 'react'
import { CATEGORIES } from '../types'
import type { NodeKind } from '../types'

// The palette groups kinds the way DESIGN.md's catalog does. Adding a node has
// two paths on purpose: drag a kind onto the canvas, or tap a kind and then tap
// where it goes. Nothing here is drag-only.

export function Palette({
  kinds,
  pendingKind,
  onPick,
}: {
  kinds: NodeKind[]
  pendingKind: string | null
  onPick: (kind: string | null) => void
}) {
  const [filter, setFilter] = useState('')

  const grouped = useMemo(() => {
    const needle = filter.trim().toLowerCase()
    const matching = kinds.filter(
      (k) =>
        needle === '' ||
        k.name.toLowerCase().includes(needle) ||
        k.doc.toLowerCase().includes(needle),
    )
    return CATEGORIES.map((category) => ({
      category,
      kinds: matching.filter((k) => k.category === category),
    })).filter((group) => group.kinds.length > 0)
  }, [kinds, filter])

  return (
    <section className="palette" aria-label="Node palette">
      <input
        type="search"
        className="palette__filter"
        placeholder="Find an operator"
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
      />
      {pendingKind !== null && (
        <p className="palette__hint">
          Tap the canvas to place <code>{pendingKind}</code>.{' '}
          <button type="button" className="quiet" onClick={() => onPick(null)}>
            Cancel
          </button>
        </p>
      )}
      <div className="palette__groups">
        {grouped.map((group) => (
          <div key={group.category} className="palette__group">
            <h3>{group.category}</h3>
            <ul>
              {group.kinds.map((kind) => (
                <li key={kind.name}>
                  <button
                    type="button"
                    className={`palette__kind${
                      pendingKind === kind.name ? ' palette__kind--armed' : ''
                    }${kind.acausal.length > 0 ? ' palette__kind--ahead' : ''}`}
                    title={kind.doc}
                    draggable
                    data-testid={`kind-${kind.name}`}
                    onDragStart={(e) => {
                      e.dataTransfer.setData('application/loki-kind', kind.name)
                      e.dataTransfer.effectAllowed = 'copy'
                    }}
                    onClick={() =>
                      onPick(pendingKind === kind.name ? null : kind.name)
                    }
                  >
                    <span className="mono">{kind.name}</span>
                    {kind.acausal.length > 0 && (
                      <span className="badge badge--ahead" title="Looks ahead in time">
                        ahead
                      </span>
                    )}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        ))}
        {grouped.length === 0 && (
          <p className="palette__none">No operator matches “{filter}”.</p>
        )}
      </div>
    </section>
  )
}
