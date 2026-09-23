import { useEffect, useRef } from 'react'
import { EditorState } from '@codemirror/state'
import { EditorView, keymap, lineNumbers, placeholder } from '@codemirror/view'
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from '@codemirror/commands'
import {
  HighlightStyle,
  StreamLanguage,
  indentOnInput,
  indentUnit,
  syntaxHighlighting,
} from '@codemirror/language'
import { julia } from '@codemirror/legacy-modes/mode/julia'
import { tags } from '@lezer/highlight'

// CodeMirror 6, not Monaco: Monaco does not support mobile browsers, and an
// expression parameter has to be editable on a phone like everything else.

// The legacy Julia mode's token names, mapped onto the theme's editor-only
// `--code-*` tokens; a comment or an error reuses the colour that already means it.
const juliaHighlight = HighlightStyle.define([
  { tag: tags.keyword, color: 'var(--code-keyword)' },
  { tag: tags.string, color: 'var(--code-string)' },
  { tag: tags.number, color: 'var(--code-number)' },
  { tag: [tags.standard(tags.variableName), tags.meta], color: 'var(--code-builtin)' },
  { tag: tags.definition(tags.variableName), fontWeight: '600' },
  { tag: tags.comment, color: 'var(--ink-faint)', fontStyle: 'italic' },
  { tag: tags.invalid, color: 'var(--alarm)' },
])

export function CodeField({
  value,
  onCommit,
  hint,
  rows = 3,
}: {
  value: string
  onCommit: (value: string) => void
  hint?: string
  rows?: number
}) {
  const host = useRef<HTMLDivElement>(null)
  const view = useRef<EditorView | null>(null)
  const commit = useRef(onCommit)
  commit.current = onCommit
  // The value the session already holds. Committing text equal to it would still
  // be a graph edit — the server invalidates the node and everything downstream
  // on any PATCH — so tabbing through a code field must not throw results away.
  const committed = useRef(value)
  committed.current = value

  useEffect(() => {
    if (host.current === null) return
    const editor = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: value,
        extensions: [
          lineNumbers(),
          history(),
          // Tab indents rather than moving focus, as in any code editor; Escape
          // then Tab still leaves the field, so the keyboard is never trapped.
          keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
          StreamLanguage.define(julia),
          // Enter indents to the open blocks, four spaces a level as Julia does,
          // and `end`, `else`, `elseif`, `catch` and `finally` dedent as they are
          // typed. The mode's own list lacks `elseif`, which only dedented by way
          // of its `else` — not when a phone's keyboard commits the whole word.
          indentUnit.of('    '),
          indentOnInput(),
          EditorState.languageData.of(() => [{ indentOnInput: /^\s*elseif\b$/ }]),
          syntaxHighlighting(juliaHighlight),
          placeholder(hint ?? ''),
          EditorView.lineWrapping,
          EditorView.theme({
            '&': { fontSize: '13px', minHeight: `${rows * 1.5 + 1}em` },
            '.cm-content': { fontFamily: 'var(--mono)' },
            '.cm-gutters': {
              background: 'transparent',
              borderRight: '1px solid var(--rule)',
              color: 'var(--ink-faint)',
            },
          }),
          // Source text is stored as text, so it is saved on blur rather than on
          // every keystroke: a half-typed expression is not a graph edit.
          EditorView.domEventHandlers({
            blur: (_, self) => {
              const text = self.state.doc.toString()
              if (text !== committed.current) commit.current(text)
              return false
            },
          }),
        ],
      }),
    })
    view.current = editor
    return () => {
      editor.destroy()
      view.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const editor = view.current
    if (editor === null || editor.state.doc.toString() === value) return
    editor.dispatch({
      changes: { from: 0, to: editor.state.doc.length, insert: value },
    })
  }, [value])

  return <div className="codefield" ref={host} data-testid="codefield" />
}
