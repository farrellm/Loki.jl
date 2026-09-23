import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import {
  check,
  defaultTimetype,
  extent,
  ordered,
  parseTime,
  PLACEHOLDERS,
  span,
  TIMETYPES,
  usedBy,
  type Draft,
  type TimeType,
} from '../contexts'
import { trapTab } from '../focus'
import type { SessionStore } from '../store'
import { DateField } from './DateField'

// The named contexts: the windows of time a node can be evaluated over.
//
// A band hanging off the session bar, as the file picker is, and for the same
// reasons — no card, no second shadow; the scrim carries the elevation.
//
// The list is a timeline. Every context is drawn as an interval on one axis, so
// the thing that matters about a set of windows — that `train` sits inside
// `analysis`, that `test` starts where `train` stops — is something you see
// rather than work out from two columns of numbers. Editing one redraws its
// interval dashed at the values being typed, against the others, before
// anything is saved.

/** Which row is open: an existing context by name, or the new one. */
type Open = { name: string; fresh: boolean } | null

export function Contexts({
  store,
  onClose,
}: {
  store: SessionStore
  onClose: () => void
}) {
  const { graph, kinds, note, resync } = store
  const contexts = graph?.contexts ?? {}
  const names = ordered(contexts)
  const band = useRef<HTMLDivElement>(null)

  const blank = (): Draft => {
    const from = contexts.analysis
    return {
      name: contexts.analysis === undefined ? 'analysis' : '',
      timetype: from?.timetype ?? defaultTimetype(contexts, graph?.tables),
      start: from === undefined ? '' : String(from.start),
      stop: from === undefined ? '' : String(from.stop),
    }
  }

  // A session with no analysis window cannot run anything, so that is the
  // first thing it is asked for.
  const [open, setOpen] = useState<Open>(() =>
    contexts.analysis === undefined ? { name: 'analysis', fresh: true } : null,
  )
  const [draft, setDraft] = useState<Draft>(blank)
  const [touched, setTouched] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [removing, setRemoving] = useState(false)
  const [busy, setBusy] = useState(false)

  // The context being edited can vanish under us — the agent removed it, or
  // the session was opened from a file.
  const current = open !== null && !open.fresh && !(open.name in contexts) ? null : open

  // Into the band, so Escape and Tab work at once — unless a field already took
  // focus, as the name does when the band opens on a new context. Saving or
  // removing unmounts the button that was pressed, and focus falls to the body,
  // from where Escape reaches nothing and Tab walks the page behind the scrim;
  // so it is caught again after every change that can do that.
  useEffect(() => {
    if (!band.current?.contains(document.activeElement)) band.current?.focus()
  }, [open, graph])

  const show = (next: Open) => {
    setOpen(next)
    setTouched(false)
    setProblem(null)
    setRemoving(false)
    if (next === null) return
    if (next.fresh) return setDraft(blank())
    const ctx = contexts[next.name]
    setDraft({
      name: next.name,
      timetype: ctx.timetype,
      start: String(ctx.start),
      stop: String(ctx.stop),
    })
  }

  const edit = (patch: Partial<Draft>) => {
    setDraft((d) => ({ ...d, ...patch }))
    setTouched(true)
    setProblem(null)
  }

  const taken = current?.fresh ? names : []
  const checked = current === null ? null : check(draft, taken)

  const save = async () => {
    if (checked === null || !checked.ok) return setTouched(true)
    const name = draft.name.trim()
    setBusy(true)
    try {
      await api.setContext(name, draft.timetype, checked.start.value, checked.stop.value)
      await resync()
      note(`Saved ${name}`)
      show(null)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  const remove = async (name: string) => {
    setBusy(true)
    try {
      await api.removeContext(name)
      await resync()
      note(`Removed ${name}`)
      show(null)
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  // One axis for every context that shares the session's time type. The draft
  // is on it too, so typing a stop past the end widens the axis rather than
  // running the interval off the edge.
  const axisType =
    contexts.analysis?.timetype ??
    (current?.fresh ? draft.timetype : undefined) ??
    contexts[names[0]]?.timetype
  const drafted =
    checked !== null && checked.start !== null && checked.stop !== null
      ? ([checked.start.axis, checked.stop.axis] as [number, number])
      : null
  const draftSpan =
    drafted !== null && drafted[0] <= drafted[1] && draft.timetype === axisType
      ? drafted
      : null
  const onAxis = names
    .filter((n) => contexts[n].timetype === axisType)
    .map((n) => span(contexts[n]))
    .filter((s): s is [number, number] => s !== null)
  const axis = extent(draftSpan === null ? onAxis : [...onAxis, draftSpan])

  const place = (s: [number, number]) =>
    axis === null
      ? {}
      : {
          left: `${((s[0] - axis[0]) / (axis[1] - axis[0])) * 100}%`,
          width: `${((s[1] - s[0]) / (axis[1] - axis[0])) * 100}%`,
        }

  const track = (name: string | null) => {
    const saved = name === null ? null : contexts[name]
    const savedSpan = saved !== null && saved.timetype === axisType ? span(saved) : null
    const editing =
      current !== null && (name === null ? current.fresh : current.name === name)
    // Dashed only once it differs from what is saved: an interval that has not
    // been changed is not a draft.
    const changed =
      editing &&
      draftSpan !== null &&
      (savedSpan === null ||
        draftSpan[0] !== savedSpan[0] ||
        draftSpan[1] !== savedSpan[1])
    return (
      <span className="contexts__track" aria-hidden="true">
        {savedSpan !== null && (
          <span
            className={`contexts__span${changed ? ' contexts__span--was' : ''}`}
            style={place(savedSpan)}
          />
        )}
        {changed && (
          <span
            className="contexts__span contexts__span--draft"
            data-testid="context-draft"
            style={place(draftSpan!)}
          />
        )}
        {saved !== null && saved.timetype !== axisType && (
          <span className="contexts__other">{saved.timetype}</span>
        )}
      </span>
    )
  }

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.stopPropagation()
      // One step back at a time: a row that is open closes before the band.
      if (current !== null && names.length > 0) return show(null)
      return onClose()
    }
    if (e.key === 'Tab') trapTab(e, band.current)
  }

  const form = (name: string | null) => {
    if (checked === null) return null
    const fresh = name === null
    const users = fresh ? [] : usedBy(name, graph?.nodes ?? [], kinds)
    const shown = problem ?? (touched && !checked.ok ? checked.problem : null)
    const [startHint, stopHint] = PLACEHOLDERS[draft.timetype as TimeType] ?? ['', '']
    const numeric = draft.timetype === 'Int64' || draft.timetype === 'Float64'
    const date = draft.timetype === 'Date'
    return (
      <form
        className="contexts__form"
        onSubmit={(e) => {
          e.preventDefault()
          void save()
        }}
      >
        <div className="contexts__fields">
          {fresh && (
            <label className="contexts__field contexts__field--wide">
              <span>Name</span>
              <input
                className="mono"
                value={draft.name}
                placeholder="train"
                autoFocus
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                data-testid="context-name"
                onChange={(e) => edit({ name: e.target.value })}
              />
            </label>
          )}
          <label className="contexts__field contexts__field--wide">
            <span>Time type</span>
            <select
              value={draft.timetype}
              data-testid="context-timetype"
              onChange={(e) => {
                // An end that means nothing in the new type is cleared rather
                // than carried over: `401` is no start for a Date.
                const timetype = e.target.value
                const keep = (text: string) =>
                  parseTime(timetype, text) === null ? '' : text
                edit({ timetype, start: keep(draft.start), stop: keep(draft.stop) })
              }}
            >
              {TIMETYPES.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
              {/* A context made at the REPL can have a time type this form
                  cannot write; it is still shown as what it is. */}
              {!(TIMETYPES as readonly string[]).includes(draft.timetype) && (
                <option value={draft.timetype}>{draft.timetype}</option>
              )}
            </select>
          </label>
          <label className="contexts__field">
            <span>Start</span>
            {date ? (
              <DateField
                value={draft.start}
                autoFocus={!fresh}
                testid="context-start"
                onChange={(start) => edit({ start })}
              />
            ) : (
              <input
                className="mono"
                value={draft.start}
                placeholder={startHint}
                inputMode={numeric ? 'decimal' : 'text'}
                autoFocus={!fresh}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                data-testid="context-start"
                onChange={(e) => edit({ start: e.target.value })}
              />
            )}
          </label>
          <label className="contexts__field">
            <span>Stop</span>
            {date ? (
              <DateField
                value={draft.stop}
                testid="context-stop"
                onChange={(stop) => edit({ stop })}
              />
            ) : (
              <input
                className="mono"
                value={draft.stop}
                placeholder={stopHint}
                inputMode={numeric ? 'decimal' : 'text'}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                data-testid="context-stop"
                onChange={(e) => edit({ stop: e.target.value })}
              />
            )}
          </label>
        </div>

        {shown !== null && (
          <p className="contexts__problem" role="alert" data-testid="context-problem">
            {shown}
          </p>
        )}
        {removing && (
          <p className="contexts__note">
            {users.length === 0
              ? `No node names ${name}.`
              : `${list(users)} ${users.length === 1 ? 'names' : 'name'} ${name}, and will fail to build until ${users.length === 1 ? 'it is' : 'they are'} pointed at another context.`}
          </p>
        )}

        <div className="contexts__foot">
          {!fresh &&
            name !== 'analysis' &&
            (removing ? (
              <>
                <button
                  type="button"
                  className="contexts__remove contexts__remove--sure"
                  disabled={busy}
                  data-testid="context-remove-confirm"
                  onClick={() => void remove(name)}
                >
                  Remove {name}
                </button>
                <button type="button" onClick={() => setRemoving(false)}>
                  Keep it
                </button>
              </>
            ) : (
              <button
                type="button"
                className="quiet contexts__remove"
                data-testid="context-remove"
                onClick={() => setRemoving(true)}
              >
                Remove
              </button>
            ))}
          {/* While a removal is being confirmed, those two buttons are the only
              choices: saving what is about to be removed means nothing. */}
          {!removing && (
            <>
              <span className="contexts__spacer" />
              {names.length > 0 && (
                <button type="button" onClick={() => show(null)}>
                  Cancel
                </button>
              )}
              <button
                type="submit"
                className="primary"
                disabled={busy || !checked.ok}
                data-testid="context-save"
              >
                Save context
              </button>
            </>
          )}
        </div>
      </form>
    )
  }

  return (
    <>
      <div className="scrim" onClick={onClose} aria-hidden="true" />
      <div
        className="contexts"
        role="dialog"
        aria-modal="true"
        aria-labelledby="contexts-title"
        data-testid="contexts"
        ref={band}
        tabIndex={-1}
        onKeyDown={onKeyDown}
      >
        <div className="contexts__head">
          <h2 id="contexts-title">Contexts</h2>
          <button type="button" className="quiet" onClick={onClose}>
            Close
          </button>
        </div>
        <p className="contexts__intro">
          Named windows of time. Runs load over <span className="mono">analysis</span>; a
          node’s context parameter can name any of them.
        </p>

        <ol className="contexts__list" data-testid="context-list">
          {axis !== null && (
            <li className="contexts__axis mono" aria-hidden="true">
              <span />
              <span className="contexts__ends">
                <span>{formatAxis(axisType, axis[0])}</span>
                <span>{formatAxis(axisType, axis[1])}</span>
              </span>
              <span />
            </li>
          )}
          {names.map((name) => {
            const ctx = contexts[name]
            const on = current !== null && !current.fresh && current.name === name
            return (
              <li
                key={name}
                className={`contexts__row${on ? ' contexts__row--on' : ''}${
                  name === 'analysis' ? ' contexts__row--analysis' : ''
                }`}
                data-testid={`context-${name}`}
              >
                <button
                  type="button"
                  className="contexts__pick"
                  aria-expanded={on}
                  onClick={() => show(on ? null : { name, fresh: false })}
                >
                  <span className="contexts__name mono">{name}</span>
                  {track(name)}
                  <span className="contexts__range mono">
                    {String(ctx.start)} → {String(ctx.stop)}
                  </span>
                </button>
                {on && form(name)}
              </li>
            )
          })}
          {current?.fresh ? (
            <li className="contexts__row contexts__row--on contexts__row--new">
              <div className="contexts__pick" aria-hidden="true">
                <span className="contexts__name mono">{draft.name.trim() || 'new'}</span>
                {track(null)}
                <span className="contexts__range mono">
                  {draft.start || '…'} → {draft.stop || '…'}
                </span>
              </div>
              {form(null)}
            </li>
          ) : (
            <li className="contexts__row">
              <button
                type="button"
                className="contexts__add"
                data-testid="context-add"
                onClick={() => show({ name: '', fresh: true })}
              >
                Add a context
              </button>
            </li>
          )}
        </ol>
      </div>
    </>
  )
}

// The ends of the axis, in the terms the fields use.
function formatAxis(timetype: string | undefined, n: number): string {
  if (timetype === 'Date') return new Date(n).toISOString().slice(0, 10)
  if (timetype === 'DateTime') return new Date(n).toISOString().slice(0, 19)
  if (timetype === 'Float64') return String(Number(n.toPrecision(6)))
  return String(n)
}

const list = (ids: string[]) =>
  ids.length === 1 ? ids[0] : `${ids.slice(0, -1).join(', ')} and ${ids[ids.length - 1]}`
