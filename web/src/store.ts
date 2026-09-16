import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { api, ApiError, authenticate } from './api'
import { EventSocket } from './ws'
import type { Graph, LokiEvent, NodeKind, Origin, Watched } from './types'

export interface Notice {
  id: number
  text: string
  tone: 'info' | 'error'
}

export interface Session {
  graph: Graph | null
  kinds: NodeKind[]
  connected: boolean
  loading: boolean
  /** Who made the most recent change — so you can see what the agent just did. */
  lastOrigin: Origin | null
  notices: Notice[]
  selected: string | null
  watched: Watched | null
  running: boolean
}

let noticeId = 0

export function useSession() {
  const [graph, setGraph] = useState<Graph | null>(null)
  const [kinds, setKinds] = useState<NodeKind[]>([])
  const [connected, setConnected] = useState(false)
  const [loading, setLoading] = useState(true)
  const [lastOrigin, setLastOrigin] = useState<Origin | null>(null)
  const [notices, setNotices] = useState<Notice[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [watched, setWatched] = useState<Watched | null>(null)

  const pending = useRef(false)

  const note = useCallback((text: string, tone: Notice['tone'] = 'info') => {
    const notice = { id: ++noticeId, text, tone }
    setNotices((all) => [...all.slice(-3), notice])
    window.setTimeout(
      () => setNotices((all) => all.filter((n) => n.id !== notice.id)),
      tone === 'error' ? 9000 : 4000,
    )
  }, [])

  // One refetch at a time, and never two in flight: the socket can ask for
  // several in a burst while a run is settling.
  const resync = useCallback(async () => {
    if (pending.current) return
    pending.current = true
    try {
      setGraph(await api.graph())
    } catch (error) {
      note(error instanceof Error ? error.message : String(error), 'error')
    } finally {
      pending.current = false
      setLoading(false)
    }
  }, [note])

  useEffect(() => {
    let socket: EventSocket | null = null
    ;(async () => {
      try {
        await authenticate()
        setKinds(await api.nodeKinds())
        await resync()
      } catch (error) {
        const message =
          error instanceof ApiError && error.status === 401
            ? 'This link has expired. Open the URL Loki printed in your terminal again.'
            : error instanceof Error
              ? error.message
              : String(error)
        note(message, 'error')
        setLoading(false)
        return
      }
      socket = new EventSocket({
        onEvent: (event: LokiEvent) => {
          if (event.origin) setLastOrigin(event.origin)
          if (event.event === 'log') {
            note(event.payload.message, event.payload.level === 'error' ? 'error' : 'info')
          }
          // Every event changes something the graph request answers for, and a
          // local server answers it in milliseconds.
          void resync()
        },
        onResync: () => void resync(),
        onStatus: setConnected,
      })
      socket.connect()
    })()
    return () => socket?.close()
  }, [note, resync])

  const act = useCallback(
    async (what: string, action: () => Promise<unknown>) => {
      try {
        await action()
        await resync()
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        note(`${what}: ${message}`, 'error')
      }
    },
    [note, resync],
  )

  const running = useMemo(
    () => graph?.nodes.some((n) => n.status === 'running') ?? false,
    [graph],
  )

  return {
    graph,
    kinds,
    connected,
    loading,
    lastOrigin,
    notices,
    selected,
    setSelected,
    watched,
    setWatched,
    running,
    resync,
    act,
    note,
  }
}

export type SessionStore = ReturnType<typeof useSession>
