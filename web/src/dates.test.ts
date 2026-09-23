import { describe, expect, it } from 'vitest'
import {
  addDays,
  addMonths,
  DATETIME_MASK,
  maskDate,
  monthGrid,
  skeletonRest,
  viewOf,
  type Mask,
} from './dates'

// Type `keys` into a field holding `text`, one at a time at the caret, as a
// browser would before the mask sees it.
function type(text: string, caret: number, keys: string, mask?: Mask) {
  for (const key of keys) {
    const next = text.slice(0, caret) + key + text.slice(caret)
    ;({ text, caret } = maskDate(text, next, caret + 1, 'insertText', mask))
  }
  return { text, caret }
}

function backspace(text: string, caret: number, mask?: Mask) {
  const next = text.slice(0, caret - 1) + text.slice(caret)
  return maskDate(text, next, caret - 1, 'deleteContentBackward', mask)
}

function del(text: string, caret: number) {
  const next = text.slice(0, caret) + text.slice(caret + 1)
  return maskDate(text, next, caret, 'deleteContentForward')
}

describe('maskDate', () => {
  it('writes the dashes, so only digits are typed', () => {
    expect(type('', 0, '2015')).toEqual({ text: '2015', caret: 4 })
    expect(type('', 0, '20150')).toEqual({ text: '2015-0', caret: 6 })
    expect(type('', 0, '20150301')).toEqual({ text: '2015-03-01', caret: 10 })
  })

  it('drops what is not a digit, and stops at eight', () => {
    expect(type('', 0, '2015x')).toEqual({ text: '2015', caret: 4 })
    expect(type('', 0, '2015030112').text).toBe('2015-03-01')
  })

  it('takes a pasted date in any of its spellings', () => {
    for (const pasted of ['2015-03-01', '20150301', '2015/03/01', ' 2015-03-01T00:00 ']) {
      expect(maskDate('', pasted, pasted.length, 'insertFromPaste').text).toBe(
        '2015-03-01',
      )
    }
  })

  it('deletes the digit beyond a dash, never the dash', () => {
    // Backspace from the end walks back over each dash.
    let s = { text: '2015-03-01', caret: 10 }
    const seen = []
    for (let i = 0; i < 5; i++) {
      s = backspace(s.text, s.caret)
      seen.push(s.text)
    }
    expect(seen).toEqual(['2015-03-0', '2015-03', '2015-0', '2015', '201'])
    // With the caret just after a dash, backspace takes the digit before it.
    expect(backspace('2015-03-01', 5)).toEqual({ text: '2010-30-1', caret: 3 })
    // With it just before one, delete takes the digit after it.
    expect(del('2015-03-01', 4)).toEqual({ text: '2015-30-1', caret: 4 })
  })

  it('overwrites rather than inserts once the field is full', () => {
    expect(type('2015-03-01', 5, '1')).toEqual({ text: '2015-13-01', caret: 6 })
    expect(type('2015-03-01', 0, '1999')).toEqual({ text: '1999-03-01', caret: 4 })
  })
})

describe('maskDate on a DateTime', () => {
  const dt = DATETIME_MASK

  it('writes the T and the colons as well as the dashes', () => {
    expect(type('', 0, '2015030109', dt)).toEqual({ text: '2015-03-01T09', caret: 13 })
    expect(type('', 0, '20150301093000', dt)).toEqual({
      text: '2015-03-01T09:30:00',
      caret: 19,
    })
    const pasted = '2015-03-01 09:30:00'
    expect(maskDate('', pasted, pasted.length, 'insertFromPaste', dt).text).toBe(
      '2015-03-01T09:30:00',
    )
  })

  it('steps back over a T or a colon', () => {
    expect(backspace('2015-03-01T09:30', 14, dt)).toEqual({
      text: '2015-03-01T03:0',
      caret: 12,
    })
    // The digits after it close up, as they do behind any deleted digit.
    expect(backspace('2015-03-01T09', 11, dt)).toEqual({
      text: '2015-03-00T9',
      caret: 9,
    })
  })

  it('overwrites inside a complete value, and runs on into milliseconds at its end', () => {
    const full = '2015-03-01T09:30:00'
    expect(type(full, 11, '1', dt)).toEqual({ text: '2015-03-01T19:30:00', caret: 12 })
    expect(type(full, 19, '5', dt)).toEqual({ text: '2015-03-01T09:30:00.5', caret: 21 })
    expect(type(full, 19, '12345', dt).text).toBe('2015-03-01T09:30:00.123')
  })

  it('draws the skeleton to the seconds, and the milliseconds once they start', () => {
    expect(skeletonRest(dt, '2015-03-01T0')).toBe('h:mm:ss')
    expect(skeletonRest(dt, '2015-03-01T09:30:00')).toBe('')
    expect(skeletonRest(dt, '2015-03-01T09:30:00.5')).toBe('ss')
  })
})

describe('the calendar', () => {
  it('lays a month out Monday first', () => {
    // 1 March 2015 was a Sunday.
    const march = monthGrid({ y: 2015, m: 3 })
    expect(march[0]).toEqual([null, null, null, null, null, null, 1])
    expect(march.flat().filter((d) => d !== null)).toHaveLength(31)
    expect(march.every((w) => w.length === 7)).toBe(true)
    expect(Math.max(...monthGrid({ y: 2016, m: 2 }).flat().map(Number))).toBe(29)
    expect(Math.max(...monthGrid({ y: 2015, m: 2 }).flat().map(Number))).toBe(28)
  })

  it('follows what has been typed so far', () => {
    expect(viewOf('201')).toBeNull()
    expect(viewOf('2015')).toEqual({ y: 2015, m: null })
    expect(viewOf('2015-0')).toEqual({ y: 2015, m: null })
    expect(viewOf('2015-03')).toEqual({ y: 2015, m: 3 })
    expect(viewOf('2015-19')).toEqual({ y: 2015, m: 12 })
  })

  it('steps across months and years', () => {
    expect(addMonths({ y: 2015, m: 12 }, 1)).toEqual({ y: 2016, m: 1 })
    expect(addMonths({ y: 2015, m: 1 }, -12)).toEqual({ y: 2014, m: 1 })
    expect(addDays('2015-02-28', 1)).toBe('2015-03-01')
    expect(addDays('2016-03-01', -1)).toBe('2016-02-29')
    expect(addDays('0050-01-01', -1)).toBe('0049-12-31')
  })
})
