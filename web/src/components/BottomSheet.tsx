import { useState, type ReactNode } from 'react'

// Below the breakpoint the five regions become one sheet over the canvas.
// Nothing is removed — the same components reflow, which is the whole point of
// one responsive UI rather than a reduced phone version.
//
// Three heights, reachable by tapping the handle as well as dragging it: a peek
// that leaves the canvas visible, a half, and full.

export type SheetHeight = 'peek' | 'half' | 'full'

export interface SheetTab {
  id: string
  label: string
  content: ReactNode
}

export function BottomSheet({
  tabs,
  active,
  onActive,
  height,
  onHeight,
}: {
  tabs: SheetTab[]
  active: string
  onActive: (id: string) => void
  height: SheetHeight
  onHeight: (height: SheetHeight) => void
}) {
  const [dragFrom, setDragFrom] = useState<number | null>(null)

  const cycle = () =>
    onHeight(height === 'peek' ? 'half' : height === 'half' ? 'full' : 'peek')

  const current = tabs.find((t) => t.id === active) ?? tabs[0]

  return (
    <section
      className={`sheet sheet--${height}`}
      aria-label="Panels"
      data-testid="sheet"
      data-height={height}
    >
      <button
        type="button"
        className="sheet__grab"
        aria-label={`Panel height: ${height}. Tap to change.`}
        onClick={cycle}
        onPointerDown={(e) => setDragFrom(e.clientY)}
        onPointerUp={(e) => {
          if (dragFrom === null) return
          const moved = dragFrom - e.clientY
          setDragFrom(null)
          if (moved > 40) onHeight(height === 'peek' ? 'half' : 'full')
          else if (moved < -40) onHeight(height === 'full' ? 'half' : 'peek')
        }}
      >
        <span className="sheet__grabline" aria-hidden="true" />
      </button>
      <div className="sheet__tabs" role="tablist">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={tab.id === current.id}
            className={`tab${tab.id === current.id ? ' tab--on' : ''}`}
            data-testid={`sheet-tab-${tab.id}`}
            onClick={() => {
              onActive(tab.id)
              if (height === 'peek') onHeight('half')
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>
      <div className="sheet__body">{current.content}</div>
    </section>
  )
}
