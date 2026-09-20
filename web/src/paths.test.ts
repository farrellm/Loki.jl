import { describe, expect, it } from 'vitest'
import {
  basename,
  formatModified,
  joinPath,
  matchesSuffix,
  parentOf,
  splitPath,
} from './paths'

describe('splitPath', () => {
  it('starts every path at the root, so there is always somewhere to climb to', () => {
    expect(splitPath('/home/farrellm/Loki')).toEqual([
      { name: '/', path: '/' },
      { name: 'home', path: '/home' },
      { name: 'farrellm', path: '/home/farrellm' },
      { name: 'Loki', path: '/home/farrellm/Loki' },
    ])
  })

  it('leaves the root as just the root', () => {
    expect(splitPath('/')).toEqual([{ name: '/', path: '/' }])
  })
})

describe('joinPath', () => {
  it('does not double the slash at the root', () => {
    expect(joinPath('/', 'home')).toBe('/home')
    expect(joinPath('/home', 'farrellm')).toBe('/home/farrellm')
  })

  it('lets a typed absolute path replace the folder outright', () => {
    expect(joinPath('/home/farrellm', '/tmp/scratch.loki.json')).toBe(
      '/tmp/scratch.loki.json',
    )
  })
})

describe('parentOf and basename', () => {
  it('climbs one level, and stops at the root', () => {
    expect(parentOf('/home/farrellm/Loki')).toBe('/home/farrellm')
    expect(parentOf('/home')).toBe('/')
    expect(parentOf('/')).toBe('/')
  })

  it('ignores a trailing slash, which is how a directory is written', () => {
    expect(parentOf('/home/farrellm/')).toBe('/home')
    expect(basename('/home/farrellm/')).toBe('farrellm')
  })

  it('names the file', () => {
    expect(basename('/tmp/prices.loki.json')).toBe('prices.loki.json')
  })
})

describe('matchesSuffix', () => {
  it('matches whatever case the file is written in', () => {
    expect(matchesSuffix('Analysis.LOKI.JSON', ['.loki.json'])).toBe(true)
    expect(matchesSuffix('prices.csv', ['.loki.json'])).toBe(false)
  })

  it('asked for nothing, matches everything — the picker is unfiltered', () => {
    expect(matchesSuffix('prices.csv')).toBe(true)
    expect(matchesSuffix('prices.csv', [])).toBe(true)
  })
})

describe('formatModified', () => {
  const now = new Date(2026, 8, 19, 16, 30)

  it('writes today to the minute, because that is what tells two saves apart', () => {
    expect(formatModified('2026-09-19T14:02:31', now)).toBe('14:02')
  })

  it('writes this year to the day', () => {
    expect(formatModified('2026-03-04T09:00:00', now)).toBe('4 Mar')
  })

  it('writes an older file in full', () => {
    expect(formatModified('2025-11-03T09:00:00', now)).toBe('2025-11-03')
  })

  it('shows nothing for a directory, which has no time', () => {
    expect(formatModified(undefined, now)).toBe('')
    expect(formatModified('not a date', now)).toBe('')
  })
})
