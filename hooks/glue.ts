// bend-guard: the pure glue. Types that cross to the compiled Bend checker,
// the event-to-Call encoding, approved.json readers, path helpers, secret
// masking and the log line. No $ here: everything that touches the disk, a
// process or the network lives in register.tsx, checker.ts and clef.ts.
//
// Design: bend2_test\docs\design.md, components 7 and 8.
// Plan: bend2_test\docs\plan.md, "Shared interfaces" and Task 4.1;
// bend2_test\docs\build-brief.md wins where they differ.

// ---------------------------------------------------------------------------
// Bend values as JavaScript (brief "Toolchain": lists are Con/Nil, Bool is a
// boolean, Nat/U32 are numbers, String is a string, constructors are {$: Name}).

export type BendList<T> = { $: 'Con'; head: T; tail: BendList<T> } | { $: 'Nil' }
export type BendArg = { $: 'Arg'; key: string; value: string }
export type BendStage = { $: 'AtCheck' } | { $: 'AtCall'; asked: boolean; consent: string }
export type BendCall = {
  $: 'Call'
  tool: string
  args: BendList<BendArg>
  cwds: BendList<string>
  root: string
  home: string
  links: BendList<string> // always Nil in this version (brief Q11)
  agent: boolean
  approver: string
  interactive: boolean
  mode: string // always "" (brief Q9: no event carries the mode)
  stage: BendStage
  log_only: boolean
}
export type BendClefAnswer = { $: 'Answer'; risky: number; unsure: number } | { $: 'NoAnswer' }
export type BendVerdict = { $: 'Allow' } | { $: 'Ask'; reason: string } | { $: 'Deny'; reason: string }
export type BendClefQ = { $: 'Triage' } | { $: 'Veto' }
export type BendStep = { $: 'Step.Done'; v: BendVerdict } | { $: 'Consult'; q: BendClefQ; base: BendVerdict; text: string }
export type BendAction = { $: string; [field: string]: unknown }
export type BendMeaning = { $: 'Known'; actions: BendList<BendAction> } | { $: 'Unknown'; why: string; known: BendList<BendAction> }

export type PolicyEntry = { dir: string; mjsSha256: string; logOnly: boolean }
export type AskConfig = { newTopLevelDir: boolean; npmInstall: boolean; testBeforeDone: string | null; lintBeforeDone: string | null }
export type ProjectEntry = { root: string; slug: string; rulesMdSha256: string; ask: AskConfig }
export type TurnLedger = { tick: number; changedAt: number | null; passedAt: Map<string, number> }
export type LogFields = {
  time: string
  session: string
  agent: string
  tool: string
  verdict: string
  enforceVerdict: string
  reason: string
  clefAsked: boolean
  clefAnswer: string
  latencyMs: number
  cacheHit: boolean
  command: string
}

export const NIL: { $: 'Nil' } = { $: 'Nil' }
export const NO_ANSWER: BendClefAnswer = { $: 'NoAnswer' }

export function toBendList<T>(xs: readonly T[]): BendList<T> {
  let l: BendList<T> = { $: 'Nil' }
  for (let i = xs.length - 1; i >= 0; i--) l = { $: 'Con', head: xs[i], tail: l }
  return l
}

// Throws on anything that is not a Con/Nil chain (the checker validates
// elements; this only walks).
export function fromBendList<T>(l: BendList<T>): T[] {
  const out: T[] = []
  let cur: any = l
  while (cur && cur.$ === 'Con') {
    out.push(cur.head)
    cur = cur.tail
  }
  if (!cur || cur.$ !== 'Nil') throw new Error('bend-guard: not a Bend list')
  return out
}

// ---------------------------------------------------------------------------
// Event to Call

function scalarText(v: unknown): string | undefined {
  if (v === undefined || v === null) return undefined
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'bigint') return String(v)
  if (typeof v === 'function' || typeof v === 'symbol') return undefined
  return JSON.stringify(v)
}

// Strings as they are; an array gives one entry per element under the same
// key, in order; a plain object gives its JSON text; numbers and booleans
// their text; undefined and null are skipped. Keys keep the input's order.
export function flattenArgs(input: Record<string, unknown>): { key: string; value: string }[] {
  const out: { key: string; value: string }[] = []
  if (!input || typeof input !== 'object') return out
  for (const key of Object.keys(input)) {
    const v = input[key]
    if (Array.isArray(v)) {
      for (const el of v) {
        const t = scalarText(el)
        if (t !== undefined) out.push({ key, value: t })
      }
    } else {
      const t = scalarText(v)
      if (t !== undefined) out.push({ key, value: t })
    }
  }
  return out
}

export type CallFacts = {
  tool: string
  input: Record<string, unknown>
  cwds: string[] // possible shell folders, event folder first
  root: string
  home: string
  agentId?: string
  approver?: string
  interactive: boolean
  stage: 'check' | 'call'
  asked?: boolean // only read for stage 'call'
  consent?: string // only read for stage 'call'
  logOnly: boolean
}

export function toBendCall(x: CallFacts): BendCall {
  const stage: BendStage =
    x.stage === 'call' ? { $: 'AtCall', asked: x.asked === true, consent: typeof x.consent === 'string' ? x.consent : '' } : { $: 'AtCheck' }
  return {
    $: 'Call',
    tool: String(x.tool ?? ''),
    args: toBendList(flattenArgs(x.input).map(a => ({ $: 'Arg' as const, key: a.key, value: a.value }))),
    cwds: toBendList(x.cwds.map(String)),
    root: String(x.root ?? ''),
    home: String(x.home ?? ''),
    links: { $: 'Nil' },
    agent: x.agentId !== undefined,
    approver: typeof x.approver === 'string' ? x.approver : '',
    interactive: x.interactive === true,
    mode: '',
    stage,
    log_only: x.logOnly === true,
  }
}

export function withStage(c: BendCall, stage: BendStage): BendCall {
  return { ...c, stage }
}

export function withLogOnly(c: BendCall, logOnly: boolean): BendCall {
  return { ...c, log_only: logOnly }
}

// ---------------------------------------------------------------------------
// Paths (comparison form only: never handed to Bend, which normalises itself)

// Lower case, forward slashes, no trailing slash.
export function normPath(p: string): string {
  let s = String(p ?? '').toLowerCase().replace(/\\/g, '/')
  while (s.length > 1 && s.endsWith('/')) s = s.slice(0, -1)
  return s
}

// p is root or inside it.
export function contains(root: string, p: string): boolean {
  const r = normPath(root)
  const q = normPath(p)
  if (!r || !q) return false
  return q === r || q.startsWith(r.endsWith('/') ? r : r + '/')
}

// Brief "Paths": normalised root with ':', '/', '.' and ' ' replaced by '-'.
// Must match tools/gen.mjs slugOf (tests/wiring.test.ts checks it).
export function slugOf(root: string): string {
  return normPath(root).replace(/[:/. ]/g, '-')
}

// ---------------------------------------------------------------------------
// Where bend-guard lives (backlog round 3, priority 5): from USERPROFILE and
// the folder Claude Code loaded the hooks from, never a fixed path. The
// hooks module (register.tsx) says what each place is for.

// "c:/users/x" -> "C:\users\x"
function winForm(p: string): string {
  const s = String(p).replace(/\//g, '\\')
  return s.replace(/^([a-z]):/, (_m: string, d: string) => d.toUpperCase() + ':')
}

export type Places = {
  home: string // as USERPROFILE gives it, backslashes, no trailing one
  state: string // <home>\.claude\bend-guard
  tools: string // <home>\.claude\local-plugins\bend-guard
  pluginRoot: string // where Claude Code loaded these hooks from
}
export type PlacesResult = { ok: true; p: Places } | { ok: false; why: string; state: string | null; pluginRoot: string }

export function placesOf(rawHome: unknown, rawRoot: unknown): PlacesResult {
  const clean = (x: unknown) => (typeof x === 'string' ? winForm(x.trim()).replace(/\\+$/, '') : '')
  const home = clean(rawHome)
  const pluginRoot = clean(rawRoot)
  const drivePath = /^[A-Z]:\\[^\\]/.test(home) && !home.split('\\').some(s => s === '..' || s === '.')
  const state = drivePath ? `${home}\\.claude\\bend-guard` : null
  if (!home) return { ok: false, why: 'USERPROFILE is not set, so bend-guard cannot find its folders', state, pluginRoot }
  if (!drivePath || !/^C:/.test(home)) return { ok: false, why: `the home folder ${home} is not a folder on drive C:, which bend-guard needs`, state, pluginRoot }
  const tools = `${home}\\.claude\\local-plugins\\bend-guard`
  const r = normPath(pluginRoot)
  const cache = normPath(`${home}\\.claude\\plugins\\cache`) + '/'
  const rest = r.startsWith(cache) ? r.slice(cache.length).split('/') : []
  const fromCache = rest.length === 3 && rest[1] === 'bend-guard' && rest.every(s => s !== '' && s !== '.' && s !== '..')
  if (!pluginRoot || (r !== normPath(tools) && !fromCache))
    return {
      ok: false,
      why: `it is loaded from ${pluginRoot || 'an unknown folder'}, but it must be installed in ${tools}`,
      state,
      pluginRoot,
    }
  return { ok: true, p: { home, state: state!, tools, pluginRoot } }
}

// ---------------------------------------------------------------------------
// approved.json, version 2 (plan "Shared interfaces"). Each reader takes the
// file's text or its parsed value, and gives null for anything malformed.

function asObject(approved: unknown): Record<string, any> | null {
  let v: unknown = approved
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v)
    } catch {
      return null
    }
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null
  const o = v as Record<string, any>
  if (o.version !== 2) return null
  return o
}

const HEX64 = /^[0-9a-f]{64}$/i

export function policyEntry(approved: unknown): PolicyEntry | null {
  const o = asObject(approved)
  if (!o) return null
  const p = o.policy
  if (!p || typeof p !== 'object' || Array.isArray(p)) return null
  if (typeof p.dir !== 'string' || !p.dir) return null
  if (typeof p.mjsSha256 !== 'string' || !HEX64.test(p.mjsSha256)) return null
  // A missing flag means enforce (the stricter reading); a wrong type is malformed.
  if (o.logOnly !== undefined && typeof o.logOnly !== 'boolean') return null
  return { dir: p.dir, mjsSha256: p.mjsSha256.toLowerCase(), logOnly: o.logOnly === true }
}

export function fingerprintOk(entry: PolicyEntry, mjsHash: string): boolean {
  if (!entry || typeof entry.mjsSha256 !== 'string' || typeof mjsHash !== 'string') return false
  if (!HEX64.test(entry.mjsSha256) || !HEX64.test(mjsHash)) return false
  return entry.mjsSha256.toLowerCase() === mjsHash.toLowerCase()
}

function parseAsk(a: any): AskConfig {
  const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v : null)
  if (!a || typeof a !== 'object') return { newTopLevelDir: false, npmInstall: false, testBeforeDone: null, lintBeforeDone: null }
  return {
    newTopLevelDir: a.newTopLevelDir === true,
    npmInstall: a.npmInstall === true,
    testBeforeDone: str(a.testBeforeDone),
    lintBeforeDone: str(a.lintBeforeDone),
  }
}

// Normalised roots of every approved project.
export function approvedRoots(approved: unknown): string[] {
  const o = asObject(approved)
  if (!o || !o.projects || typeof o.projects !== 'object' || Array.isArray(o.projects)) return []
  return Object.keys(o.projects).map(normPath).filter(r => r.length > 0)
}

// The deepest approved project whose root contains cwd, or null.
export function projectFor(approved: unknown, cwd: string): ProjectEntry | null {
  const o = asObject(approved)
  if (!o || !o.projects || typeof o.projects !== 'object' || Array.isArray(o.projects)) return null
  let best: ProjectEntry | null = null
  for (const key of Object.keys(o.projects)) {
    const root = normPath(key)
    if (!root || !contains(root, cwd)) continue
    if (best && best.root.length >= root.length) continue
    const e = o.projects[key] ?? {}
    best = {
      root,
      slug: typeof e.slug === 'string' && e.slug ? e.slug : slugOf(root),
      rulesMdSha256: typeof e.rulesMdSha256 === 'string' ? e.rulesMdSha256.toLowerCase() : '',
      ask: parseAsk(e.ask),
    }
  }
  return best
}

// Ask config of the deepest approved project containing cwd. A project with
// no (or a malformed) `ask` entry gets every ask turned off.
export function askEntry(approved: unknown, cwd: string): { root: string; ask: AskConfig } | null {
  const p = projectFor(approved, cwd)
  return p ? { root: p.root, ask: p.ask } : null
}

// ---------------------------------------------------------------------------
// Clef cache key: in memory only, so the plain triple is enough.

export function cacheKey(model: string, questionsVersion: string, text: string): string {
  return JSON.stringify([model, questionsVersion, text])
}

// ---------------------------------------------------------------------------
// Secret masking, for what goes to Clef and to the log.

const REDACTIONS: [RegExp, string][] = [
  [/\bsk-or-[A-Za-z0-9_-]{8,}/g, 'sk-or-***'],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, 'sk-***'],
  [/\bgithub_pat_[A-Za-z0-9_]{16,}/g, 'github_pat_***'],
  [/\b(gh[pousr]_)[A-Za-z0-9]{16,}/g, '$1***'],
  [/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, 'AKIA***'],
  [/\b(Bearer)\s+[A-Za-z0-9._~+/=-]{6,}/gi, '$1 ***'],
  [/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/:@'"]+:[^\s/@'"]+@/gi, '$1***:***@'],
  [/(\b[\w.-]*?(?:key|token|secret)["']?\s*[=:]\s*["']?)[A-Za-z0-9+/_.~-]{16,}={0,2}/gi, '$1***'],
  [/(\b[\w.-]*?(?:password|passwd|pwd)["']?\s*[=:]\s*["']?)[^\s"'&;|]+/gi, '$1***'],
]

export function redact(text: string): string {
  let s = String(text ?? '')
  for (const [re, to] of REDACTIONS) s = s.replace(re, to)
  return s
}

// ---------------------------------------------------------------------------
// Verdict to the tool.check answer. Anything that is not a known verdict
// refuses.

export function verdictToCheck(v: BendVerdict): { decision: 'deny' | 'ask'; reason: string } | 'pass' {
  const t = (v as any)?.$
  if (t === 'Allow') return 'pass'
  const reason = typeof (v as any)?.reason === 'string' ? (v as any).reason : ''
  if (t === 'Ask') return { decision: 'ask', reason }
  if (t === 'Deny') return { decision: 'deny', reason }
  return { decision: 'deny', reason: 'bend-guard: the checker gave an unknown verdict; refusing. To fix: run the compile command and approve again.' }
}

export function verdictName(v: BendVerdict): string {
  const t = (v as any)?.$
  return t === 'Allow' ? 'allow' : t === 'Ask' ? 'ask' : 'deny'
}

// ---------------------------------------------------------------------------
// Log line: tab separated, one line per verdict; command and reason are
// masked. Ends with "\n".

export const LOG_HEADER =
  'time\tsession\tagent\ttool\tverdict\tenforceVerdict\treason\tclefAsked\tclefAnswer\tlatencyMs\tcacheHit\tcommand\n'

function esc(s: unknown): string {
  return String(s ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/\t/g, '\\t')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
}

export function logLine(f: LogFields): string {
  return (
    [
      esc(f.time),
      esc(f.session),
      esc(f.agent),
      esc(f.tool),
      esc(f.verdict),
      esc(f.enforceVerdict),
      esc(redact(f.reason)),
      f.clefAsked ? 'yes' : 'no',
      esc(f.clefAnswer),
      String(Math.round(Number(f.latencyMs) || 0)),
      f.cacheHit ? 'yes' : 'no',
      esc(redact(f.command)),
    ].join('\t') + '\n'
  )
}
