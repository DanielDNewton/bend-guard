// bend-guard: runs the compiled checker. One node child per request
// ($.process.run of node with the host's source as its -e program, no shell,
// full paths, no host file read), fed the exact policy.mjs text that was
// hashed at session start. Every reply is shape
// checked; anything unexpected throws and the calling hook denies.
//
// Brief: bend2_test\docs\build-brief.md, "Decisions that
// replace the spike gates" (Q2, P14) and "Checker host protocol".
// Design: bend2_test\docs\design.md, component 8.

import {
  type BendAction,
  type BendCall,
  type BendClefAnswer,
  type BendMeaning,
  type BendStep,
  type BendVerdict,
  NO_ANSWER,
  withLogOnly,
  withStage,
} from './glue'

export const NODE_EXE = 'C:\\Program Files\\nodejs\\node.exe'
// The hook deadline for one host run (brief Q2).
export const HOST_TIMEOUT_MS = 4000

export type HostOp =
  | { op: 'decide' | 'meaning' | 'next_cwds' | 'paths'; call: BendCall }
  | { op: 'run'; call: BendCall; answer: BendClefAnswer }

function fail(why: string): never {
  throw new Error('bend-guard checker: ' + why)
}

// Runs the host once. Resolves the raw results, one per op; throws on a
// non-zero exit, cut output, bad JSON, ok:false or the wrong result count.
// `cwd` is the folder the host runs in: the plugin's folder, from the session
// ($.plugin.root), never a fixed path (backlog round 3, priority 5). The host
// reads no file, so the folder only has to exist.
export async function runHost($: any, policyText: string, ops: HostOp[], timeoutMs: number, cwd: string): Promise<unknown[]> {
  if (typeof policyText !== 'string' || !policyText) fail('no policy text')
  if (typeof cwd !== 'string' || !/^[A-Za-z]:[\\/]/.test(cwd)) fail('no folder to run the host in')
  const stdin = JSON.stringify({ policy: policyText, ops })
  // The host runs from HOST_SOURCE, the copy of host\host.mjs built into this
  // module, never from that file: an edit to host.mjs on disk cannot change a
  // verdict. Node reads an -e program as an ES module with --input-type=module.
  const r = await $.process.run([NODE_EXE, '--input-type=module', '-e', HOST_SOURCE], {
    stdin,
    cwd,
    timeoutMs,
    // Neutralise preload hooks a user environment could add to node.
    env: { NODE_OPTIONS: '', NODE_PATH: '' },
  })
  if (!r || typeof r !== 'object') fail('no result from process.run')
  if (r.exitCode !== 0) fail(`host exited ${r.exitCode}: ${String(r.stderr ?? '').slice(0, 200)}`)
  if (r.isStdoutTruncated) fail('host output was cut')
  let reply: any
  try {
    reply = JSON.parse(String(r.stdout ?? '').trim())
  } catch {
    fail('host output is not JSON')
  }
  if (!reply || typeof reply !== 'object') fail('host reply is not an object')
  if (reply.ok !== true) fail('host: ' + String(reply.error ?? 'unknown error').slice(0, 300))
  if (!Array.isArray(reply.results) || reply.results.length !== ops.length) fail('host gave the wrong number of results')
  return reply.results
}

// ---------------------------------------------------------------------------
// Shape validators: tags and field types, per plan "Shared interfaces".

const MAX_LIST = 100000

function isObj(x: unknown): x is Record<string, any> {
  return x !== null && typeof x === 'object' && !Array.isArray(x)
}

// Walks a Con/Nil chain; every head must pass `el`.
export function isBendListOf(x: unknown, el: (v: unknown) => boolean): boolean {
  let cur: any = x
  for (let n = 0; n <= MAX_LIST; n++) {
    if (!isObj(cur)) return false
    if (cur.$ === 'Nil') return true
    if (cur.$ !== 'Con' || !('head' in cur) || !('tail' in cur)) return false
    if (!el(cur.head)) return false
    cur = cur.tail
  }
  return false
}

function listToArray<T>(x: any): T[] {
  const out: T[] = []
  let cur = x
  while (cur.$ === 'Con') {
    out.push(cur.head)
    cur = cur.tail
  }
  return out
}

const isStr = (v: unknown): v is string => typeof v === 'string'
const isBool = (v: unknown): v is boolean => typeof v === 'boolean'

export function isStringList(x: unknown): boolean {
  return isBendListOf(x, isStr)
}

export function isVerdict(x: unknown): x is BendVerdict {
  if (!isObj(x)) return false
  if (x.$ === 'Allow') return true
  if (x.$ === 'Ask' || x.$ === 'Deny') return isStr(x.reason)
  return false
}

export function isStep(x: unknown): x is BendStep {
  if (!isObj(x)) return false
  // Bend's Base owns the constructor Done, so Types.bend names it Step.Done (NOTES.md).
  if (x.$ === 'Step.Done') return isVerdict(x.v)
  if (x.$ === 'Consult') {
    return isObj(x.q) && (x.q.$ === 'Triage' || x.q.$ === 'Veto') && isVerdict(x.base) && isStr(x.text)
  }
  return false
}

// Path segments are String or Nat codes (brief Q5: the Path agent picks).
const isSeg = (v: unknown) => isStr(v) || (typeof v === 'number' && Number.isInteger(v) && v >= 0)
function isPath(x: unknown): boolean {
  return isObj(x) && x.$ === 'Path' && isStr(x.drive) && isBendListOf(x.segs, isSeg)
}

const PATH_ACTIONS = new Set(['Read', 'ReadTree', 'ListDir', 'Write', 'WriteTree', 'Delete', 'DeleteTree', 'MoveFrom', 'MakeDir', 'ChangeDir'])

export function isAction(x: unknown): x is BendAction {
  if (!isObj(x) || !isStr(x.$)) return false
  if (PATH_ACTIONS.has(x.$)) return isPath(x.path)
  switch (x.$) {
    case 'GitRead':
    case 'GitRef':
    case 'Inert':
      return true
    case 'GitPush':
      return isPath(x.dir) && isBool(x.force) && isBool(x.all) && isStringList(x.refs) && isBool(x.unsure)
    case 'NpmInstall':
      return isStringList(x.pkgs)
    case 'RunScript':
      return isStr(x.name)
    case 'DraftCheck':
      return isStr(x.slug)
    default:
      return false
  }
}

export function isMeaning(x: unknown): x is BendMeaning {
  if (!isObj(x)) return false
  if (x.$ === 'Known') return isBendListOf(x.actions, isAction)
  if (x.$ === 'Unknown') return isStr(x.why) && isBendListOf(x.known, isAction)
  return false
}

function want<T>(x: unknown, ok: (v: unknown) => boolean, what: string): T {
  if (!ok(x)) fail(`${what} has the wrong shape`)
  return x as T
}

function strings(x: unknown, what: string): string[] {
  if (!isStringList(x)) fail(`${what} has the wrong shape`)
  return listToArray<string>(x)
}

// ---------------------------------------------------------------------------
// Typed requests. `call` is the call as built by toBendCall; its stage is
// replaced here, and its log_only says whether to add the enforce runs.
//
// The engine fires tool.call first and tool.check inside its next(e)
// (claude-code.d.ts 'tool.check'; live run 3467a4), and tool.call carries no
// approver. So one request judges a call both ways at AtCheck: as the call
// says (for tool.call: a person can answer) and with nobody to answer
// (approver none, not interactive). tool.check then picks one of the two by
// the approver it is given, without a second host run. Bend's AtCall stage
// is not used at runtime; its laws still hold.

const AT_CHECK = { $: 'AtCheck' } as const

// The same call where nobody can answer an ask.
export function withNobody(c: BendCall): BendCall {
  return { ...c, approver: '', interactive: false }
}

export type CheckResult = {
  step: BendStep
  atCheck: BendVerdict // run at AtCheck with NoAnswer, approver as given
  atCheckNobody: BendVerdict // the same with nobody to answer
  meaning: BendMeaning
  nextCwds: string[] // [] = not known
  enforce: BendVerdict | null // log-only: atCheck as enforce mode would give it; else null
  enforceNobody: BendVerdict | null // log-only: atCheckNobody as enforce mode would give it; else null
}

export type ClefRunResult = {
  atCheck: BendVerdict
  atCheckNobody: BendVerdict
  enforce: BendVerdict | null
  enforceNobody: BendVerdict | null
}

// The one request per judged call (brief "Checker host protocol").
export async function checkRequest($: any, policyText: string, call: BendCall, timeoutMs: number, cwd: string): Promise<CheckResult> {
  const c = withStage(call, AT_CHECK)
  const n = withNobody(c)
  const ops: HostOp[] = [
    { op: 'decide', call: c },
    { op: 'run', call: c, answer: NO_ANSWER },
    { op: 'run', call: n, answer: NO_ANSWER },
    { op: 'meaning', call: c },
    { op: 'next_cwds', call: c },
  ]
  if (call.log_only) {
    ops.push({ op: 'run', call: withLogOnly(c, false), answer: NO_ANSWER })
    ops.push({ op: 'run', call: withLogOnly(n, false), answer: NO_ANSWER })
  }
  const r = await runHost($, policyText, ops, timeoutMs, cwd)
  return {
    step: want<BendStep>(r[0], isStep, 'decide'),
    atCheck: want<BendVerdict>(r[1], isVerdict, 'run at check'),
    atCheckNobody: want<BendVerdict>(r[2], isVerdict, 'run at check (nobody to ask)'),
    meaning: want<BendMeaning>(r[3], isMeaning, 'meaning'),
    nextCwds: strings(r[4], 'next_cwds'),
    enforce: call.log_only ? want<BendVerdict>(r[5], isVerdict, 'run with log_only off') : null,
    enforceNobody: call.log_only ? want<BendVerdict>(r[6], isVerdict, 'run with log_only off (nobody to ask)') : null,
  }
}

// The second request, after Clef answered a Consult step.
export async function afterClefRequest(
  $: any,
  policyText: string,
  call: BendCall,
  answer: BendClefAnswer,
  timeoutMs: number,
  cwd: string,
): Promise<ClefRunResult> {
  const c = withStage(call, AT_CHECK)
  const n = withNobody(c)
  const ops: HostOp[] = [
    { op: 'run', call: c, answer },
    { op: 'run', call: n, answer },
  ]
  if (call.log_only) {
    ops.push({ op: 'run', call: withLogOnly(c, false), answer })
    ops.push({ op: 'run', call: withLogOnly(n, false), answer })
  }
  const r = await runHost($, policyText, ops, timeoutMs, cwd)
  return {
    atCheck: want<BendVerdict>(r[0], isVerdict, 'run at check'),
    atCheckNobody: want<BendVerdict>(r[1], isVerdict, 'run at check (nobody to ask)'),
    enforce: call.log_only ? want<BendVerdict>(r[2], isVerdict, 'run with log_only off') : null,
    enforceNobody: call.log_only ? want<BendVerdict>(r[3], isVerdict, 'run with log_only off (nobody to ask)') : null,
  }
}

// Folders the shell may be in after the call ([] = not known).
export async function nextCwdsRequest($: any, policyText: string, call: BendCall, timeoutMs: number, cwd: string): Promise<string[]> {
  const r = await runHost($, policyText, [{ op: 'next_cwds', call }], timeoutMs, cwd)
  return strings(r[0], 'next_cwds')
}

// The meaning alone (for the ask hooks when no check result is at hand).
export async function meaningRequest($: any, policyText: string, call: BendCall, timeoutMs: number, cwd: string): Promise<BendMeaning> {
  const r = await runHost($, policyText, [{ op: 'meaning', call }], timeoutMs, cwd)
  return want<BendMeaning>(r[0], isMeaning, 'meaning')
}

// ---------------------------------------------------------------------------
// The checker host, as a byte-for-byte copy of host\host.mjs (that file stays
// the readable source and is used by tests\lib). runHost hands this text to
// node as its -e program, so no host file is read at check time. After any
// change to host.mjs, copy it here; a tools test compares the two.
export const HOST_SOURCE: string = String.raw`// bend-guard: the checker host. Runs as a child of the hooks module, once per
// check. hooks/checker.ts holds a byte-for-byte copy of this file (HOST_SOURCE)
// and runs it with $.process.run(['node.exe', '--input-type=module', '-e',
// HOST_SOURCE], { stdin }), so no file is read at check time. Change this file,
// then copy it into HOST_SOURCE; a tools test compares the two.
//
// stdin:  { "policy": "<policy.mjs text>", "ops": [ { "op", "call", "answer"? }, ... ] }
// stdout: one JSON line, { "ok": true, "results": [...] } or { "ok": false, "error": "..." }
//
// The policy is imported from a data: URL made from the text the glue hashed
// and checked, so this file never reads a path and never uses the network.
// It converts nothing beyond what Bend returns. Always exits 0.
//
// Brief: docs\build-brief.md of the bend2_test project, "Checker host protocol".

// The entry's export keys. If Bend spells them differently, the foundation
// agent records the real keys in bend\NOTES.md: change them here.
const KEYS = {
  decide: 'Policy.decide',
  run: 'Policy.run',
  meaning: 'Policy.meaning',
  next_cwds: 'Policy.next_cwds',
  paths: 'Policy.paths',
}

let answered = false
function reply(obj) {
  if (answered) return
  answered = true
  let line
  try {
    line = JSON.stringify(obj)
  } catch (err) {
    line = JSON.stringify({ ok: false, error: 'result is not JSON: ' + short(err) })
  }
  process.stdout.write(line + '\n')
  process.exitCode = 0
}

function short(err) {
  const s = err && typeof err === 'object' && 'message' in err ? String(err.message) : String(err)
  return s.length > 300 ? s.slice(0, 300) + '...' : s
}

function fail(msg) {
  reply({ ok: false, error: msg })
}

process.on('uncaughtException', err => fail('uncaught: ' + short(err)))
process.on('unhandledRejection', err => fail('unhandled: ' + short(err)))

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : chunk)
  return Buffer.concat(chunks).toString('utf8')
}

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
}

async function main() {
  let req
  try {
    req = JSON.parse(await readStdin())
  } catch (err) {
    return fail('bad request: ' + short(err))
  }
  if (!isObject(req) || typeof req.policy !== 'string' || !Array.isArray(req.ops)) {
    return fail('bad request: want { policy: string, ops: [] }')
  }

  let mod
  try {
    const url = 'data:text/javascript;base64,' + Buffer.from(req.policy, 'utf8').toString('base64')
    mod = await import(url)
  } catch (err) {
    return fail('policy did not load: ' + short(err))
  }
  const api = mod && mod.default
  if (!isObject(api)) return fail('policy has no default export object')
  for (const k of Object.values(KEYS)) {
    if (typeof api[k] !== 'function') return fail('policy lacks export ' + k)
  }

  const results = []
  for (let i = 0; i < req.ops.length; i++) {
    const o = req.ops[i]
    if (!isObject(o) || typeof o.op !== 'string' || !Object.prototype.hasOwnProperty.call(KEYS, o.op)) {
      return fail('op ' + i + ': unknown op')
    }
    if (!isObject(o.call)) return fail('op ' + i + ': call is not an object')
    const f = api[KEYS[o.op]]
    try {
      if (o.op === 'run') {
        if (!isObject(o.answer)) return fail('op ' + i + ': run needs an answer')
        results.push(f(o.call, o.answer))
      } else {
        results.push(f(o.call))
      }
    } catch (err) {
      return fail('op ' + i + ' (' + o.op + ') threw: ' + short(err))
    }
  }
  reply({ ok: true, results })
}

main().catch(err => fail('host: ' + short(err)))
`
