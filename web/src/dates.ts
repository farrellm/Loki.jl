// A `Date` or `DateTime` as the contexts band edits it: digits, with the
// separators of `YYYY-MM-DDThh:mm:ss` drawn in rather than typed, and the month
// grid a calendar lays those digits out on.

/** How a time type's digits are grouped, and what separates the groups. */
export interface Mask {
  groups: number[]
  seps: string[]
  /** How many digits make a complete value; more may follow at the end. */
  full: number
  /** What an empty field shows. Past `full` digits, the rest of it appears. */
  skeleton: string
}

export const DATE_MASK: Mask = {
  groups: [4, 2, 2],
  seps: ['-', '-'],
  full: 8,
  skeleton: 'YYYY-MM-DD',
}

// Seconds are complete; milliseconds are there for a value that has them, and
// are drawn only once they are typed into.
export const DATETIME_MASK: Mask = {
  groups: [4, 2, 2, 2, 2, 2, 3],
  seps: ['-', '-', 'T', ':', ':', '.'],
  full: 14,
  skeleton: 'YYYY-MM-DDThh:mm:ss.sss',
}

/** The mask a time type is typed through, if it has one. */
export function maskFor(timetype: string): Mask | null {
  if (timetype === 'Date') return DATE_MASK
  if (timetype === 'DateTime') return DATETIME_MASK
  return null
}

const maxDigits = (mask: Mask) => mask.groups.reduce((a, b) => a + b, 0)

const digitsOf = (text: string) => text.replace(/\D/g, '')

/** How many digits come before `pos` in `text`. */
const digitIndex = (text: string, pos: number) => digitsOf(text.slice(0, pos)).length

// A separator is written only once the group after it has started, so the text
// is always a prefix of a value: `2015`, `2015-0`, `2015-03-01T0`.
function format(mask: Mask, d: string): string {
  let out = ''
  let at = 0
  mask.groups.forEach((size, i) => {
    if (at >= d.length) return
    if (i > 0) out += mask.seps[i - 1]
    out += d.slice(at, at + size)
    at += size
  })
  return out
}

/** Where the caret goes after the `n`th digit. */
function caretAt(mask: Mask, n: number): number {
  let seps = 0
  let edge = 0
  for (const size of mask.groups.slice(0, -1)) {
    edge += size
    if (n > edge) seps += 1
  }
  return n + seps
}

/** What the field draws faint after the text typed so far. */
export function skeletonRest(mask: Mask, text: string): string {
  const complete = format(mask, '0'.repeat(mask.full)).length
  const shown = text.length > complete ? mask.skeleton : mask.skeleton.slice(0, complete)
  return shown.slice(text.length)
}

/**
 * One edit to a masked field. `prev` is what it held, `next` and `caret` what
 * the browser made of the keystroke, paste or cut, and `inputType` the input
 * event's. The separators cannot be typed or deleted: deleting one takes the
 * digit beyond it instead. A digit typed into a complete value overwrites the
 * one after the caret rather than pushing the rest along, except at the end,
 * where a `DateTime` goes on into milliseconds.
 */
export function maskDate(
  prev: string,
  next: string,
  caret: number,
  inputType?: string,
  mask: Mask = DATE_MASK,
): { text: string; caret: number } {
  const before = digitsOf(prev)
  const max = maxDigits(mask)
  let d = digitsOf(next)
  let at = digitIndex(next, caret)
  if (d === before && next.length < prev.length) {
    if (inputType === 'deleteContentForward') d = d.slice(0, at) + d.slice(at + 1)
    else if (at > 0) {
      d = d.slice(0, at - 1) + d.slice(at)
      at -= 1
    }
  }
  const inserted = d.length - before.length
  if (inserted > 0 && before.length >= mask.full && at < d.length) {
    d = d.slice(0, at) + d.slice(at + inserted)
  }
  if (d.length > max) d = d.slice(0, at) + d.slice(at + d.length - max)
  d = d.slice(0, max)
  return { text: format(mask, d), caret: caretAt(mask, Math.min(at, d.length)) }
}

/** A month: `m` runs from 1 to 12. */
export interface Month {
  y: number
  m: number
}

/**
 * The month a partly typed date points at: a year once it has four digits, and
 * a month too once it has six. `m` is `null` when only the year is known.
 */
export function viewOf(text: string): { y: number; m: number | null } | null {
  const d = digitsOf(text)
  if (d.length < 4) return null
  const y = Math.max(1, +d.slice(0, 4))
  if (d.length < 6) return { y, m: null }
  return { y, m: Math.min(12, Math.max(1, +d.slice(4, 6))) }
}

export function addMonths({ y, m }: Month, k: number): Month {
  const n = Math.min(Math.max(y * 12 + (m - 1) + k, 12), 9999 * 12 + 11)
  return { y: Math.floor(n / 12), m: (n % 12) + 1 }
}

// `Date.UTC` reads years 0–99 as 1900–1999; `setUTCFullYear` does not.
function utcDate(y: number, m: number, d: number): Date {
  const date = new Date(0)
  date.setUTCFullYear(y, m - 1, d)
  return date
}

export const iso = (y: number, m: number, d: number) =>
  `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`

/** The day `k` days after the ISO date `day`. */
export function addDays(day: string, k: number): string {
  const [y, m, d] = day.split('-').map(Number)
  const date = utcDate(y, m, d + k)
  return iso(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate())
}

/**
 * The weeks of a month, Monday first as ISO and Julia's `dayofweek` count
 * them, with `null` for the days that belong to the months either side.
 */
export function monthGrid({ y, m }: Month): (number | null)[][] {
  const lead = (utcDate(y, m, 1).getUTCDay() + 6) % 7
  const days = utcDate(y, m + 1, 0).getUTCDate()
  const cells: (number | null)[] = [
    ...Array<null>(lead).fill(null),
    ...Array.from({ length: days }, (_, i) => i + 1),
  ]
  while (cells.length % 7 !== 0) cells.push(null)
  return Array.from({ length: cells.length / 7 }, (_, w) => cells.slice(w * 7, w * 7 + 7))
}

export const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]
