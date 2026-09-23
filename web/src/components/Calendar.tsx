import { useEffect, useRef, useState } from 'react'
import { parseTime } from '../contexts'
import { addDays, addMonths, iso, monthGrid, MONTHS, viewOf, type Month } from '../dates'

// The calendar under a `Date` context's start and stop. One month, and across
// it the window drawn the way the timeline above draws it — a line with a tick
// at each end — under the dates rather than through them, so how long the
// window is and where it stops are seen along with the day being picked.
//
// It is one calendar for both ends: a day sets whichever end is active, which
// is the field last focused. Typing a date moves it to that month, so years
// away is four keystrokes, not forty taps.

const WEEKDAYS = [
  ['Mo', 'Monday'],
  ['Tu', 'Tuesday'],
  ['We', 'Wednesday'],
  ['Th', 'Thursday'],
  ['Fr', 'Friday'],
  ['Sa', 'Saturday'],
  ['Su', 'Sunday'],
]

const monthOf = (day: string): Month => {
  const [y, m] = day.split('-').map(Number)
  return { y, m }
}

export function Calendar({
  start,
  stop,
  end,
  onPick,
}: {
  /** The two ends as typed, which may be partial. */
  start: string
  stop: string
  end: 'start' | 'stop'
  onPick: (day: string) => void
}) {
  const active = end === 'start' ? start : stop
  const other = end === 'start' ? stop : start
  const follow = viewOf(active) ?? viewOf(other) ?? { y: 2015, m: 1 }
  const [view, setView] = useState<Month>({ y: follow.y, m: follow.m ?? 1 })
  // The day that takes Tab into the grid, and that the arrow keys move.
  const [cursor, setCursor] = useState<string | null>(null)
  const grid = useRef<HTMLTableElement>(null)
  const refocus = useRef(false)
  const picked = useRef(false)

  // Follow the active end as it is typed, or when another field takes over. A
  // pick hands the calendar to the stop, but the month stays where the finger
  // was rather than jumping to wherever the stop happens to be.
  const { y: fy, m: fm } = follow
  useEffect(() => {
    if (picked.current) {
      picked.current = false
      return
    }
    setView((v) => ({ y: fy, m: fm ?? v.m }))
  }, [fy, fm])
  // Whether or not the pick moved the active end to another month, it has been
  // seen once the render it caused is committed.
  useEffect(() => {
    picked.current = false
  })

  useEffect(() => {
    if (!refocus.current || cursor === null) return
    refocus.current = false
    grid.current?.querySelector<HTMLElement>(`[data-day="${cursor}"]`)?.focus()
  }, [cursor, view])

  const s = parseTime('Date', start) === null ? null : start.trim()
  const t = parseTime('Date', stop) === null ? null : stop.trim()
  const span = s !== null && t !== null && s <= t ? { s, t } : null
  const chosen = parseTime('Date', active) === null ? null : active.trim()

  const inView = (day: string | null) => {
    if (day === null) return false
    const m = monthOf(day)
    return m.y === view.y && m.m === view.m
  }
  const first = iso(view.y, view.m, 1)
  const tabbable = [cursor, chosen].find(inView) ?? first

  const move = (months: number) => setView((v) => addMonths(v, months))

  const pick = (day: string) => {
    picked.current = true
    setCursor(day)
    onPick(day)
  }

  const onKeyDown = (e: React.KeyboardEvent, day: string) => {
    const step: Record<string, number> = {
      ArrowLeft: -1,
      ArrowRight: 1,
      ArrowUp: -7,
      ArrowDown: 7,
    }
    let next: string | null = null
    if (e.key in step) next = addDays(day, step[e.key])
    else if (e.key === 'PageUp' || e.key === 'PageDown') {
      const months = (e.key === 'PageUp' ? -1 : 1) * (e.shiftKey ? 12 : 1)
      const target = addMonths(monthOf(day), months)
      const last = monthGrid(target)
        .flat()
        .filter((d) => d !== null).length
      next = iso(target.y, target.m, Math.min(Number(day.slice(8)), last))
    }
    if (next === null) return
    e.preventDefault()
    refocus.current = true
    setCursor(next)
    setView(monthOf(next))
  }

  const cell = (d: number) => {
    const day = iso(view.y, view.m, d)
    const isStart = day === s
    const isStop = day === t
    const classes = ['calendar__day']
    if (span !== null && day > span.s && day < span.t) classes.push('calendar__day--in')
    if (isStart) classes.push('calendar__day--start')
    if (isStop) classes.push('calendar__day--stop')
    // A zero-length window, or one the wrong way round, is only its ticks.
    if (span !== null && s !== t && (isStart || isStop))
      classes.push('calendar__day--run')
    if (day === chosen) classes.push('calendar__day--active')
    const role = [isStart && 'start', isStop && 'stop'].filter(Boolean).join(' and ')
    return (
      <button
        type="button"
        className={classes.join(' ')}
        tabIndex={day === tabbable ? 0 : -1}
        aria-pressed={day === chosen}
        aria-label={`${d} ${MONTHS[view.m - 1]} ${view.y}${role ? `, ${role}` : ''}`}
        data-day={day}
        data-testid={`calendar-${day}`}
        onClick={() => pick(day)}
        onKeyDown={(e) => onKeyDown(e, day)}
      >
        {d}
      </button>
    )
  }

  const heading = `${MONTHS[view.m - 1]} ${view.y}`
  return (
    <div className="calendar" data-testid="calendar">
      <div className="calendar__head">
        <button
          type="button"
          className="quiet"
          aria-label="Previous year"
          onClick={() => move(-12)}
        >
          «
        </button>
        <button
          type="button"
          className="quiet"
          aria-label="Previous month"
          onClick={() => move(-1)}
        >
          ‹
        </button>
        <h3 className="calendar__month" id="calendar-month" aria-live="polite">
          {heading}
        </h3>
        <button
          type="button"
          className="quiet"
          aria-label="Next month"
          onClick={() => move(1)}
        >
          ›
        </button>
        <button
          type="button"
          className="quiet"
          aria-label="Next year"
          onClick={() => move(12)}
        >
          »
        </button>
      </div>
      <table
        className="calendar__grid"
        role="grid"
        aria-labelledby="calendar-month"
        ref={grid}
      >
        <thead>
          <tr>
            {WEEKDAYS.map(([short, long]) => (
              <th key={short} scope="col" abbr={long}>
                {short}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {monthGrid(view).map((week, w) => (
            <tr key={w}>
              {week.map((d, i) => (
                <td key={i}>{d === null ? null : cell(d)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
