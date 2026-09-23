import { useLayoutEffect, useRef } from 'react'
import { maskDate, SKELETON } from '../dates'

// One end of a `Date` context, typed as digits. The whole `YYYY-MM-DD` is
// always there: what has been typed in ink, and the rest of the skeleton faint
// behind the input, lined up character for character in the monospace face.
// The dashes belong to the skeleton, so they are never typed and cannot be
// deleted — see `maskDate`.

export function DateField({
  value,
  onChange,
  autoFocus,
  testid,
}: {
  value: string
  onChange: (text: string) => void
  autoFocus?: boolean
  testid: string
}) {
  const input = useRef<HTMLInputElement>(null)
  // The mask moves the caret when it writes or skips a dash; React's re-render
  // would otherwise put it at the end.
  const caret = useRef<number | null>(null)
  useLayoutEffect(() => {
    if (caret.current === null || input.current !== document.activeElement) return
    input.current?.setSelectionRange(caret.current, caret.current)
    caret.current = null
  })

  return (
    <span className="datefield">
      <span className="datefield__skeleton mono" aria-hidden="true">
        <span className="datefield__typed">{value}</span>
        {SKELETON.slice(value.length)}
      </span>
      <input
        ref={input}
        className="mono"
        value={value}
        inputMode="numeric"
        autoFocus={autoFocus}
        autoComplete="off"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        data-testid={testid}
        onChange={(e) => {
          const el = e.target
          const next = maskDate(
            value,
            el.value,
            el.selectionStart ?? el.value.length,
            (e.nativeEvent as InputEvent).inputType,
          )
          caret.current = next.caret
          onChange(next.text)
        }}
      />
    </span>
  )
}
