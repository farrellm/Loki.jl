import { useEffect, useRef } from 'react'
import { EditorState } from '@codemirror/state'
import { EditorView, keymap, lineNumbers, placeholder } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { StreamLanguage } from '@codemirror/language'
import { julia } from '@codemirror/legacy-modes/mode/julia'

// CodeMirror 6, not Monaco: Monaco does not support mobile browsers, and an
// expression parameter has to be editable on a phone like everything else.

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

  useEffect(() => {
    if (host.current === null) return
    const editor = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: value,
        extensions: [
          lineNumbers(),
          history(),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          StreamLanguage.define(julia),
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
              commit.current(self.state.doc.toString())
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
