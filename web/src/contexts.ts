import type { ContextSpec, GraphNode, NodeKind, TableSpec } from './types'

// Named contexts as the browser edits them: text in two fields, checked here
// before it goes anywhere, because `PUT /api/contexts/:name` only learns that
// "2015-13-01" is not a date by failing to build a `Context` from it.

/** The time types a session file can store, and so the ones worth offering. */
export const TIMETYPES = ['Int64', 'Float64', 'Date', 'DateTime'] as const
export type TimeType = (typeof TIMETYPES)[number]

export const PLACEHOLDERS: Record<TimeType, [string, string]> = {
  Int64: ['0', '1000'],
  Float64: ['0.0', '1.0'],
  Date: ['2015-01-01', '2026-01-01'],
  DateTime: ['2015-01-01T00:00:00', '2026-01-01T00:00:00'],
}

/** A time as the server wants it, and where it falls on an axis. */
export interface Parsed {
  value: number | string
  axis: number
}

const INTEGER = /^-?\d+$/
const REAL = /^-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/
const DATETIME = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$/

/** Parse one end of a window, or `null` if it is not a `timetype`. */
export function parseTime(timetype: string, text: string): Parsed | null {
  const t = text.trim()
  if (timetype === 'Int64') {
    if (!INTEGER.test(t)) return null
    const n = Number(t)
    return Number.isSafeInteger(n) ? { value: n, axis: n } : null
  }
  if (timetype === 'Float64') {
    if (!REAL.test(t)) return null
    const n = Number(t)
    return Number.isFinite(n) ? { value: n, axis: n } : null
  }
  if (timetype === 'Date') {
    const m = DATE.exec(t)
    if (m === null) return null
    const axis = utc(+m[1], +m[2], +m[3], 0, 0, 0, 0)
    return axis === null ? null : { value: t, axis }
  }
  if (timetype === 'DateTime') {
    const m = DATETIME.exec(t)
    if (m === null) return null
    const ms = m[7] === undefined ? 0 : Number(m[7].padEnd(3, '0'))
    const axis = utc(+m[1], +m[2], +m[3], +m[4], +m[5], +(m[6] ?? 0), ms)
    return axis === null ? null : { value: t, axis }
  }
  return null
}

// `Date.UTC` rolls 2015-02-30 over into March; Julia refuses it, so we do too.
function utc(
  y: number,
  mo: number,
  d: number,
  h: number,
  mi: number,
  s: number,
  ms: number,
) {
  if (h > 23 || mi > 59 || s > 59) return null
  const axis = Date.UTC(y, mo - 1, d, h, mi, s, ms)
  const back = new Date(axis)
  return back.getUTCFullYear() === y &&
    back.getUTCMonth() === mo - 1 &&
    back.getUTCDate() === d
    ? axis
    : null
}

/** Where a context the server sent falls on an axis, if its type has one. */
export function span(ctx: ContextSpec): [number, number] | null {
  const start = parseTime(ctx.timetype, String(ctx.start))
  const stop = parseTime(ctx.timetype, String(ctx.stop))
  return start === null || stop === null ? null : [start.axis, stop.axis]
}

// The exporter writes each context as a `const` binding, so a name that is not
// a Julia identifier saves and runs but cannot be exported.
const IDENTIFIER = /^[\p{L}_][\p{L}\p{N}_!]*$/u

export interface Draft {
  name: string
  timetype: string
  start: string
  stop: string
}

export type Checked =
  | { ok: true; start: Parsed; stop: Parsed }
  | { ok: false; problem: string; start: Parsed | null; stop: Parsed | null }

const article = (word: string) => (/^[AEIOU]/i.test(word) ? `an ${word}` : `a ${word}`)

/**
 * Check a draft before it is sent. `taken` holds the names already in use,
 * which a new context may not reuse — `PUT` would quietly replace it.
 */
export function check(draft: Draft, taken: string[] = []): Checked {
  const start = parseTime(draft.timetype, draft.start)
  const stop = parseTime(draft.timetype, draft.stop)
  const fail = (problem: string): Checked => ({ ok: false, problem, start, stop })
  const name = draft.name.trim()
  if (name === '') return fail('Give the context a name.')
  if (!IDENTIFIER.test(name)) {
    return fail(
      `${name} is not a Julia name. Use letters, digits and underscores, starting with a letter.`,
    )
  }
  if (taken.includes(name))
    return fail(`${name} already exists. Pick it above to change it.`)
  const example = PLACEHOLDERS[draft.timetype as TimeType]?.[0]
  const expected = `${article(draft.timetype)}${example ? `, such as ${example}` : ''}`
  if (start === null) return fail(`The start is not ${expected}.`)
  if (stop === null) return fail(`The stop is not ${expected}.`)
  if (start.axis > stop.axis) return fail('The start comes after the stop.')
  return { ok: true, start, stop }
}

/**
 * The time type a new context should start with: the one the session already
 * uses, since a context has to match its sources' time type. With no context
 * yet, a table's `time` column is the best guess there is.
 */
export function defaultTimetype(
  contexts: Record<string, ContextSpec>,
  tables: TableSpec[] = [],
): TimeType {
  const known = (t: string | undefined): t is TimeType =>
    (TIMETYPES as readonly string[]).includes(t ?? '')
  const existing = contexts.analysis?.timetype ?? Object.values(contexts)[0]?.timetype
  if (known(existing)) return existing
  for (const table of tables) {
    const type = table.types[table.columns.indexOf('time')]
    if (known(type)) return type
  }
  return 'Int64'
}

/**
 * The names in the order the band lists them: `analysis` first, because it is
 * the one runs use, then the rest by where they start, then by name.
 */
export function ordered(contexts: Record<string, ContextSpec>): string[] {
  const start = (name: string) => span(contexts[name])?.[0] ?? Infinity
  return Object.keys(contexts).sort((a, b) => {
    if (a === 'analysis' || b === 'analysis') return a === 'analysis' ? -1 : 1
    return start(a) - start(b) || a.localeCompare(b)
  })
}

/** The extent of a set of spans, widened so a zero-length one still has a width. */
export function extent(spans: [number, number][]): [number, number] | null {
  if (spans.length === 0) return null
  let lo = Math.min(...spans.map((s) => s[0]))
  let hi = Math.max(...spans.map((s) => s[1]))
  if (lo === hi) {
    lo -= 1
    hi += 1
  }
  return [lo, hi]
}

/**
 * The nodes whose parameters name the context `name` — those the kind's schema
 * marks as a context picker. Removing the context breaks them, so the band says
 * which they are first.
 */
export function usedBy(name: string, nodes: GraphNode[], kinds: NodeKind[]): string[] {
  const byName = new Map(kinds.map((k) => [k.name, k]))
  return nodes
    .filter((node) => {
      const props = byName.get(node.kind)?.paramschema.properties ?? {}
      return Object.entries(props).some(
        ([param, schema]) =>
          schema['x-loki'] === 'context' && node.params[param] === name,
      )
    })
    .map((node) => node.id)
}
