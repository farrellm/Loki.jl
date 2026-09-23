import { expect, test, type Page } from '@playwright/test'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

// Build a graph, run it, read a diagnostic, export. The iPhone project runs the
// same specs with touch only — Playwright's device profile has no mouse — so a
// hover-only or drag-only affordance fails here rather than on someone's phone.

const TOKEN = process.env.LOKI_TEST_TOKEN ?? 'playwright-token'

async function open(page: Page) {
  await page.goto(`/#token=${TOKEN}`)
  await expect(page.getByTestId('session-bar')).toBeVisible()
  // The token is exchanged for a cookie and taken out of the address bar, so it
  // never lingers in history.
  await expect.poll(() => page.url()).not.toContain('token=')

  // One session serves the whole run, so a spec starts from the source alone
  // rather than on top of whatever the last one built. Deleting from outside the
  // app also exercises the socket: the canvas has to hear about it.
  await page.evaluate(async () => {
    const graph = await (await fetch('/api/graph', { credentials: 'same-origin' })).json()
    for (const node of graph.nodes) {
      if (node.id !== 'n1') {
        await fetch(`/api/nodes/${node.id}`, {
          method: 'DELETE',
          credentials: 'same-origin',
        })
      }
    }
  })
  await expect(page.locator('.node')).toHaveCount(1)
}

const narrow = (page: Page) => page.viewportSize()!.width < 900

const focusIsInPicker = (page: Page) =>
  page.evaluate(() =>
    document
      .querySelector('[data-testid="file-picker"]')!
      .contains(document.activeElement),
  )

/** Tap or click, whichever this project has. */
async function tap(page: Page, target: ReturnType<Page['getByTestId']>) {
  if (narrow(page)) await target.tap()
  else await target.click()
}

/** Open a panel, wherever it lives at this width. */
async function panel(page: Page, id: 'diagnostics' | 'table' | 'inspector') {
  if (narrow(page)) {
    await page.getByTestId(`sheet-tab-${id}`).tap()
  } else if (id !== 'inspector') {
    await page.getByTestId(`panel-tab-${id}`).click()
  }
}

const nodeIds = (page: Page) =>
  page.evaluate(() =>
    [...document.querySelectorAll('[data-testid^="node-"]')].map((n) =>
      n.getAttribute('data-testid')!.replace('node-', ''),
    ),
  )

/** Add a node by tapping a kind and then the canvas, and return its id. */
async function addNode(page: Page, kind: string): Promise<string> {
  const before = new Set(await nodeIds(page))
  const chip = page.getByTestId(`kind-${kind}`)
  if (narrow(page)) {
    await page.getByTestId('sheet-tab-palette').tap()
    await chip.tap()
  } else {
    await chip.click()
  }
  const canvas = page.getByTestId('canvas')
  const box = (await canvas.boundingBox())!
  // Away from the nodes, from React Flow's zoom controls in the bottom left, and
  // — on a phone — from the sheet along the bottom: the tap has to reach the
  // pane itself.
  const point = narrow(page)
    ? { x: box.width * 0.72, y: box.height * 0.3 }
    : { x: box.width * 0.75, y: box.height * 0.82 }
  if (narrow(page)) await canvas.tap({ position: point })
  else await canvas.click({ position: point })

  // React Flow does not render in creation order, so the id is the one that was
  // not there a moment ago, not the last in the DOM.
  await expect
    .poll(async () => (await nodeIds(page)).filter((id) => !before.has(id)).length)
    .toBe(1)
  const added = (await nodeIds(page)).filter((id) => !before.has(id))
  return added[0]
}

/** Bring the whole graph into view — a node added off-screen is not clickable. */
async function fitView(page: Page) {
  const fit = page.locator('.react-flow__controls-fitview')
  if (narrow(page)) await fit.tap()
  else await fit.click()
}

/** Get the sheet out of the way, the way a thumb on the handle would. */
async function collapseSheet(page: Page) {
  if (!narrow(page)) return
  const sheet = page.getByTestId('sheet')
  for (let i = 0; i < 3; i++) {
    if ((await sheet.getAttribute('data-height')) === 'peek') return
    await page.locator('.sheet__grab').tap()
  }
}

async function select(page: Page, id: string) {
  await collapseSheet(page)
  await fitView(page)
  const node = page.getByTestId(`node-${id}`)
  if (narrow(page)) await node.tap()
  else await node.click()
  await panel(page, 'inspector')
}

test.describe.configure({ mode: 'serial' })

test('builds a graph, runs it, reads a diagnostic and exports', async ({ page }) => {
  await open(page)

  // The source is already there; add a transform and wire it up.
  await expect(page.getByTestId('node-n1')).toBeVisible()
  const id = await addNode(page, 'ema')
  await expect(page.getByTestId(`node-${id}`)).toBeVisible()

  await select(page, id)
  await expect(page.getByTestId('inspector')).toContainText('ema')
  // A parameter commits when you leave the field or press Enter, not on every
  // keystroke — an edit invalidates the node and everything downstream.
  const column = page.getByLabel('column', { exact: false }).first()
  await column.fill('close')
  await column.press('Enter')
  const span = page.getByLabel('span', { exact: false }).first()
  await span.fill('12')
  await span.press('Enter')

  // The node shows the line of Julia it exports, so an edit is visible on the
  // canvas rather than only in the form — and both edits survive, which they
  // would not if a parameter change replaced the whole object.
  await expect(page.getByTestId(`node-${id}`)).toContainText('ema(:close; span = 12)')

  // Connect the source to it over the API rather than by dragging a handle: the
  // drag is covered by React Flow, and what matters here is that the canvas
  // renders the edge and the run flows through it.
  await page.evaluate(
    async ([from, to]) => {
      await fetch('/api/edges', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ from: [from, 'out'], to: [to, 'in'] }),
      })
    },
    ['n1', id],
  )
  await expect(page.locator('.react-flow__edge')).toHaveCount(1)

  // Run, and watch the node settle.
  if (narrow(page)) await page.getByTestId('run').tap()
  else await page.getByTestId('run').click()
  await expect(page.getByTestId(`node-${id}`)).toHaveAttribute('data-status', 'ok')
  await expect(page.getByTestId(`node-${id}`)).toContainText('rows')

  // Inspect the port, then read a diagnostic off it.
  await select(page, id)
  const inspect = page.locator('.portactions button', { hasText: 'Inspect' }).first()
  if (narrow(page)) await inspect.tap()
  else await inspect.click()
  await panel(page, 'diagnostics')
  await expect(page.getByTestId('diagnostics')).toBeVisible()
  const acf = page.getByTestId('view-acf')
  if (narrow(page)) await acf.tap()
  else await acf.click()
  await expect(page.getByTestId('plot')).toBeVisible()

  // And the rows behind it.
  await panel(page, 'table')
  await expect(page.getByTestId('table-preview')).toBeVisible()
  await expect(page.getByTestId('table-preview')).toContainText('of 400')

  // The script is the ground truth of what the graph means, so exporting it is
  // part of the loop rather than a separate feature.
  const download = page.waitForEvent('download')
  const exportButton = page.getByTestId('export')
  if (narrow(page)) await exportButton.tap()
  else await exportButton.click()
  expect((await download).suggestedFilename()).toBe('analysis.jl')
})

test('shows a failing node where it failed, and blocks what is downstream', async ({
  page,
}) => {
  await open(page)
  const failing = await page.evaluate(async () => {
    const post = (path: string, body: unknown) =>
      fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify(body),
      }).then((r) => r.json())
    const bad = await post('/api/nodes', {
      kind: 'addcolumns',
      params: { function: 'r -> error("boom")' },
      position: [80, 320],
    })
    const after = await post('/api/nodes', {
      kind: 'head',
      params: { n: 3 },
      position: [360, 320],
    })
    await post('/api/edges', { from: ['n1', 'out'], to: [bad.id, 'in'] })
    await post('/api/edges', { from: [bad.id, 'out'], to: [after.id, 'in'] })
    await post('/api/run', { targets: [after.id] })
    return { bad: bad.id, after: after.id }
  })

  await expect(page.getByTestId(`node-${failing.bad}`)).toHaveAttribute(
    'data-status',
    'error',
  )
  await expect(page.getByTestId(`node-${failing.after}`)).toHaveAttribute(
    'data-status',
    'blocked',
  )
  await select(page, failing.bad)
  await expect(page.getByRole('alert')).toContainText('boom')
})

test('badges an acausal fit and everything downstream of it', async ({ page }) => {
  await open(page)
  const ids = await page.evaluate(async () => {
    const post = (path: string, body: unknown) =>
      fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify(body),
      }).then((r) => r.json())
    const log = await post('/api/nodes', {
      kind: 'logtransform',
      params: { column: 'close' },
      position: [320, 60],
    })
    const fit = await post('/api/nodes', {
      kind: 'fit',
      params: {
        family: 'arma',
        column: 'close_log',
        order: [1, 0, 1],
        fitcontext: 'train',
      },
      position: [600, 60],
    })
    const after = await post('/api/nodes', {
      kind: 'head',
      params: { n: 5 },
      position: [900, 60],
    })
    await post('/api/edges', { from: ['n1', 'out'], to: [log.id, 'in'] })
    await post('/api/edges', { from: [log.id, 'out'], to: [fit.id, 'in'] })
    await post('/api/edges', { from: [fit.id, 'insample'], to: [after.id, 'in'] })
    await post('/api/run', {
      targets: [
        [fit.id, 'insample'],
        [fit.id, 'model'],
      ],
    })
    return { log: log.id, fit: fit.id, after: after.id }
  })

  // Taint is contagious: the fit's in-sample port is acausal, so what reads it is
  // too — and what feeds it is not.
  await expect(page.getByTestId(`node-${ids.fit}`)).toHaveAttribute(
    'data-acausal',
    'true',
  )
  await expect(page.getByTestId(`node-${ids.after}`)).toHaveAttribute(
    'data-acausal',
    'true',
  )
  await expect(page.getByTestId(`node-${ids.log}`)).toHaveAttribute(
    'data-acausal',
    'false',
  )

  // The residual panel is what the fit was made for, and it opens on itself.
  await expect(page.getByTestId(`node-${ids.fit}`)).toHaveAttribute('data-status', 'ok')
  await select(page, ids.fit)
  const inspect = page.locator('.portactions button', { hasText: 'Inspect' }).last()
  if (narrow(page)) await inspect.tap()
  else await inspect.click()
  await panel(page, 'diagnostics')
  await expect(page.getByTestId('view-residuals')).toHaveAttribute(
    'aria-selected',
    'true',
  )
  await expect(page.locator('.verdict')).toContainText(/white noise|autocorrelated/)
  await expect(page.locator('.residuals__cell')).toHaveCount(6)
})

test('keeps a moved node on the canvas through the refetches that follow', async ({
  page,
}) => {
  await open(page)
  await collapseSheet(page)
  const card = page.getByTestId('node-n1')
  const position = () =>
    page.evaluate(async () => {
      const graph = await (
        await fetch('/api/graph', { credentials: 'same-origin' })
      ).json()
      return graph.nodes.find((n: { id: string }) => n.id === 'n1').position as number[]
    })
  const start = await position()

  // Playwright has no touch drag for WebKit, so the phone taps — which selects
  // the node, the start of every drag — and the desktop drags. Either way a
  // selection, a move and a refetch land together; each refetch used to hand
  // React Flow unmeasured nodes, and one that landed at the wrong moment left
  // the node hidden until a reload.
  if (narrow(page)) {
    await card.tap()
  } else {
    const box = (await card.boundingBox())!
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
    await page.mouse.down()
    await page.mouse.move(box.x + box.width / 2 + 60, box.y + box.height / 2 + 40, {
      steps: 8,
    })
    await page.mouse.up()
    await expect.poll(position).not.toEqual(start)
  }

  // A move from outside the app is one more refetch, of the node just touched.
  await page.evaluate(async (at) => {
    await fetch('/api/nodes/n1', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ position: at }),
    })
  }, start)
  await expect.poll(position).toEqual(start)
  await expect(card).toBeVisible()
})

test('learns about a change it did not make itself', async ({ page, context }) => {
  await open(page)
  const before = await page.locator('.node').count()

  // A raw fetch goes around the app's own state, so the only way the canvas can
  // learn about this node is the event socket telling it to refetch. This is the
  // path an agent's edit takes in Milestone 4, and the user's second tab today.
  const id = await page.evaluate(async () => {
    const r = await fetch('/api/nodes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ kind: 'emptyframe', params: {}, position: [80, 520] }),
    })
    return (await r.json()).id as string
  })
  await expect(page.locator('.node')).toHaveCount(before + 1)
  await expect(page.getByTestId(`node-${id}`)).toBeVisible()

  // And it survives losing the network. The socket's own reconnect and resync
  // rules — a gap in `seq`, the server's `desync`, the backoff — are unit-tested
  // in src/ws.test.ts, where the socket can be driven directly; what is checked
  // here is that the app is still usable afterwards.
  await context.setOffline(true)
  await context.setOffline(false)
  await page.evaluate(async (nid) => {
    await fetch(`/api/nodes/${nid}`, { method: 'DELETE', credentials: 'same-origin' })
  }, id)
  await expect(page.locator('.node')).toHaveCount(before)
})

test('adds, edits and removes a context from the bar', async ({ page }, info) => {
  await open(page)
  // Both projects share one server, so each works on a context of its own, and
  // clears what a failed earlier attempt may have left behind.
  const name = `holdout_${info.project.name}`
  await page.evaluate(async (n) => {
    await fetch(`/api/contexts/${n}`, { method: 'DELETE', credentials: 'same-origin' })
  }, name)
  const contexts = () =>
    page.evaluate(async () =>
      (await fetch('/api/contexts', { credentials: 'same-origin' })).json(),
    )

  // The window in the bar is the button that edits it, at every width.
  await expect(page.getByTestId('session-window')).toHaveText('0 → 401')
  await tap(page, page.getByTestId('session-window'))
  const band = page.getByTestId('contexts')
  await expect(band).toBeVisible()
  await expect(page.getByTestId('context-analysis')).toContainText('0 → 401')
  await expect(page.getByTestId('context-train')).toContainText('0 → 201')

  // A new context starts from the analysis window; a bad value is refused in
  // place, and never sent.
  await tap(page, page.getByTestId('context-add'))
  await page.getByTestId('context-name').fill(name)
  await expect(page.getByTestId('context-start')).toHaveValue('0')
  await page.getByTestId('context-start').fill('3x')
  await expect(page.getByTestId('context-problem')).toHaveText(
    'The start is not an Int64, such as 0.',
  )
  await expect(page.getByTestId('context-save')).toBeDisabled()
  await page.getByTestId('context-start').fill('201')
  // The interval redraws as it is typed, before anything is saved.
  await expect(page.getByTestId('context-draft')).toBeVisible()
  await tap(page, page.getByTestId('context-save'))
  await expect(page.getByTestId(`context-${name}`)).toContainText('201 → 401')
  expect((await contexts())[name]).toEqual({ timetype: 'Int64', start: 201, stop: 401 })

  // Editing keeps the name and changes the window.
  await tap(page, page.getByTestId(`context-${name}`).locator('.contexts__pick'))
  await page.getByTestId('context-stop').fill('350')
  await page.getByTestId('context-stop').press('Enter')
  await expect(page.getByTestId(`context-${name}`)).toContainText('201 → 350')
  expect((await contexts())[name].stop).toBe(350)

  // Removing takes two taps, and analysis cannot be removed at all.
  await tap(page, page.getByTestId('context-analysis').locator('.contexts__pick'))
  await expect(page.getByTestId('context-remove')).toHaveCount(0)
  await tap(page, page.getByTestId(`context-${name}`).locator('.contexts__pick'))
  await tap(page, page.getByTestId('context-remove'))
  await expect(page.getByTestId(`context-${name}`)).toBeVisible()
  await tap(page, page.getByTestId('context-remove-confirm'))
  await expect(page.getByTestId(`context-${name}`)).toHaveCount(0)
  expect(name in (await contexts())).toBe(false)

  // Escape closes the band, and focus goes back to the button that opened it.
  await page.keyboard.press('Escape')
  await expect(band).toBeHidden()
  await expect(page.getByTestId('session-window')).toBeFocused()
})

test('types and picks the ends of a Date context', async ({ page }, info) => {
  await open(page)
  const name = `daily_${info.project.name}`
  await page.evaluate(async (n) => {
    await fetch(`/api/contexts/${n}`, { method: 'DELETE', credentials: 'same-origin' })
  }, name)

  await tap(page, page.getByTestId('session-window'))
  await tap(page, page.getByTestId('context-add'))
  await page.getByTestId('context-name').fill(name)
  // The analysis window's Int64 ends mean nothing as dates, so they go.
  await page.getByTestId('context-timetype').selectOption('Date')
  const start = page.getByTestId('context-start')
  const stop = page.getByTestId('context-stop')
  await expect(start).toHaveValue('')

  // Digits only: the dashes are the field's, and Backspace steps over them.
  await start.focus()
  await start.pressSequentially('20150301')
  await expect(start).toHaveValue('2015-03-01')
  for (let i = 0; i < 3; i++) await start.press('Backspace')
  await expect(start).toHaveValue('2015-0')
  await start.pressSequentially('214')
  await expect(start).toHaveValue('2015-02-14')

  // The calendar followed the typing to February; a day picked there sets the
  // start, and hands the calendar to the stop.
  await expect(page.getByTestId('calendar')).toContainText('February 2015')
  await tap(page, page.getByTestId('calendar-2015-02-02'))
  await expect(start).toHaveValue('2015-02-02')
  await tap(page, page.getByLabel('Next month'))
  await tap(page, page.getByTestId('calendar-2015-03-20'))
  await expect(stop).toHaveValue('2015-03-20')
  await expect(page.getByTestId('calendar-2015-03-20')).toHaveAttribute(
    'aria-pressed',
    'true',
  )
  // The arrows walk the days, and Page Down turns the month under them.
  await page.getByTestId('calendar-2015-03-20').press('ArrowRight')
  await expect(page.getByTestId('calendar-2015-03-21')).toBeFocused()
  await page.keyboard.press('PageDown')
  await expect(page.getByTestId('calendar-2015-04-21')).toBeFocused()
  await expect(page.getByTestId('calendar')).toContainText('April 2015')

  await tap(page, page.getByTestId('context-save'))
  await expect(page.getByTestId(`context-${name}`)).toContainText(
    '2015-02-02 → 2015-03-20',
  )
  const saved = await page.evaluate(async () =>
    (await fetch('/api/contexts', { credentials: 'same-origin' })).json(),
  )
  expect(saved[name]).toEqual({
    timetype: 'Date',
    start: '2015-02-02',
    stop: '2015-03-20',
  })
  await page.evaluate(async (n) => {
    await fetch(`/api/contexts/${n}`, { method: 'DELETE', credentials: 'same-origin' })
  }, name)
})

test('types and picks the ends of a DateTime context', async ({ page }, info) => {
  await open(page)
  const name = `intraday_${info.project.name}`
  await page.evaluate(async (n) => {
    await fetch(`/api/contexts/${n}`, { method: 'DELETE', credentials: 'same-origin' })
  }, name)

  await tap(page, page.getByTestId('session-window'))
  await tap(page, page.getByTestId('context-add'))
  await page.getByTestId('context-name').fill(name)
  const start = page.getByTestId('context-start')
  const stop = page.getByTestId('context-stop')
  const toEnd = (field: typeof start) =>
    field.evaluate((el: HTMLInputElement) =>
      el.setSelectionRange(el.value.length, el.value.length),
    )

  // A date carries over into a DateTime at midnight rather than being cleared.
  await page.getByTestId('context-timetype').selectOption('Date')
  await start.focus()
  await start.pressSequentially('20150301')
  await page.getByTestId('context-timetype').selectOption('DateTime')
  await expect(start).toHaveValue('2015-03-01T00:00:00')

  // The T and the colons are the field's: Backspace steps back over them, and
  // the time is typed as digits.
  await start.focus()
  await toEnd(start)
  for (let i = 0; i < 6; i++) await start.press('Backspace')
  await expect(start).toHaveValue('2015-03-01')
  await start.pressSequentially('093000')
  await expect(start).toHaveValue('2015-03-01T09:30:00')

  // A picked day takes midnight when its end has no time, and keeps the time
  // when it has one.
  await stop.focus()
  await tap(page, page.getByTestId('calendar-2015-03-05'))
  await expect(stop).toHaveValue('2015-03-05T00:00:00')
  await start.focus()
  await tap(page, page.getByTestId('calendar-2015-03-02'))
  await expect(start).toHaveValue('2015-03-02T09:30:00')

  await tap(page, page.getByTestId('context-save'))
  await expect(page.getByTestId(`context-${name}`)).toContainText(
    '2015-03-02T09:30:00 → 2015-03-05T00:00:00',
  )
  const saved = await page.evaluate(async () =>
    (await fetch('/api/contexts', { credentials: 'same-origin' })).json(),
  )
  expect(saved[name]).toEqual({
    timetype: 'DateTime',
    start: '2015-03-02T09:30:00',
    stop: '2015-03-05T00:00:00',
  })
  await page.evaluate(async (n) => {
    await fetch(`/api/contexts/${n}`, { method: 'DELETE', credentials: 'same-origin' })
  }, name)
})

test('saves the analysis to a path on the server and opens it again', async ({
  page,
}) => {
  await open(page)
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'loki-e2e-'))
  fs.mkdirSync(path.join(scratch, 'nested'))
  const extra = await addNode(page, 'ema')

  // Save somewhere new. That is the file name in the bar, not `Save`, which
  // overwrites — and the two projects share one server, so this spec cannot
  // assume the session has never been saved. The path line is at once the
  // breadcrumb and the file name, so the whole path goes in by typing it,
  // which is also how a path pasted from a terminal gets in.
  await tap(page, page.getByTestId('session-file'))
  await expect(page.getByTestId('file-picker')).toBeVisible()
  await tap(page, page.getByLabel('Type a path'))
  const typed = page.getByTestId('file-path')
  await typed.fill(path.join(scratch, 'e2e.loki.json'))
  await typed.press('Enter')
  await expect(page.getByTestId('file-name')).toHaveValue('e2e.loki.json')
  await tap(page, page.getByTestId('file-confirm'))

  // The bar says what you are looking at, and the file is really there.
  await expect(page.getByTestId('file-picker')).toBeHidden()
  await expect(page.getByTestId('session-file')).toHaveText('e2e.loki.json')
  expect(fs.existsSync(path.join(scratch, 'e2e.loki.json'))).toBe(true)

  // Throw the node away, then open the file back over the top of the session.
  await page.evaluate(async (id) => {
    await fetch(`/api/nodes/${id}`, { method: 'DELETE', credentials: 'same-origin' })
  }, extra)
  await expect(page.locator('.node')).toHaveCount(1)

  await tap(page, page.getByTestId('open'))
  // It starts in the folder the session was saved to, so the file is one tap
  // away rather than a path away.
  await expect(page.getByTestId('file-picker')).toContainText(scratch)
  // Walking into a folder destroys the button that was tapped, and focus falls
  // to the body — from where Tab walks the page behind the scrim. It has to
  // land back inside the band.
  await tap(page, page.getByTestId('file-nested'))
  await expect(page.getByTestId('file-picker')).toContainText('nested')
  expect(await focusIsInPicker(page)).toBe(true)
  await tap(page, page.getByTestId('file-up'))
  expect(await focusIsInPicker(page)).toBe(true)

  // A file is chosen and then confirmed: one tap must not replace the analysis.
  await tap(page, page.getByTestId('file-e2e.loki.json'))
  await expect(page.locator('.node')).toHaveCount(1)
  await tap(page, page.getByTestId('file-confirm'))

  await expect(page.locator('.node')).toHaveCount(2)
  await expect(page.getByTestId('session-file')).toHaveText('e2e.loki.json')
  // The directory stays: the session now points at this file, and the next
  // project to run against the same server opens its picker beside it.
})

test('picks the file a node reads, and where a sink writes', async ({ page }) => {
  await open(page)
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'loki-e2e-'))
  const csv = path.join(scratch, 'prices.csv')
  fs.writeFileSync(csv, 'time,close\n1,100.5\n2,101.0\n3,100.75\n')
  fs.writeFileSync(path.join(scratch, 'notes.md'), 'not a table\n')

  const reader = await addNode(page, 'readcsv')
  // The sink over the API: the palette would drop it where the reader already
  // sits.
  const writer: string = await page.evaluate(async () => {
    const response = await fetch('/api/nodes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ kind: 'writecsv', params: {}, position: [360, 320] }),
    })
    return (await response.json()).id
  })
  await select(page, reader)
  const field = page.getByTestId('path-field')
  await expect(field).toHaveText('Choose a file to read')

  // The path is the button: there is no box to type a long path into in a
  // column this narrow, and the picker is where a path is typed.
  await tap(page, field)
  const picker = page.getByTestId('file-picker')
  await expect(picker).toBeVisible()
  await expect(picker).toContainText('Choose the file to read')
  await tap(page, page.getByLabel('Type a path'))
  const typed = page.getByTestId('file-path')
  await typed.fill(scratch + '/')
  await typed.press('Enter')

  // A file the node cannot read is shown dimmed, not hidden, and cannot be
  // chosen.
  await expect(picker).toContainText('notes.md')
  await expect(page.getByTestId('file-notes.md')).toHaveCount(0)
  await tap(page, page.getByTestId('file-prices.csv'))
  await expect(page.getByTestId('file-confirm')).toHaveText('Use this file')
  await tap(page, page.getByTestId('file-confirm'))

  // The field reads the path as the picker does, and focus is back where the
  // picker was opened from.
  await expect(picker).toBeHidden()
  await expect(field).toContainText('prices.csv')
  await expect(field).toHaveAttribute('title', csv)
  await expect(field).toBeFocused()
  await expect(page.getByTestId(`node-${reader}`)).toContainText('prices.csv')

  // A CSV's columns are strings until typed, and the seeded context's time is
  // an integer — set over the API, as the other specs set up state.
  await page.evaluate(async (id) => {
    await fetch(`/api/nodes/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        params: { types: 'Dict(:time => Int, :close => Float64)' },
      }),
    })
  }, reader)
  await tap(page, page.getByRole('button', { name: 'Run this node' }))
  await expect(page.getByTestId(`node-${reader}`)).toHaveAttribute('data-status', 'ok')
  await expect(page.getByTestId(`node-${reader}`)).toContainText('3 rows')

  // A sink's path is somewhere to write: the picker saves, and it starts in no
  // particular folder, so the name is typed with the path.
  await select(page, writer)
  await expect(field).toHaveText('Choose where to write')
  await tap(page, field)
  await expect(picker).toContainText('Choose the file to write')
  await tap(page, page.getByLabel('Type a path'))
  await typed.fill(path.join(scratch, 'prices.csv'))
  await typed.press('Enter')
  await expect(page.getByTestId('file-name')).toHaveValue('prices.csv')
  // It would overwrite what the reader reads, and says so.
  await expect(page.getByTestId('file-confirm')).toHaveText('Replace')
  await page.getByTestId('file-name').fill('smoothed.csv')
  await expect(page.getByTestId('file-confirm')).toHaveText('Use this file')
  await tap(page, page.getByTestId('file-confirm'))
  await expect(field).toContainText('smoothed.csv')
})

test('highlights and indents Julia in a code field', async ({ page }) => {
  await open(page)
  const id = await addNode(page, 'ema')
  await select(page, id)

  const field = page.getByTestId('codefield')
  const content = field.locator('.cm-content')
  if (narrow(page)) await content.tap()
  else await content.click()
  await page.keyboard.type('function f(x)')
  await page.keyboard.press('Enter')
  await page.keyboard.type('x')
  await page.keyboard.press('Enter')
  await page.keyboard.type('end')

  // Enter indents to the open block, four spaces a level, and `end` takes its
  // line back out as it is typed.
  const text = async () => (await field.locator('.cm-line').allInnerTexts()).join('\n')
  await expect.poll(text).toBe('function f(x)\n    x\nend')

  // A keyword is drawn in a colour of its own, not the text's.
  const keyword = field.locator('.cm-line span', { hasText: /^function$/ })
  const colour = (el: Element) => getComputedStyle(el).color
  expect(await keyword.evaluate(colour)).not.toBe(await content.evaluate(colour))

  // Tab indents rather than leaving the field, and Escape then Tab still leaves.
  if (narrow(page)) return
  await page.keyboard.press('Enter')
  await page.keyboard.press('Tab')
  await expect.poll(text).toBe('function f(x)\n    x\nend\n    ')
  await page.keyboard.press('Escape')
  await page.keyboard.press('Tab')
  await expect
    .poll(() => content.evaluate((el) => el.contains(document.activeElement)))
    .toBe(false)
})
