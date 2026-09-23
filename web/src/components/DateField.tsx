import { useLayoutEffect, useRef } from 'react'
import { maskDate, skeletonRest, type Mask } from '../dates'

// One end of a `Date` or `DateTime` context, typed as digits. The whole
// `YYYY-MM-DD` or `YYYY-MM-DDThh:mm:ss` is always there: what has been typed in
// ink, and the rest of the skeleton faint behind the input, lined up character
// for character in the monospace face. The separators belong to the skeleton,
// so they are never typed and cannot be deleted — see `maskDate`.

export function DateField({
  mask,
  value,
  onChange,
  onFocus,
  active,
  autoFocus,
  testid,
}: {
  mask: Mask
  value: string
  onChange: (text: string) => void
  onFocus: () => void
  /** The end the calendar below is setting. */
  active: boolean
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
    <span className={`datefield${active ? ' datefield--active' : ''}`}>
      <span className="datefield__skeleton mono" aria-hidden="true">
        <span className="datefield__typed">{value}</span>
        {skeletonRest(mask, value)}
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
        onFocus={onFocus}
        onChange={(e) => {
          const el = e.target
          const next = maskDate(
            value,
            el.value,
            el.selectionStart ?? el.value.length,
            (e.nativeEvent as InputEvent).inputType,
            mask,
          )
          caret.current = next.caret
          onChange(next.text)
        }}
      />
    </span>
  )
}
