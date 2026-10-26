// bend-guard wiring tests: the world beneath the plugin. Every noun the hooks
// touch is answered here from memory (fs, process, http, clock, session, ui),
// so a test never reads or writes the real state folder, never starts a
// process and never reaches the network.
//
// The checker host (host\host.mjs) is replaced by a small fake policy that
// answers in the Bend encoding (Con/Nil lists, {$: Name} constructors, the
// Verdict / Step / Meaning shapes of hooks\glue.ts and bend\core\Types.bend).
// It mirrors the real policy's finishing step: an Ask stands at AtCheck only
// when the call is not an agent's, the approver is "person" and the session
// is interactive (bend\core\Call.bend can_ask); at AtCall it becomes Allow
// only when it was asked about, else Deny. Project-rule denies are relaxed
// in log-only mode, self-protection never.
//
// Commands the fake understands (Bash / PowerShell / Monitor `command`):
//   ls ...                 Allow, ListDir
//   cat <p>                Allow, Read; <p> with specs: Veto consult; openrouter.key: self deny
//   rm -rf <p>             DeleteTree; with specs: project Deny "rule 1"
//   npm install [pkgs]     Ask, NpmInstall
//   npm test, npm run lint Allow, RunScript
//   touch <p>, mkdir <p>   Allow, Write / MakeDir
//   cd <p>                 Allow, ChangeDir, next_cwds [<cwd>\<p>]
//   popd                   Allow, next_cwds [] (folder forgotten)
//   cdask <p>              Ask, ChangeDir, next_cwds [<cwd>\<p>] (a cd the user may refuse)
//   ask-anyway ...         Ask even where nobody can be asked (exercises the ask/call path)
//   a && b                 each part as above; one unknown part makes it Unknown
//                          (the other parts' actions are its known actions)
//   anything else          Unknown: Triage consult, base Ask; $( ), $VAR,
//                          backticks, heredocs and loop keywords give the
//                          lexer's "shell syntax" reason, as the real policy does
// Read / Write / Edit by file_path; an mcp__ tool: Unknown, Ask (never sent to
// Clef); any other tool: Allow, no actions. Reasons use the real policy's
// wording (bend\core\Guard.bend) where the glue reads them.
//
// The host is started as node --input-type=module -e HOST_SOURCE (checker.ts):
// a host run is recognised by those arguments, never by a file.

import { mock } from 'claude-code/testing'
import { sha256Hex } from '../../hooks/sha256'
import { HOST_SOURCE } from '../../hooks/checker'

// The plugin's folder is the one the test runner loads ($.plugin.root): this
// file's folder, two levels up. The hooks accept it only as
// <home>\.claude\local-plugins\bend-guard, so HOME is the home that folder sits
// in, and the project and state folders hang off HOME. The in-memory file
// system holds the rest, so the tests give the same results on any PC.
const LOCAL_PLUGINS = '\\.claude\\local-plugins\\bend-guard'
export const PLUGIN = String((import.meta as any).dir).replace(/\\tests\\lib\\?$/i, '')
export const HOME = PLUGIN.toLowerCase().endsWith(LOCAL_PLUGINS) ? PLUGIN.slice(0, -LOCAL_PLUGINS.length) : 'C:\\Users\\user'
export const S = HOME + '\\.claude\\bend-guard'
export const ROOT = HOME + '\\bend2_test'
// ROOT as Path.show prints it (lower case, forward slashes)
export const ROOT_N = ROOT.replace(/\\/g, '/').toLowerCase()
export const NODE = 'C:\\Program Files\\nodejs\\node.exe'
export const HOST_MJS = PLUGIN + '\\host\\host.mjs' // never read or run by the hooks
export const HOST_ARGV = [NODE, '--input-type=module', '-e', HOST_SOURCE]
// The real policy's reason for a change under specs/ (rule kind NoChange).
export const SPECS_DENY = `bend-guard rule (BEND_RULES.md): ${ROOT_N}/specs may not be changed. Leave it as it is, or ask the user to change BEND_RULES.md.`
export const SPECS_DENIED = 'specs may not be changed'
export const SHELL_SYNTAX =
  'the command text uses shell syntax that bend-guard does not read (such as variables, $(...), a comma list, a comment, a quote that is not closed, or a non-ASCII character)'
export const notUnderstood = (why: string) => `bend-guard: not understood (${why}). The user can approve; or use a known command.`
export const APPROVE_MJS = PLUGIN + '\\tools\\approve.mjs'
export const TOKEN_FILE = S + '\\.approve-token'
export const APPROVED_PATH = S + '\\approved.json'
export const POLICY_PATH = S + '\\live\\policy\\policy.mjs'
export const KEY_PATH = S + '\\openrouter.key'
export const SLUG = ROOT_N.replace(/[:/. ]/g, '-') // as tools/gen.mjs slugOf gives it
export const SORT_PATH = S + '\\live\\projects\\' + SLUG + '\\sort.json'
export const RULES_PATH = ROOT + '\\BEND_RULES.md'
export const POLICY_TEXT = '// fake compiled policy for the wiring tests\nexport default {}\n'
export const RULES_MD = '# Rules\n1. Never change specs/.\n'
export const SESSION_ID = 'sess-wiring-1'
// 2026-10-26 23:30 UTC: the log file is named by the UTC day and the session
// (<day>.<first 8 letters or digits of the session id>.tsv).
export const NOW = Date.UTC(2026, 9, 26, 23, 30, 0)
export const LOG_DIR = S + '\\log'
export const LOG_PATH = LOG_DIR + '\\2026-10-26.sesswiri.tsv'
export const LOG_HEADER = 'time\tsession\tagent\ttool\tverdict\tenforceVerdict\treason\tclefAsked\tclefAnswer\tlatencyMs\tcacheHit\tcommand\n'

// ------------------------------------------------------------ Bend values

export type V = { $: 'Allow' } | { $: 'Ask'; reason: string } | { $: 'Deny'; reason: string }
export const ALLOW: V = { $: 'Allow' }
export const ask = (reason: string): V => ({ $: 'Ask', reason })
export const deny = (reason: string): V => ({ $: 'Deny', reason })

export function L(xs: readonly unknown[]): any {
  let l: any = { $: 'Nil' }
  for (let i = xs.length - 1; i >= 0; i--) l = { $: 'Con', head: xs[i], tail: l }
  return l
}

export function A(l: any): any[] {
  const out: any[] = []
  let cur = l
  while (cur && cur.$ === 'Con') {
    out.push(cur.head)
    cur = cur.tail
  }
  return out
}

function winJoin(cwd: string, rel: string): string {
  const r = rel.replace(/\//g, '\\').replace(/^"|"$/g, '')
  if (/^[a-zA-Z]:\\/.test(r)) return r
  return cwd.replace(/\\+$/, '') + '\\' + r.replace(/^\.\\/, '')
}

export function bendPath(win: string): any {
  const s = win.replace(/\//g, '\\')
  const m = /^([a-zA-Z]):\\?(.*)$/.exec(s)
  if (!m) return { $: 'Path', drive: '?', segs: L([]) }
  const segs = m[2].split('\\').filter(x => x.length > 0).map(x => x.toLowerCase())
  return { $: 'Path', drive: m[1].toLowerCase(), segs: L(segs) }
}

type Kind = 'plain' | 'project' | 'self'
type Classified = {
  meaning: any
  base: V
  kind: Kind
  consult?: { q: 'Triage' | 'Veto'; text: string }
  next: string[] | null
  forceAsk?: boolean
}

function argOf(call: any, key: string): string | undefined {
  for (const a of A(call.args)) if (a.key === key) return a.value
  return undefined
}

const SELF_KEY = /openrouter\.key/i
const SPECS = /(^|[\\/ ])specs([\\/]|$)/i

export function classify(call: any): Classified {
  const cwds = A(call.cwds) as string[]
  const cwd = cwds[0] ?? call.root
  const known = (actions: any[]) => ({ $: 'Known', actions: L(actions) })
  const tool = call.tool
  if (tool === 'Bash' || tool === 'PowerShell' || tool === 'Monitor') {
    const c = (argOf(call, 'command') ?? '').trim()
    let m: RegExpExecArray | null
    if (c.includes(' && ')) {
      const parts = c.split(' && ').map(p => classify({ ...call, args: L([{ $: 'Arg', key: 'command', value: p }]) }))
      const acts = parts.flatMap(p => A(p.meaning.$ === 'Known' ? p.meaning.actions : p.meaning.known))
      const unknown = parts.find(p => p.meaning.$ === 'Unknown')
      if (unknown) return { ...unknown, meaning: { $: 'Unknown', why: unknown.meaning.why, known: L(acts) }, consult: { q: 'Triage', text: c } }
      const denied = parts.find(p => p.base.$ === 'Deny')
      return { meaning: known(acts), base: parts.map(p => p.base).reduce(stricter, ALLOW), kind: denied?.kind ?? 'plain', next: parts[parts.length - 1]!.next }
    }
    if (/^ls\b/.test(c)) return { meaning: known([{ $: 'ListDir', path: bendPath(cwd) }]), base: ALLOW, kind: 'plain', next: null }
    if ((m = /^cat (.+)$/.exec(c))) {
      const p = winJoin(cwd, m[1])
      if (SELF_KEY.test(p)) return { meaning: known([{ $: 'Read', path: bendPath(p) }]), base: deny('bend-guard (self-protection): the OpenRouter key file is never read.'), kind: 'self', next: null }
      const meaning = known([{ $: 'Read', path: bendPath(p) }])
      if (SPECS.test(m[1])) return { meaning, base: ALLOW, kind: 'plain', next: null, consult: { q: 'Veto', text: c } }
      return { meaning, base: ALLOW, kind: 'plain', next: null }
    }
    if ((m = /^rm -rf (.+)$/.exec(c))) {
      const p = winJoin(cwd, m[1])
      const meaning = known([{ $: 'DeleteTree', path: bendPath(p) }])
      // under specs from any folder the shell may be in (or the text names it)
      const under = cwds.some((d: string) => /\\bend2_test\\specs(\\|$)/i.test(winJoin(d, m![1])))
      if (SPECS.test(m[1]) || under) return { meaning, base: deny(SPECS_DENY), kind: 'project', next: null }
      return { meaning, base: ALLOW, kind: 'plain', next: null }
    }
    if ((m = /^npm (install|i|ci)\b ?(.*)$/.exec(c))) {
      const pkgs = m[2].split(/\s+/).filter(x => x && !x.startsWith('-'))
      return { meaning: known([{ $: 'NpmInstall', pkgs: L(pkgs) }]), base: ask('bend-guard: npm install runs package.json scripts; the user decides.'), kind: 'plain', next: null }
    }
    if ((m = /^npm (test|run lint)$/.exec(c))) return { meaning: known([{ $: 'RunScript', name: m[1] === 'test' ? 'test' : 'lint' }]), base: ALLOW, kind: 'plain', next: null }
    if ((m = /^touch (.+)$/.exec(c))) return { meaning: known([{ $: 'Write', path: bendPath(winJoin(cwd, m[1])) }]), base: ALLOW, kind: 'plain', next: null }
    if ((m = /^mkdir (.+)$/.exec(c))) return { meaning: known([{ $: 'MakeDir', path: bendPath(winJoin(cwd, m[1])) }]), base: ALLOW, kind: 'plain', next: null }
    if ((m = /^cd (.+)$/.exec(c))) {
      const p = winJoin(cwd, m[1])
      return { meaning: known([{ $: 'ChangeDir', path: bendPath(p) }]), base: ALLOW, kind: 'plain', next: [p] }
    }
    if (/^popd\b/.test(c)) return { meaning: known([]), base: ALLOW, kind: 'plain', next: [] }
    if ((m = /^cdask (.+)$/.exec(c))) {
      const p = winJoin(cwd, m[1])
      return { meaning: known([{ $: 'ChangeDir', path: bendPath(p) }]), base: ask('bend-guard: the test policy asks before this cd.'), kind: 'plain', next: [p] }
    }
    if (/^ask-anyway\b/.test(c)) return { meaning: known([]), base: ask('bend-guard: the test policy asks about this.'), kind: 'plain', next: null, forceAsk: true }
    const why = /\$|`|<<|(?:^|[;&|(])\s*(?:for|while|until|if)\s/.test(c) ? SHELL_SYNTAX : `the command ${c.split(/\s+/)[0]} is not modelled`
    return {
      meaning: { $: 'Unknown', why, known: L([]) },
      base: ask(notUnderstood(why)),
      kind: 'plain',
      next: null,
      consult: { q: 'Triage', text: c },
    }
  }
  if (typeof tool === 'string' && tool.startsWith('mcp__')) {
    const why = `tool ${tool} not modelled`
    return { meaning: { $: 'Unknown', why, known: L([]) }, base: ask(notUnderstood(why)), kind: 'plain', next: null }
  }
  const fp = argOf(call, 'file_path')
  if (tool === 'Read' && fp) {
    if (SELF_KEY.test(fp)) return { meaning: known([{ $: 'Read', path: bendPath(fp) }]), base: deny('bend-guard (self-protection): the OpenRouter key file is never read.'), kind: 'self', next: null }
    return { meaning: known([{ $: 'Read', path: bendPath(fp) }]), base: ALLOW, kind: 'plain', next: null }
  }
  if ((tool === 'Write' || tool === 'Edit') && fp) {
    const meaning = known([{ $: 'Write', path: bendPath(fp) }])
    if (SPECS.test(fp)) return { meaning, base: deny(SPECS_DENY), kind: 'project', next: null }
    return { meaning, base: ALLOW, kind: 'plain', next: null }
  }
  return { meaning: known([]), base: ALLOW, kind: 'plain', next: null }
}

const RANK: Record<string, number> = { Allow: 0, Ask: 1, Deny: 2 }
const stricter = (a: V, b: V): V => (RANK[b.$] > RANK[a.$] ? b : a)

export function fakeRun(call: any, answer: any): V {
  const c = classify(call)
  let v = c.base
  if (c.consult && answer && answer.$ === 'Answer') {
    if (c.consult.q === 'Triage' && answer.risky >= 800) v = deny('bend-guard: Clef says this looks risky; refused.')
    if (c.consult.q === 'Veto' && answer.risky >= 500) v = stricter(v, ask('bend-guard: Clef thinks this may change a protected file.'))
  }
  if (v.$ === 'Deny' && c.kind === 'project' && call.log_only === true) v = ALLOW
  const canAsk = call.agent !== true && call.approver === 'person' && call.interactive === true
  if (v.$ === 'Ask') {
    if (call.stage.$ === 'AtCheck') {
      if (!canAsk && !c.forceAsk) v = deny('bend-guard: no person can answer an ask here, so this is refused. Ask the user in the main session. (' + v.reason + ')')
    } else {
      v = call.stage.asked === true && (canAsk || c.forceAsk) ? ALLOW : deny("bend-guard: this call needed the user's approval and did not get it. Ask the user in the main session. (" + v.reason + ')')
    }
  }
  return v
}

export function fakeDecide(call: any): any {
  const c = classify(call)
  if (c.consult) return { $: 'Consult', q: { $: c.consult.q }, base: c.base, text: c.consult.text }
  return { $: 'Step.Done', v: fakeRun(call, { $: 'NoAnswer' }) }
}

export function fakeNextCwds(call: any): any {
  const c = classify(call)
  return L(c.next ?? A(call.cwds))
}

export type HostReq = { policy: string; ops: any[] }

export function fakeHostReply(req: HostReq): any[] {
  return req.ops.map((o: any) => {
    if (o.op === 'decide') return fakeDecide(o.call)
    if (o.op === 'run') return fakeRun(o.call, o.answer)
    if (o.op === 'meaning') return classify(o.call).meaning
    if (o.op === 'next_cwds') return fakeNextCwds(o.call)
    if (o.op === 'paths') return L([])
    throw new Error('fake host: unknown op ' + o.op)
  })
}

// ------------------------------------------------------------ the world

export type AskCfg = { newTopLevelDir: boolean; npmInstall: boolean; testBeforeDone: string | null; lintBeforeDone: string | null }
export const ASK_ALL: AskCfg = { newTopLevelDir: true, npmInstall: true, testBeforeDone: 'npm test', lintBeforeDone: 'npm run lint' }
export const ASK_NONE: AskCfg = { newTopLevelDir: false, npmInstall: false, testBeforeDone: null, lintBeforeDone: null }

export type RunResult = { exitCode: number; stdout: string; stderr?: string; isStdoutTruncated?: boolean }
export type FetchAnswer = { status: number; text: string } | 'hang' | 'refuse'

export type Opts = {
  approved?: Record<string, any> | string | null // null: no approved.json; a string: written as is
  approvedUnreadable?: boolean // approved.json exists but reading it fails
  existsFails?: RegExp // $.fs.exists fails (throws) for a path that matches
  logOnly?: boolean
  ask?: AskCfg
  rulesMd?: boolean // BEND_RULES.md in ROOT (default true)
  rulesMdText?: string // what BEND_RULES.md holds now (default RULES_MD, the approved text)
  policyText?: string | null // the policy.mjs on disk (null: missing)
  policyDir?: string
  mjsSha256?: string // the fingerprint approved.json records (default: of policyText)
  key?: string | null // openrouter.key
  sortJson?: string | null
  existing?: string[] // folders that exist
  host?: (req: HostReq) => RunResult | 'refuse'
  fetch?: (url: string, init: any) => FetchAnswer
  approve?: (argv: string[], init: any) => RunResult | 'refuse'
  spawn?: (e: any) => { chunks: { stream: 'stdout' | 'stderr'; text: string }[]; code: number | null } | 'refuse'
  surfaces?: string[]
  cwd?: string
  // USERPROFILE as the plugin reads it (default HOME); null: not set. The
  // plugin's folder ($.plugin.root) is the real one the test runner loads.
  home?: string | null
  // Any other process the hooks start (not the host, not approve.mjs).
  run?: (argv: string[], init: any) => RunResult | 'refuse'
  failWrites?: RegExp
  toolResult?: (e: any) => any
  // Play the real engine's permission step (see engineSim below): pass the
  // test's own $, who answers asks, and what the person says to an ask.
  engine?: { $: any; approver?: 'person' | 'host'; person?: 'yes' | 'no' }
}

export type World = {
  files: Map<string, string>
  writes: { path: string; text: string }[]
  toasts: string[]
  statuses: (string | undefined)[]
  hostReqs: HostReq[]
  hostRuns: { argv: string[]; init: any }[]
  fetches: { url: string; init: any }[]
  runs: { argv: string[]; init: any }[]
  spawns: any[]
  toolRuns: any[]
  checksBelow: any[]
  permissionRequests: any[]
  registered: any[]
  reads: string[]
  clock: any
  logText(): string
  logLines(): string[][]
  hostCalls(): any[] // the call of the first op of each host request
  // engine mode: each tool.check the engine raised inside a tool.call (input and answer)
  engineChecks: { e: any; c: any }[]
  // engine mode: what the person was shown (each ask that reached a person)
  dialogs: { e: any; reason: string }[]
  preToolUse: any[] // every classic.PreToolUse the engine raised (it sits inside tool.call's next)
  // What $.session.cwd() answers now (default: opts.cwd or ROOT); a test may
  // move it, as a shell cd moves the real session folder.
  liveCwd: string
}

const lc = (p: string) => p.replace(/\//g, '\\').toLowerCase()

export async function defaultApproved(o: Opts, policyText: string): Promise<Record<string, any>> {
  return {
    version: 2,
    logOnly: o.logOnly === true,
    policy: { dir: o.policyDir ?? 'live\\policy', mjsSha256: o.mjsSha256 ?? (await sha256Hex(policyText)) },
    projects: {
      [ROOT_N]: {
        slug: SLUG,
        rulesMdSha256: await sha256Hex(RULES_MD),
        ask: o.ask ?? ASK_ALL,
      },
    },
  }
}

// The approved sort.json, in the shape tools/gen.mjs writes it.
export const SORT_LINE_1 = 'Never delete or edit files in `specs/`. They are signed off by the client; changes go through a pull request written by a person.'
export const SORT_JSON = JSON.stringify({
  root: ROOT_N,
  lines: [
    { line: 1, text: SORT_LINE_1, kind: 'hard', reason: 'Names a folder.', rules: [{ kind: 'NoChange', rel: 'specs' }] },
    { line: 2, text: 'Never edit `.env` or anything in `secrets/`, and never print their contents.', kind: 'hard', reason: 'x', rules: [{ kind: 'NoReadOrChange', rel: '.env' }, { kind: 'NoReadOrChange', rel: 'secrets' }] },
    { line: 4, text: "Don't create new top-level folders without asking first.", kind: 'ask', reason: 'x', rules: [] },
    { line: 5, text: 'Never run `git push --force` or `git push -f`.', kind: 'hard', reason: 'x', rules: [{ kind: 'NoForcePush' }] },
    { line: 6, text: 'Never push directly to `main`; work on a branch.', kind: 'hard', reason: 'x', rules: [{ kind: 'NoPushTo', branch: 'main' }] },
    { line: 7, text: 'Never run `rm -rf` on anything outside `tmp/`.', kind: 'hard', reason: 'x', rules: [{ kind: 'TreeDeleteOnlyUnder', rel: 'tmp' }] },
  ],
})

function hostOut(results: any[]): RunResult {
  return { exitCode: 0, stdout: JSON.stringify({ ok: true, results }) + '\n' }
}

export function hostAnswer(req: HostReq): RunResult {
  return hostOut(fakeHostReply(req))
}

// Registers every hook of the world on the test's `on`; call it before the
// first $ call.
export async function world(on: any, o: Opts = {}): Promise<World> {
  const policyText = o.policyText === undefined ? POLICY_TEXT : o.policyText
  const approvedObj = o.approved === undefined ? await defaultApproved(o, policyText ?? POLICY_TEXT) : o.approved
  const files = new Map<string, string>()
  const put = (p: string, t: string) => files.set(lc(p), t)
  if (approvedObj !== null) put(APPROVED_PATH, typeof approvedObj === 'string' ? approvedObj : JSON.stringify(approvedObj, null, 2))
  if (policyText !== null) put(POLICY_PATH, policyText)
  if (o.rulesMd !== false) put(RULES_PATH, o.rulesMdText ?? RULES_MD)
  if (o.key) put(KEY_PATH, o.key + '\n')
  const sort = o.sortJson === undefined ? SORT_JSON : o.sortJson
  if (sort !== null) put(SORT_PATH, sort)
  const dirs = new Set((o.existing ?? []).map(lc))

  const w: World = {
    files,
    writes: [],
    toasts: [],
    statuses: [],
    hostReqs: [],
    hostRuns: [],
    fetches: [],
    runs: [],
    spawns: [],
    toolRuns: [],
    checksBelow: [],
    permissionRequests: [],
    registered: [],
    reads: [],
    clock: null,
    logText: () => files.get(lc(LOG_PATH)) ?? '',
    logLines: () =>
      (files.get(lc(LOG_PATH)) ?? '')
        .split('\n')
        .filter(l => l.length > 0)
        .map(l => l.split('\t')),
    hostCalls: () => w.hostReqs.map(r => r.ops[0]?.call),
    engineChecks: [],
    dialogs: [],
    preToolUse: [],
    liveCwd: o.cwd ?? ROOT,
  }

  w.clock = mock.clock(on, { now: NOW })
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: w.liveCwd }))
  on('session.root', () => ({ value: o.cwd ?? ROOT }))
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.surfaces', () => ({ value: o.surfaces ?? [] }))
  on('env.get', (_: any, e: any) => ({ value: e.name === 'USERPROFILE' ? (o.home === undefined ? HOME : (o.home ?? undefined)) : undefined }))
  on('command.register', (_: any, e: any) => {
    w.registered.push(e)
    return { value: { command: String(e.name ?? '') } }
  })
  on('ui.toast', (_: any, e: any) => {
    w.toasts.push(String(e.text ?? ''))
    return { value: undefined }
  })
  on('ui.status', (_: any, e: any) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('fs.exists', (_: any, e: any) => {
    const p = lc(String(e.path))
    if (o.existsFails && o.existsFails.test(String(e.path))) return { deny: 'EIO: the check failed' }
    if (p === lc(APPROVED_PATH) && o.approvedUnreadable) return { value: true }
    return { value: files.has(p) || dirs.has(p) }
  })
  on('fs.read', (_: any, e: any) => {
    const p = String(e.path)
    w.reads.push(p)
    if (lc(p) === lc(APPROVED_PATH) && o.approvedUnreadable) return { deny: 'EACCES: permission denied' }
    const t = files.get(lc(p))
    if (t === undefined) return { deny: 'ENOENT: no such file' }
    return { value: t }
  })
  on('fs.write', (_: any, e: any) => {
    const p = String(e.path)
    if (o.failWrites && o.failWrites.test(p)) return { deny: 'EACCES: permission denied' }
    w.writes.push({ path: p, text: String(e.text) })
    files.set(lc(p), String(e.text))
    return { value: undefined }
  })
  on('process.run', (_: any, e: any) => {
    const argv = (e.argv ?? []).map(String)
    const init = e.init ?? {}
    // The checker host: node --input-type=module -e <source> (checker.ts runHost).
    if (argv[1] === '--input-type=module' && argv[2] === '-e') {
      let req: HostReq
      try {
        req = JSON.parse(String(init.stdin ?? ''))
      } catch {
        return { value: { exitCode: 0, stdout: JSON.stringify({ ok: false, error: 'bad request' }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
      }
      w.hostReqs.push(req)
      w.hostRuns.push({ argv, init })
      const r = o.host ? o.host(req) : hostAnswer(req)
      if (r === 'refuse') return { deny: 'process.run: timed out' }
      return { value: { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr ?? '', isStdoutTruncated: r.isStdoutTruncated === true, isStderrTruncated: false } }
    }
    w.runs.push({ argv, init })
    if (argv[1] && lc(argv[1]) === lc(APPROVE_MJS) && o.approve) {
      const r = o.approve(argv, init)
      if (r === 'refuse') return { deny: 'process.run: timed out' }
      return { value: { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (o.run) {
      const r = o.run(argv, init)
      if (r === 'refuse') return { deny: 'process.run: timed out' }
      return { value: { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    return { value: { exitCode: 1, stdout: '', stderr: 'not mocked: ' + argv.join(' '), isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* (_: any, e: any) {
    w.spawns.push(e)
    const r = o.spawn ? o.spawn(e) : { chunks: [{ stream: 'stdout' as const, text: '{"ok":false,"message":"not mocked"}\n' }], code: 1 }
    if (r === 'refuse') throw new Error('spawn refused')
    for (const c of r.chunks) yield c
    // a stand-in for a call on $ ends its stream with { value: <how the child ended> }
    return { value: { code: r.code, signal: null } }
  })
  on('http.fetch', async (_: any, e: any) => {
    w.fetches.push({ url: String(e.url), init: e.init })
    const a: FetchAnswer = o.fetch ? o.fetch(String(e.url), e.init) : { status: 500, text: 'not mocked' }
    if (a === 'refuse') return { deny: 'network down' }
    if (a === 'hang') {
      await w.clock.sleep(60000)
      return { value: { status: 200, ok: true, headers: {}, text: CLEF_SAFE } }
    }
    return { value: { status: a.status, ok: a.status >= 200 && a.status < 300, headers: {}, text: a.text } }
  })
  // core's own decision beneath the plugin: allow (the session's mode allows it)
  on('tool.check', (_: any, e: any) => {
    w.checksBelow.push(e)
    return { decision: 'allow' }
  })
  // the engine running the tool
  on('tool.call', (_: any, e: any) => {
    w.toolRuns.push(e)
    if (o.toolResult) return o.toolResult(e)
    return { result: { stdout: 'ran: ' + String(e.command ?? e.file_path ?? e.tool), stderr: '', interrupted: false }, text: 'ok' }
  })
  // the person's yes to an ask (a test cannot play a person; this classic hook stands in)
  on('classic.PermissionRequest', (_: any, e: any) => {
    w.permissionRequests.push(e)
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } } }
  })
  on('turn.complete', (_: any, e: any) => ({ text: String(e.answer ?? '') }))
  if (o.engine) engineSim(on, w, files, o.engine)
  return w
}

// ------------------------------------------------------- the engine's order
// Verified live (run 3467a4) and in claude-code.d.ts: for a real tool call the
// engine fires tool.call first; tool.check fires only inside tool.call's
// next(e), after PreToolUse, with the same tool_use_id; tool.call carries no
// approver; with nobody to answer, the engine turns a plugin's ask into a deny
// with the plugin's reason. The test kit's own $.tool.call keeps that order but
// raises tool.check with no approver, and approver is pinned, so a test cannot
// set it. engineSim plays the permission step instead: inside tool.call's
// next(e) (the test's classic.PreToolUse hook) it raises tool.check through the
// test's $ with the approver given and the call's tool_use_id and agentId, and
// settles the answer as the engine would: deny refuses; ask goes to the person
// (approver person in the main loop: their yes or no) or, with nobody to ask,
// becomes a deny with the plugin's reason; allow runs. The kit then raises its
// own (approver-less) tool.check for the same call; ABSORB answers that one,
// so bend-guard sees exactly one tool.check per call, as in a session.
const SETTLED = 'C:\\engine-sim\\settled\\'
const CALL_META = new Set(['tool', 'tool_use_id', 'agentId', 'consent', 'requestMeta'])

function engineSim(on: any, w: World, files: Map<string, string>, eng: NonNullable<Opts['engine']>): void {
  on('classic.PreToolUse', async (_: any, e: any) => {
    w.preToolUse.push(e)
    const input: Record<string, unknown> = {}
    for (const k of Object.keys(e ?? {})) if (!CALL_META.has(k) && !k.startsWith('hook_') && k !== 'session_id' && k !== 'transcript_path' && k !== 'cwd') input[k] = e[k]
    const q: any = { tool: e.tool, input }
    if (typeof e.tool_use_id === 'string') q.tool_use_id = e.tool_use_id
    if (typeof e.agentId === 'string') q.agentId = e.agentId
    if (eng.approver) q.approver = eng.approver
    const c = await eng.$.tool.check(q)
    w.engineChecks.push({ e: q, c })
    // What the permission step settled; ABSORB answers it as the last word of
    // the kit's own tool.check, which would otherwise read core's allow.
    let settled: { decision: 'allow' | 'deny'; reason?: string }
    if (c?.decision === 'deny') settled = { decision: 'deny', reason: String(c.reason ?? 'denied') }
    else if (c?.decision === 'ask') {
      const reason = String(c.reason ?? '')
      // a dialog (person) or the IDE's own dialog (host) puts it to the user
      const person = eng.approver !== undefined && q.agentId === undefined
      if (!person) settled = { decision: 'deny', reason }
      else {
        w.dialogs.push({ e: q, reason })
        settled = eng.person === 'no' ? { decision: 'deny', reason: 'The user said no. ' + reason } : { decision: 'allow' }
      }
    } else settled = { decision: 'allow' }
    if (typeof e.tool_use_id === 'string') files.set(lc(SETTLED + e.tool_use_id), JSON.stringify(settled))
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: settled.decision, permissionDecisionReason: settled.reason ?? 'allowed' } }
  })
}

// Load beside the plugin under test with engine mode: it answers the kit's own
// second, approver-less tool.check for a call engineSim already settled, with
// what engineSim settled.
export const ABSORB = {
  name: 'engine-sim',
  tier: 'prepend',
  register(on: any) {
    on('tool.check', async ($: any, e: any, next: any) => {
      if (typeof e.tool_use_id === 'string' && e.approver === undefined) {
        let t: unknown
        try {
          t = await $.fs.read('C:\\engine-sim\\settled\\' + e.tool_use_id)
        } catch {
          t = undefined
        }
        if (typeof t === 'string') return JSON.parse(t)
      }
      return next(e)
    })
  },
}
export const ENGINE = { plugins: [ABSORB] } as any

let seq = 0
export const nextId = () => `toolu_sim${++seq}`

// Why a $.tool.call was refused, or undefined when it ran: a tool.call hook's
// { deny }, or the errored result a deny beneath tool.call gives.
export function refused(r: any): string | undefined {
  if (r && typeof r.deny === 'string') return r.deny
  if (r && r.isError === true) return String(r.text ?? '')
  return undefined
}

export function clefBody(danger: number, unclear: number): string {
  return JSON.stringify({
    answers: {
      danger: { noul: danger },
      kind: { choice: 'readonly', probabilities: { readonly: 1 - unclear, changes_project: 0, changes_protected: 0, runs_other_code: 0, unclear } },
    },
    usage: { cost: 0.00004 },
  })
}
export const CLEF_SAFE = clefBody(0.02, 0.01)
export const CLEF_RISKY = clefBody(0.93, 0.05)

export const TURN = { answer: 'All done.', durationMs: 5, isAborted: false, turnId: 't1', reason: 'answer' }

// Why a $.tool.call was refused, or undefined when it ran. A refusal by a
// tool.call hook comes back as { deny }; one by a tool.check hook (raised
// beneath the tool.call hooks) as the errored result { isError, text }.
export function refusal(r: any): string | undefined {
  if (r && typeof r.deny === 'string') return r.deny
  if (r && r.isError === true && typeof r.text === 'string' && /denied by plugin bend-guard/.test(r.text)) return r.text
  return undefined
}

// Host requests by who made them: tool.check sends decide first; tool.call's
// own judgement (no matching check) sends run first.
export const checkReqs = (w: World) => w.hostReqs.filter(r => r.ops[0]?.op === 'decide')
export const callReqs = (w: World) => w.hostReqs.filter(r => r.ops[0]?.op !== 'decide')

export function commandOf(call: any): string {
  for (const a of A(call?.args)) if (a.key === 'command') return a.value
  return ''
}

// The folders every host request for this shell command was sent with.
export function cwdsSent(w: World, command: string, agent?: boolean): string[][] {
  return w.hostReqs
    .map(r => r.ops[0]?.call)
    .filter(c => commandOf(c) === command && (agent === undefined || c.agent === agent))
    .map(c => A(c.cwds))
}
