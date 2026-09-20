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
