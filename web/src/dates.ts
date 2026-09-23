// A `Date` as the contexts band edits it: eight digits, with the dashes of
// `YYYY-MM-DD` drawn in rather than typed, and the month grid a calendar lays
// those digits out on.

/** What an empty date field shows, and what is left of it once typing starts. */
export const SKELETON = 'YYYY-MM-DD'

const DIGITS = 8

const digitsOf = (text: string) => text.replace(/\D/g, '')

/** How many digits come before `pos` in `text`. */
const digitIndex = (text: string, pos: number) => digitsOf(text.slice(0, pos)).length

/** Where the caret goes after the `n`th digit of a formatted date. */
const caretAt = (n: number) => n + (n > 4 ? 1 : 0) + (n > 6 ? 1 : 0)

// A dash is written only once the group after it has started, so the text is
// always a prefix of a date: `2015`, `2015-0`, `2015-03-0`.
function format(d: string): string {
  if (d.length <= 4) return d
  if (d.length <= 6) return `${d.slice(0, 4)}-${d.slice(4)}`
  return `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6)}`
}

/**
 * One edit to a date field. `prev` is what it held, `next` and `caret` what
 * the browser made of the keystroke, paste or cut, and `inputType` the input
 * event's. The dashes cannot be typed or deleted: deleting one takes the digit
 * beyond it instead, and a digit typed into a full field overwrites the one
 * after the caret rather than pushing the last off the end.
 */
export function maskDate(
  prev: string,
  next: string,
  caret: number,
  inputType?: string,
): { text: string; caret: number } {
  let d = digitsOf(next)
  let at = digitIndex(next, caret)
  if (d === digitsOf(prev) && next.length < prev.length) {
    if (inputType === 'deleteContentForward') d = d.slice(0, at) + d.slice(at + 1)
    else if (at > 0) {
      d = d.slice(0, at - 1) + d.slice(at)
      at -= 1
    }
  }
  if (d.length > DIGITS) d = d.slice(0, at) + d.slice(at + d.length - DIGITS)
  d = d.slice(0, DIGITS)
  return { text: format(d), caret: caretAt(Math.min(at, d.length)) }
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
