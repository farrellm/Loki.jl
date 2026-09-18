import { useEffect, useRef } from 'react'
import type Plotly from 'plotly.js-dist-min'

// Plotly is 1.4MB gzipped and the canvas is not. It is imported on first use
// rather than on load, so the graph is interactive before a chart library the
// user may never open has finished downloading — which is the difference
// between usable and not on a phone over cellular.
let plotly: typeof Plotly | null = null
async function library(): Promise<typeof Plotly> {
  plotly ??= (await import('plotly.js-dist-min')).default
  return plotly
}

// Every chart goes through here, so the theme and the touch configuration are
// written once. Plotly is configured for a finger: pan and pinch-zoom, readouts
// that do not need a hover, and no mode bar to miss.

// `plotly.js-dist-min` ships types for the module but not for a trace, so a
// trace is described here rather than reached for through the namespace.
export type Trace = Record<string, unknown>

export interface PlotSpec {
  data: Trace[]
  layout?: Partial<Plotly.Layout>
}

// Plotly cannot read a CSS custom property, so the tokens are resolved to real
// colours here and handed to the trace builders. One place, so a chart is never
// a different green from the node rail beside it.
export interface Palette {
  ink: string
  quiet: string
  rule: string
  signal: string
  alarm: string
  ahead: string
  band: string
}

export function palette(): Palette {
  const style = getComputedStyle(document.documentElement)
  const token = (name: string, fallback: string) =>
    style.getPropertyValue(name).trim() || fallback
  return {
    ink: token('--ink', '#17201f'),
    quiet: token('--ink-quiet', '#5b6663'),
    rule: token('--rule', '#c5cdc9'),
    signal: token('--signal', '#1d6b57'),
    alarm: token('--alarm', '#a93a2e'),
    ahead: token('--ahead', '#6e5aa3'),
    // `color-mix` does not resolve through `getPropertyValue`, so the band is a
    // literal neutral that works on either background.
    band: 'rgba(125, 135, 132, 0.18)',
  }
}

function themed(): Partial<Plotly.Layout> {
  const style = getComputedStyle(document.documentElement)
  const { ink, rule } = palette()
  return {
    paper_bgcolor: 'transparent',
    plot_bgcolor: 'transparent',
    font: { family: style.getPropertyValue('--ui').trim(), size: 12, color: ink },
    margin: { l: 48, r: 12, t: 18, b: 34 },
    xaxis: { gridcolor: rule, zerolinecolor: rule, linecolor: rule },
    yaxis: { gridcolor: rule, zerolinecolor: rule, linecolor: rule },
    hovermode: 'x unified',
    showlegend: false,
    dragmode: 'pan',
  }
}

export function Plot({ spec, height = 200, label }: {
  spec: PlotSpec
  height?: number
  label: string
}) {
  const host = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const element = host.current
    if (element === null) return
    let live = true
    void library().then((P) => {
      if (!live) return
      void P.react(element, spec.data as never, { ...themed(), ...spec.layout }, {
        displayModeBar: false,
        responsive: true,
        scrollZoom: true,
        // Pinch-zoom and drag-to-pan both reach the plot rather than the page.
        doubleClick: 'reset',
      })
    })
    return () => {
      live = false
      plotly?.purge(element)
    }
  }, [spec])

  return (
    <div
      className="plot"
      ref={host}
      style={{ height }}
      role="img"
      aria-label={label}
      data-testid="plot"
    />
  )
}

export function seriesTraces(data: Record<string, any>): PlotSpec {
  const p = palette()
  // The actual series in ink, anything fitted or derived in the signal colour
  // and dotted: the difference between what was measured and what was modelled
  // should not need a legend.
  const colours = [p.ink, p.signal, p.ahead, p.alarm]
  return {
    data: (data.series ?? []).map((trace: any, i: number) => ({
      type: 'scattergl',
      mode: 'lines',
      name: trace.name,
      x: trace.time,
      y: trace.values,
      line: {
        width: i === 0 ? 1.4 : 1.2,
        dash: i === 0 ? 'solid' : 'dot',
        color: colours[i % colours.length],
      },
      connectgaps: false,
    })),
    layout: { showlegend: (data.series ?? []).length > 1, legend: { orientation: 'h' } },
  }
}

// A correlogram is stems and a band — the most characteristic picture in this
// subject, and the reason the significance band is drawn as a shaded region
// rather than two stray lines.
export function correlogramTraces(data: Record<string, any>): PlotSpec {
  const lags: number[] = data.lags ?? []
  const values: (number | null)[] = data.values ?? []
  const band: number | null = data.band ?? null
  const p = palette()
  const stems: Trace[] = [
    {
      type: 'bar',
      x: lags,
      y: values,
      width: 0.12,
      // A lag outside the band is the thing being looked for, so it is the only
      // thing here that is not ink.
      marker: {
        color: values.map((v, i) =>
          band !== null && v !== null && lags[i] !== 0 && Math.abs(v) > band
            ? p.signal
            : p.ink,
        ),
      },
      hovertemplate: 'lag %{x}: %{y:.3f}<extra></extra>',
    } as Trace,
  ]
  const shapes =
    band === null
      ? []
      : [
          {
            type: 'rect' as const,
            xref: 'paper' as const,
            x0: 0,
            x1: 1,
            y0: -band,
            y1: band,
            fillcolor: p.band,
            line: { width: 0 },
            layer: 'below' as const,
          },
        ]
  return { data: stems, layout: { shapes, bargap: 0 } }
}

export function histogramTraces(data: Record<string, any>): PlotSpec {
  const p = palette()
  const edges: number[] = data.edges ?? []
  const centres = edges.slice(0, -1).map((e, i) => (e + edges[i + 1]) / 2)
  const traces: Trace[] = [
    {
      type: 'bar',
      x: centres,
      y: data.density ?? [],
      marker: { color: p.band },
      hovertemplate: '%{x:.3g}<extra></extra>',
    } as Trace,
  ]
  // The fitted normal is the reference the bars are read against, so it is the
  // line drawn over them rather than another bar colour.
  if (data.normal) {
    traces.push({
      type: 'scatter',
      mode: 'lines',
      x: data.normal.x,
      y: data.normal.pdf,
      line: { width: 1.5, color: p.signal },
    } as Trace)
  }
  return { data: traces, layout: { bargap: 0.02 } }
}

export function qqTraces(data: Record<string, any>): PlotSpec {
  const p = palette()
  const theoretical: number[] = data.theoretical ?? []
  const line = data.line
  const traces: Trace[] = [
    {
      type: 'scattergl',
      mode: 'markers',
      x: theoretical,
      y: data.sample ?? [],
      marker: { size: 4, color: p.ink, opacity: 0.55 },
    } as Trace,
  ]
  if (line && theoretical.length > 1) {
    const ends = [theoretical[0], theoretical[theoretical.length - 1]]
    traces.push({
      type: 'scatter',
      mode: 'lines',
      x: ends,
      y: ends.map((t) => line.intercept + line.slope * t),
      line: { width: 1, dash: 'dash', color: p.signal },
    } as Trace)
  }
  return { data: traces }
}

// The fan: the history, the mean, and a band per level, widening with the
// horizon. The hatch on a tainted node and this widening say the same thing —
// past here, you are not looking at what you know.
export function fanTraces(data: Record<string, any>): PlotSpec {
  const p = palette()
  const traces: Trace[] = []
  for (const interval of [...(data.intervals ?? [])].reverse()) {
    traces.push({
      type: 'scatter',
      mode: 'lines',
      x: [...data.time, ...[...data.time].reverse()],
      y: [...interval.upper, ...[...interval.lower].reverse()],
      fill: 'toself',
      fillcolor: p.band,
      line: { width: 0 },
      hoverinfo: 'skip',
    } as Trace)
  }
  traces.push({
    type: 'scatter',
    mode: 'lines',
    x: data.history?.time ?? [],
    y: data.history?.values ?? [],
    line: { width: 1.4, color: p.ink },
  } as Trace)
  traces.push({
    type: 'scatter',
    mode: 'lines',
    x: data.time ?? [],
    y: data.mean ?? [],
    line: { width: 1.6, dash: 'dot', color: p.signal },
  } as Trace)
  return { data: traces }
}
