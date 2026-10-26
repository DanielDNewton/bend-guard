// bend-guard: reasons that help. Display text only: the glue adds it below or
// after the Bend reason on an Ask or a Deny. Nothing here reads or changes a
// verdict, and the Bend reason always stays in the text as it was.
//
//   - the rule line: which BEND_RULES.md line a rule reason comes from, from
//     the approved sort.json (also added to the log's reason column);
//   - what bend-guard understood the call to do (Policy.meaning), in at most
//     four short lines, Windows path form, with the part it did not understand;
//   - one hint for a call it did not understand: a checked tool that does the
//     same job (never a way around a rule, never bend-guard's own files);
//   - on an Ask, facts the user should see in the dialog (a long or multi-line
//     command, what an MCP tool may do and its text arguments), and for a
//     shell command it did not understand, the NoChange folders it mentions
//     ("It mentions specs\ (rule 1).", backlog round 3, priority 3).
//
// Everything added after the reason is masked (glue.ts redact), as the log is.
//
// Backlog round 2, priority 12. Pure: no $, no I/O.

import { type BendAction, type BendMeaning, normPath, redact } from './glue'

// ---------------------------------------------------------------- rule lines

export type SortRule = { kind: string; rel?: string; branch?: string }
export type SortLine = { line: number; text: string; rules: SortRule[] }
export type SortRules = { root: string; lines: SortLine[] }

const RULE_PREFIX = 'bend-guard rule (BEND_RULES.md): '
const LINE_TEXT_MAX = 120

// The approved sort.json ({root, lines: [{line, text, rules}]}) as rule lines,
// or null when it is missing or has another shape.
export function parseSortRules(sortText: string | undefined, fallbackRoot: string): SortRules | null {
  if (!sortText) return null
  let v: any
  try {
    v = JSON.parse(sortText)
  } catch {
    return null
  }
  if (!v || typeof v !== 'object' || !Array.isArray(v.lines)) return null
  const root = normPath(typeof v.root === 'string' && v.root ? v.root : fallbackRoot)
  const lines: SortLine[] = []
  for (const l of v.lines) {
    if (!l || typeof l !== 'object' || !Number.isInteger(l.line) || typeof l.text !== 'string' || !Array.isArray(l.rules)) continue
    const rules: SortRule[] = []
    for (const r of l.rules) {
      if (!r || typeof r.kind !== 'string') continue
      rules.push({ kind: r.kind, rel: typeof r.rel === 'string' ? r.rel : undefined, branch: typeof r.branch === 'string' ? r.branch : undefined })
    }
    if (rules.length) lines.push({ line: l.line, text: l.text, rules })
  }
  return { root, lines }
}

// The texts a Guard reason (bend/core/Guard.bend) holds for each rule kind.
function ruleTexts(root: string, r: SortRule): string[] {
  const zone = r.rel !== undefined ? `${root}/${normPath(r.rel).replace(/^\.\//, '')}` : ''
  switch (r.kind) {
    case 'NoChange':
      return zone ? [`${zone} may not be changed.`] : []
    case 'NoReadOrChange':
      return zone ? [`${zone} may not be read or changed.`, `contains ${zone}, which may not be read.`] : []
    case 'TreeDeleteOnlyUnder':
      return zone ? [`are allowed only under ${zone}.`] : []
    case 'NoForcePush':
      return [`force pushes are not allowed in ${root}.`]
    case 'NoPushTo':
      return r.branch ? [`pushing to '${r.branch}' is not allowed in ${root}.`, `this push may update '${r.branch}', which may not be pushed to`] : []
    default:
      return []
  }
}

function cut(s: string, max: number): string {
  const t = s.replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, max - 3) + '...' : t
}

// ' (BEND_RULES.md line N: "<text>")' for the rule lines a reason comes from,
// every matching line listed; '' when the reason names no rule of this project.
export function ruleSuffix(reason: string, sort: SortRules | null): string {
  if (!sort || typeof reason !== 'string' || !reason.includes(RULE_PREFIX)) return ''
  const hits: SortLine[] = []
  for (const l of sort.lines) {
    if (hits.includes(l)) continue
    if (l.rules.some(r => ruleTexts(sort.root, r).some(t => reason.includes(t)))) hits.push(l)
  }
  if (!hits.length) return ''
  return ' (BEND_RULES.md ' + hits.map(l => `line ${l.line}: "${cut(l.text, LINE_TEXT_MAX)}"`).join('; ') + ')'
}

// --------------------------------------------------------- what was understood

function listOf<T>(l: unknown): T[] {
  const out: T[] = []
  let cur: any = l
  for (let n = 0; cur && cur.$ === 'Con' && n < 100000; n++) {
    out.push(cur.head as T)
    cur = cur.tail
  }
  return out
}

function segText(s: unknown): string {
  if (typeof s === 'string') return s
  if (typeof s === 'number') return String(s)
  return listOf<number>(s)
    .map(c => String.fromCharCode(Number(c)))
    .join('')
}

// A Bend Path as a Windows path, relative to `base` when inside it.
export function showPath(p: any, base: string): string {
  if (!p || p.$ !== 'Path' || typeof p.drive !== 'string' || p.drive === '?') return '(a path)'
  const segs = listOf<unknown>(p.segs).map(segText)
  const full = `${p.drive.toUpperCase()}:\\${segs.join('\\')}`
  const b = normPath(base)
  const f = normPath(full)
  if (b && f === b) return 'the current folder'
  if (b && f.startsWith(b.endsWith('/') ? b : b + '/')) return full.slice(b.length + (b.endsWith('/') ? 0 : 1))
  return full
}

function actionText(a: BendAction, base: string): string | null {
  const at = (k = 'path') => showPath((a as any)[k], base)
  switch (a.$) {
    case 'Read':
      return `reads ${at()}`
    case 'ReadTree':
      return `reads everything under ${at()}`
    case 'ListDir':
      return `lists ${at()}`
    case 'Write':
      return `writes ${at()}`
    case 'WriteTree':
      return `may change anything under ${at()}`
    case 'Delete':
      return `deletes ${at()}`
    case 'DeleteTree':
      return `deletes the tree ${at()}`
    case 'MoveFrom':
      return `moves ${at()}`
    case 'MakeDir':
      return `makes the folder ${at()}`
    case 'ChangeDir':
      return `goes to the folder ${at()}`
    case 'GitRead':
      return 'reads git history or state'
    case 'GitRef':
      return 'makes a git branch'
    case 'GitPush': {
      const refs = listOf<string>((a as any).refs).map(String)
      const what = refs.length ? refs.join(', ') : 'the current branch'
      return `pushes ${what} from ${at('dir')}${(a as any).force === true ? ', with force' : ''}`
    }
    case 'NpmInstall': {
      const pkgs = listOf<string>((a as any).pkgs).map(String)
      return pkgs.length ? `installs ${pkgs.join(', ')} (runs install scripts)` : 'installs the packages in package.json (runs install scripts)'
    }
    case 'RunScript':
      return `runs the package.json script '${String((a as any).name)}'`
    case 'DraftCheck':
      return `runs the draft check for ${String((a as any).slug)}`
    default:
      return null // Inert (prints text) and anything new
  }
}

// The parts of a shell command, split at ; & | and newlines (quotes are not
// read: this is only for showing a part).
function partsOf(command: string): string[] {
  return command
    .split(/\r?\n|&&|\|\||[;|&]/)
    .map(p => p.trim())
    .filter(p => p.length > 0)
}

function firstWord(part: string): string {
  const w = (part.split(/\s+/)[0] ?? '').replace(/^["']|["']$/g, '')
  return (w.split(/[\\/]/).pop() ?? '').replace(/\.exe$/i, '').toLowerCase()
}

const SYNTAX: RegExp[] = [
  /\$\([^)]*\)?/, // $( )
  /`[^`]*`?/, // backticks
  /<<-?\s*["']?\w*["']?/, // heredoc
  /(?:^|[;&|(])\s*(?:for|while|until|if|case|select|function)\s/, // a shell keyword starting a part
  /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/, // a variable
  /(?:^|\s)[A-Za-z_][A-Za-z0-9_]*=\S*/, // an assignment
  /\{[^}]*\}?/, // a script block
]

// The word of `command` that holds the first piece of syntax bend-guard does
// not read, or null.
function syntaxWord(command: string): string | null {
  for (const re of SYNTAX) {
    const m = re.exec(command)
    if (!m) continue
    let i = m.index
    while (i < command.length && /\s|[;&|]/.test(command[i]!)) i++
    let s = i
    while (s > 0 && !/\s/.test(command[s - 1]!)) s--
    let e = i
    while (e < command.length && !/\s/.test(command[e]!)) e++
    const w = command.slice(s, e).replace(/[;&|]+$/, '')
    if (w) return w
  }
  return null
}

function code(s: string, max = 80): string {
  return '`' + cut(s, max).replace(/`/g, "'") + '`'
}

// The part of the call bend-guard did not understand, as one short phrase.
export function unknownPart(tool: string, command: string | undefined, why: string): string {
  const toolName = /^tool (\S+) not modelled/.exec(why)
  if (toolName) return `the tool ${toolName[1]}`
  if (typeof command !== 'string' || !command.trim()) return cut(why, 120)
  const m = /^the command (\S+) is not modelled/.exec(why) ?? /^([A-Za-z0-9_.-]+):/.exec(why) ?? /^([A-Za-z0-9_.-]+) can run other/.exec(why)
  if (m) {
    const word = m[1]!.replace(/\.exe$/i, '').toLowerCase()
    const part = partsOf(command).find(p => firstWord(p) === word)
    if (part) return code(part)
  }
  if (/shell syntax|shell keyword|variable assignment|redirect|not modelled \(an empty/.test(why)) {
    const block = tool === 'PowerShell' ? /\{[^{}]*\}?/.exec(command) : null
    if (block) return code(block[0], 60)
    const w = syntaxWord(command)
    if (w) return code(w, 60)
  }
  return cut(why, 120)
}

const MEANING_LINES = 4

// What the call does as bend-guard read it: at most four short lines.
export function meaningLines(meaning: BendMeaning | undefined, base: string, tool: string, command: string | undefined): string[] {
  if (!meaning || typeof meaning !== 'object') return []
  const acts = listOf<BendAction>(meaning.$ === 'Known' ? (meaning as any).actions : (meaning as any).known)
  const items: string[] = []
  for (const a of acts) {
    const t = actionText(a, base)
    if (t && !items.includes(t)) items.push(t)
  }
  if (meaning.$ === 'Unknown') items.push('not understood: ' + unknownPart(tool, command, String((meaning as any).why ?? '')))
  if (items.length <= MEANING_LINES) return items
  const unknownLast = meaning.$ === 'Unknown' ? [items[items.length - 1]!] : []
  const known = meaning.$ === 'Unknown' ? items.slice(0, -1) : items
  const room = MEANING_LINES - 1 - unknownLast.length
  return [...known.slice(0, room), `and ${known.length - room} more`, ...unknownLast]
}

// ----------------------------------------------------------------------- hints

export const HINTS = {
  grepContext: 'Hint: the Grep tool has -A, -B and -C for lines around a match.',
  readRange: 'Hint: to read part of a file, use the Read tool with offset and limit.',
  find: 'Hint: to find files by name, use the Glob tool.',
  loop: 'Hint: run one command per file, or use the Grep or Glob tool.',
  editCode: 'Hint: to change a file, use the Edit or Write tool.',
  variable: 'Hint: write the path out in full instead of a variable or $(...).',
  scriptBlock: 'Hint: use Get-ChildItem -Filter, or the Glob tool, instead of a script block.',
} as const

const WRITES_CODE = /open\([^)]*['"][wax]|\.write|writeFile|appendFile|shutil|os\.remove|os\.unlink|unlink|rmSync|rename|\bmkdir|Set-Content|Out-File|>/

// One hint for a call bend-guard did not understand, or null. Only for an
// Unknown meaning, and never on a self-protection or rule reason.
export function hintFor(tool: string, command: string | undefined, meaning: BendMeaning | undefined, reason: string): string | null {
  if (!meaning || meaning.$ !== 'Unknown') return null
  if (/self-protection|bend-guard rule \(BEND_RULES\.md\)|git hooks and git config/.test(reason)) return null
  if (typeof command !== 'string' || !command.trim()) return null
  const why = String((meaning as any).why ?? '')
  const words = partsOf(command).map(firstWord)
  if (tool === 'PowerShell') {
    if (/\{/.test(command)) return HINTS.scriptBlock
  }
  if (/^grep: the flag -[ABC]\b/.test(why) || (words.includes('grep') && /\s(?:-[A-Za-z]*[ABC]\s*\d*|--(?:after|before)-context|--context)\b/.test(command))) return HINTS.grepContext
  // A commit message written with $(cat <<'EOF' ...) is text, not a path or a file.
  if (words.includes('git') && /\s(?:-m|--message)\b/.test(command)) return null
  if (/(?:^|[;&|(])\s*(?:for|while|until)\s[\s\S]*\bdo\b/.test(command)) return HINTS.loop
  if (/<<-?\s*["']?\w/.test(command) && (/>/.test(command.replace(/<<-?\s*["']?\w+["']?/g, '')) || WRITES_CODE.test(command))) return HINTS.editCode
  for (const p of partsOf(command)) {
    const w = firstWord(p)
    if (/^(python[0-9.]*|py|node|deno|bun|perl|ruby)$/.test(w) && /\s-(?:c|e|-eval)\b/.test(p) && WRITES_CODE.test(p)) return HINTS.editCode
  }
  if (words.includes('find')) return HINTS.find
  if (words.includes('sed') && /\bsed\s+(?:-[a-zA-Z]*n|--quiet|--silent)\b/.test(command)) return HINTS.readRange
  if (words.some(w => w === 'head' || w === 'tail') && /^(?:head|tail)\b/.test(why)) return HINTS.readRange
  if (/\$\(|`|\$\{?[A-Za-z_]/.test(command)) return HINTS.variable
  return null
}

// ------------------------------------------------------------- facts for the user

const LONG_COMMAND = 1000
const ARG_TEXT = 200
const MAX_ARGS = 6

function grouped(n: number): string {
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

// What an MCP tool may do, by its name, or null.
export function mcpKind(tool: string): string | null {
  if (!tool.startsWith('mcp__')) return null
  const name = (tool.split('__').pop() ?? '').toLowerCase()
  if (name === 'javascript_tool' || name.endsWith('javascript_tool')) return 'runs JavaScript in your browser'
  if (name === 'computer') return 'controls your desktop'
  if (/exec|shell|run|eval|terminal/.test(name)) return 'may run commands'
  return null
}

// Facts for the dialog, most important first.
export function askFacts(tool: string, input: Record<string, unknown>, command: string | undefined): string[] {
  const out: string[] = []
  const kind = mcpKind(tool)
  if (kind) out.push(`This MCP tool ${kind}.`)
  if (typeof command === 'string') {
    if (command.length > LONG_COMMAND) out.push(`The command is ${grouped(command.length)} characters; the dialog may show only the start.`)
    const lines = command.split(/\r?\n/).length
    if (lines > 1) out.push(`The command has ${grouped(lines)} lines.`)
  }
  if (tool.startsWith('mcp__')) {
    let n = 0
    for (const k of Object.keys(input ?? {})) {
      const v = input[k]
      if (typeof v !== 'string' || !v.trim()) continue
      if (n++ >= MAX_ARGS) break
      out.push(`${k}: ${cut(v, ARG_TEXT)}`)
    }
  }
  return out
}

// ------------------------------------------- NoChange folders a command names
// The same matcher as Guard.bend's no-read check (nr.*), for NoChange zones:
// the command lower-cased, '\' read as '/', a run of '/' as one; a zone
// counts as written from the project folder or from the call's folder, after
// the start or one of the characters in ZONE_BEFORE, and followed (after any
// dots, which Windows drops) by the end or one of ZONE_AFTER. A '/' before it
// also covers ../specs and the absolute spellings. Display only: Bend refuses
// a not-understood command that names a no-read zone; a NoChange zone may be
// read, so the dialog only says so.

const ZONE_BEFORE = new Set([' ', '\t', '\n', '\r', '"', "'", '`', '=', '(', '/', ';', ',', '|', '&', '<', '>', '@', ':', '{', '['])
const ZONE_AFTER = new Set([' ', '\t', '\n', '\r', '"', "'", '`', '/', ')', ';', ',', '|', '&', '<', '>', ']', '}', ':', '*', '?'])

function foldCommand(s: string): string {
  return s.toLowerCase().replace(/\\/g, '/').replace(/\/{2,}/g, '/')
}

// zone (parts) as written from folder `from` (parts): what is left after
// their longest common start (Guard.bend nr.rest), joined with '/'.
function spelledFrom(zone: string[], from: string[]): string {
  let i = 0
  while (i < zone.length && i < from.length && zone[i] === from[i]) i++
  return zone.slice(i).join('/')
}

function namesAt(text: string, sp: string): boolean {
  if (!sp) return false
  for (let i = text.indexOf(sp); i >= 0; i = text.indexOf(sp, i + 1)) {
    if (i > 0 && !ZONE_BEFORE.has(text[i - 1]!)) continue
    let j = i + sp.length
    while (j < text.length && text[j] === '.') j++
    if (j === text.length || ZONE_AFTER.has(text[j]!)) return true
  }
  return false
}

const partsOfPath = (p: string) => normPath(p).split('/').filter(s => s !== '')

function joinAnd(xs: string[]): string {
  return xs.length <= 1 ? (xs[0] ?? '') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`
}

// The NoChange folders of the approved rules that `command` names, each with
// its BEND_RULES.md lines: "specs\ (rule 1)", "build\ (rules 3 and 9)". The
// call's folder is not used when it is on another drive than the project.
export function namedNoChange(command: string, sort: SortRules | null, base: string): string[] {
  if (!sort || typeof command !== 'string' || !command) return []
  const text = foldCommand(command)
  const root = partsOfPath(sort.root)
  const cwd = partsOfPath(base)
  const hits = new Map<string, number[]>()
  for (const l of sort.lines) {
    for (const r of l.rules) {
      if (r.kind !== 'NoChange' || typeof r.rel !== 'string') continue
      const rel = normPath(r.rel).replace(/^\.\//, '')
      if (!rel || rel === '.') continue
      const zone = [...root, ...rel.split('/').filter(s => s !== '')]
      const sps = [spelledFrom(zone, root)]
      if (cwd[0] === root[0]) sps.push(spelledFrom(zone, cwd))
      if (!sps.some(sp => namesAt(text, sp))) continue
      const lines = hits.get(rel) ?? []
      if (!lines.includes(l.line)) lines.push(l.line)
      hits.set(rel, lines)
    }
  }
  return [...hits].map(([rel, lines]) => `${rel.replace(/\//g, '\\')}\\ (${lines.length === 1 ? 'rule' : 'rules'} ${joinAnd(lines.map(String))})`)
}

// ------------------------------------------------------------------- the text

export type ExplainArgs = {
  decision: 'ask' | 'deny'
  reason: string // the verdict's reason, as Bend and the ask hooks gave it
  tool: string
  input: Record<string, unknown>
  meaning: BendMeaning | undefined
  base: string // the folder relative paths are shown from
  sort: SortRules | null
}

export function shellCommand(tool: string, input: Record<string, unknown>): string | undefined {
  return (tool === 'Bash' || tool === 'PowerShell' || tool === 'Monitor') && typeof input?.command === 'string' ? (input.command as string) : undefined
}

// The reason as shown on an Ask or a Deny: the reason with its rule line, then
// (Ask) the NoChange folders a not-understood command mentions and the facts,
// what bend-guard read, and one hint. The added lines are masked; the reason
// stays as it was. Never throws: on any failure the reason comes back as it
// was.
export function explain(a: ExplainArgs): string {
  const reason = String(a.reason ?? '')
  try {
    const command = shellCommand(a.tool, a.input)
    const lines: string[] = []
    if (a.decision === 'ask' && command !== undefined && a.meaning?.$ === 'Unknown') {
      const zones = namedNoChange(command, a.sort, a.base)
      if (zones.length) lines.push(`It mentions ${joinAnd(zones)}.`)
    }
    if (a.decision === 'ask') lines.push(...askFacts(a.tool, a.input, command))
    const seen = meaningLines(a.meaning, a.base, a.tool, command)
    if (seen.length) lines.push('What bend-guard read: ' + seen.join('; ') + '.')
    const hint = hintFor(a.tool, command, a.meaning, reason)
    if (hint) lines.push(hint)
    return [reason + ruleSuffix(reason, a.sort), ...lines.map(redact)].join('\n')
  } catch {
    return reason
  }
}
