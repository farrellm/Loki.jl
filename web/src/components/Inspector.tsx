import { useMemo } from 'react'
import { ParamField, type FieldContext } from './ParamField'
import { api } from '../api'
import type { SessionStore } from '../store'
import type { GraphNode, NodeKind } from '../types'

// The inspector is a form generated from the node kind's `paramschema` — the
// same schema the MCP server publishes as a tool's input schema, so the user and
// an agent edit one vocabulary rather than two.

export function Inspector({ store }: { store: SessionStore }) {
  const { graph, kinds, selected, act } = store
  const node = graph?.nodes.find((n) => n.id === selected) ?? null
  const kind = kinds.find((k) => k.name === node?.kind) ?? null

  const fieldContext: FieldContext = useMemo(() => {
    if (graph === null || node === null) {
      return { columns: [], contexts: [], tables: [] }
    }
    // Column pickers are fed by the last evaluated schema of the node's input —
    // CausalFrames schemas are data-driven, so there is nothing to offer until
    // something upstream has produced a chunk.
    const upstream = graph.edges
      .filter((e) => e.to[0] === node.id)
      .map((e) => graph.nodes.find((n) => n.id === e.from[0]))
    const columns = new Set<string>()
    for (const source of upstream) {
      for (const shape of Object.values(source?.results ?? {})) {
        for (const column of shape.columns) columns.add(column)
      }
    }
    // A node that has run knows its own output columns too, which is what the
    // `name` and `column` fields of a self-referring parameter want.
    for (const shape of Object.values(node.results)) {
      for (const column of shape.columns) columns.add(column)
    }
    return {
      columns: [...columns],
      contexts: Object.keys(graph.contexts),
      tables: graph.tables.map((t) => t.name),
    }
  }, [graph, node])

  if (node === null || kind === null) {
    return (
      <section className="inspector" aria-label="Inspector">
        <p className="inspector__none">
          Select a node to see and change what it does.
        </p>
      </section>
    )
  }

  const properties = kind.paramschema.properties ?? {}
  const required = new Set(kind.paramschema.required ?? [])
  // Declaration order, not hash order: `family` and `column` before the options.
  const order = (kind.paramorder ?? []).filter((name) => name in properties)
  const names = [
    ...order,
    ...Object.keys(properties).filter((name) => !order.includes(name)),
  ]

  // Only the parameter that changed. The server merges it, so two edits in quick
  // succession cannot undo each other by each sending a copy of the whole object
  // taken before the other landed.
  const setParam = (name: string, value: unknown) =>
    void act('Could not change the parameter', () =>
      api.updateParams(node.id, { [name]: value ?? null }),
    )

  return (
    <section className="inspector" aria-label="Inspector" data-testid="inspector">
      <header className="inspector__head">
        <div>
          <h2 className="mono">{node.kind}</h2>
          <span className="inspector__id mono">{node.id}</span>
        </div>
        {node.acausal && (
          <span className="badge badge--ahead" title="Looks ahead in time">
            looks ahead
          </span>
        )}
      </header>

      {kind.doc && <p className="inspector__doc">{kind.doc}</p>}

      {node.error !== null && (
        <div className="problem" role="alert">
          <h3>
            {node.status === 'blocked'
              ? `Blocked by node ${node.error.node}`
              : 'This node failed'}
          </h3>
          <pre className="problem__message">{node.error.message}</pre>
        </div>
      )}

      <div className="inspector__fields">
        {names.map((name) => (
          <ParamField
            key={name}
            name={name}
            schema={properties[name]}
            value={node.params[name]}
            required={required.has(name)}
            context={fieldContext}
            onChange={(value) => setParam(name, value)}
          />
        ))}
        {Object.keys(properties).length === 0 && (
          <p className="inspector__none">This operator takes no parameters.</p>
        )}
      </div>

      <footer className="inspector__actions">
        <button
          type="button"
          className="primary"
          onClick={() => void act('Could not run', () => api.run([node.id]))}
        >
          Run this node
        </button>
        {node.outputs.map((port) => (
          <PortActions key={port} node={node} port={port} store={store} />
        ))}
        {node.write && (
          <button
            type="button"
            onClick={() => void act('Could not write', () => api.write(node.id))}
          >
            Write the file
          </button>
        )}
        <button
          type="button"
          onClick={() => void act('Could not remove', () => api.removeNode(node.id))}
        >
          Delete node
        </button>
      </footer>
    </section>
  )
}

function PortActions({
  node,
  port,
  store,
}: {
  node: GraphNode
  port: string
  store: SessionStore
}) {
  const { act, setWatched } = store
  const evaluated = node.results[port] !== undefined
  return (
    <div className="portactions">
      {node.outputs.length > 1 && <span className="portactions__name mono">{port}</span>}
      <button type="button" disabled={!evaluated} onClick={() => setWatched({ id: node.id, port })}>
        {evaluated ? `Inspect ${node.results[port].rows.toLocaleString()} rows` : 'Not run yet'}
      </button>
      <button
        type="button"
        onClick={() => void act('Could not freeze', () => api.freeze(node.id, port))}
      >
        Freeze output
      </button>
    </div>
  )
}

export type { NodeKind }
