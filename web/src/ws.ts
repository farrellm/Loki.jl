import type { LokiEvent } from './types'

// The event socket.
//
// Events are a live-update convenience; the REST state is the truth. The socket
// is expected to drop — iOS suspends background tabs and closes their sockets,
// and a phone changes networks — so this reconnects with backoff and tells the
// app to resync rather than replay. It resyncs on three signals: a reconnect, a
// `desync` message (the server's queue overflowed), and a gap in `seq`.

const MIN_BACKOFF = 500
const MAX_BACKOFF = 15_000
const PING_MS = 25_000

export interface SocketHandlers {
  onEvent(event: LokiEvent): void
  /** Refetch everything: what we have may be stale or incomplete. */
  onResync(reason: string): void
  onStatus(connected: boolean): void
}

export class EventSocket {
  private socket: WebSocket | null = null
  private backoff = MIN_BACKOFF
  private timer: number | undefined
  private ping: number | undefined
  private closed = false
  private lastSeq = 0

  constructor(private readonly handlers: SocketHandlers) {}

  connect() {
    if (this.closed) return
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
    const socket = new WebSocket(`${protocol}//${location.host}/ws`)
    this.socket = socket

    socket.onopen = () => {
      this.backoff = MIN_BACKOFF
      this.handlers.onStatus(true)
      // Traffic in both directions, so a proxy does not decide the socket is idle.
      this.ping = window.setInterval(() => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ type: 'ping' }))
        }
      }, PING_MS)
    }

    socket.onmessage = (message) => {
      let event: LokiEvent
      try {
        event = JSON.parse(message.data as string)
      } catch {
        return
      }
      if (event.event === 'heartbeat' || event.event === 'pong') return
      if (event.event === 'desync') {
        this.handlers.onResync('the server dropped events')
        return
      }
      if (event.event === 'hello') {
        this.lastSeq = event.payload.seq ?? 0
        this.handlers.onResync('reconnected')
        return
      }
      if (typeof event.seq === 'number') {
        // A gap means we missed something; the REST state settles it.
        if (this.lastSeq > 0 && event.seq > this.lastSeq + 1) {
          this.handlers.onResync('missed an event')
        }
        this.lastSeq = Math.max(this.lastSeq, event.seq)
      }
      this.handlers.onEvent(event)
    }

    const reopen = () => {
      window.clearInterval(this.ping)
      this.handlers.onStatus(false)
      if (this.closed) return
      this.timer = window.setTimeout(() => this.connect(), this.backoff)
      this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF)
    }
    socket.onclose = reopen
    socket.onerror = () => socket.close()
  }

  close() {
    this.closed = true
    window.clearTimeout(this.timer)
    window.clearInterval(this.ping)
    this.socket?.close()
  }
}
