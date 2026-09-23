import { describe, expect, it } from 'vitest'
import {
  check,
  convert,
  defaultTimetype,
  extent,
  ordered,
  parseTime,
  span,
  usedBy,
} from './contexts'
import type { GraphNode, NodeKind } from './types'

describe('parseTime', () => {
  it('reads each time type the server can build a Context from', () => {
    expect(parseTime('Int64', ' 401 ')).toEqual({ value: 401, axis: 401 })
    expect(parseTime('Float64', '-1.5e2')).toEqual({ value: -150, axis: -150 })
    expect(parseTime('Date', '2015-01-02')?.value).toBe('2015-01-02')
    expect(parseTime('DateTime', '2015-01-01T00:00')?.axis).toBe(Date.UTC(2015, 0, 1))
    expect(parseTime('DateTime', '2015-01-01T00:00:00.5')?.axis).toBe(
      Date.UTC(2015, 0, 1, 0, 0, 0, 500),
    )
  })

  it('refuses what Julia would refuse, rather than rolling it over', () => {
    expect(parseTime('Int64', '1.5')).toBeNull()
    expect(parseTime('Date', '2015-02-30')).toBeNull()
    expect(parseTime('Date', '2015-1-1')).toBeNull()
    expect(parseTime('DateTime', '2015-01-01T24:00')).toBeNull()
    expect(parseTime('Time', '12:00')).toBeNull()
  })
})

describe('convert', () => {
  it('carries an end between Date and DateTime, and clears what will not parse', () => {
    expect(convert('Date', 'DateTime', '2015-03-01')).toBe('2015-03-01T00:00:00')
    expect(convert('Date', 'DateTime', '2015-03')).toBe('2015-03')
    expect(convert('DateTime', 'Date', '2015-03-01T09:30:00')).toBe('2015-03-01')
    expect(convert('Int64', 'Date', '401')).toBe('')
    expect(convert('Int64', 'Float64', '401')).toBe('401')
  })
})

describe('check', () => {
  const draft = { name: 'train', timetype: 'Int64', start: '0', stop: '200' }
  const problem = (d: Partial<typeof draft>, taken: string[] = []) => {
    const c = check({ ...draft, ...d }, taken)
    return c.ok ? null : c.problem
  }

  it('passes a well-formed window', () => {
    expect(problem({})).toBeNull()
  })

  it('says which part is wrong, and how to put it right', () => {
    expect(problem({ name: ' ' })).toMatch(/name/)
    expect(problem({ name: 'my window' })).toMatch(/not a Julia name/)
    expect(problem({}, ['train'])).toMatch(/already exists/)
    expect(problem({ start: 'x' })).toBe('The start is not an Int64, such as 0.')
    expect(problem({ timetype: 'Date', start: '2015-01-01', stop: 'soon' })).toBe(
      'The stop is not a Date, such as 2015-01-01.',
    )
    expect(problem({ start: '300' })).toMatch(/after the stop/)
  })

  it('accepts a zero-length window, as Context does', () => {
    expect(problem({ stop: '0' })).toBeNull()
  })
})

describe('defaultTimetype', () => {
  it('follows the session, then a time column, then falls back to Int64', () => {
    const date = { timetype: 'Date', start: '2015-01-01', stop: '2016-01-01' }
    expect(defaultTimetype({ analysis: date })).toBe('Date')
    const table = {
      name: 'prices',
      rows: 3,
      columns: ['time', 'close'],
      types: ['DateTime', 'Float64'],
      frame: false,
    }
    expect(defaultTimetype({}, [table])).toBe('DateTime')
    expect(defaultTimetype({})).toBe('Int64')
  })
})

describe('ordered', () => {
  it('puts analysis first and the rest in time order', () => {
    const c = (start: number, stop: number) => ({ timetype: 'Int64', start, stop })
    expect(
      ordered({ test: c(200, 400), analysis: c(0, 400), train: c(0, 200), a: c(0, 5) }),
    ).toEqual(['analysis', 'a', 'train', 'test'])
  })
})

describe('span and extent', () => {
  it('puts every window on one axis', () => {
    expect(span({ timetype: 'Int64', start: 0, stop: 10 })).toEqual([0, 10])
    expect(span({ timetype: 'Time', start: '12:00', stop: '13:00' })).toBeNull()
    expect(
      extent([
        [0, 10],
        [5, 20],
      ]),
    ).toEqual([0, 20])
    expect(extent([[3, 3]])).toEqual([2, 4])
    expect(extent([])).toBeNull()
  })
})

describe('usedBy', () => {
  it('finds the nodes whose context parameters name a context', () => {
    const kind = {
      name: 'fit',
      paramschema: {
        properties: {
          context: { type: 'string', 'x-loki': 'context' },
          label: { type: 'string' },
        },
      },
    } as unknown as NodeKind
    const node = (id: string, params: Record<string, unknown>) =>
      ({ id, kind: 'fit', params }) as unknown as GraphNode
    const nodes = [
      node('n1', { context: 'train' }),
      node('n2', { context: 'test' }),
      node('n3', { label: 'train' }),
    ]
    expect(usedBy('train', nodes, [kind])).toEqual(['n1'])
  })
})
