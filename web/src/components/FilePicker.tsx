import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { trapTab } from '../focus'
import {
  basename,
  formatModified,
  joinPath,
  matchesSuffix,
  parentOf,
  splitPath,
} from '../paths'
import type { FileEntry, FileListing } from '../types'

// A path on the machine Loki is running on.
//
// Not a floating dialog: `app.css` says panels are regions of one grid
// separated by hairlines, and that there is exactly one shadow in the whole
// interface. So the picker is a drawer hanging off the session bar it was
// opened from — flush to the bar and to the left edge, hairline on the two
// free sides, no radius, no shadow. The scrim behind carries the elevation
// instead, and the shadow count in the app stays at one. It stops at a
// readable measure rather than spanning the window, because a file name is
// text, and it fills the screen below the breakpoint.
//
// The path is the subject and the list is a way of editing it. That line is at
// once the breadcrumb (every ancestor is a button), the file name field, and
// the literal string that will be written — so you are never assembling a path
// in your head from a folder above and a box below. Pressing `/`, or clicking
// the empty tail of the line, swaps it for one plain input, which is how a path
// pasted from a terminal gets in.
//
// Nothing here knows about sessions: it takes suffixes, a folder and a name and
// hands back a path, which is the whole contract — the session bar opens and
// saves with it, and a file node's `path` parameter is chosen with it. It hangs
// from the side it was opened from: the bar's own band from the left, the
// inspector's from the right, over the column the field was in.

export function FilePicker({
  mode,
  title,
  confirm,
  suffixes,
  start,
  name: initialName = '',
  side = 'start',
  onChoose,
  onCancel,
}: {
  mode: 'open' | 'save'
  title: string
  confirm: string
  /** Files that do not match are shown dimmed, never hidden. */
  suffixes?: string[]
  start?: string
  name?: string
  side?: 'start' | 'end'
  onChoose: (path: string) => void
  onCancel: () => void
}) {
  const [listing, setListing] = useState<FileListing | null>(null)
  const [dir, setDir] = useState<string | undefined>(start)
  const [name, setName] = useState(initialName)
  const [problem, setProblem] = useState<string | null>(null)
  const [typed, setTyped] = useState<string | null>(null)
  const band = useRef<HTMLDivElement>(null)
  const nameField = useRef<HTMLInputElement>(null)
  const typedField = useRef<HTMLInputElement>(null)

  useEffect(() => {
    let live = true
    api
      .files(dir)
      .then((next) => {
        if (!live) return
        setListing(next)
        setProblem(null)
      })
      .catch((error: unknown) => {
        if (!live) return
        // The folder that could not be read stays on screen: losing it would
        // leave nowhere to go back to.
        setProblem(error instanceof Error ? error.message : String(error))
      })
    return () => {
      live = false
    }
  }, [dir])

  // Save opens on the name, because that is usually the only thing to change.
  useEffect(() => {
    if (mode === 'save') nameField.current?.select()
  }, [mode])

  useEffect(() => {
    if (typed !== null) typedField.current?.select()
  }, [typed])

  // Entering a directory destroys the button that was tapped, and focus falls
  // to the body — from where Tab walks the page behind the scrim rather than
  // this band. Catch it once the new list is on screen, not when it arrives:
  // the old button is still mounted until React commits. A tap that never
  // focused anything in the first place lands here too.
  useEffect(() => {
    if (!band.current?.contains(document.activeElement)) band.current?.focus()
  }, [listing])

  const here = listing?.path ?? dir ?? ''
  const chosen = name.trim() === '' ? '' : joinPath(here, name.trim())
  // Only a save has anything to warn about: in open mode a file that is there
  // is the whole point.
  const overwriting =
    mode === 'save'
      ? listing?.entries.find((e) => !e.dir && e.name === name.trim())
      : undefined

  const go = useCallback((next: string) => {
    setDir(next)
    setTyped(null)
  }, [])

  // A directory is entered; a file is only *chosen*, and the button below
  // confirms it. Opening replaces the whole analysis, so one stray tap in a
  // list should not be able to throw away what is on the canvas.
  const pick = (entry: FileEntry) => {
    if (entry.dir) return go(joinPath(here, entry.name))
    setName(entry.name)
  }

  const submit = () => {
    if (chosen !== '') onChoose(chosen)
  }

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.stopPropagation()
      if (typed !== null) return setTyped(null)
      return onCancel()
    }
    if (e.key === 'Tab') trapTab(e, band.current)
    // `/` is how a shell starts a path, and it is what opens the whole line for
    // typing here — except while something is already being typed into.
    if (e.key === '/' && !isTextEntry(e.target)) {
      e.preventDefault()
      setTyped(here === '/' ? '/' : here + '/')
    }
  }

  return (
    <>
      <div className="scrim" onClick={onCancel} aria-hidden="true" />
      <div
        className={side === 'end' ? 'picker picker--end' : 'picker'}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        data-testid="file-picker"
        ref={band}
        tabIndex={-1}
        onKeyDown={onKeyDown}
      >
        <div className="picker__head">
          <h2>{title}</h2>
          <button type="button" className="quiet" onClick={onCancel}>
            Cancel
          </button>
        </div>

        {typed === null ? (
          <div className="picker__path mono">
            {splitPath(here).map((crumb, i) => (
              <button
                type="button"
                key={crumb.path}
                className="picker__crumb"
                onClick={() => go(crumb.path)}
              >
                {i === 0 ? crumb.name : crumb.name + '/'}
              </button>
            ))}
            {mode === 'save' ? (
              <input
                ref={nameField}
                className="picker__name mono"
                value={name}
                size={Math.max(name.length + 2, 14)}
                aria-label="File name"
                data-testid="file-name"
                placeholder="a file name"
                onChange={(e) => setName(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && submit()}
              />
            ) : (
              name !== '' && (
                <span className="picker__name" data-testid="file-name">
                  {name}
                </span>
              )
            )}
            <button
              type="button"
              className="picker__type"
              aria-label="Type a path"
              onClick={() => setTyped(here === '/' ? '/' : here + '/')}
            />
          </div>
        ) : (
          <div className="picker__path">
            <input
              ref={typedField}
              className="picker__typed mono"
              value={typed}
              aria-label="Path"
              data-testid="file-path"
              onChange={(e) => setTyped(e.target.value)}
              onKeyDown={(e) => {
                if (e.key !== 'Enter') return
                const text = typed.trim()
                // A path ending in a slash is a folder to go to; anything else
                // names a file in its parent.
                if (text.endsWith('/')) return go(text.replace(/\/+$/, '') || '/')
                setName(basename(text))
                go(parentOf(text))
              }}
            />
          </div>
        )}

        {problem !== null && (
          <p className="picker__problem" role="alert">
            Loki cannot read this folder. {problem}
          </p>
        )}

        <ul className="picker__list" data-testid="file-list">
          {listing !== null && listing.parent !== null && (
            <li>
              <button
                type="button"
                className="picker__entry picker__entry--up mono"
                data-testid="file-up"
                onClick={() => go(listing.parent!)}
              >
                ../
              </button>
            </li>
          )}
          {listing?.entries.map((entry) => {
            // A file this picker cannot use is still worth seeing: a folder
            // filtered down to nothing cannot tell you whether it is the right
            // folder, and a folder of dimmed CSVs can.
            const usable = entry.dir || matchesSuffix(entry.name, suffixes)
            if (!usable) {
              return (
                <li
                  key={entry.name}
                  className="picker__entry picker__entry--unusable mono"
                >
                  <span>{entry.name}</span>
                  <span className="picker__when num">
                    {formatModified(entry.modified)}
                  </span>
                </li>
              )
            }
            return (
              <li key={entry.name}>
                <button
                  type="button"
                  className={`picker__entry mono${
                    !entry.dir && entry.name === name.trim() ? ' picker__entry--on' : ''
                  }`}
                  data-testid={`file-${entry.name}`}
                  onClick={() => pick(entry)}
                >
                  <span>{entry.dir ? entry.name + '/' : entry.name}</span>
                  <span className="picker__when num">
                    {formatModified(entry.modified)}
                  </span>
                </button>
              </li>
            )
          })}
          {listing?.entries.length === 0 && problem === null && (
            <li className="picker__empty">
              Nothing here. Type a path above to go somewhere else.
            </li>
          )}
        </ul>

        <div className="picker__foot">
          <span className="picker__note">
            {listing?.truncated === true &&
              'This folder holds more than Loki will list. Type a path to go straight there.'}
            {overwriting !== undefined && `${overwriting.name} already exists.`}
          </span>
          <button
            type="button"
            className="primary"
            disabled={chosen === ''}
            data-testid="file-confirm"
            onClick={submit}
          >
            {overwriting !== undefined ? 'Replace' : confirm}
          </button>
        </div>
      </div>
    </>
  )
}

const isTextEntry = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.tagName === 'INPUT' || target.isContentEditable)
