// bend-guard: the wiring. Loads the approved policy once at session.start,
// then checks every tool call with the compiled Bend checker (one node child
// per check, see checker.ts), asks Clef on a Consult step (clef.ts), adds the
// rule 4 and 8 asks and the rules 9 and 10 reminder (asks.ts), and logs one
// line per call. tool.call judges each call once (the engine fires it first);
// tool.check, inside its next(e), answers ask or deny by its approver. Every
// guarding hook judges before calling next and has a .catch that refuses. It also serves /bend-guard, the user's own
// way to approve and switch modes, and to see why calls were judged as they
// were (see "the /bend-guard command" below). No home or user is fixed in
// here: see "where things are".
//
// Design: bend2_test\docs\design.md, components 8, 10 and 11,
// and "Failure behaviour". Plan: bend2_test\docs\plan.md,
// Tasks 4.2 and 4.4. The brief (bend2_test\docs\build-brief.md)
// wins where they differ: "Simplifications" sets when the mod is active.

import type { Register } from 'claude-code'

import {
  type AskConfig,
  type BendCall,
  type BendClefAnswer,
  type BendMeaning,
  type BendVerdict,
  type PlacesResult,
  type ProjectEntry,
  type TurnLedger,
  LOG_HEADER,
  approvedRoots,
  askEntry,
  fingerprintOk,
  flattenArgs,
  logLine,
  normPath,
  placesOf,
  policyEntry,
  projectFor,
  redact,
  toBendCall,
  verdictName,
} from './glue'
import { sha256Hex } from './sha256'
import { HOST_TIMEOUT_MS, afterClefRequest, checkRequest } from './checker'
import { CLEF_MODEL, CLEF_SESSION_CAP, CLEF_TIMEOUT_MS, type ClefBudget, askClef } from './clef'
import { askForRules, askOutcome, newLedger, npmInstallNote, recordCall, stopReason } from './asks'
import { type SortRules, explain, meaningLines, parseSortRules, ruleSuffix } from './reasons'

const TOAST_MS = 10000
const SHELL_TOOLS = new Set(['Bash', 'PowerShell', 'Monitor'])
// Keys tool.call adds beside the tool's own arguments (claude-code.d.ts:
// ToolCallReserved, AgentLoop, ToolRequestMeta).
const CALL_META = new Set(['tool', 'tool_use_id', 'agentId', 'consent', 'requestMeta'])

// ------------------------------------------------------------ where things are
// Backlog round 3, priority 5: no fixed home or user. The home folder comes
// from USERPROFILE, the plugin's folder from $.plugin.root, and everything else
// from them: the state folder <home>\.claude\bend-guard, and the tools (the
// approve tool the Bend policy names) under <home>\.claude\local-plugins\
// bend-guard. Claude Code may load the hooks from its plugin cache, a copy it
// makes of that folder (<home>\.claude\plugins\cache\<marketplace>\bend-guard\
// <version>), so that place is accepted too; the tools still run from the
// local-plugins folder. Anything else is the broken state wherever bend-guard
// is meant to guard (load below). There is no fallback to any fixed path.

async function resolvePlaces($: any): Promise<PlacesResult> {
  let h: unknown
  let r: unknown
  try {
    h = await $.env.get('USERPROFILE')
  } catch {
    h = undefined
  }
  try {
    r = $.plugin.root // the engine allows only this spelling
  } catch {
    r = undefined
  }
  return placesOf(h, r)
}

let places: PlacesResult | null = null // set by every load; a command before any load resolves it itself

async function placesNow($: any): Promise<PlacesResult> {
  if (!places) places = await resolvePlaces($)
  return places
}

// The paths that hang off the state folder. Only called where places are ok.
function stateDir(): string {
  if (!places || !places.ok) throw new Error('bend-guard: its folders are not known')
  return places.p.state
}
const approvedPath = () => `${stateDir()}\\approved.json`
const keyPath = () => `${stateDir()}\\openrouter.key`

// The fix named in every refusal.
function fixText(): string {
  if (places && !places.ok) return 'Install bend-guard as its README says ("Install on another PC"), or turn the plugin off.'
  return places && places.ok ? `To fix: type /bend-guard approve, or check ${places.p.state}\\approved.json.` : 'To fix: type /bend-guard approve.'
}

// ------------------------------------------------------------ module state
// Reset at session.start; a hot reload empties it and the first hook reloads.
// After /bend-guard changes what is approved, started is false again and the
// first hook reloads too (ensureStarted).

type State =
  | { kind: 'inactive' }
  | { kind: 'broken'; why: string }
  | {
      kind: 'active'
      policyText: string // the exact text that was hashed; never re-read
      logOnly: boolean
      project: ProjectEntry
      ask: { root: string; ask: AskConfig } | null
      zones: string[]
      sort: SortRules | null // the approved sort.json's rule lines, for reasons that name their line
    }

// The engine fires tool.call first and tool.check inside its next(e), with the
// same tool_use_id (claude-code.d.ts 'tool.check'; live run 3467a4). tool.call
// judges the call once, both ways (someone can answer / nobody can), and keeps
// the judgment here for tool.check, which picks one by the approver it is given.
type PendingCall = {
  key: string // tool, flattened input and cwds the judgment was made for
  judgment: Judgment
}

let state: State = { kind: 'inactive' }
let started = false
let home = ''
let root = ''
let sessionCwd = ''
let sessionId = ''
let interactive = false
let clefKey: string | undefined // never logged, returned or passed to the host
let clefCache = new Map<string, BendClefAnswer>()
let creditToastShown = false
// Clef calls sent in this session, and the cap (priority 3 C). Kept across a
// reload after /bend-guard; a new session starts at 0.
let clefBudget: ClefBudget = { sent: 0, cap: CLEF_SESSION_CAP }
let capToastShown = false
let cwdMap = new Map<string, string[]>() // agentId or 'main' -> possible shell folders (all shell tools)
// By tool_use_id, for calls between bend-guard's tool.call and its end. All
// are cleared in tool.call's finally.
let pendingCalls = new Map<string, PendingCall>()
let seenAtCheck = new Set<string>() // bend-guard's tool.check answered this call
let askedAtCheck = new Set<string>() // ... and answered ask
let refusedAtCheck = new Set<string>() // ... and answered deny, or what it called beneath did
let judgedAtCheck = new Map<string, Judgment>() // a judgment tool.check made itself (input not what tool.call saw)
let ledger: TurnLedger = newLedger()
let logChain: Promise<void> = Promise.resolve()
let logTexts = new Map<string, string>() // log file path -> what this copy wrote there
let sessionSeen = false // session.start ran in this copy of the module: its cwd and isInteractive stand
let loading: Promise<void> | null = null // a lazy load in progress; every hook waits for it

// The loaded policy and what goes with it.
function resetPolicy(): void {
  state = { kind: 'inactive' }
  started = false
  clefKey = undefined
  clefCache = new Map()
  creditToastShown = false
}

function resetState(): void {
  resetPolicy()
  clefBudget = { sent: 0, cap: CLEF_SESSION_CAP }
  capToastShown = false
  cwdMap = new Map()
  pendingCalls = new Map()
  seenAtCheck = new Set()
  askedAtCheck = new Set()
  refusedAtCheck = new Set()
  judgedAtCheck = new Map()
  ledger = newLedger()
  recent = []
}

// ------------------------------------------------------------------ helpers

async function readText($: any, path: string): Promise<string | undefined> {
  try {
    const t = await $.fs.read(path)
    return typeof t === 'string' ? t : undefined
  } catch {
    return undefined
  }
}

async function existsSafe($: any, path: string): Promise<boolean> {
  try {
    return (await $.fs.exists(path)) === true
  } catch {
    return false
  }
}

// 'yes', 'no', or 'unknown' when $.fs.exists itself failed: a failed check is
// never taken as "the file is not there" where that would turn guarding off
// (review R1-06).
async function existsCheck($: any, path: string): Promise<'yes' | 'no' | 'unknown'> {
  try {
    return (await $.fs.exists(path)) === true ? 'yes' : 'no'
  } catch {
    return 'unknown'
  }
}

function toast($: any, text: string, timeoutMs = TOAST_MS): void {
  try {
    $.ui.toast(text, { timeoutMs })
  } catch {
    // A notice that cannot be shown changes nothing.
  }
}

// "c:/users/x" -> "C:\users\x"
function winPath(p: string): string {
  const s = String(p).replace(/\//g, '\\')
  return s.replace(/^([a-z]):/, (_m: string, d: string) => d.toUpperCase() + ':')
}

// The folder and each parent up to the drive root.
function ancestors(dir: string): string[] {
  const parts = winPath(dir).replace(/\\+$/, '').split('\\').filter((x, i) => i === 0 || x.length > 0)
  const out: string[] = []
  for (let i = parts.length; i >= 1 && out.length < 64; i--) out.push(i === 1 ? parts[0] + '\\' : parts.slice(0, i).join('\\'))
  return out
}

// Folders here and above that hold a BEND_RULES.md. Where the exists check
// fails, a file that can be read counts as there (review R1-06).
async function rulesMdFolders($: any, dir: string): Promise<string[]> {
  const out: string[] = []
  for (const d of ancestors(dir)) {
    const p = `${d.replace(/\\$/, '')}\\BEND_RULES.md`
    const ex = await existsCheck($, p)
    if (ex === 'yes' || (ex === 'unknown' && (await readText($, p)) !== undefined)) out.push(d)
  }
  return out
}

// NoChange / NoReadOrChange rule paths of a project, from its approved
// sort.json, as "specs/" etc. Any shape is walked; [] gives Clef the
// generic wording.
function zonesFrom(sortText: string | undefined): string[] {
  if (!sortText) return []
  let v: unknown
  try {
    v = JSON.parse(sortText)
  } catch {
    return []
  }
  const out = new Set<string>()
  const walk = (x: unknown, depth: number): void => {
    if (depth > 8 || !x || typeof x !== 'object') return
    if (Array.isArray(x)) {
      for (const y of x) walk(y, depth + 1)
      return
    }
    const o = x as Record<string, unknown>
    if ((o.kind === 'NoChange' || o.kind === 'NoReadOrChange') && typeof o.rel === 'string' && /^[A-Za-z0-9._/-]+$/.test(o.rel))
      out.add(o.rel.replace(/\/+$/, '') + '/')
    for (const y of Object.values(o)) walk(y, depth + 1)
  }
  walk(v, 0)
  return [...out].slice(0, 32)
}

function policyMjsPath(dir: string): string | null {
  const d = String(dir).replace(/\//g, '\\').replace(/\\+$/, '')
  if (d.split('\\').some(s => s === '..')) return null
  return /^[a-zA-Z]:\\/.test(d) ? `${d}\\policy.mjs` : `${stateDir()}\\${d.replace(/^\\+/, '')}\\policy.mjs`
}

async function nowMs($: any): Promise<number> {
  try {
    const t = await $.clock.now()
    if (typeof t === 'number' && Number.isFinite(t)) return t
  } catch {
    // fall through
  }
  return Date.now()
}

function since(t0: number): number {
  try {
    return performance.now() - t0
  } catch {
    return 0
  }
}

async function currentCwd($: any): Promise<string> {
  try {
    const c = await $.session.cwd()
    return typeof c === 'string' && c ? c : sessionCwd
  } catch {
    return sessionCwd
  }
}

// One list of possible shell folders per agent (or 'main'), shared by Bash,
// PowerShell and Monitor: in Claude Code they all read and move the same
// session folder, so a cd in one moves the others (review R1-01).
function cwdKey(agentId: string | undefined): string {
  return agentId ?? 'main'
}

// The folders a call may run in. For a shell tool: the tracked list, widened
// with the live session folder ($.session.cwd()), which only ever adds a
// folder. A forgotten folder ([]: any folder) stays forgotten, since adding
// one would narrow it.
async function cwdsFor($: any, agentId: string | undefined, tool: string): Promise<string[]> {
  const cwd = await currentCwd($)
  if (!SHELL_TOOLS.has(tool)) return [cwd]
  const tracked = cwdMap.get(cwdKey(agentId))
  if (!tracked) return [cwd]
  if (tracked.length === 0) return []
  return tracked.some(x => normPath(x) === normPath(cwd)) ? tracked : [...tracked, cwd]
}

function inputKey(tool: string, input: Record<string, unknown>, cwds: string[]): string {
  return JSON.stringify([tool, flattenArgs(input), cwds])
}

function callArgs(e: any): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(e ?? {})) if (!CALL_META.has(k)) out[k] = e[k]
  return out
}

function commandText(tool: string, input: Record<string, unknown>): string {
  const pick = (k: string) => (typeof input[k] === 'string' ? (input[k] as string) : undefined)
  const c = pick('command') ?? pick('file_path') ?? pick('notebook_path') ?? pick('path') ?? pick('url') ?? pick('pattern')
  if (c !== undefined) return c.slice(0, 2000)
  try {
    return JSON.stringify(input).slice(0, 500)
  } catch {
    return tool
  }
}

const RANK: Record<string, number> = { Allow: 0, Ask: 1, Deny: 2 }
function stricter(a: BendVerdict, b: BendVerdict): BendVerdict {
  return (RANK[b.$] ?? 2) > (RANK[a.$] ?? 2) ? b : a
}

// ---------------------------------------------------------------- the log

function utcStamp(t: number): { day: string; time: string } {
  const iso = new Date(t).toISOString()
  return { day: iso.slice(0, 10), time: iso }
}

type LogEntry = {
  agentId: string | undefined
  who?: string // who could be asked, as the check saw it
  tool: string
  verdict: BendVerdict
  enforce: BendVerdict
  clefAsked: boolean
  clefAnswer: string
  latencyMs: number
  cacheHit: boolean
  command: string
}

// The reason a log line and /bend-guard why carry: the verdict's reason (or,
// for a log-only Allow, the enforce verdict's), with its rule line (priority 12 D).
function entryReason(x: LogEntry): string {
  const bendReason = String((x.verdict.$ !== 'Allow' ? (x.verdict as any).reason : x.enforce.$ !== 'Allow' ? (x.enforce as any).reason : '') ?? '')
  return bendReason + ruleSuffix(bendReason, state.kind === 'active' ? state.sort : null)
}

function entryAgent(x: LogEntry): string {
  return (x.agentId ?? 'main') + (x.who ? ` (${x.who})` : '')
}

// The state log of this session for a UTC day.
function logPathFor(day: string): string {
  return `${stateDir()}\\log\\${day}.${logSessionTag()}.tsv`
}

async function appendLog($: any, x: LogEntry): Promise<void> {
  const { day, time } = utcStamp(await nowMs($))
  const reason = entryReason(x)
  const line = logLine({
    time,
    session: sessionId,
    agent: entryAgent(x),
    tool: x.tool,
    verdict: verdictName(x.verdict),
    enforceVerdict: verdictName(x.enforce),
    reason,
    clefAsked: x.clefAsked,
    clefAnswer: x.clefAnswer,
    latencyMs: x.latencyMs,
    cacheHit: x.cacheHit,
    command: x.command,
  })
  // One file per session and UTC day: $.fs has no append, so a shared file
  // would be read, changed and written back, and two sessions could drop each
  // other's lines. This copy of the module keeps its file's text and writes it
  // whole; only its first write reads the file (it may exist after a hot reload).
  const path = logPathFor(day)
  let text = logTexts.get(path)
  if (text === undefined) {
    const prev = await readText($, path)
    text = prev === undefined || prev === '' ? LOG_HEADER : prev
  }
  text += line
  logTexts.set(path, text)
  await $.fs.write(path, text)
}

// The first 8 letters or digits of the session id, or 'nosession'.
function logSessionTag(): string {
  const t = String(sessionId ?? '').replace(/[^A-Za-z0-9]/g, '').slice(0, 8)
  return t || 'nosession'
}

// Serialised so parallel hooks do not drop each other's lines; never throws.
// Each logged call is also kept, masked, for /bend-guard why.
function writeLog($: any, x: LogEntry): Promise<void> {
  try {
    remember({
      agent: entryAgent(x),
      tool: x.tool,
      verdict: verdictName(x.verdict),
      enforce: verdictName(x.enforce),
      reason: redact(entryReason(x)),
      command: redact(x.command),
    })
  } catch {
    // The record is for display; it never changes a verdict or the log.
  }
  logChain = logChain.then(() => appendLog($, x)).catch(() => undefined)
  return logChain
}

// ------------------------------------------------- what /bend-guard why shows
// The last calls checked in this session, newest last, masked like the log.
// Reset with the session; after a hot reload it is empty and /bend-guard why
// reads this session's log file instead.

type Seen = { agent: string; tool: string; verdict: string; enforce: string; reason: string; command: string }
const RECENT_MAX = 20
let recent: Seen[] = []

function remember(s: Seen): void {
  recent.push(s)
  if (recent.length > RECENT_MAX) recent.splice(0, recent.length - RECENT_MAX)
}

// The log's own escapes (glue.ts esc), undone.
function unesc(s: string): string {
  return s.replace(/\\(\\|t|r|n)/g, (_m: string, c: string) => (c === 't' ? '\t' : c === 'r' ? '\r' : c === 'n' ? '\n' : '\\'))
}

// This session's calls from its log file of today (UTC), when the module was
// reloaded and its record is empty. Never throws.
async function recentFromLog($: any): Promise<Seen[]> {
  try {
    const path = logPathFor(utcStamp(await nowMs($)).day)
    const text = logTexts.get(path) ?? (await readText($, path)) ?? ''
    const out: Seen[] = []
    for (const line of text.split('\n')) {
      const f = line.split('\t')
      if (f.length < 12 || f[0] === 'time') continue
      out.push({ agent: unesc(f[2]!), tool: unesc(f[3]!), verdict: f[4]!, enforce: f[5]!, reason: unesc(f[6]!), command: unesc(f[11]!) })
    }
    return out.slice(-RECENT_MAX)
  } catch {
    return []
  }
}

// ------------------------------------------------------------- loading

// keepSession: a reload after /bend-guard changed what is approved. What the
// session saw so far (the shell's possible folders, the calls in flight, the
// turn's ledger) stays true, so only the policy is reloaded.
//
// Review R1-02: no hook ever sees a half-loaded state. Everything is worked
// out in local values first (the old state keeps guarding meanwhile), then
// put in place in one synchronous step at the end; started becomes true only
// there. Every load runs through the `loading` gate (runLoad), which every
// hook waits for. If the load throws, nothing is put in place and the hook
// waiting for it refuses.
async function load($: any, cwd: string, isInteractive: boolean, notices: boolean, keepSession = false): Promise<void> {
  places = await resolvePlaces($) // folders only; the same for every load of this install
  const pl = places
  const newHome = pl.ok ? pl.p.home : ''
  const newCwd = cwd || newHome
  let newRoot: string
  try {
    const r = await $.session.root()
    newRoot = typeof r === 'string' && r ? r : newCwd
  } catch {
    newRoot = newCwd
  }
  let newId: string
  try {
    const id = await $.session.id()
    newId = typeof id === 'string' ? id : ''
  } catch {
    newId = ''
  }
  const found = await decide($, pl, newCwd, newRoot)

  // The one step that changes what hooks see.
  if (keepSession) resetPolicy()
  else resetState()
  home = newHome
  sessionCwd = newCwd
  interactive = isInteractive === true
  root = newRoot
  sessionId = newId
  clefKey = found.clefKey
  state = found.state
  started = true
  if (notices && found.say.length) toast($, found.say.join('\n'))
}

type Decided = { state: State; clefKey: string | undefined; say: string[] }

// What the session is: inactive, broken or active, with its notices. Changes
// no module state except reading `places` (fixText, stateDir).
async function decide($: any, pl: PlacesResult, sessionCwd: string, root: string): Promise<Decided> {
  const say: string[] = []
  const rulesHere = await rulesMdFolders($, sessionCwd)

  if (!pl.ok) {
    // Installed somewhere bend-guard cannot vouch for: refuse wherever it is
    // meant to guard (a BEND_RULES.md here or above, or a project approved in
    // the state folder USERPROFILE names), and stay out of the way elsewhere.
    let approvedHere = false
    if (pl.state) {
      const t = await readText($, `${pl.state}\\approved.json`)
      approvedHere = t !== undefined && (projectFor(t, sessionCwd) ?? projectFor(t, root)) !== null
    }
    if (rulesHere.length > 0 || approvedHere) {
      const why = `it is not installed correctly: ${pl.why}`
      say.push(`bend-guard: refusing every tool call here: ${why}. ${fixText()}`)
      return { state: { kind: 'broken', why }, clefKey: undefined, say }
    }
    return { state: { kind: 'inactive' }, clefKey: undefined, say }
  }

  // approved.json: absent only when $.fs.exists says so. An exists check that
  // fails is not "absent" (review R1-06): the file is read, and a read that
  // fails counts as unreadable.
  const APPROVED = approvedPath()
  let approvedText: string | undefined
  let malformed = false
  if ((await existsCheck($, APPROVED)) !== 'no') {
    approvedText = await readText($, APPROVED)
    if (approvedText === undefined) malformed = true
    else {
      try {
        const o = JSON.parse(approvedText)
        malformed = !o || typeof o !== 'object' || Array.isArray(o) || o.version !== 2
      } catch {
        malformed = true
      }
    }
  }

  if (malformed) {
    // Brief "Simplifications": deny everything only where BEND_RULES.md says
    // this folder is meant to be guarded.
    if (rulesHere.length > 0) {
      const why = approvedText === undefined ? 'approved.json cannot be read' : 'approved.json is not valid (version 2 expected)'
      say.push(`bend-guard: refusing every tool call here: ${why}. ${fixText()}`)
      return { state: { kind: 'broken', why }, clefKey: undefined, say }
    }
    return { state: { kind: 'inactive' }, clefKey: undefined, say }
  }

  const project = approvedText === undefined ? null : (projectFor(approvedText, sessionCwd) ?? projectFor(approvedText, root))
  const roots = approvedText === undefined ? [] : approvedRoots(approvedText)
  const unapproved = rulesHere.find(d => !roots.includes(normPath(d)))
  if (unapproved) say.push(`bend-guard: ${winPath(unapproved).replace(/\\$/, '')}\\BEND_RULES.md is not approved, so it is not enforced. Run /bend-guard:compile, then type /bend-guard approve.`)

  if (!project || approvedText === undefined) return { state: { kind: 'inactive' }, clefKey: undefined, say }

  // From here the session is in an approved project: any failure refuses.
  const fail = (why: string): Decided => {
    say.unshift(`bend-guard: refusing every tool call in ${winPath(project.root)}: ${why}. ${fixText()}`)
    return { state: { kind: 'broken', why }, clefKey: undefined, say }
  }
  try {
    const entry = policyEntry(approvedText)
    const mjsPath = entry ? policyMjsPath(entry.dir) : null
    if (!entry) return fail('approved.json has no valid policy entry')
    if (!mjsPath) return fail('the policy folder in approved.json is not allowed')
    const text = await readText($, mjsPath)
    if (text === undefined || text === '') return fail(`cannot read ${mjsPath}`)
    if (!fingerprintOk(entry, await sha256Hex(text))) return fail('policy.mjs does not match its fingerprint in approved.json')
    const sortText = await readText($, `${stateDir()}\\live\\projects\\${project.slug}\\sort.json`)
    const key = (await readText($, keyPath()))?.trim()
    const clefKey = key ? key : undefined
    const active: State = {
      kind: 'active',
      policyText: text,
      logOnly: entry.logOnly,
      project,
      ask: askEntry(approvedText, sessionCwd) ?? askEntry(approvedText, root),
      zones: zonesFrom(sortText),
      sort: parseSortRules(sortText, project.root),
    }
    say.unshift(
      `bend-guard: guarding ${winPath(project.root)}` +
        (entry.logOnly ? ' in log-only mode (project rules are logged, not enforced; self-protection is enforced).' : ' (rules enforced).') +
        (clefKey ? '' : ' No OpenRouter key: unknown commands are asked about without Clef.'),
    )
    try {
      if (project.rulesMdSha256) {
        const md = await readText($, `${winPath(project.root)}\\BEND_RULES.md`)
        if (md === undefined || (await sha256Hex(md)) !== project.rulesMdSha256)
          say.push('bend-guard: BEND_RULES.md changed since approval; run /bend-guard:compile and approve again.')
      }
    } catch {
      // A notice only; the policy is loaded.
    }
    return { state: active, clefKey, say }
  } catch {
    return fail('its start-up check failed')
  }
}

// Runs a load through the one `loading` gate: it starts after any load in
// progress, and every hook that calls ensureStarted waits for it.
function runLoad(work: () => Promise<void>): Promise<void> {
  const prev = loading
  let run: Promise<void> | null = null
  run = (async () => {
    try {
      if (prev) await prev.catch(() => undefined)
      await work()
    } finally {
      if (loading === run) loading = null
    }
  })()
  loading = run
  return run
}

// A hot reload empties module state without a new session.start, and
// /bend-guard sets started to false after it changed what is approved. The
// first hook then loads; every other hook waits for that load (and for a
// session.start's load), so none sees a half-loaded state and lets a call
// through unchecked.
async function ensureStarted($: any): Promise<void> {
  while (loading) await loading
  if (started) return
  await runLoad(async () => {
    if (started) return
    if (sessionSeen) {
      await load($, sessionCwd, interactive, false, true)
      return
    }
    await registerCommand($) // the reload may have dropped the old copy's registration
    let surfaces: readonly unknown[] = []
    try {
      surfaces = (await $.session.surfaces()) ?? []
    } catch {
      surfaces = []
    }
    await load($, await currentCwd($), surfaces.length > 0, false)
  })
}

// -------------------------------------------------------------- checking

function refusal(why: string): string {
  return `bend-guard: ${why}. ${fixText()}`
}

function clefLabel(status: string, a: BendClefAnswer): string {
  if (status === 'http-402') return 'clef-credit-exhausted'
  return a.$ === 'Answer' ? `${status} risky=${a.risky} unsure=${a.unsure}` : status
}

// What one verdict pair means: `verdict` is what is enforced in the current
// mode, `enforce` what enforce mode would give (the same unless log-only).
type Variant = { verdict: BendVerdict; enforce: BendVerdict }

// One judgment of a call, made once: both for when someone can answer an ask
// (`given`: the approver the judgment was asked with) and for when nobody can
// (`nobody`: approver none, not interactive). A Deny in `given` is a Deny for
// every approver, since Bend's no_ask_without_person only tightens.
type Judgment = {
  tool: string
  agentId: string | undefined
  input: Record<string, unknown>
  cwds: string[]
  given: Variant
  nobody: Variant
  meaning: BendMeaning
  nextCwds: string[]
  clefAsked: boolean
  clefAnswer: string
  clefCacheHit: boolean
  clefWouldAsk: boolean // /bend-guard test only: Bend's step was Consult and Clef was not asked
  latencyMs: number
}

// How a judgment is made. A real call: the mode in force, Clef asked on a
// Consult step. /bend-guard test: both modes (log-only on, the enforce runs
// beside it) and no Clef, so it costs nothing and changes no state.
type JudgeHow = { logOnly: boolean; clef: boolean }

type JudgeArgs = {
  tool: string
  input: Record<string, unknown>
  agentId: string | undefined
  approver: string | undefined // as Bend gets it ('person' when the user can answer)
  present: boolean // someone can answer an ask now
  cwds: string[]
}

// The folder the checker host runs in: the plugin's own (places).
function hostCwd(): string {
  if (!places || !places.ok) throw new Error('bend-guard: its folders are not known')
  return places.p.pluginRoot
}

async function judge($: any, a: JudgeArgs, how?: JudgeHow): Promise<Judgment> {
  if (state.kind !== 'active') throw new Error('not active')
  const st = state
  const logOnly = how ? how.logOnly : st.logOnly
  const useClef = how ? how.clef : true
  const t0 = performance.now()
  const { tool, input, agentId, approver, present, cwds } = a
  const call: BendCall = toBendCall({ tool, input, cwds, root, home, agentId, approver, interactive: present, stage: 'check', logOnly })

  // One host request: the given approver and nobody to answer, at AtCheck.
  const res = await checkRequest($, st.policyText, call, HOST_TIMEOUT_MS, hostCwd())
  let given: Variant = { verdict: res.atCheck, enforce: res.enforce ?? res.atCheck }
  let nobody: Variant = { verdict: res.atCheckNobody, enforce: res.enforceNobody ?? res.atCheckNobody }

  let clefAsked = false
  let clefAnswer = ''
  let clefCacheHit = false
  const clefWouldAsk = res.step.$ === 'Consult' && !useClef
  if (res.step.$ === 'Consult' && useClef) {
    // Clef's step runs here, once per call, as Bend decides.
    clefAsked = true
    const c = await askClef($, { text: res.step.text }, { key: clefKey, model: CLEF_MODEL, timeoutMs: CLEF_TIMEOUT_MS, zones: st.zones, budget: clefBudget }, clefCache)
    clefAnswer = clefLabel(c.status, c.answer)
    clefCacheHit = c.status === 'cache'
    if (c.status === 'http-402' && !creditToastShown) {
      creditToastShown = true
      toast($, 'bend-guard: OpenRouter credit used up; unknown commands are asked about without Clef.')
    }
    if (c.status === 'capped' && !capToastShown) {
      capToastShown = true
      toast($, `bend-guard: Clef limit for this session reached (${clefBudget.cap}); unknown calls are asked or refused without a second opinion.`)
    }
    // With NoAnswer the runs above already hold the verdicts.
    if (c.answer.$ === 'Answer') {
      const r2 = await afterClefRequest($, st.policyText, call, c.answer, HOST_TIMEOUT_MS, hostCwd())
      given = { verdict: r2.atCheck, enforce: r2.enforce ?? r2.atCheck }
      nobody = { verdict: r2.atCheckNobody, enforce: r2.enforceNobody ?? r2.atCheckNobody }
    }
  }

  // Rule 4, only on top of an Allow (asks.ts). Log-only logs it alone.
  if (st.ask && (given.enforce.$ === 'Allow' || nobody.enforce.$ === 'Allow')) {
    const why = await askForRules(res.meaning, st.ask.root, p => existsSafe($, p), st.ask.ask)
    if (why) {
      const canAsk = askOutcome(agentId, approver) === 'ask' && present
      const refuse: BendVerdict = { $: 'Deny', reason: `Ask the user in the main session. ${why}` }
      const add = (x: Variant, v: BendVerdict): Variant => {
        if (x.enforce.$ !== 'Allow') return x
        return { enforce: stricter(x.enforce, v), verdict: !logOnly && x.verdict.$ === 'Allow' ? v : x.verdict }
      }
      given = add(given, canAsk ? { $: 'Ask', reason: why } : refuse)
      nobody = add(nobody, refuse)
    }
  }

  // Rule 8: name the packages in the policy's install Ask.
  const note = npmInstallNote(res.meaning)
  const withNote = (v: BendVerdict): BendVerdict => (note && v.$ === 'Ask' ? { $: 'Ask', reason: `${v.reason} ${note}` } : v)
  given = { verdict: withNote(given.verdict), enforce: withNote(given.enforce) }
  nobody = { verdict: withNote(nobody.verdict), enforce: withNote(nobody.enforce) }

  return { tool, agentId, input, cwds, given, nobody, meaning: res.meaning, nextCwds: res.nextCwds, clefAsked, clefAnswer, clefCacheHit, clefWouldAsk, latencyMs: since(t0) }
}

// Who can answer, from what the engine says at tool.check. In the IDE
// extensions the extension's dialog (approver 'host') is the user answering; a host
// with no surface (claude -p, the SDK) stays a program, never a person.
// Approver 'person' means a dialog reaches the user, so they are at the screen even
// when the start-up guess (a hot reload in VS Code sees no surface) said
// nobody was. An agent is never asked.
function whoAtCheck(e: any): { rawApprover: string | undefined; agentId: string | undefined; present: boolean; approver: string | undefined; person: boolean } {
  const agentId: string | undefined = typeof e?.agentId === 'string' ? e.agentId : undefined
  const rawApprover: string | undefined = typeof e?.approver === 'string' ? e.approver : undefined
  const present = interactive || (rawApprover === 'person' && agentId === undefined)
  const approver = rawApprover === 'host' && present && agentId === undefined ? 'person' : rawApprover
  const person = agentId === undefined && present && approver === 'person'
  return { rawApprover, agentId, present, approver, person }
}

// The text shown with an Ask or a Deny: the verdict's reason (kept whole)
// with its BEND_RULES.md line, then what bend-guard read, a hint, and on an
// Ask the facts for the dialog (reasons.ts). Display only.
function shown(j: Judgment, decision: 'ask' | 'deny', reason: string): string {
  return explain({
    decision,
    reason,
    tool: j.tool,
    input: j.input,
    meaning: j.meaning,
    base: j.cwds[0] ?? sessionCwd,
    sort: state.kind === 'active' ? state.sort : null,
  })
}

function logEntry(j: Judgment, v: Variant, who: string, cacheHit: boolean): LogEntry {
  return {
    agentId: j.agentId,
    who,
    tool: j.tool,
    verdict: v.verdict,
    enforce: v.enforce,
    clefAsked: j.clefAsked,
    clefAnswer: j.clefAnswer,
    latencyMs: j.latencyMs,
    cacheHit: cacheHit || j.clefCacheHit,
    command: commandText(j.tool, j.input),
  }
}

// What happened to a call after tool.call's next(e), as far as it is known.
// There is no engine field for "refused beneath tool.call": a refusal there
// comes back as an errored result, the same shape as a tool that failed (or
// one whose output merely says "denied"). So an errored result is UNSURE
// unless bend-guard's own tool.check saw the refusal.
type Outcome = 'ran' | 'not-run' | 'unsure'

function outcomeOf(r: any, id: string | undefined): Outcome {
  if (r && typeof r === 'object' && typeof r.deny === 'string') return 'not-run'
  if (r && typeof r === 'object' && r.isError !== true) return 'ran'
  if (id !== undefined && refusedAtCheck.has(id)) return 'not-run'
  return 'unsure'
}

// Folder tracking and the rules 9/10 ledger, only as far as it is known the
// tool ran. Folders are a safety input: when unsure, the possible folders
// widen (old and new), never move. Never throws.
function bookkeeping(r: any, id: string | undefined, j: Judgment, command: string | undefined): void {
  try {
    const outcome = outcomeOf(r, id)
    if (outcome === 'not-run') return
    const shell = SHELL_TOOLS.has(j.tool)
    if (shell) {
      const k = cwdKey(j.agentId)
      if (outcome === 'ran') cwdMap.set(k, j.nextCwds)
      else {
        const old = cwdMap.get(k) ?? j.cwds
        // A forgotten folder ([]) stays forgotten.
        cwdMap.set(k, old.length === 0 || j.nextCwds.length === 0 ? [] : [...new Set([...old, ...j.nextCwds])])
      }
    }
    if (outcome === 'ran') {
      recordCall(ledger, j.meaning, shell ? command : undefined, shell ? 0 : undefined)
      return
    }
    // Unsure: a reminder only. Not counted when the user was asked (their "no" looks
    // like this) or the engine's refusal text says so; otherwise counted as a
    // failed run, so a failed npm test still does not count as passed.
    const text = String(r?.text ?? '')
    if ((id !== undefined && askedAtCheck.has(id)) || /^Permission to use \S+ denied/.test(text)) return
    recordCall(ledger, j.meaning, shell ? command : undefined, shell ? 1 : undefined)
  } catch {
    // Bookkeeping never changes the tool's result.
  }
}


// ---------------------------------------------------- the /bend-guard command
// The user approves and switches modes by typing /bend-guard in Claude Code;
// tools\approve.mjs does the work (its header has the steps). The command
// answers only a person's own typing, judged by the run's origin. Whatever
// writes to S starts only through the one-time token handshake: the mod writes
// sha256(token) to S\.approve-token and gives the token to approve.mjs on
// stdin. Claude never sees the token and cannot write S in a guarded session
// (self-protection), and bend-guard's default rule denies a Claude tool call
// that runs approve.mjs or invokes /bend-guard. The token is never logged or
// returned.

const NODE = 'C:\\Program Files\\nodejs\\node.exe'
// The tools folder and the token file, from the places (never a fixed path).
function toolsDir(): string {
  if (!places || !places.ok) throw new Error('bend-guard: its folders are not known')
  return places.p.tools
}
const approveMjs = () => `${toolsDir()}\\tools\\approve.mjs`
const tokenFile = () => `${stateDir()}\\.approve-token`
const COMMAND = 'bend-guard'
const PENDING_MS = 30 * 60 * 1000
const RESULT_TOAST_MS = 60000
// A person's own typing (PromptOrigin in claude-code.d.ts). Every other kind is
// refused, by name: plugin, peer, peer-send-message, task-notification,
// scheduled-trigger, projects-relay, channel, coordinator, observer,
// observer-activity, auto-continuation, and any kind added later. Which kind
// the VS Code extension stamps is not known, so sdk and unclassified stay in,
// but the engine does not attest them as a person (sdk is also claude -p and
// the Agent SDK; unclassified is any unstamped source). From those two, the
// commands that change something (confirm, enforce, log-only) go ahead only
// after a yes in the engine's own dialog ($.ui.ask), which a -p run cannot
// answer (review R1-03).
const PERSON_ORIGINS = new Set(['composer', 'sdk', 'bridge', 'unclassified', 'slack-ping'])
const UNATTESTED_ORIGINS = new Set(['sdk', 'unclassified'])
const GATE_YES = 'Yes, go ahead'
const GATE_NO = 'No'

// Resolves to null when the command may go ahead, else the text to answer.
type PersonGate = (question: string) => Promise<string | null>
const NO_GATE: PersonGate = async () => null

function personGate($: any, kind: string): PersonGate {
  if (!UNATTESTED_ORIGINS.has(kind)) return NO_GATE
  return async (question: string) => {
    let answer: unknown
    try {
      answer = await $.ui.ask(`bend-guard: this /bend-guard command came from "${kind}", which Claude Code cannot confirm is you typing. ${question}`, {
        options: [GATE_NO, GATE_YES], // "No" first: a dialog that settles by itself lands on no
        header: 'bend-guard',
      })
    } catch {
      answer = undefined
    }
    if (answer === GATE_YES) return null
    return `bend-guard: nothing was done. This run came from "${kind}", and nobody answered "${GATE_YES}" in the dialog. Type the command yourself in Claude Code.`
  }
}
const USAGE = [
  'bend-guard: type one of these yourself (Claude cannot run them):',
  '  /bend-guard approve    show how this project\'s BEND_RULES.md would be approved, line by line, with its laws',
  '  /bend-guard confirm    prove and approve what approve showed, in log-only mode (add --enforce to enforce at once)',
  '  /bend-guard status     show what is approved, and the mode',
  '  /bend-guard enforce    enforce the project rules in every approved project',
  '  /bend-guard log-only   only log the project rules in every approved project (self-protection stays on)',
  '  /bend-guard why [n]    show the last n calls bend-guard checked in this session and why (default 5, at most 20)',
  '  /bend-guard test [Bash|PowerShell] <command>   show what bend-guard would say to a command, in both modes; nothing runs',
  '  /bend-guard doctor     check that bend-guard is installed and set up (reads only)',
].join('\n')
const NO_RULES = 'bend-guard: there is no BEND_RULES.md in this folder or any folder above it, so there is nothing to approve.'

type Pending = { root: string; snapshot: string; previewSha256: string; at: number }
type LastRun = { root: string; ok: boolean; at: number; lines: string[] }

let pending: Pending | null = null // what /bend-guard approve showed, waiting for /bend-guard confirm
let approving: string | null = null // the project a background approval runs for
let switching = false // a mode switch is running
let lastRun: LastRun | null = null // the last confirm's end, for /bend-guard status

function errText(err: unknown): string {
  const s = err && typeof err === 'object' && 'message' in err ? String((err as any).message) : String(err)
  return s.replace(/\s+/g, ' ').trim().slice(0, 300)
}

function clipText(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 3) + '...' : s
}

function setStatus($: any, text: string | undefined): void {
  try {
    $.ui.status(text)
  } catch {
    // A status line that cannot be drawn changes nothing.
  }
}

async function registerCommand($: any): Promise<void> {
  try {
    await $.command.register({
      name: COMMAND,
      description: "Approve this project's BEND_RULES.md, switch log-only or enforce, show status, or explain verdicts",
      argumentHint: 'approve | confirm | status | enforce | log-only | why [n] | test [Bash|PowerShell] <command> | doctor',
    })
  } catch {
    // Without the command, approve.mjs in the user's own terminal still works.
  }
}

// After /bend-guard changed what is approved: the next tool call loads
// approved.json and the policy again (ensureStarted).
function reloadAfterChange(): void {
  started = false
}

// The last non-empty line of approve.mjs's output, if it is a JSON object.
function lastJson(out: string): Record<string, any> | null {
  const lines = String(out ?? '')
    .split(/\r?\n/)
    .map(l => l.trim())
    .filter(l => l !== '')
  const last = lines[lines.length - 1]
  if (!last || !last.startsWith('{')) return null
  try {
    const v = JSON.parse(last)
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null
  } catch {
    return null
  }
}

// The nearest folder at or above the session's folder that holds BEND_RULES.md.
async function rulesRoot($: any): Promise<string | null> {
  for (const d of ancestors(await currentCwd($))) {
    if (await existsSafe($, `${d.replace(/\\$/, '')}\\BEND_RULES.md`)) return d
  }
  return null
}

async function runApprove($: any, args: string[], timeoutMs: number, stdin?: string): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const init: Record<string, unknown> = { cwd: toolsDir(), timeoutMs }
  if (stdin !== undefined) init.stdin = stdin
  const r = await $.process.run([NODE, approveMjs(), ...args], init)
  return { exitCode: Number(r?.exitCode), stdout: String(r?.stdout ?? ''), stderr: String(r?.stderr ?? '') }
}

// The mod's half of the handshake. Returns why it failed, or null.
async function writeToken($: any, token: string): Promise<string | null> {
  try {
    await $.fs.write(tokenFile(), await sha256Hex(token))
    return null
  } catch (err) {
    return `bend-guard: could not write the one-time token file ${tokenFile()} (${errText(err)}), so nothing was started.`
  }
}

// /bend-guard approve: approve.mjs --preview shows what would be approved and
// keeps a copy of the draft; pending remembers it for /bend-guard confirm.
async function commandApprove($: any): Promise<string> {
  pending = null
  const root = await rulesRoot($)
  if (!root) return NO_RULES
  let r: { exitCode: number; stdout: string; stderr: string }
  try {
    r = await runApprove($, ['--preview', root], 180000)
  } catch (err) {
    return `bend-guard: approve.mjs could not run or took too long (${errText(err)}). Nothing was changed.`
  }
  const out = lastJson(r.stdout)
  if (!out) {
    const said = clipText((r.stderr.trim() || r.stdout.trim()).replace(/\s+/g, ' '), 600)
    return `bend-guard: approve.mjs gave no answer (exit code ${r.exitCode}).${said ? ` It said: ${said}` : ''} Nothing was changed.`
  }
  if (out.ok !== true) return `bend-guard: ${root} cannot be approved yet. ${typeof out.error === 'string' && out.error ? out.error : 'approve.mjs did not say why.'}`
  const hex = typeof out.previewSha256 === 'string' && /^[0-9a-f]{64}$/.test(out.previewSha256)
  if (typeof out.snapshot !== 'string' || !out.snapshot || typeof out.display !== 'string' || !hex || normPath(String(out.root ?? '')) !== normPath(root)) {
    return 'bend-guard: approve.mjs answered in a shape this command does not know, so there is nothing to confirm. Nothing was changed.'
  }
  pending = { root, snapshot: out.snapshot, previewSha256: out.previewSha256, at: await nowMs($) }
  return `${out.display}\n\nTo make these rules live (log-only first), type /bend-guard confirm. Add --enforce to enforce at once.`
}

// /bend-guard confirm [--enforce]: the approval itself, in the background.
async function commandConfirm($: any, args: string[], gate: PersonGate = NO_GATE): Promise<string> {
  const flags = new Set(args)
  if (args.length > 1 || [...flags].some(f => f !== '--enforce' && f !== '--log-only')) return `bend-guard: confirm takes only --enforce or --log-only.\n${USAGE}`
  const enforce = flags.has('--enforce')
  if (approving) return `bend-guard: an approval of ${approving} is already running. Wait for its notice.`
  if (switching) return 'bend-guard: a switch of mode is running. Type /bend-guard approve again once it is done.'
  const root = await rulesRoot($)
  if (!root) return NO_RULES
  const p = pending
  if (!p) return 'bend-guard: there is nothing to confirm yet. Type /bend-guard approve first, read what it shows, then type /bend-guard confirm.'
  pending = null
  if (normPath(p.root) !== normPath(root)) return `bend-guard: what you looked at was for ${p.root}, but this session is now in ${root}. Type /bend-guard approve again.`
  const now = await nowMs($)
  if (now < p.at || now - p.at > PENDING_MS) return 'bend-guard: what you looked at is more than 30 minutes old. Type /bend-guard approve again.'
  const refusedBy = await gate(`Approve the rules of ${root} now${enforce ? ', enforcing them at once' : ''}?`)
  if (refusedBy) {
    pending = p
    return refusedBy
  }
  if (approving || switching) {
    pending = p
    return 'bend-guard: another approval or switch of mode started meanwhile. Type /bend-guard confirm again once it is done.'
  }
  const token = crypto.randomUUID() + crypto.randomUUID()
  const failed = await writeToken($, token)
  if (failed) {
    pending = p
    return failed
  }
  approving = root
  setStatus($, 'bend-guard: approving... starting')
  void runApproval($, root, p, enforce, token).catch(() => undefined)
  return `Approving ${root}: all proofs run again (about 5 minutes). Keep working; a notice appears when it is done.`
}

// The background half of /bend-guard confirm: approve.mjs --snapshot, its
// progress on the status line, then a notice and a reload of the policy.
// Never throws.
async function runApproval($: any, root: string, p: Pending, enforce: boolean, token: string): Promise<void> {
  const seen: string[] = []
  let carry = ''
  let errTail = ''
  let code: number | null = null
  let broke = ''
  try {
    const proc = $.process.spawn({
      argv: [NODE, approveMjs(), '--snapshot', p.snapshot, '--expect', p.previewSha256, '--from-mod', enforce ? '--enforce' : '--log-only'],
      cwd: toolsDir(),
      input: token + '\n',
    })
    for await (const piece of proc) {
      const text = String(piece?.text ?? '')
      if (piece?.stream === 'stderr') {
        errTail = (errTail + text).slice(-2000)
        continue
      }
      const parts = (carry + text).split(/\r?\n/)
      carry = parts.pop() ?? ''
      for (const raw of parts) {
        const l = raw.trim()
        if (!l) continue
        seen.push(l)
        if (seen.length > 40) seen.shift()
        if (!l.startsWith('{')) setStatus($, `bend-guard: approving... ${clipText(l, 80)}`)
      }
    }
    if (carry.trim()) seen.push(carry.trim())
    try {
      const end = await proc.result
      code = typeof end?.code === 'number' ? end.code : null
    } catch {
      code = null
    }
  } catch (err) {
    broke = `approve.mjs could not run or was stopped (${errText(err)})`
  } finally {
    approving = null
    setStatus($, undefined)
    reloadAfterChange()
  }
  // Only the very last line counts as approve.mjs's answer.
  const final = lastJson(seen.length ? seen[seen.length - 1] : '')
  const ok = !broke && code === 0 && final?.ok === true
  const progress = seen.filter(l => !l.startsWith('{'))
  lastRun = { root, ok, at: await nowMs($), lines: progress.slice(-12) }
  if (ok) {
    toast($, `bend-guard: rules for ${root} are live (${enforce ? 'enforcing' : 'log-only'}).`, RESULT_TOAST_MS)
    return
  }
  const why =
    broke ||
    (final && typeof final.message === 'string' && final.message) ||
    clipText(errTail.trim().replace(/\s+/g, ' '), 600) ||
    progress[progress.length - 1] ||
    `approve.mjs ended with exit code ${code ?? 'unknown'}`
  toast($, `bend-guard: ${root} was not approved: ${why}`, RESULT_TOAST_MS)
}

// /bend-guard status: approve.mjs --status, plus what this session has going.
async function commandStatus($: any): Promise<string> {
  let text: string
  try {
    const r = await runApprove($, ['--status'], 60000)
    text = r.stdout.trim() || r.stderr.trim() || `bend-guard: approve.mjs --status printed nothing (exit code ${r.exitCode}).`
  } catch (err) {
    text = `bend-guard: could not run approve.mjs --status (${errText(err)}).`
  }
  const notes: string[] = []
  notes.push(`Clef (the second opinion) calls sent in this session: ${clefBudget.sent} of at most ${clefBudget.cap}.`)
  if (approving) notes.push(`An approval of ${approving} is running in the background; a notice appears when it is done.`)
  if (pending) notes.push(`You looked at the rules of ${pending.root} with /bend-guard approve. Type /bend-guard confirm within 30 minutes of that to approve them.`)
  if (lastRun) {
    notes.push(`The last /bend-guard confirm in this session (${new Date(lastRun.at).toISOString()}) ${lastRun.ok ? 'approved' : 'did not approve'} ${lastRun.root}. Its last lines:`)
    for (const l of lastRun.lines) notes.push(`  ${l}`)
  }
  return notes.length ? `${text}\n\n${notes.join('\n')}` : text
}

// /bend-guard enforce and /bend-guard log-only: the handshake, then approve.mjs
// --mode-only. The user typing the command is their yes.
async function commandMode($: any, enforce: boolean, gate: PersonGate = NO_GATE): Promise<string> {
  if (approving) return `bend-guard: an approval of ${approving} is running. Switch after its notice; a switch now would make that approval stop at its end.`
  if (switching) return 'bend-guard: a switch of mode is already running.'
  const refusedBy = await gate(enforce ? 'Enforce the project rules in every approved project now?' : 'Switch every approved project to log-only now (project rules logged, not enforced)?')
  if (refusedBy) return refusedBy
  if (approving || switching) return 'bend-guard: an approval or another switch of mode started meanwhile. Type the command again once it is done.'
  switching = true
  try {
    const token = crypto.randomUUID() + crypto.randomUUID()
    const failed = await writeToken($, token)
    if (failed) return failed
    let r: { exitCode: number; stdout: string; stderr: string }
    try {
      r = await runApprove($, ['--mode-only', '--from-mod', enforce ? '--enforce' : '--log-only'], 60000, token + '\n')
    } catch (err) {
      return `bend-guard: approve.mjs could not run or took too long (${errText(err)}). Type /bend-guard status to see the mode.`
    } finally {
      reloadAfterChange()
    }
    return r.stdout.trim() || r.stderr.trim() || `bend-guard: approve.mjs printed nothing (exit code ${r.exitCode}). Type /bend-guard status to see the mode.`
  } finally {
    switching = false
  }
}

// ------------------------------------------- /bend-guard why, test and doctor
// Backlog round 3, priority 10. In log-only mode the user sees nothing for a call
// that enforce mode would refuse; these show them what bend-guard decided and
// why, without opening the log. They read only: no log line, no folder
// tracking, no rules 9/10 ledger, no Clef call, no state written.

const WHY_DEFAULT = 5
const SHAPE_MAX = 120
const REASON_MAX = 400

// A command as shown: masked, on one line, at most 120 characters.
function shape(command: string): string {
  return clipText(redact(String(command ?? '')).replace(/\s+/g, ' ').trim(), SHAPE_MAX)
}

function plainReason(reason: string): string {
  return clipText(redact(String(reason ?? '')).replace(/\s+/g, ' ').trim(), REASON_MAX)
}

// "deny", or "allow (enforce mode: deny)" when the modes differ.
function verdictPair(verdict: string, enforce: string): string {
  return verdict === enforce ? verdict : `${verdict} (enforce mode: ${enforce})`
}

async function commandWhy($: any, arg: string | undefined): Promise<string> {
  let n = WHY_DEFAULT
  if (arg !== undefined) {
    if (!/^\d{1,3}$/.test(arg) || Number(arg) < 1) return 'bend-guard: why takes a number of calls, 1 to 20: /bend-guard why 10'
    n = Math.min(Number(arg), RECENT_MAX)
  }
  await ensureStarted($)
  if (state.kind === 'inactive') return `bend-guard: it is not guarding ${winPath(await currentCwd($))}, so it has checked no calls here.`
  if (state.kind === 'broken') return `bend-guard: it refuses every call here: ${state.why}. ${fixText()}`
  const from = recent.length ? recent : await recentFromLog($)
  const list = from.slice(-n)
  if (!list.length) return 'bend-guard: it has checked no calls in this session yet.'
  const mode = state.logOnly ? 'log-only: project rules are logged, not enforced' : 'enforce'
  const out = [`bend-guard: the last ${list.length === 1 ? 'call' : `${list.length} calls`} it checked in this session, newest last (mode: ${mode}):`]
  list.forEach((x, i) => {
    const who = /^main\b/.test(x.agent) ? '' : ` (agent ${x.agent.split(' ')[0]})`
    const why = x.reason ? ` ${plainReason(x.reason)}` : ''
    out.push(`${i + 1}. ${x.tool}${who}: ${shape(x.command) || '(no text)'} -> ${verdictPair(x.verdict, x.enforce)}.${why}`)
  })
  return out.join('\n')
}

const TEST_TOOLS: Record<string, string> = { bash: 'Bash', powershell: 'PowerShell' }

async function commandTest($: any, text: string): Promise<string> {
  let tool = 'Bash'
  let command = text
  const m = /^(\S+)\s+([\s\S]*)$/.exec(text)
  if (m && TEST_TOOLS[m[1]!.toLowerCase()]) {
    tool = TEST_TOOLS[m[1]!.toLowerCase()]!
    command = m[2]!
  } else if (TEST_TOOLS[text.toLowerCase()]) command = ''
  command = command.trim()
  if (!command) return 'bend-guard: test needs a command, for example: /bend-guard test cat README.md, or /bend-guard test PowerShell Get-ChildItem src'
  await ensureStarted($)
  const cwd = await currentCwd($)
  if (state.kind === 'inactive') return `bend-guard: it is not guarding ${winPath(cwd)} (no approved project here), so it would not check this command.`
  if (state.kind === 'broken') return `bend-guard: it refuses every call here: ${state.why}. ${fixText()}`
  const logOnlyNow = state.logOnly
  // A main-session call in the session folder, with a person to answer: the
  // same host run as a real call, judged in both modes, without Clef.
  const j = await judge($, { tool, input: { command }, agentId: undefined, approver: 'person', present: true, cwds: [cwd] }, { logOnly: true, clef: false })
  const v = j.given
  const sort = state.kind === 'active' ? state.sort : null
  const said = (x: BendVerdict) => {
    const name = verdictName(x)
    const reason = x.$ === 'Allow' ? '' : String((x as any).reason ?? '')
    return reason ? `${name}. ${plainReason(reason + ruleSuffix(reason, sort))}` : name
  }
  const enforceName = verdictName(v.enforce)
  const logName = verdictName(v.verdict)
  const logLine = logName === enforceName ? said(v.verdict) : `${logName} (logged: enforce mode would ${enforceName})`
  const seen = meaningLines(j.meaning, cwd, tool, command)
  const out = [
    `bend-guard: test of a ${tool} call in ${winPath(cwd)}: ${shape(command)}`,
    `  enforce mode: ${said(v.enforce)}`,
    `  log-only mode: ${logLine}`,
    `  this project is in ${logOnlyNow ? 'log-only' : 'enforce'} mode now.`,
    `  what bend-guard read: ${seen.length ? redact(seen.join('; ')) : 'nothing it acts on'}.`,
  ]
  if (j.clefWouldAsk) out.push('  Clef would be asked for a second opinion; it can only make the answer stricter. This test does not ask it.')
  out.push('  Nothing ran, and nothing was logged.')
  return out.join('\n')
}

// /bend-guard doctor: tools\doctor.mjs (read-only, no network without --clef).
async function commandDoctor($: any): Promise<string> {
  const pl = await placesNow($)
  const dir = pl.ok ? pl.p.tools : pl.pluginRoot
  if (!dir) return `bend-guard: doctor cannot run: ${pl.ok ? 'no tools folder' : pl.why}.`
  try {
    const r = await $.process.run([NODE, `${dir}\\tools\\doctor.mjs`], { cwd: dir, timeoutMs: 120000 })
    const out = String(r?.stdout ?? '').trim() || String(r?.stderr ?? '').trim()
    return out || `bend-guard: doctor printed nothing (exit code ${Number(r?.exitCode)}).`
  } catch (err) {
    return `bend-guard: doctor could not run or took too long (${errText(err)}).`
  }
}

async function serveCommand($: any, e: any): Promise<{ text: string }> {
  try {
    const origin = e?.origin
    const kind = typeof origin?.kind === 'string' ? origin.kind : 'unknown'
    if (!PERSON_ORIGINS.has(kind)) {
      const from = kind === 'plugin' && typeof origin?.name === 'string' ? `plugin (${origin.name})` : kind
      return { text: `bend-guard: /bend-guard answers only your own typing. This run came from "${from}", so it was refused and nothing was done.` }
    }
    const words = String(e?.args ?? '')
      .trim()
      .split(/\s+/)
      .filter(w => w !== '')
    const sub = (words[0] ?? '').toLowerCase()
    const rest = words.slice(1)
    // These read only, and work wherever the command is typed.
    if (sub === 'why' && rest.length <= 1) return { text: await commandWhy($, rest[0]) }
    if (sub === 'test') return { text: await commandTest($, String(e?.args ?? '').trim().replace(/^\S+\s*/, '')) }
    if (sub === 'doctor' && rest.length === 0) return { text: await commandDoctor($) }
    // The rest run approve.mjs from the tools folder, so they need to know it.
    const known = ['approve', 'confirm', 'status', 'enforce', 'log-only']
    if (known.includes(sub)) {
      const pl = await placesNow($)
      if (!pl.ok) return { text: `bend-guard: /bend-guard ${sub} cannot run: bend-guard is not installed correctly: ${pl.why}. ${fixText()}` }
    }
    if (sub === 'approve' && rest.length === 0) return { text: await commandApprove($) }
    if (sub === 'confirm') return { text: await commandConfirm($, rest, personGate($, kind)) }
    if (sub === 'status' && rest.length === 0) return { text: await commandStatus($) }
    if ((sub === 'enforce' || sub === 'log-only') && rest.length === 0) return { text: await commandMode($, sub === 'enforce', personGate($, kind)) }
    return { text: USAGE }
  } catch (err) {
    return { text: `bend-guard: the command failed: ${errText(err)}` }
  }
}

// ---------------------------------------------------------------- hooks

export const register: Register = on => {
  on('session.start', async ($: any, e: any, next: any) => {
    // Always, even where bend-guard is inactive, so the user can approve the first time.
    pending = null
    await registerCommand($)
    // Through the loading gate, so every hook waits for this load (R1-02).
    await runLoad(async () => {
      await load($, typeof e?.cwd === 'string' ? e.cwd : '', e?.isInteractive === true, true)
      sessionSeen = true
    })
    return next(e)
  }).catch(($: any, e: any, next: any) => next(e))

  // /bend-guard: answered here, never passed on.
  // Claude Code shows a command's text under the plugin's name, so drop our own
  // prefix from every line (USAGE and approve.mjs answers have several).
  on('command.run', { command: COMMAND }, async ($: any, e: any) => {
    const r = await serveCommand($, e)
    return { text: r.text.replace(/^bend-guard: /gm, '') }
  }).catch(($: any, e: any, next: any) => ({
    text: `the command failed: ${String(next?.error?.message ?? next?.error?.kind ?? 'unknown error').slice(0, 300)}`,
  }))

  // The engine's order: tool.call fires first and judges the call once (one
  // checker host run, Clef at most once). It refuses a Deny itself: a Deny
  // judged with a person present is a Deny for every approver. tool.check
  // fires inside tool.call's next(e) with the same tool_use_id and the
  // approver; it answers ask or deny from the kept judgment, without a host
  // run. One log line per call.
  on('tool.check', async ($: any, e: any, next: any) => {
    await ensureStarted($)
    if (state.kind === 'inactive') return next(e)
    if (state.kind === 'broken') return { decision: 'deny', reason: refusal(state.why) }

    const id: string | undefined = typeof e.tool_use_id === 'string' ? e.tool_use_id : undefined
    const tool = String(e.tool ?? '')
    const who = whoAtCheck(e)
    const input: Record<string, unknown> = e.input && typeof e.input === 'object' ? e.input : {}
    const cwds = await cwdsFor($, who.agentId, tool)
    const p = id !== undefined ? pendingCalls.get(id) : undefined

    let j: Judgment
    let v: Variant
    let reused = false
    if (p && p.judgment.agentId === who.agentId && p.key === inputKey(tool, input, cwds)) {
      // The judgment tool.call made for exactly this input.
      j = p.judgment
      v = who.person ? j.given : j.nobody
      reused = true
    } else {
      // No judgment from tool.call ($.tool.check, or a hook beneath
      // bend-guard's tool.call rewrote the input): judge with this approver.
      j = await judge($, { tool, input, agentId: who.agentId, approver: who.approver, present: who.present, cwds })
      v = j.given
      if (id !== undefined && pendingCalls.has(id)) judgedAtCheck.set(id, j)
    }
    if (id !== undefined) seenAtCheck.add(id)
    await writeLog($, logEntry(j, v, `approver=${who.rawApprover ?? 'none'}${who.present ? '' : ' not-interactive'}`, reused))

    const verdict = v.verdict
    const refusedBeneath = (core: any) => {
      if (id !== undefined && core?.decision === 'deny') refusedAtCheck.add(id)
      return core
    }
    if (verdict.$ === 'Deny') {
      if (id !== undefined) refusedAtCheck.add(id)
      return { decision: 'deny', reason: shown(j, 'deny', verdict.reason) }
    }
    if (verdict.$ === 'Ask') {
      if (id !== undefined) askedAtCheck.add(id)
      const core = refusedBeneath(await next(e))
      return core?.decision === 'deny' ? core : { decision: 'ask', reason: shown(j, 'ask', verdict.reason) }
    }
    if (verdict.$ === 'Allow') return refusedBeneath(await next(e))
    if (id !== undefined) refusedAtCheck.add(id)
    return { decision: 'deny', reason: 'bend-guard: the checker gave an unknown verdict; refusing. To fix: run /bend-guard:compile and approve again.' }
  }).catch(($: any, e: any, next: any) => {
    if (next.called) return next(e)
    if (typeof e?.tool_use_id === 'string') refusedAtCheck.add(e.tool_use_id)
    return { decision: 'deny', reason: `bend-guard: its check of ${String(e?.tool ?? 'this tool')} failed or took too long, so it refuses. Retry; if it keeps failing, ${fixText()}` }
  })

  on('tool.call', async ($: any, e: any, next: any) => {
    await ensureStarted($)
    if (state.kind === 'inactive') return next(e)
    if (state.kind === 'broken') return { deny: refusal(state.why) }

    const tool = String(e.tool ?? '')
    const agentId: string | undefined = typeof e.agentId === 'string' ? e.agentId : undefined
    const id: string | undefined = typeof e.tool_use_id === 'string' ? e.tool_use_id : undefined
    try {
      const input = callArgs(e)
      const cwds = await cwdsFor($, agentId, tool)
      // tool.call carries no approver. Judge as if the user can answer in the main
      // loop; the nobody-to-answer verdict is in the same judgment. An agent is
      // never asked (Bend turns its Ask into a Deny).
      const j = await judge($, { tool, input, agentId, approver: 'person', present: agentId === undefined ? true : interactive, cwds })
      if (j.given.verdict.$ === 'Deny') {
        await writeLog($, logEntry(j, j.given, 'refused before the permission step', false))
        return { deny: shown(j, 'deny', j.given.verdict.reason) }
      }
      if (id !== undefined) pendingCalls.set(id, { key: inputKey(tool, input, cwds), judgment: j })

      const r = await next(e)
      // What ran is what tool.check judged when it judged a rewritten input.
      const ran = (id !== undefined ? judgedAtCheck.get(id) : undefined) ?? j
      if (id !== undefined && !seenAtCheck.has(id)) {
        // bend-guard's tool.check never answered this call: a plugin above it
        // (an administrator's prepend plugin) answered the permission step
        // first. Log it once here, with what bend-guard would have answered
        // where the user can be asked (a Deny was already refused above). If that
        // was an Ask and the tool ran, the user is told once.
        await writeLog($, logEntry(j, j.given, 'permission step answered by another plugin', false))
        const v = j.given.verdict
        if (v.$ === 'Ask' && outcomeOf(r, id) === 'ran') {
          const why = clipText((v.reason + ruleSuffix(v.reason, state.kind === 'active' ? state.sort : null)).replace(/\s+/g, ' '), 600)
          toast($, `bend-guard: ${tool} ran without bend-guard's question; another plugin answered the permission step first. bend-guard would have asked: ${why}`)
        }
      }
      bookkeeping(r, id, ran, typeof ran.input.command === 'string' ? (ran.input.command as string) : undefined)
      return r
    } finally {
      if (id !== undefined) {
        pendingCalls.delete(id)
        seenAtCheck.delete(id)
        askedAtCheck.delete(id)
        refusedAtCheck.delete(id)
        judgedAtCheck.delete(id)
      }
    }
  }).catch(($: any, e: any, next: any) =>
    next.called ? next(e) : { deny: `bend-guard: its check of ${String(e?.tool ?? 'this tool')} before running failed or took too long, so it refuses. Retry; if it keeps failing, ${fixText()}` },
  )

  // Rules 9 and 10: a reminder on the main loop's answer (turn.complete
  // cannot block; brief Q7).
  on('turn.complete', async ($: any, e: any, next: any) => {
    if (e?.agentId !== undefined) return next(e)
    let reason: string | null = null
    try {
      if (state.kind === 'active' && state.ask) reason = stopReason(ledger, state.ask.ask)
    } catch {
      reason = null
    }
    ledger = newLedger()
    const r = await next(e)
    if (!reason || !r || typeof r.text !== 'string') return r
    return { ...r, text: r.text + '\n\n' + reason }
  }).catch(($: any, e: any, next: any) => next(e))
}

export default register
