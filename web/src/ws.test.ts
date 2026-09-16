import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { EventSocket } from './ws'

// The socket is expected to drop, so what matters is not that it delivers every
// event but that it notices when it has not: a gap in `seq`, a `desync`, or a
// reconnect all mean "refetch, do not replay".

class FakeSocket {
  static last: FakeSocket | null = null
  // The real `WebSocket.OPEN`, which the ping guard reads off the constructor.
  static OPEN = 1
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  readyState = 1
  sent: string[] = []

  constructor(public url: string) {
    FakeSocket.last = this
  }
  send(text: string) {
    this.sent.push(text)
  }
  close() {
    this.readyState = 3
    this.onclose?.()
  }
  deliver(payload: unknown) {
    this.onmessage?.({ data: JSON.stringify(payload) })
  }
}

describe('EventSocket', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', FakeSocket as unknown as typeof WebSocket)
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  function connect() {
    const events: string[] = []
    const resyncs: string[] = []
    const statuses: boolean[] = []
    const socket = new EventSocket({
      onEvent: (e) => events.push(e.event),
      onResync: (reason) => resyncs.push(reason),
      onStatus: (up) => statuses.push(up),
    })
    socket.connect()
    FakeSocket.last!.onopen!()
    return { socket, events, resyncs, statuses, fake: FakeSocket.last! }
  }

  it('resyncs on hello rather than trusting what it has', () => {
    const { resyncs, fake } = connect()
    fake.deliver({ event: 'hello', payload: { seq: 12 } })
    expect(resyncs).toEqual(['reconnected'])
  })

  it('passes ordinary events through', () => {
    const { events, resyncs, fake } = connect()
    fake.deliver({ event: 'hello', payload: { seq: 1 } })
    fake.deliver({ event: 'graph_changed', seq: 2, payload: {} })
    fake.deliver({ event: 'node_status', seq: 3, payload: {} })
    expect(events).toEqual(['graph_changed', 'node_status'])
    expect(resyncs).toEqual(['reconnected'])
  })

  it('notices a gap in the sequence', () => {
    const { resyncs, fake } = connect()
    fake.deliver({ event: 'hello', payload: { seq: 1 } })
    fake.deliver({ event: 'graph_changed', seq: 2, payload: {} })
    fake.deliver({ event: 'graph_changed', seq: 9, payload: {} })
    expect(resyncs).toContain('missed an event')
  })

  it('resyncs when the server says it dropped events', () => {
    const { resyncs, fake } = connect()
    fake.deliver({ event: 'desync', payload: { dropped: 7 } })
    expect(resyncs).toEqual(['the server dropped events'])
  })

  it('ignores the heartbeat and the pong', () => {
    const { events, fake } = connect()
    fake.deliver({ event: 'heartbeat', payload: {} })
    fake.deliver({ event: 'pong', payload: {} })
    expect(events).toEqual([])
  })

  it('survives a message that is not JSON', () => {
    const { events, fake } = connect()
    fake.onmessage!({ data: 'not json' })
    expect(events).toEqual([])
  })

  it('reconnects with backoff, and stops when closed', () => {
    const { socket, statuses, fake } = connect()
    expect(statuses).toEqual([true])
    fake.close()
    expect(statuses).toEqual([true, false])
    vi.advanceTimersByTime(600)
    FakeSocket.last!.onopen!()
    expect(statuses).toEqual([true, false, true])

    // Closing deliberately still reports disconnected — that is the honest
    // state — but it must not reconnect afterwards.
    socket.close()
    expect(statuses).toEqual([true, false, true, false])
    const before = FakeSocket.last
    vi.advanceTimersByTime(60_000)
    expect(FakeSocket.last).toBe(before)
    expect(statuses).toEqual([true, false, true, false])
  })

  it('pings so a proxy sees traffic in both directions', () => {
    const { fake } = connect()
    vi.advanceTimersByTime(26_000)
    expect(JSON.parse(fake.sent[0])).toEqual({ type: 'ping' })
  })
})
