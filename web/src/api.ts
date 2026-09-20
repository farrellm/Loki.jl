import type { Diagnostic, FileListing, Graph, NodeKind, TableSpec } from './types'

// The REST client. The token arrives in the URL fragment, which a browser never
// sends to a server and never puts in a `Referer`; we exchange it once for an
// HttpOnly cookie and then take it out of the address bar, so it does not linger
// in history and a reloaded tab still authenticates.

export class ApiError extends Error {
  readonly status: number
  readonly node?: string

  constructor(status: number, message: string, node?: string) {
    super(message)
    this.status = status
    this.node = node
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) {
    let message = `${method} ${path} failed (${response.status})`
    let node: string | undefined
    try {
      const problem = await response.json()
      if (typeof problem.error === 'string') message = problem.error
      if (typeof problem.node === 'string') node = problem.node
    } catch {
      // A response that is not JSON has nothing more to tell us.
    }
    throw new ApiError(response.status, message, node)
  }
  if (response.status === 204) return undefined as T
  const type = response.headers.get('Content-Type') ?? ''
  return (type.includes('json') ? response.json() : response.text()) as Promise<T>
}

/** Exchange the fragment token for a session cookie, then clear the address bar. */
export async function authenticate(): Promise<boolean> {
  const token = new URLSearchParams(location.hash.slice(1)).get('token')
  if (token === null) return false
  await request('POST', '/api/auth', { token })
  history.replaceState(null, '', location.pathname + location.search)
  return true
}

export const api = {
  graph: (context?: string) =>
    request<Graph>('GET', `/api/graph${context ? `?context=${context}` : ''}`),
  nodeKinds: () => request<NodeKind[]>('GET', '/api/nodekinds'),
  tables: () => request<TableSpec[]>('GET', '/api/tables'),

  addNode: (kind: string, params: Record<string, unknown>, position: [number, number]) =>
    request<{ id: string }>('POST', '/api/nodes', { kind, params, position }),
  updateParams: (id: string, params: Record<string, unknown>) =>
    request<unknown>('PATCH', `/api/nodes/${id}`, { params }),
  moveNode: (id: string, position: [number, number]) =>
    request<unknown>('PATCH', `/api/nodes/${id}`, { position }),
  removeNode: (id: string) => request<unknown>('DELETE', `/api/nodes/${id}`),
  freeze: (id: string, port: string, name?: string) =>
    request<{ table: string; rows: number }>('POST', `/api/nodes/${id}/freeze`, {
      port,
      ...(name ? { name } : {}),
    }),

  connect: (from: [string, string], to: [string, string]) =>
    request<{ id: string }>('POST', '/api/edges', { from, to }),
  disconnect: (id: string) => request<unknown>('DELETE', `/api/edges/${id}`),

  setContext: (name: string, timetype: string, start: unknown, stop: unknown) =>
    request<unknown>('PUT', `/api/contexts/${name}`, { timetype, start, stop }),

  run: (targets: (string | [string, string])[], context = 'analysis') =>
    request<unknown>('POST', '/api/run', { targets, context }),
  cancel: () => request<unknown>('POST', '/api/cancel'),
  write: (id: string) => request<unknown>('POST', `/api/write/${id}`),

  result: (id: string, port: string, params: Record<string, string | number>) =>
    request<Diagnostic>(
      'GET',
      `/api/results/${id}/${port}?${new URLSearchParams(
        Object.entries(params).map(([k, v]) => [k, String(v)]),
      )}`,
    ),
  diagnostic: (
    id: string,
    port: string,
    kind: string,
    params: Record<string, string | number> = {},
  ) =>
    request<Diagnostic>(
      'GET',
      `/api/diagnostics/${id}/${port}/${kind}?${new URLSearchParams(
        Object.entries(params).map(([k, v]) => [k, String(v)]),
      )}`,
    ),

  exportScript: () => request<string>('GET', '/api/export'),

  /** One directory on the machine Loki runs on, for the file picker. */
  files: (path?: string, hidden = false) =>
    request<FileListing>(
      'GET',
      `/api/files?${new URLSearchParams({
        ...(path === undefined ? {} : { path }),
        ...(hidden ? { hidden: 'true' } : {}),
      })}`,
    ),

  sessionPath: () => request<{ path: string | null }>('GET', '/api/session'),
  save: (path: string) => request<{ path: string }>('PUT', '/api/session', { path }),
  open: (path: string) => request<unknown>('POST', '/api/session', { path }),

  uploadTable: async (name: string, file: File, format: 'csv' | 'parquet') => {
    const response = await fetch(`/api/tables/${name}?format=${format}`, {
      method: 'POST',
      credentials: 'same-origin',
      body: await file.arrayBuffer(),
    })
    if (!response.ok) {
      const problem = await response.json().catch(() => ({}))
      throw new ApiError(response.status, problem.error ?? 'the upload failed')
    }
    return response.json()
  },
}
