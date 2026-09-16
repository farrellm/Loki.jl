import { defineConfig, devices } from '@playwright/test'

// Two projects, because the point is that one UI works on both: a desktop
// browser, and WebKit on an iPhone profile, where the specs may only tap.
//
// One session is shared by the whole run, so the specs are not parallel: they
// are driving the same graph, and a spec that ran beside another would see the
// other's nodes.

const PORT = Number(process.env.LOKI_TEST_PORT ?? 8713)
const TOKEN = process.env.LOKI_TEST_TOKEN ?? 'playwright-token'

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : [['list']],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: 'on-first-retry',
  },
  webServer: {
    command: 'julia --project=.. tests/server.jl',
    url: `http://127.0.0.1:${PORT}/`,
    reuseExistingServer: !process.env.CI,
    // Julia's first load of Loki is slow; the bundle is already built by then.
    timeout: 300_000,
    stdout: 'pipe',
    stderr: 'pipe',
    env: { LOKI_TEST_PORT: String(PORT), LOKI_TEST_TOKEN: TOKEN },
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'iphone', use: { ...devices['iPhone 14'] } },
  ],
})
