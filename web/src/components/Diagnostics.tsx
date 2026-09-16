import { useCallback, useEffect, useState } from 'react'
import {
  Plot,
  correlogramTraces,
  fanTraces,
  histogramTraces,
  qqTraces,
  seriesTraces,
} from './Plot'
import { api } from '../api'
import type { Diagnostic, GraphNode, Watched } from '../types'

// Diagnostics are whole-window analyses of a node's loaded frame. The residual
// panel is the one that matters most: it is the Box-Jenkins identification loop
// in one view, so changing an order and looking again is a glance rather than
// six separate questions.

const VIEWS = ['series', 'acf', 'pacf', 'distribution', 'stationarity', 'residuals',
  'forecast', 'fit'] as const
type View = (typeof VIEWS)[number]

export function Diagnostics({
  watched,
  node,
}: {
  watched: Watched | null
  node: GraphNode | null
}) {
  const [view, setView] = useState<View>('series')
  const [column, setColumn] = useState<string>('')
  const [result, setResult] = useState<Diagnostic | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const shape = watched && node ? node.results[watched.port] : undefined
  const columns = (shape?.columns ?? []).filter((c) => c !== 'time')

  useEffect(() => {
    if (column === '' && columns.length > 0) setColumn(columns[0])
    if (column !== '' && columns.length > 0 && !columns.includes(column)) {
      setColumn(columns[0])
    }
  }, [columns, column])

  // A residual column means there is a fit here, so open on the panel that
  // answers the question the fit was asked.
  useEffect(() => {
    const residual = columns.find((c) => c.endsWith('_residual'))
    if (residual !== undefined) {
      setView('residuals')
      setColumn(residual)
    }
  }, [watched?.id, watched?.port])

  const load = useCallback(async () => {
    if (watched === null || column === '') return
    setBusy(true)
    setProblem(null)
    try {
      setResult(await api.diagnostic(watched.id, watched.port, kindOf(view), { column }))
    } catch (error) {
      setResult(null)
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }, [watched, column, view])

  useEffect(() => {
    void load()
  }, [load])

  if (watched === null || node === null) {
    return (
      <div className="diagnostics diagnostics--none">
        <p>Run a node and inspect a port to see its diagnostics.</p>
      </div>
    )
  }

  return (
    <div className="diagnostics" data-testid="diagnostics">
      <div className="diagnostics__bar">
        <div className="diagnostics__views" role="tablist">
          {VIEWS.map((v) => (
            <button
              key={v}
              type="button"
              role="tab"
              aria-selected={view === v}
              className={`tab${view === v ? ' tab--on' : ''}`}
              onClick={() => setView(v)}
              data-testid={`view-${v}`}
            >
              {LABELS[v]}
            </button>
          ))}
        </div>
        <label className="diagnostics__column">
          <span className="visually-hidden">Column</span>
          <select
            className="mono"
            value={column}
            onChange={(e) => setColumn(e.target.value)}
            data-testid="diagnostic-column"
          >
            {columns.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </label>
      </div>

      {problem !== null && (
        <p className="problem__message" role="alert">
          {problem}
        </p>
      )}
      {busy && result === null && <p className="diagnostics__busy">Computing…</p>}
      {result !== null && <Panel result={result} view={view} />}
    </div>
  )
}

const LABELS: Record<View, string> = {
  series: 'Series',
  acf: 'ACF',
  pacf: 'PACF',
  distribution: 'Distribution',
  stationarity: 'Stationarity',
  residuals: 'Residuals',
  forecast: 'Forecast',
  fit: 'Fit',
}

function kindOf(view: View): string {
  return view === 'distribution'
    ? 'histogram'
    : view === 'stationarity'
      ? 'adf'
      : view
}

function Panel({ result, view }: { result: Diagnostic; view: View }) {
  return (
    <div className="panel">
      <Warnings warnings={result.warnings} />
      {view === 'residuals' ? (
        <ResidualPanel result={result} />
      ) : (
        <>
          <Chart result={result} />
          <Numbers summary={result.summary} />
        </>
      )}
    </div>
  )
}

function Warnings({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return (
    <ul className="warnings">
      {warnings.map((w, i) => (
        <li key={i}>{w}</li>
      ))}
    </ul>
  )
}

function Chart({ result, height }: { result: Diagnostic; height?: number }) {
  switch (result.kind) {
    case 'seriesplot':
      return <Plot spec={seriesTraces(result.data)} height={height} label="Series" />
    case 'acf':
    case 'pacf':
      return (
        <Plot
          spec={correlogramTraces(result.data)}
          height={height}
          label={`${result.kind.toUpperCase()} with its significance band`}
        />
      )
    case 'histogram':
      return (
        <Plot
          spec={histogramTraces(result.data)}
          height={height}
          label="Distribution against a fitted normal"
        />
      )
    case 'qqplot':
      return <Plot spec={qqTraces(result.data)} height={height} label="Normal QQ plot" />
    case 'forecastfan':
      return (
        <Plot spec={fanTraces(result.data)} height={height} label="Forecast fan" />
      )
    default:
      return null
  }
}

// The identification loop in one view: residuals over time, fitted against
// actual, the correlogram, the tests, and the distribution.
function ResidualPanel({ result }: { result: Diagnostic }) {
  const panels = result.panels ?? {}
  const verdict = result.summary.whitenoise
  return (
    <div className="residuals">
      <p className="verdict">
        {verdict === true
          ? 'What is left looks like white noise.'
          : verdict === false
            ? 'What is left is still autocorrelated — try different orders.'
            : 'Not enough rows to judge the residuals.'}
      </p>
      <div className="residuals__grid">
        {(['fitted', 'series', 'acf', 'pacf', 'histogram', 'qqplot'] as const).map(
          (name) =>
            panels[name] ? (
              <figure key={name} className="residuals__cell">
                <figcaption>{RESIDUAL_LABELS[name]}</figcaption>
                <Chart result={panels[name]} height={160} />
              </figure>
            ) : null,
        )}
      </div>
      {panels.ljungbox && <LjungBox result={panels.ljungbox} />}
      <Numbers summary={result.summary} />
    </div>
  )
}

const RESIDUAL_LABELS: Record<string, string> = {
  fitted: 'Fitted over actual',
  series: 'Residuals over time',
  acf: 'Residual ACF',
  pacf: 'Residual PACF',
  histogram: 'Residual distribution',
  qqplot: 'Residual QQ',
}

function LjungBox({ result }: { result: Diagnostic }) {
  const tests = result.data.tests ?? []
  if (tests.length === 0) return null
  return (
    <table className="numbers">
      <caption>Ljung–Box, giving up {result.summary.dof} degrees of freedom</caption>
      <thead>
        <tr>
          <th scope="col">Lags</th>
          <th scope="col">Statistic</th>
          <th scope="col">p</th>
        </tr>
      </thead>
      <tbody>
        {tests.map((test: any) => (
          <tr key={test.lags}>
            <td className="num">{test.lags}</td>
            <td className="num">{format(test.statistic)}</td>
            <td className="num">{format(test.pvalue)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function Numbers({ summary }: { summary: Record<string, any> }) {
  const scalars = Object.entries(summary).filter(
    ([, v]) => v === null || typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean',
  )
  if (scalars.length === 0) return null
  return (
    <dl className="summary">
      {scalars.map(([key, value]) => (
        <div key={key}>
          <dt>{key}</dt>
          <dd className="num">{format(value)}</dd>
        </div>
      ))}
    </dl>
  )
}

function format(value: unknown): string {
  if (value === null || value === undefined) return '—'
  if (typeof value === 'boolean') return value ? 'yes' : 'no'
  if (typeof value === 'number') {
    if (Number.isInteger(value)) return value.toLocaleString()
    return Math.abs(value) < 0.001 || Math.abs(value) >= 1e6
      ? value.toExponential(3)
      : value.toFixed(4)
  }
  return String(value)
}
