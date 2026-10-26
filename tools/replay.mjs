// bend-guard: noise replay. How often would bend-guard ask, refuse, or send a
// call to Clef, over real tool calls from past Claude Code transcripts?
//
//   node tools/replay.mjs [--transcripts <dir>] [--n 5500] [--seed 1]
//                         [--project <root>] [--home <dir>] [--policy <file>] [--agent-as-is]
//                         [--per-file 25] [--before <date>] [--json <file>]
//                         [--temp <dir>] [--tool <name>] [--show]
//
// It samples tool calls (half from main sessions, half from subagents, at most
// --per-file from one transcript, the same sample for the same seed; with
// --before only calls made before that date, so a before/after pair of runs
// sees the same calls even while new transcripts are written; with --tool only
// calls of that tool, such as PowerShell, still half main and half subagent,
// with the same seed logic), rewrites
// each call's folder into --project, and runs it through the compiled policy as
// a main-session call with a person present and no Clef answer. With
// --agent-as-is a subagent's call is replayed as an agent call instead.
//
// It prints COUNTS ONLY: verdict shares overall, for main sessions and for
// subagents, per tool (Bash, PowerShell, MCP, other); the share that would go
// to Clef; the understood share of Bash and PowerShell; the top unknown
// reasons and refusals; and the top shapes of the shell parts that are not
// understood (first word, subcommand and flag names, never values, paths or
// raw text). Reasons are reduced to their wording: anything that is not a
// plain word becomes "…". --json writes the same report to a file.
//
// --show also prints one line per call with its command, masked with the
// glue's secret rules (hooks/glue.ts redact). Use it only in your own terminal.
//
// The raw sample is written to a fresh folder under the OS temp folder (or
// under --temp) and removed when the run ends, also on an error or Ctrl+C.
//
// Defaults: transcripts ~/.claude/projects, project: the fixture root the
// compiled test policy is built for (tests/lib/policy.mjs ROOT), home: yours,
// policy tests/.build/policy.mjs (or BG_POLICY), seed 1, 5500 calls.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { performance } from 'node:perf_hooks'
import { pathToFileURL } from 'node:url'
import { load, call, run, decide, meaning, verdictOf, POLICY, NO_ANSWER, ROOT } from '../tests/lib/policy.mjs'
import { redact } from '../hooks/glue.ts'


export const DEFAULTS = {
  transcripts: path.join(os.homedir(), '.claude', 'projects'),
  n: 5500,
  seed: 1,
  project: ROOT,
  home: os.homedir(),
  policy: POLICY,
  agentAsIs: false,
  perFile: 25,
  json: null,
  temp: os.tmpdir(),
  show: false,
  before: null,
  tool: null,
}

const USAGE = `usage: node tools/replay.mjs [--transcripts <dir>] [--n <calls>] [--seed <n>]
  [--project <root>] [--home <dir>] [--policy <file>] [--agent-as-is] [--per-file <n>]
  [--before <date>] [--json <file>] [--temp <dir>] [--tool <name>] [--show]`

export class ArgError extends Error {}

export function parseArgs(argv) {
  const o = { ...DEFAULTS }
  const val = (i, name) => {
    const v = argv[i + 1]
    if (v === undefined || v.startsWith('--')) throw new ArgError(`${name} needs a value`)
    return v
  }
  const int = (s, name, min) => {
    if (!/^\d+$/.test(s) || +s < min) throw new ArgError(`${name} must be a whole number of at least ${min}`)
    return +s
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    switch (a) {
      case '--transcripts': o.transcripts = path.resolve(val(i, a)); i++; break
      case '--n': o.n = int(val(i, a), a, 1); i++; break
      case '--seed': o.seed = int(val(i, a), a, 0); i++; break
      case '--project': o.project = path.resolve(val(i, a)); i++; break
      case '--home': o.home = path.resolve(val(i, a)); i++; break
      case '--policy': o.policy = path.resolve(val(i, a)); i++; break
      case '--per-file': o.perFile = int(val(i, a), a, 1); i++; break
      case '--json': o.json = path.resolve(val(i, a)); i++; break
      case '--temp': o.temp = path.resolve(val(i, a)); i++; break
      case '--before': {
        const d = new Date(val(i, a)); i++
        if (Number.isNaN(d.getTime())) throw new ArgError('--before must be a date such as 2026-10-26 or 2026-10-26T12:00Z')
        o.before = d.toISOString()
        break
      }
      case '--tool': {
        const t = val(i, a); i++
        if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(t)) throw new ArgError('--tool must be a tool name such as PowerShell or Bash')
        o.tool = t
        break
      }
      case '--agent-as-is': o.agentAsIs = true; break
      case '--show': o.show = true; break
      case '--help': case '-h': throw new ArgError('')
      default: throw new ArgError(`unknown option ${a}`)
    }
  }
  return o
}

// ---------------------------------------------------------------------------
// Seeded random numbers (mulberry32), so one seed always gives one sample.

export function rng(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function shuffle(xs, rnd) {
  for (let i = xs.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1))
    ;[xs[i], xs[j]] = [xs[j], xs[i]]
  }
  return xs
}

// ---------------------------------------------------------------------------
// Mining: tool_use blocks of assistant lines.

function transcriptFiles(dir) {
  const out = []
  const walk = d => {
    let es
    try { es = fs.readdirSync(d, { withFileTypes: true }) } catch { return }
    es.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    for (const e of es) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(p)
    }
  }
  walk(dir)
  return out
}

const isSubPath = f => f.split(path.sep).includes('subagents')

function callsIn(file, before, tool = null) {
  const calls = []
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch { return calls }
  for (const line of text.split('\n')) {
    if (!line.includes('"tool_use"')) continue
    let j
    try { j = JSON.parse(line) } catch { continue }
    if (j?.type !== 'assistant' || !Array.isArray(j.message?.content)) continue
    if (before && !(typeof j.timestamp === 'string' && new Date(j.timestamp).toISOString() < before)) continue
    const sub = j.isSidechain === true || (j.isSidechain === undefined && isSubPath(file))
    for (const b of j.message.content) {
      if (b?.type === 'tool_use' && typeof b.name === 'string' && (!tool || b.name === tool)) calls.push({ tool: b.name, input: b.input && typeof b.input === 'object' ? b.input : {}, cwd: typeof j.cwd === 'string' ? j.cwd : '', sub })
    }
  }
  return calls
}

// A number from the seed and a file's place under the transcripts folder.
// Files are read in this order and each file's calls are shuffled with it, so
// a new transcript does not reshuffle the others: with --before, a later run
// over a grown folder takes the same sample.
const seedOf = (seed, rel) => crypto.createHash('sha256').update(`${seed}:${rel.split(path.sep).join('/')}`).digest().readUInt32BE(0)

// Writes the sample to <tmp>/sample.jsonl; returns how many of each kind.
export function mine(o, samplePath) {
  const files = transcriptFiles(o.transcripts)
    .map(f => ({ f, k: seedOf(o.seed, path.relative(o.transcripts, f)) }))
    .sort((a, b) => a.k - b.k || (a.f < b.f ? -1 : 1))
  const want = { main: Math.ceil(o.n / 2), sub: Math.floor(o.n / 2) }
  const got = { main: 0, sub: 0 }
  const fd = fs.openSync(samplePath, 'w')
  let read = 0
  try {
    for (const { f, k: fileSeed } of files) {
      if (got.main >= want.main && got.sub >= want.sub) break
      const g = isSubPath(f) ? 'sub' : 'main'
      if (got[g] >= want[g]) continue
      read++
      const calls = shuffle(callsIn(f, o.before, o.tool), rng(fileSeed))
      let taken = 0
      for (const c of calls) {
        const k = c.sub ? 'sub' : 'main'
        if (taken >= o.perFile) break
        if (got[k] >= want[k]) continue
        fs.writeSync(fd, JSON.stringify(c) + '\n')
        got[k]++
        taken++
      }
    }
  } finally {
    fs.closeSync(fd)
  }
  return { files: files.length, read, main: got.main, sub: got.sub }
}

// ---------------------------------------------------------------------------
// Rewriting the call's folder into the project.

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
export function rebaser(cwd, project) {
  const strip = s => s.replace(/[\\/]+$/, '')
  if (!cwd || strip(cwd).toLowerCase() === strip(project).toLowerCase()) return s => s
  const win = strip(cwd).replace(/\//g, '\\')
  const fwd = win.replace(/\\/g, '/')
  const msys = fwd.replace(/^([A-Za-z]):/, (_, d) => '/' + d.toLowerCase())
  const R = strip(project).replace(/\//g, '\\'), Rf = R.replace(/\\/g, '/'), Rm = Rf.replace(/^([A-Za-z]):/, (_, d) => '/' + d.toLowerCase())
  // Longest spellings first; a match must not run on into a longer name.
  const end = '(?![A-Za-z0-9_.-])'
  const pats = [
    [new RegExp(esc(win.replace(/\\/g, '\\\\')) + end, 'gi'), R.replace(/\\/g, '\\\\')],
    [new RegExp(esc(win) + end, 'gi'), R],
    [new RegExp(esc(fwd) + end, 'gi'), Rf],
    [new RegExp(esc(msys) + end, 'gi'), Rm],
  ]
  return s => { for (const [re, to] of pats) s = s.replace(re, () => to); return s }
}
const deep = (v, f) => typeof v === 'string' ? f(v) : Array.isArray(v) ? v.map(x => deep(x, f)) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deep(x, f)])) : v

// ---------------------------------------------------------------------------
// Shapes and reasons, with no values in them.

// Top-level parts of a shell command: split on ; && || | & and newlines,
// outside quotes and brackets. Stops at a heredoc's first line.
export function segments(s) {
  const segs = []
  let cur = '', q = null, depth = 0, heredoc = false
  for (let i = 0; i < s.length; i++) {
    const c = s[i], n = s[i + 1]
    if (q === "'") { cur += c; if (c === "'") q = null; continue }
    if (q === '"') { cur += c; if (c === '\\') { cur += n ?? ''; i++ } else if (c === '"') q = null; continue }
    if (c === '\\' && n !== '\n') { cur += c + (n ?? ''); i++; continue }
    if (c === "'" || c === '"') { q = c; cur += c; continue }
    if (c === '(' || c === '{') depth++
    if (c === ')' || c === '}') depth = Math.max(0, depth - 1)
    if (c === '<' && n === '<' && s[i + 2] !== '<') heredoc = true
    if (depth === 0) {
      const two = c + (n ?? '')
      if (two === '&&' || two === '||') { segs.push(cur); cur = ''; i++; continue }
      if (c === ';' || c === '\n' || (c === '|' && n !== '&') || (c === '&' && n !== '>' && s[i - 1] !== '>')) {
        segs.push(cur); cur = ''
        if (c === '\n' && heredoc) return segs.map(x => x.trim()).filter(Boolean)
        continue
      }
    }
    cur += c
  }
  segs.push(cur)
  return segs.map(x => x.trim()).filter(Boolean)
}

const MULTI = /^(git|npm|npx|pnpm|yarn|gh|docker|fly|flyctl|cargo|go|pip|pip3|uv|kubectl|az|supabase|wsl|claude|node|bun|deno|rustup|winget|choco|systemctl|python|tasklist|dotnet|bend)$/
const WRAPPERS = /^(timeout|sudo|env|nohup|time|xargs|command|exec)$/

// Single-dash words longer than three letters that are flag names, not a
// letter with a value joined to it (mysql -pSECRET).
const LONG_SINGLE = new Set(['-name', '-iname', '-type', '-maxdepth', '-mindepth', '-path', '-ipath', '-newer', '-mtime', '-mmin', '-size', '-exec', '-execdir', '-delete', '-print', '-print0', '-printf', '-prune', '-not', '-and', '-regex', '-empty', '-perm', '-user', '-fprint', '-okdir', '-jar', '-version', '-help', '-command', '-file', '-noprofile', '-nologo', '-noninteractive', '-executionpolicy'])

// First word, subcommand and flag names of one part. `pwsh` reads -Name
// parameters as words. The subcommand is the first word after the program
// that is not a flag (git's -C and -c values skipped), and only for programs
// that have subcommands; a script path there gives none.
export function shapeOf(seg, pwsh = false) {
  const w = seg.replace(/^(\s*\$?[A-Za-z_][A-Za-z0-9_]*=\S*(\s+|$))+/, 'VAR=… ').split(/\s+/).filter(Boolean)
  let i = 0
  const pre = []
  if (w[0] === 'VAR=…') { pre.push('VAR=…'); i++ }
  while (i < w.length && WRAPPERS.test(w[i]) && pre.length < 3) {
    pre.push(w[i]); i++
    while (w[i] && /^-|^\d+[smh]?$/.test(w[i])) i++
  }
  let cmd = (w[i] ?? '').replace(/^[&.]$/, '').replace(/^["'(]+|["')]+$/g, '').replace(/^.*[\\/]/, '').replace(/\.(exe|cmd|bat|ps1)$/i, '')
  if (!cmd && w[i] !== undefined && /^[&.]$/.test(w[i])) { pre.push(w[i]); i++; cmd = (w[i] ?? '').replace(/^["']+|["']+$/g, '').replace(/^.*[\\/]/, '') }
  if (/^python3?(\.\d+)?$/i.test(cmd)) cmd = 'python'
  // A program name only: no dots other than a version (a host name or a file
  // name is a value), and "…/" when it was started by its path.
  if (!/^[A-Za-z0-9_][A-Za-z0-9_+-]{0,30}(\.\d+)*$/.test(cmd)) cmd = cmd ? '…' : pre.length ? '' : '(empty)'
  else if (/[\\/]/.test(w[i] ?? '')) cmd = '…/' + cmd
  if (pwsh) cmd = cmd.toLowerCase()
  let sub = '', subSeen = false
  const flags = new Set()
  const rest = w.slice(i + 1)
  for (let j = 0; j < rest.length; j++) {
    const t = rest[j]
    if (cmd === 'git' && !subSeen && (t === '-C' || t === '-c')) { flags.add(t); j++; continue }
    if (t === '--') flags.add('--')
    else if (/^--/.test(t)) {
      const name = t.replace(/=.*$/s, '=')
      flags.add(/^--[A-Za-z0-9][A-Za-z0-9-]{0,30}=?$/.test(name) ? name : '--…')
    } else if (/^-/.test(t)) {
      if (pwsh) {
        const name = t.replace(/:.*$/s, ':')
        flags.add(/^-[A-Za-z][A-Za-z0-9]{0,30}:?$/.test(name) ? name.toLowerCase() : '-…')
      } else if (t === '-') flags.add('-')
      else if (/^-\d+$/.test(t)) flags.add('-N')
      else if (/^-[A-Za-z]\d+$/.test(t)) flags.add(t.slice(0, 2) + 'N')
      else if (/^-[A-Za-z]{1,3}$/.test(t) || LONG_SINGLE.has(t.toLowerCase())) flags.add(t)
      else flags.add(t.slice(0, 2).replace(/[^-A-Za-z]/g, '') + '…')
    } else if (!subSeen) {
      subSeen = true
      if (MULTI.test(cmd) && /^[a-z][a-z0-9:_-]{0,24}$/i.test(t)) sub = t
    }
  }
  if (cmd === 'python' && flags.has('-c')) { sub = '-c'; flags.delete('-c') }
  const fl = [...flags].sort()
  return redact([...pre, cmd, sub, ...fl].filter(Boolean).join(' '))
}

// A reason reduced to its plain words: paths, quoted text, numbers' digits
// and anything else that is not an ordinary word become "…".
const PLAIN = /^[(\[]?(?:[A-Za-z][A-Za-z'-]{0,23}|-{1,2}[A-Za-z][A-Za-z-]{0,20}|\d+)[)\],.:;!?]*$/
export function reasonKey(why) {
  const toks = String(why ?? '').replace(/^bend-guard:\s*/, '').split(/\s+/).filter(Boolean)
  const out = []
  for (const t of toks) {
    const k = PLAIN.test(t) ? t.replace(/\d+/g, 'N') : '…'
    if (k === '…' && out[out.length - 1] === '…') continue
    out.push(k)
  }
  const s = redact(out.join(' '))
  return s.length <= 170 ? s : s.slice(0, s.lastIndexOf(' ', 160)) + ' …'
}

const SYNTAX = /^the command text uses shell syntax/

// ---------------------------------------------------------------------------
// Replay and counting.

const bucket = tool => tool === 'Bash' ? 'Bash' : tool === 'PowerShell' ? 'PowerShell' : tool.startsWith('mcp__') ? 'MCP' : 'other'
const SHELL = new Set(['Bash', 'PowerShell'])
const VERDICTS = ['allow', 'ask', 'deny', 'crash']

function newTally() { return { n: 0, allow: 0, ask: 0, deny: 0, crash: 0, clef: 0, shell: 0, understood: 0 } }
function add(t, r) {
  t.n++
  t[r.verdict]++
  if (r.clef) t.clef++
  if (r.shell) { t.shell++; if (r.known) t.understood++ }
}
const pct = (a, b) => (b ? Math.round((1000 * a) / b) / 10 : 0)
function shares(t) {
  const s = { n: t.n }
  for (const v of VERDICTS) s[v] = { count: t[v], pct: pct(t[v], t.n) }
  s.clef = { count: t.clef, pct: pct(t.clef, t.n) }
  if (t.shell) s.understood = { count: t.understood, of: t.shell, pct: pct(t.understood, t.shell) }
  return s
}
function top(map, k) {
  return [...map].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, k).map(([key, count]) => ({ key, count }))
}
const bump = (m, k, by = 1) => m.set(k, (m.get(k) || 0) + by)

// The step, the verdict with no Clef answer, and the meaning of one call.
// The public entries each run the translator again, so when the build exports
// the parts they are made of, the translator runs once and the guard gets its
// meaning: Policy.decide is Guard.decide_m(Rules.table, Call.ctx, meaning,
// Guard.clef_text) by definition, and Policy.run equals Policy.run_m on the
// same parts by the proven law run_is_translator_then_policy. The tests check
// both paths agree.
const PART_KEYS = ['../core/Guard:decide_m', 'Rules:table', '../core/Call:ctx', '../core/Guard:clef_text', 'Policy.run_m']
export function judge(P, c, fast = PART_KEYS.every(k => typeof P[k] === 'function')) {
  let d, v, m
  if (fast) {
    m = meaning(P, c)
    const x = P['../core/Call:ctx'](c), t = P['../core/Guard:clef_text'](c)
    d = P['../core/Guard:decide_m'](P['Rules:table'](), x, m, t)
    v = d?.$ === 'Step.Done' ? d.v : P['Policy.run_m'](x, m, t, NO_ANSWER)
  } else {
    d = decide(P, c)
    v = run(P, c)
    m = meaning(P, c)
  }
  return { verdict: verdictOf(v), reason: typeof v.reason === 'string' ? v.reason : '', clef: d?.$ === 'Consult', known: m?.$ === 'Known', why: m?.$ === 'Known' ? null : String(m?.why ?? '') }
}

export async function replay(o, samplePath, out = s => process.stdout.write(s)) {
  const P = await load(o.policy)
  const callOpts = sub => ({ cwds: [o.project], root: o.project, home: o.home, agent: o.agentAsIs && sub })
  // warm up the compiled code before timing
  for (let i = 0; i < 20; i++) run(P, call('Bash', { command: 'git status' }, callOpts(false)))
  const all = newTally(), byGroup = { main: newTally(), sub: newTally() }
  const byTool = {}, byGroupTool = { main: {}, sub: {} }
  const otherTools = new Map(), unknownWhy = new Map(), denyKeys = new Map(), shapes = new Map()
  const lat = []
  const shapeCache = new Map()
  const lines = fs.readFileSync(samplePath, 'utf8').split('\n').filter(Boolean)
  for (const line of lines) {
    const x = JSON.parse(line)
    const group = x.sub ? 'sub' : 'main'
    const input = deep(x.input ?? {}, rebaser(x.cwd, o.project))
    const c = call(x.tool, input, callOpts(x.sub))
    const b = bucket(x.tool)
    const shell = SHELL.has(x.tool) && typeof input.command === 'string'
    let r
    const t0 = performance.now()
    try {
      r = judge(P, c)
      lat.push(performance.now() - t0)
    } catch {
      r = { verdict: 'crash', reason: '', clef: false, known: false, why: 'the checker crashed' }
    }
    r.shell = shell
    add(all, r); add(byGroup[group], r)
    add((byTool[b] ??= newTally()), r)
    add((byGroupTool[group][b] ??= newTally()), r)
    if (b === 'other') bump(otherTools, x.tool.length <= 40 && /^[A-Za-z0-9_-]+$/.test(x.tool) ? x.tool : '…')
    if (!r.known) bump(unknownWhy, `${b}: ${reasonKey(r.why)}`)
    let segShapes = null
    if (shell && (!r.known || r.verdict === 'deny')) {
      segShapes = []
      for (const seg of segments(input.command).slice(0, 40)) {
        const key = x.tool + '\0' + seg
        let s = shapeCache.get(key)
        if (s === undefined) {
          let sm = null
          try { sm = meaning(P, call(x.tool, { command: seg }, callOpts(x.sub))) } catch {}
          s = sm?.$ === 'Known' ? null : (sm && SYNTAX.test(String(sm.why)) ? 'syntax: ' : '') + shapeOf(seg, x.tool === 'PowerShell')
          if (shapeCache.size < 50000) shapeCache.set(key, s)
        }
        if (s) segShapes.push(s)
      }
      if (!r.known) for (const s of new Set(segShapes)) bump(shapes, `${x.tool}: ${s}`)
    }
    if (r.verdict === 'deny') {
      const what = segShapes ? (segShapes.length ? [...new Set(segShapes)].slice(0, 3).join(' | ') : 'understood') : b === 'other' ? x.tool : b
      bump(denyKeys, `${x.tool.startsWith('mcp__') ? 'MCP' : x.tool}: ${what} — ${reasonKey(r.reason)}`)
    }
    if (o.show) {
      const text = shell ? input.command : JSON.stringify(input)
      out(`${group}\t${x.tool}\t${r.verdict}${r.clef ? '\tclef' : ''}\t${redact(String(text)).replace(/\s+/g, ' ').slice(0, 300)}${r.reason ? '\t' + redact(r.reason).slice(0, 200) : ''}\n`)
    }
  }
  lat.sort((a, b) => a - b)
  const q = p => (lat.length ? Math.round(lat[Math.min(lat.length - 1, Math.floor(p * lat.length))] * 100) / 100 : 0)
  const toolShares = m => Object.fromEntries(['Bash', 'PowerShell', 'MCP', 'other'].filter(k => m[k]).map(k => [k, shares(m[k])]))
  return {
    all: shares(all),
    main: shares(byGroup.main),
    sub: shares(byGroup.sub),
    tools: toolShares(byTool),
    toolsMain: toolShares(byGroupTool.main),
    toolsSub: toolShares(byGroupTool.sub),
    otherTools: top(otherTools, 15),
    unknownReasons: top(unknownWhy, 20),
    denies: top(denyKeys, 20),
    shapes: top(shapes, 30),
    crashes: all.crash,
    msPerCall: { p50: q(0.5), p95: q(0.95), max: q(1) },
  }
}

// ---------------------------------------------------------------------------
// Report.

const fmtShare = s => `n ${s.n}  allow ${s.allow.pct}%  ask ${s.ask.pct}%  deny ${s.deny.pct}%  crash ${s.crash.count}  clef ${s.clef.pct}%${s.understood ? `  understood ${s.understood.pct}% of ${s.understood.of}` : ''}`

export function formatReport(rep) {
  const L = []
  const m = rep.meta
  L.push(`bend-guard noise replay: ${m.calls} calls (${m.main} main, ${m.sub} subagent) from ${m.filesRead} of ${m.files} transcripts, seed ${m.seed}${m.tool ? `, tool ${m.tool} only` : ''}${m.before ? `, before ${m.before}` : ''}, policy ${m.policySha}${m.agentAsIs ? ', subagent calls as agent calls' : ', every call as a main-session call'}`)
  L.push(`  all       ${fmtShare(rep.all)}`)
  L.push(`  main      ${fmtShare(rep.main)}`)
  L.push(`  subagent  ${fmtShare(rep.sub)}`)
  for (const [title, t] of [['by tool, all', rep.tools], ['by tool, main', rep.toolsMain], ['by tool, subagent', rep.toolsSub]]) {
    L.push(title)
    for (const [k, s] of Object.entries(t)) L.push(`  ${k.padEnd(12)}${fmtShare(s)}`)
  }
  L.push(`clef share (calls that would go to Clef): ${rep.all.clef.pct}% (main ${rep.main.clef.pct}%, subagent ${rep.sub.clef.pct}%)`)
  L.push(`host crashes: ${rep.crashes}`)
  const list = (title, xs) => { L.push(title); for (const x of xs) L.push(`  ${String(x.count).padStart(5)}  ${x.key}`) }
  list('other tools', rep.otherTools)
  list('top unknown reasons', rep.unknownReasons)
  list('top refusals (tool: shapes of the parts not understood — reason)', rep.denies)
  list('top shapes of shell parts not understood (commands containing them)', rep.shapes)
  L.push(`time: mining ${m.mineSeconds} s, replay ${m.replaySeconds} s; checker ms per call p50 ${rep.msPerCall.p50} p95 ${rep.msPerCall.p95} max ${rep.msPerCall.max}`)
  return L.join('\n') + '\n'
}

export async function main(argv, out = s => process.stdout.write(s)) {
  const o = parseArgs(argv)
  if (!fs.existsSync(o.policy)) throw new Error('no compiled policy at the --policy file: run node tests/lib/build.mjs first')
  if (!fs.existsSync(o.transcripts) || !fs.statSync(o.transcripts).isDirectory()) throw new Error('the --transcripts folder does not exist')
  fs.mkdirSync(o.temp, { recursive: true })
  const tmp = fs.mkdtempSync(path.join(o.temp, 'bg-replay-'))
  const cleanup = () => { try { fs.rmSync(tmp, { recursive: true, force: true }) } catch {} }
  const onSignal = () => { cleanup(); process.exit(130) }
  process.on('exit', cleanup)
  process.once('SIGINT', onSignal)
  process.once('SIGTERM', onSignal)
  try {
    const samplePath = path.join(tmp, 'sample.jsonl')
    const t0 = performance.now()
    const mined = mine(o, samplePath)
    const t1 = performance.now()
    const rep = await replay(o, samplePath, out)
    const t2 = performance.now()
    const sha = crypto.createHash('sha256').update(fs.readFileSync(o.policy)).digest('hex').slice(0, 12)
    rep.meta = { calls: mined.main + mined.sub, main: mined.main, sub: mined.sub, files: mined.files, filesRead: mined.read, seed: o.seed, tool: o.tool, before: o.before, perFile: o.perFile, agentAsIs: o.agentAsIs, policySha: sha, mineSeconds: Math.round((t1 - t0) / 100) / 10, replaySeconds: Math.round((t2 - t1) / 100) / 10 }
    out(formatReport(rep))
    if (o.json) fs.writeFileSync(o.json, JSON.stringify(rep, null, 2) + '\n')
    return rep
  } finally {
    cleanup()
    process.off('exit', cleanup)
    process.off('SIGINT', onSignal)
    process.off('SIGTERM', onSignal)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(e => {
    if (e instanceof ArgError) {
      if (e.message) process.stderr.write(`replay: ${e.message}\n`)
      process.stderr.write(USAGE + '\n')
      process.exit(e.message ? 2 : 0)
    }
    process.stderr.write(`replay: ${redact(e?.message ?? String(e))}\n`)
    process.exit(1)
  })
}
