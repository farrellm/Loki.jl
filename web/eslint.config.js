import js from '@eslint/js'
import prettier from 'eslint-config-prettier'
import reactHooks from 'eslint-plugin-react-hooks'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['test-results/', 'playwright-report/'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, tseslint.configs.recommended],
    languageOptions: { globals: { ...globals.browser } },
    rules: {
      // Table data, diagnostic summaries and event payloads arrive as untyped
      // server JSON; narrowing them to `unknown` is a job of its own.
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  {
    // react-hooks v7's `recommended` also turns on the React Compiler rules,
    // which the sync effects here would fail. Take the two core rules only.
    files: ['src/**/*.{ts,tsx}'],
    plugins: { 'react-hooks': reactHooks },
    rules: {
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
  {
    files: ['vite.config.ts', 'playwright.config.ts', 'tests/**/*.ts'],
    languageOptions: { globals: { ...globals.node } },
  },
  prettier,
)
