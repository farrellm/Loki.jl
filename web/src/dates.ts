// A `Date` as the contexts band edits it: eight digits, with the dashes of
// `YYYY-MM-DD` drawn in rather than typed.

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
