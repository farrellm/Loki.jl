import { useEffect, useState } from 'react'
import { BottomSheet, type SheetHeight } from './components/BottomSheet'
import { Canvas } from './components/Canvas'
import { Diagnostics } from './components/Diagnostics'
import { Inspector } from './components/Inspector'
import { Palette } from './components/Palette'
import { SessionBar } from './components/SessionBar'
import { TablePreview } from './components/TablePreview'
import { useSession } from './store'

type Theme = 'system' | 'light' | 'dark'

const WIDE = '(min-width: 900px)'

export default function App() {
  const store = useSession()
  const [pendingKind, setPendingKind] = useState<string | null>(null)
  const [compact, setCompact] = useState(() => remembered('loki.compact') === 'true')
  const [theme, setTheme] = useState<Theme>(
    () => (remembered('loki.theme') as Theme | null) ?? 'system',
  )
  const [wide, setWide] = useState(() => window.matchMedia(WIDE).matches)
  const [sheetTab, setSheetTab] = useState('palette')
  const [sheetHeight, setSheetHeight] = useState<SheetHeight>('peek')

  useEffect(() => {
    const media = window.matchMedia(WIDE)
    const listen = (e: MediaQueryListEvent) => setWide(e.matches)
    media.addEventListener('change', listen)
    return () => media.removeEventListener('change', listen)
  }, [])

  useEffect(() => {
    if (theme === 'system') document.documentElement.removeAttribute('data-theme')
    else document.documentElement.setAttribute('data-theme', theme)
    remember('loki.theme', theme)
  }, [theme])

  useEffect(() => remember('loki.compact', String(compact)), [compact])

  // Arming a kind from the palette gets the sheet out of the way: it covers the
  // lower half of the canvas, and being unable to reach the place you meant to
  // tap is a dead end rather than a nuisance.
  useEffect(() => {
    if (pendingKind !== null && !wide) setSheetHeight('peek')
  }, [pendingKind, wide])

  // Opening a port's panels is what a "watched" node means to the engine, so
  // the sheet follows it on a phone.
  useEffect(() => {
    if (store.watched !== null && !wide) {
      setSheetTab('diagnostics')
      setSheetHeight('half')
    }
  }, [store.watched, wide])

  const watchedNode = store.graph?.nodes.find((n) => n.id === store.watched?.id) ?? null

  const canvas = (
    <Canvas
      store={store}
      compact={compact}
      pendingKind={pendingKind}
      onPlaced={() => setPendingKind(null)}
    />
  )
  const palette = (
    <Palette kinds={store.kinds} pendingKind={pendingKind} onPick={setPendingKind} />
  )
  const inspector = <Inspector store={store} />
  const diagnostics = <Diagnostics watched={store.watched} node={watchedNode} />
  const table = <TablePreview watched={store.watched} />

  if (store.loading) {
    return (
      <div className="loading">
        <p>Opening the session…</p>
      </div>
    )
  }

  return (
    <div className={`app${wide ? '' : ' app--narrow'}`}>
      <SessionBar
        store={store}
        compact={compact}
        onCompact={setCompact}
        theme={theme}
        onTheme={setTheme}
        onMenu={() => {
          setSheetTab('palette')
          setSheetHeight(sheetHeight === 'peek' ? 'half' : 'peek')
        }}
      />

      {wide ? (
        <>
          <aside className="region region--palette">{palette}</aside>
          <main className="region region--canvas">{canvas}</main>
          <section className="region region--panels">
            <Tabs
              tabs={[
                { id: 'diagnostics', label: 'Diagnostics', content: diagnostics },
                { id: 'table', label: 'Table', content: table },
              ]}
            />
          </section>
          <aside className="region region--inspector">{inspector}</aside>
        </>
      ) : (
        <>
          <main className="region region--canvas">{canvas}</main>
          <BottomSheet
            tabs={[
              { id: 'palette', label: 'Nodes', content: palette },
              { id: 'inspector', label: 'Inspector', content: inspector },
              { id: 'diagnostics', label: 'Diagnostics', content: diagnostics },
              { id: 'table', label: 'Table', content: table },
            ]}
            active={sheetTab}
            onActive={setSheetTab}
            height={sheetHeight}
            onHeight={setSheetHeight}
          />
        </>
      )}

      <div className="notices" role="status" aria-live="polite">
        {store.notices.map((notice) => (
          <p key={notice.id} className={`notice notice--${notice.tone}`}>
            {notice.text}
          </p>
        ))}
      </div>
    </div>
  )
}

function Tabs({
  tabs,
}: {
  tabs: { id: string; label: string; content: React.ReactNode }[]
}) {
  const [active, setActive] = useState(tabs[0].id)
  const current = tabs.find((t) => t.id === active) ?? tabs[0]
  return (
    <div className="tabs">
      <div className="tabs__strip" role="tablist">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={tab.id === current.id}
            className={`tab${tab.id === current.id ? ' tab--on' : ''}`}
            data-testid={`panel-tab-${tab.id}`}
            onClick={() => setActive(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>
      <div className="tabs__body">{current.content}</div>
    </div>
  )
}

// Per-viewer conveniences only. Anything that matters is session state on the
// server, which is what makes a phone and a desktop see the same analysis.
function remembered(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function remember(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    // Private browsing, blocked site data: a remembered preference is not worth
    // an error.
  }
}
