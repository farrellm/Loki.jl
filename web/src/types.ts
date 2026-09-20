// What the server sends. `GET /api/graph` is the whole picture in one request,
// which is deliberate: a client that reconnects, or that sees a gap in the event
// sequence, refetches this rather than trusting what it has.

export type Status = 'idle' | 'running' | 'ok' | 'error' | 'blocked'
export type Origin = 'ui' | 'mcp' | 'repl'

export interface PortSpec {
  name: string
  variadic: boolean
  optional: boolean
}

export interface ResultShape {
  rows: number
  columns: string[]
  types: string[]
}

export interface NodeError {
  node: string
  message: string
}

export interface GraphNode {
  id: string
  kind: string
  params: Record<string, unknown>
  position: [number, number]
  status: Status
  acausal: boolean
  acausalports: Record<string, boolean>
  error: NodeError | null
  inputs: PortSpec[]
  outputs: string[]
  write: boolean
  results: Record<string, ResultShape>
  /** The line of Julia each output port exports as. The canvas draws this. */
  calls: Record<string, string>
}

export interface GraphEdge {
  id: string
  from: [string, string]
  to: [string, string]
}

export interface ContextSpec {
  timetype: string
  start: number | string
  stop: number | string
}

export interface TableSpec {
  name: string
  rows: number
  columns: string[]
  types: string[]
  frame: boolean
}

export interface Graph {
  nodes: GraphNode[]
  edges: GraphEdge[]
  contexts: Record<string, ContextSpec>
  tables: TableSpec[]
  prelude: string
  nextid: number
  seq: number
  context: string
  /** The file this session was saved to or opened from, if it has one. */
  file: string | null
  running: { targets: [string, string][]; cancelled: boolean } | null
}

/** One row of `GET /api/files`. A directory has no modified time to show. */
export interface FileEntry {
  name: string
  dir: boolean
  modified?: string
}

export interface FileListing {
  path: string
  /** `null` at the root of the filesystem, where there is nowhere to climb. */
  parent: string | null
  home: string
  working: string
  /** True when the folder held more than the server was willing to send. */
  truncated: boolean
  entries: FileEntry[]
}

export interface ParamSchema {
  type?: string | string[]
  enum?: string[]
  items?: ParamSchema
  anyOf?: ParamSchema[]
  properties?: Record<string, ParamSchema>
  required?: string[]
  description?: string
  default?: unknown
  /** Loki's own vocabulary: column, columns, code, context, table, summarizers. */
  'x-loki'?: string
}

export interface NodeKind {
  name: string
  category: string
  doc: string
  inputs: PortSpec[]
  outputs: string[]
  acausal: string[]
  write: boolean
  canemit: boolean
  paramschema: ParamSchema
  /** The order the kind declares its parameters in; a JSON object has none. */
  paramorder: string[]
}

export interface Diagnostic {
  kind: string
  data: Record<string, any>
  summary: Record<string, any>
  warnings: string[]
  panels: Record<string, Diagnostic>
}

export interface LokiEvent {
  event: string
  origin?: Origin
  seq?: number
  time?: number
  payload: Record<string, any>
}

/** A watched port: what a diagnostic panel or a table preview is open on. */
export interface Watched {
  id: string
  port: string
}

export const CATEGORIES = [
  'sources',
  'files',
  'rows',
  'columns',
  'summarizing',
  'joins',
  'time series',
  'models',
  'acausal',
  'other',
] as const
