// Posix path arithmetic for the file picker, kept out of the component so it can
// be tested without rendering anything — and so the picker itself stays a view.
//
// The server is the authority on what a path means; these only shape what is
// already an absolute path it handed back, and the one the person types before
// it is sent.

/** The ancestors of an absolute path, each with the name to show for it. */
export function splitPath(path: string): { name: string; path: string }[] {
  const parts = path.split('/').filter((p) => p !== '')
  const crumbs = [{ name: '/', path: '/' }]
  let here = ''
  for (const part of parts) {
    here += '/' + part
    crumbs.push({ name: part, path: here })
  }
  return crumbs
}

export function joinPath(dir: string, name: string): string {
  if (name.startsWith('/')) return name
  return dir === '/' ? '/' + name : dir + '/' + name
}

export function parentOf(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  const cut = trimmed.lastIndexOf('/')
  return cut <= 0 ? '/' : trimmed.slice(0, cut)
}

export function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  return trimmed.slice(trimmed.lastIndexOf('/') + 1)
}

/** With no suffixes asked for, everything matches: the picker is unfiltered. */
export function matchesSuffix(name: string, suffixes?: string[]): boolean {
  if (suffixes === undefined || suffixes.length === 0) return true
  const lower = name.toLowerCase()
  return suffixes.some((s) => lower.endsWith(s.toLowerCase()))
}

// What you want from a session file's timestamp is which one is the latest, so
// the nearer it is the more precisely it is written.
export function formatModified(iso: string | undefined, now = new Date()): string {
  if (iso === undefined) return ''
  const when = new Date(iso)
  if (Number.isNaN(when.getTime())) return ''
  const sameDay =
    when.getFullYear() === now.getFullYear() &&
    when.getMonth() === now.getMonth() &&
    when.getDate() === now.getDate()
  if (sameDay) return `${pad(when.getHours())}:${pad(when.getMinutes())}`
  if (when.getFullYear() === now.getFullYear()) {
    return `${when.getDate()} ${MONTHS[when.getMonth()]}`
  }
  return `${when.getFullYear()}-${pad(when.getMonth() + 1)}-${pad(when.getDate())}`
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
    'Oct', 'Nov', 'Dec']

const pad = (n: number) => String(n).padStart(2, '0')
