import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

// The bundle ships inside the package, not in version control: `assets/web` is
// gitignored, and `Loki.serve()` serves a page saying how to build it when it is
// not there. Everything is bundled and self-hosted — the server binds to the
// loopback, checks `Origin`, and is meant to work offline behind Tailscale, so
// the page must not fetch a font or a script from anywhere at run time.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../assets/web',
    emptyOutDir: true,
    // Plotly is large and the canvas is not: splitting them means the graph is
    // interactive before a chart library the user may never open has loaded.
    rollupOptions: {
      output: {
        manualChunks: (id) => (id.includes('plotly.js') ? 'plotly' : undefined),
      },
    },
  },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8712',
      '/ws': { target: 'ws://127.0.0.1:8712', ws: true },
    },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
})
