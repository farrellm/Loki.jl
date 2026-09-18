import { useState } from 'react'
import { api } from '../api'
import type { SessionStore } from '../store'

// The session bar: what window you are looking at, what is running, and the one
// piece of motion in the whole app — a line that sweeps while a run is in
// flight. Everything else here is still.

export function SessionBar({
  store,
  compact,
  onCompact,
  theme,
  onTheme,
  onMenu,
}: {
  store: SessionStore
  compact: boolean
  onCompact: (compact: boolean) => void
  theme: 'system' | 'light' | 'dark'
  onTheme: (theme: 'system' | 'light' | 'dark') => void
  onMenu: () => void
}) {
  const { graph, connected, running, lastOrigin, act, note } = store
  const [busy, setBusy] = useState(false)
  const analysis = graph?.contexts.analysis

  const exportScript = async () => {
    setBusy(true)
    try {
      const text = await api.exportScript()
      const url = URL.createObjectURL(new Blob([text], { type: 'text/x-julia' }))
      const link = document.createElement('a')
      link.href = url
      link.download = 'analysis.jl'
      // Attached and revoked a turn later: WebKit cancels a download whose blob
      // URL is revoked in the same task as the click, and Firefox ignores a
      // click on an anchor that is not in the document.
      document.body.append(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 0)
      note('Exported analysis.jl')
    } catch (error) {
      note(error instanceof Error ? error.message : String(error), 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <header className="bar" data-testid="session-bar">
      {running && <span className="bar__sweep" aria-hidden="true" />}
      <button type="button" className="bar__menu quiet" onClick={onMenu} aria-label="Menu">
        ≡
      </button>
      <span className="bar__name">Loki</span>
      {analysis && (
        <span className="bar__window mono" title="The window nodes are evaluated over">
          {String(analysis.start)} → {String(analysis.stop)}
        </span>
      )}

      <div className="bar__actions">
        <button
          type="button"
          className="primary"
          disabled={running}
          onClick={() => void act('Could not run', () => api.run(runTargets(store)))}
          data-testid="run"
        >
          Run
        </button>
        <button
          type="button"
          disabled={!running}
          onClick={() => void act('Could not cancel', () => api.cancel())}
        >
          Cancel run
        </button>
        <button type="button" disabled={busy} onClick={exportScript} data-testid="export">
          Export script
        </button>
      </div>

      <div className="bar__toggles">
        <label className="toggle">
          <input
            type="checkbox"
            checked={compact}
            onChange={(e) => onCompact(e.target.checked)}
          />
          <span>Compact nodes</span>
        </label>
        <select
          aria-label="Theme"
          value={theme}
          onChange={(e) => onTheme(e.target.value as 'system' | 'light' | 'dark')}
        >
          <option value="system">Match the system</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </div>

      <span className="bar__state">
        {!connected && <span className="bar__reconnect">Reconnecting…</span>}
        {connected && lastOrigin === 'mcp' && (
          <span className="bar__origin" title="The agent made the last change">
            changed by the agent
          </span>
        )}
      </span>
    </header>
  )
}

// With nothing selected, run every port nothing else reads — the sinks, which is
// what the exporter defaults to as well.
function runTargets(store: SessionStore): string[] {
  const graph = store.graph
  if (graph === null) return []
  if (store.selected !== null) return [store.selected]
  const read = new Set(graph.edges.map((e) => e.from[0]))
  const sinks = graph.nodes.filter((n) => !read.has(n.id)).map((n) => n.id)
  return sinks.length > 0 ? sinks : graph.nodes.map((n) => n.id)
}
