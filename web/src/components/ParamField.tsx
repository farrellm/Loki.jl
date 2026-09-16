import { useEffect, useState } from 'react'
import { CodeField } from './CodeField'
import type { ParamSchema } from '../types'

// A parameter edit is a graph edit: it invalidates the node and everything
// downstream. So a text field commits when you leave it or press Enter, not on
// every keystroke — otherwise typing `close` would throw away four results on
// the way to the fifth.
function CommittedInput({
  id,
  value,
  onCommit,
  ...rest
}: {
  id: string
  value: string
  onCommit: (text: string) => void
} & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange'>) {
  const [draft, setDraft] = useState(value)
  // Take the server's value again whenever it changes under us — an agent may
  // have edited the same node.
  useEffect(() => setDraft(value), [value])
  return (
    <input
      {...rest}
      id={id}
      value={draft}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => draft !== value && onCommit(draft)}
      onKeyDown={(e) => {
        if (e.key === 'Enter') e.currentTarget.blur()
        if (e.key === 'Escape') setDraft(value)
      }}
    />
  )
}

// One field per parameter, generated from the kind's JSON Schema. Loki's own
// vocabulary rides in `x-loki`, which is what turns a string into a column
// picker, a context picker, or a code editor rather than a text box.
//
// Column pickers are fed by the last evaluated schema of the node's input. A
// node that has never run has no schema to offer, so the field stays free text
// rather than an empty dropdown that looks broken.

export interface FieldContext {
  columns: string[]
  contexts: string[]
  tables: string[]
}

export function ParamField({
  name,
  schema,
  value,
  required,
  context,
  onChange,
}: {
  name: string
  schema: ParamSchema
  value: unknown
  required: boolean
  context: FieldContext
  onChange: (value: unknown) => void
}) {
  const loki = schema['x-loki']
  const id = `param-${name}`

  return (
    <div className="field">
      <label htmlFor={id}>
        <span className="field__name mono">{name}</span>
        {required && (
          <span className="field__required" title="Required">
            required
          </span>
        )}
      </label>
      {schema.description && <p className="field__doc">{schema.description}</p>}
      <Control
        id={id}
        name={name}
        schema={schema}
        loki={loki}
        value={value}
        context={context}
        onChange={onChange}
      />
    </div>
  )
}

function Control({
  id,
  name,
  schema,
  loki,
  value,
  context,
  onChange,
}: {
  id: string
  name: string
  schema: ParamSchema
  loki: string | undefined
  value: unknown
  context: FieldContext
  onChange: (value: unknown) => void
}) {
  const blank = value === null || value === undefined

  if (loki === 'code') {
    return (
      <CodeField
        value={blank ? '' : String(value)}
        hint="Julia, evaluated in the session's module"
        onCommit={(text) => onChange(text.trim() === '' ? null : text)}
      />
    )
  }

  if (loki === 'column' || loki === 'context' || loki === 'table') {
    const options =
      loki === 'column'
        ? context.columns
        : loki === 'context'
          ? context.contexts
          : context.tables
    // With nothing to choose from — a node that has never run — free text is
    // more useful than an empty dropdown.
    if (options.length === 0) {
      return (
        <CommittedInput
          id={id}
          className="mono"
          value={blank ? '' : String(value)}
          placeholder={`a ${loki} name`}
          onCommit={(text) => onChange(text === '' ? null : text)}
        />
      )
    }
    return (
      <select
        id={id}
        className="mono"
        value={blank ? '' : String(value)}
        onChange={(e) => onChange(e.target.value === '' ? null : e.target.value)}
      >
        <option value="">—</option>
        {options.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
    )
  }

  if (loki === 'columns') {
    const current = Array.isArray(value) ? value.join(', ') : blank ? '' : String(value)
    return (
      <CommittedInput
        id={id}
        className="mono"
        value={current}
        placeholder="one column, or several separated by commas"
        onCommit={(text) => {
          const parts = text
            .split(',')
            .map((p) => p.trim())
            .filter((p) => p !== '')
          onChange(parts.length === 0 ? null : parts.length === 1 ? parts[0] : parts)
        }}
      />
    )
  }

  if (loki === 'summarizers') {
    return (
      <SummarizerList
        value={Array.isArray(value) ? (value as Record<string, unknown>[]) : []}
        onChange={onChange}
      />
    )
  }

  if (schema.enum) {
    return (
      <select
        id={id}
        value={blank ? '' : String(value)}
        onChange={(e) => onChange(e.target.value === '' ? null : e.target.value)}
      >
        <option value="">—</option>
        {schema.enum.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
    )
  }

  if (schema.type === 'boolean') {
    return (
      <input
        id={id}
        type="checkbox"
        checked={value === true}
        onChange={(e) => onChange(e.target.checked)}
      />
    )
  }

  if (schema.type === 'integer' || schema.type === 'number') {
    return (
      <CommittedInput
        id={id}
        type="number"
        className="num"
        step={schema.type === 'integer' ? 1 : 'any'}
        value={blank ? '' : String(value)}
        onCommit={(text) => {
          if (text === '') return onChange(null)
          const parsed =
            schema.type === 'integer'
              ? Number.parseInt(text, 10)
              : Number.parseFloat(text)
          onChange(Number.isNaN(parsed) ? null : parsed)
        }}
      />
    )
  }

  if (schema.type === 'array') {
    // `integers`: the ARMA orders, and the rolling windows.
    const current = Array.isArray(value) ? value.join(', ') : ''
    return (
      <CommittedInput
        id={id}
        className="mono"
        value={current}
        placeholder={name === 'order' ? 'p, d, q' : 'numbers separated by commas'}
        onCommit={(text) => {
          const parts = text
            .split(',')
            .map((p) => Number.parseInt(p.trim(), 10))
            .filter((p) => !Number.isNaN(p))
          onChange(parts.length === 0 ? null : parts)
        }}
      />
    )
  }

  return (
    <CommittedInput
      id={id}
      className="mono"
      value={blank ? '' : String(value)}
      onCommit={(text) => onChange(text === '' ? null : text)}
    />
  )
}

// A summarizer entry is `{summarizer, columns, options}`. The options are free
// text per entry, because each summarizer's are its own.
function SummarizerList({
  value,
  onChange,
}: {
  value: Record<string, unknown>[]
  onChange: (value: unknown) => void
}) {
  const replace = (index: number, entry: Record<string, unknown>) =>
    onChange(value.map((e, i) => (i === index ? entry : e)))

  return (
    <div className="summarizers">
      {value.map((entry, index) => (
        <div className="summarizers__entry" key={index}>
          <input
            className="mono"
            value={String(entry.summarizer ?? '')}
            placeholder="Mean"
            aria-label="Summarizer"
            onChange={(e) => replace(index, { ...entry, summarizer: e.target.value })}
          />
          <input
            className="mono"
            value={
              Array.isArray(entry.columns) ? (entry.columns as string[]).join(', ') : ''
            }
            placeholder="columns"
            aria-label="Columns"
            onChange={(e) =>
              replace(index, {
                ...entry,
                columns: e.target.value
                  .split(',')
                  .map((p) => p.trim())
                  .filter((p) => p !== ''),
              })
            }
          />
          <button
            type="button"
            className="quiet"
            aria-label={`Remove summarizer ${index + 1}`}
            onClick={() => onChange(value.filter((_, i) => i !== index))}
          >
            Remove
          </button>
        </div>
      ))}
      <button
        type="button"
        onClick={() => onChange([...value, { summarizer: '', columns: [] }])}
      >
        Add a summarizer
      </button>
    </div>
  )
}
