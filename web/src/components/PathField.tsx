import { useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { FilePicker } from './FilePicker'
import { basename, folderOf } from '../paths'

// A file node's `path`. The path is the button: the inspector is too narrow for
// a long path in a text box, whose visible start (`/home/…`) is the part that
// says least, and on a phone a text box opens a keyboard over a string nobody
// wants to type. So the field reads the path the way the picker does — the
// file is the subject, and its folder the quiet line above, cut from the left
// so the nearest folder is the one still showing. A path is still typed or
// pasted, inside the picker, where the whole line opens for it.
//
// The picker is portalled rather than rendered here: the bottom sheet is a
// stacking context of its own, and a scrim inside it could not dim the bar. It
// goes to the app root rather than the body, so the narrow layout's rules still
// reach it.

export function PathField({
  id,
  name: param,
  value,
  write,
  suffixes,
  onChange,
}: {
  id: string
  /** The parameter's name, which a button's own label would otherwise hide. */
  name: string
  value: string
  /** A sink's path is somewhere to write, so the picker saves rather than opens. */
  write: boolean
  suffixes?: string[]
  onChange: (path: string) => void
}) {
  const [open, setOpen] = useState(false)
  const button = useRef<HTMLButtonElement>(null)

  const close = () => {
    setOpen(false)
    button.current?.focus()
  }

  const folder = value.slice(0, value.lastIndexOf('/') + 1)
  const name = value.slice(folder.length)
  const root = button.current?.closest('.app') ?? document.body
  const prompt = write ? 'Choose where to write' : 'Choose a file to read'

  return (
    <>
      <button
        ref={button}
        id={id}
        type="button"
        className="pathfield"
        data-testid="path-field"
        title={value === '' ? undefined : value}
        aria-label={
          value === '' ? `${param}: ${prompt}` : `${param}: ${value}. Choose a file`
        }
        onClick={() => setOpen(true)}
      >
        {value === '' ? (
          <span className="pathfield__none">{prompt}</span>
        ) : (
          <>
            {folder !== '' && (
              <span className="pathfield__folder">
                <bdi dir="ltr">{folder}</bdi>
              </span>
            )}
            <span className="pathfield__name">{name}</span>
          </>
        )}
      </button>
      {open &&
        createPortal(
          <FilePicker
            mode={write ? 'save' : 'open'}
            title={write ? 'Choose the file to write' : 'Choose the file to read'}
            confirm="Use this file"
            suffixes={suffixes}
            start={folderOf(value)}
            name={value === '' ? '' : basename(value)}
            side="end"
            onCancel={close}
            onChoose={(path) => {
              close()
              if (path !== value) onChange(path)
            }}
          />,
          root,
        )}
    </>
  )
}
