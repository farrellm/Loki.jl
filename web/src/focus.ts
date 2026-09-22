// The bands that hang off the session bar — the file picker, the contexts — are
// modal, so Tab stays inside them.

export function trapTab(e: React.KeyboardEvent, band: HTMLElement | null) {
  if (band === null) return
  const focusable = [
    ...band.querySelectorAll<HTMLElement>(
      'button:not(:disabled), input:not(:disabled), select:not(:disabled)',
    ),
  ]
  if (focusable.length === 0) return
  const first = focusable[0]
  const last = focusable[focusable.length - 1]
  if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  } else if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  }
}
