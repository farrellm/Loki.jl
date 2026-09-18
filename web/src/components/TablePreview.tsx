import { useCallback, useEffect, useState } from 'react'
import { api } from '../api'
import type { Diagnostic, Watched } from '../types'

const PAGE = 50

// A page of a node's rows. The table scrolls inside its own panel rather than
// scrolling the page, which is what keeps it usable on a phone.

export function TablePreview({ watched }: { watched: Watched | null }) {
  const [offset, setOffset] = useState(0)
  const [page, setPage] = useState<Diagnostic | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  useEffect(() => setOffset(0), [watched?.id, watched?.port])

  const load = useCallback(async () => {
    if (watched === null) return
    try {
      setPage(await api.result(watched.id, watched.port, { offset, limit: PAGE }))
      setProblem(null)
    } catch (error) {
      setPage(null)
      setProblem(error instanceof Error ? error.message : String(error))
    }
  }, [watched, offset])

  useEffect(() => {
    void load()
  }, [load])

  if (watched === null) {
    return (
      <div className="table table--none">
        <p>Run a node and inspect a port to page through its rows.</p>
      </div>
    )
  }
  if (problem !== null) {
    return (
      <div className="table table--none">
        <p role="alert">{problem}</p>
      </div>
    )
  }
  if (page === null) return <div className="table table--none">Loading…</div>

  const { columns, types, rows, total } = page.data
  const last = Math.min(offset + rows.length, total)

  return (
    <div className="table" data-testid="table-preview">
      <div className="table__scroll">
        <table>
          <thead>
            <tr>
              {columns.map((name: string, i: number) => (
                <th key={name} scope="col">
                  <span className="mono">{name}</span>
                  <span className="table__type">{types[i]}</span>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row: unknown[], r: number) => (
              <tr key={r}>
                {row.map((cell, c) => (
                  <td key={c} className={typeof cell === 'number' ? 'num' : 'mono'}>
                    {cell === null ? <span className="missing">missing</span> : String(cell)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="table__pager">
        <button
          type="button"
          disabled={offset === 0}
          onClick={() => setOffset(Math.max(0, offset - PAGE))}
        >
          Previous
        </button>
        <span className="table__range num">
          {total === 0 ? 'no rows' : `${offset + 1}–${last} of ${total.toLocaleString()}`}
        </span>
        <button
          type="button"
          disabled={last >= total}
          onClick={() => setOffset(offset + PAGE)}
        >
          Next
        </button>
      </div>
    </div>
  )
}
