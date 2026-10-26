// bend-guard: the approve tool, the only way project rules become live. The user
// runs it in their own terminal (it needs a TTY and the typed word "approve"),
// or through the /bend-guard command (hooks\register.tsx), which proves with a
// one-time token that the run came from their own typing. Either way Claude
// cannot run it unseen. It works from a private copy of Claude's draft, builds
// the project's Bend files from the fixed templates (gen.mjs), shows every
// numbered line of BEND_RULES.md with its law, and, once the user says yes, checks
// the pinned bend binary, proves everything in WSL (prove.sh --no-cache: the
// checker and the Lean-checked kernel, in parallel, never trusting the proof
// cache), compiles the policy, runs the probe calls on it,
// and only then writes the state folder.
// Design: docs\design.md (in the bend2_test project) component 6. Plan:
// docs\plan.md Task 3.3; docs\build-brief.md ("Simplifications") wins where
// they differ.
//
//   node approve.mjs <projectRoot> [--enforce | --log-only]   (log-only is the default)
//   node approve.mjs --status
//   node approve.mjs --enforce --mode-only   |   node approve.mjs --log-only --mode-only
//   (node approve.mjs --probe-child is internal: the probe run, in a child process.)
//
// The /bend-guard command runs the same steps without a terminal, in two halves:
//   node approve.mjs --preview <projectRoot>
//       /bend-guard approve. Copies the draft to D\<slug>\.approve-<random>\,
//       generates and checks it as above, and stores preview.json there (the
//       hashes of everything shown). Prints one JSON line last: { ok, root,
//       slug, snapshot, rulesMdSha256, previewSha256, display, error? }.
//       Writes nothing to S.
//   node approve.mjs --snapshot <dir> --expect <previewSha256> --from-mod [--enforce | --log-only]
//       /bend-guard confirm. Proves and approves exactly what --preview showed:
//       preview.json must hash to --expect (the mod kept it in memory), and the
//       draft copy, BEND_RULES.md, the core sources, the generated files and the
//       approvals must all still match it. Prints progress, then one JSON line
//       { ok, message }, and removes the copy.
//   node approve.mjs --mode-only --from-mod --enforce | --log-only
//       /bend-guard enforce and /bend-guard log-only.
// A --from-mod run first reads and removes S\.approve-token, then needs a
// token on stdin (one line) whose sha256 is that file's text. Only the mod
// writes the file; Claude cannot write S in a guarded session and never sees
// the token. No match, or no file: refused, nothing written.
//
// On success it writes, under S = <home>\.claude\bend-guard (home: os.homedir()):
//   live\projects\<slug>\  the copied sort.json and ask.json, display.json,
//                          probes.json, the generated project .bend files, and
//                          approved-rules.md and approved-sort.json (the
//                          BEND_RULES.md and sort.json approved, which the next
//                          preview compares with: "Changed since your last approval")
//   live\policy\           the staged core\, laws\ and project\ .bend files, and policy.mjs
//   approved.json          version 2, as hooks\glue.ts reads it; written atomically,
//                          keeping other projects' entries
// On any failure it writes nothing there (a --from-mod run only removes
// S\.approve-token). It never reads S\openrouter.key.
//
// Hashes in approved.json (SHA-256, lower-case hex):
//   policy.mjsSha256      the bytes of policy.mjs. It must be valid UTF-8, so this
//                         equals register.tsx's sha256Hex of the text it reads.
//   policy.sourcesSha256  UTF-8 of JSON.stringify([name + "\n" + text, ...]), one item
//                         per staged .bend file, sorted by name ("core/Types.bend",
//                         "laws/path/LAWS.bend", "project/Rules.bend", ...)
//   policy.coreSha256     the same over core/ and laws/ only. When it changes, the
//                         next approval shows the core laws again.
//   policy.bendSha256     the bend binary in WSL, equal to the pin in BEND_VERSION
//   projects[root].rulesJsonSha256  the bytes of the approved sort.json
//   projects[root].rulesMdSha256    the bytes of BEND_RULES.md, BOM and line ends
//                         included: the engine's $.fs.read decodes with Buffer
//                         toString('utf8'), which keeps a BOM, so register.tsx
//                         hashes the same bytes.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import readline from 'node:readline'
import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { generate, slugOf, lawStem, GenError } from './gen.mjs'
import { KEYS } from './probes.mjs'
import { runWsl, toWslPath, bendSha256, WSL_EXE, DISTRO, compiledSha, compiledMatches } from './wsl.mjs'
import { stateDir, draftsDir } from './home.mjs'

const THIS_FILE = fileURLToPath(import.meta.url)
const TOOLS = path.dirname(THIS_FILE)
const PLUGIN = path.dirname(TOOLS)
const BEND_DIR = path.join(PLUGIN, 'bend')
const BEND_VERSION = path.join(PLUGIN, 'BEND_VERSION')

// The folders register.tsx (S) and the compile command (D) use, under the
// home folder (tools/home.mjs). Keep each on one line: the tests' sandbox
// copy replaces these two lines.
const S = stateDir()
const D = draftsDir()
const APPROVED = path.join(S, 'approved.json')
const LIVE = path.join(S, 'live')
const LIVE_PROJECTS = path.join(LIVE, 'projects')
const LIVE_POLICY = path.join(LIVE, 'policy')
const POLICY_DIR = 'live\\policy' // approved.json policy.dir; register.tsx joins it to S

const HEX64 = /^[0-9a-f]{64}$/
const MiB = 1024 * 1024
const MIN = 60 * 1000
const RESTART = 'Start a new Claude Code session or run /reload-plugins.'
const MOD_RELOAD = 'The session that ran /bend-guard uses it from its next tool call; other open sessions need /reload-plugins or a restart.'

// The /bend-guard command's files (see the header).
const TOKEN_FILE = path.join(S, '.approve-token')
const PREVIEW_FILE = 'preview.json'
const SNAPSHOT_NAME = /^\.approve-[0-9a-f]{16}$/
const SNAPSHOT_STALE_MS = 24 * 60 * MIN

const USAGE = [
  'usage:',
  '  node approve.mjs <projectRoot> [--enforce | --log-only]   approve a project (log-only by default)',
  '  node approve.mjs --status                                 show what is approved',
  '  node approve.mjs --enforce --mode-only                    switch every approved project to enforcing',
  '  node approve.mjs --log-only --mode-only                   switch every approved project to log-only',
  '  (--preview, --snapshot, --expect and --from-mod are for the /bend-guard command in Claude Code.)',
].join('\n')

// ---------------------------------------------------------------------------
// Failures

class Refusal extends Error {
  constructor(msg, details = []) {
    super(msg)
    this.details = details
  }
}
function refuse(msg, details) {
  throw new Refusal(msg, details)
}

// A failed write to S. `dirty` is true when putting things back failed too.
class StateError extends Error {
  constructor(msg, dirty) {
    super(msg)
    this.dirty = dirty
  }
}

let doing = 'approve' // or 'mode', for the failure wording
let how = 'terminal' // or 'mod' (the /bend-guard command), for the wording
let jsonOut = null // 'preview' or 'snapshot': the run ends with the mod's JSON line
const facts = { root: null, slug: null } // for a --preview failure's JSON line
let committing = false
const cleanups = []

function finish(code) {
  for (const f of cleanups.splice(0).reverse()) {
    try {
      f()
    } catch {
      // best effort: only the private temp folder is cleaned up here
    }
  }
  process.exit(code)
}

// ---------------------------------------------------------------------------
// Small helpers

const sha256 = data => crypto.createHash('sha256').update(data).digest('hex')
const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v)
const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)

function short(err, max = 300) {
  const s = err && typeof err === 'object' && 'message' in err ? String(err.message) : String(err)
  const t = s.replace(/\u0000/g, '').trim()
  return t.length > max ? t.slice(0, max) + '...' : t
}

function lstatOrNull(p) {
  try {
    return fs.lstatSync(p)
  } catch {
    return null
  }
}

const isDir = p => lstatOrNull(p)?.isDirectory() === true

// A folder, following links (a project root may be a junction).
function isFolder(p) {
  try {
    return fs.statSync(p).isDirectory()
  } catch {
    return false
  }
}

// Text from the draft, for the user's terminal: invisible, control and
// bidi-override characters become spaces and runs of spaces become one, so a
// draft cannot fake a separate line or hide text.
// Code point ranges: C0 and C1 controls, soft hyphen, Arabic letter mark,
// Mongolian vowel separator, zero-width and direction marks, line and
// paragraph separators, bidi embeddings, overrides and isolates, invisible
// operators, the BOM and the interlinear annotation marks.
const HIDDEN = [[0x0, 0x1f], [0x7f, 0x9f], [0xad, 0xad], [0x61c, 0x61c], [0x180e, 0x180e], [0x200b, 0x200f], [0x2028, 0x202e], [0x2060, 0x206f], [0xfeff, 0xfeff], [0xfff9, 0xfffb]]
const shown = (s, max = 400) => {
  let t = ''
  for (const ch of String(s)) {
    const c = ch.codePointAt(0)
    t += HIDDEN.some(([a, b]) => c >= a && c <= b) ? ' ' : ch
  }
  t = t.replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, max) + '...' : t
}

// Non-empty output lines, without the NULs of wsl.exe's own UTF-16 messages.
function outLines(text) {
  return String(text)
    .replace(/\u0000/g, '')
    .split(/\r?\n/)
    .map(l => l.trimEnd())
    .filter(l => l.trim() !== '')
}

function took(t0) {
  const s = Math.round((Date.now() - t0) / 1000)
  return s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, '0')} s`
}

// glue.ts normPath: lower case, / separators, no trailing /.
function normPath(p) {
  let s = String(p).toLowerCase().replace(/\\/g, '/')
  while (s.length > 1 && s.endsWith('/')) s = s.slice(0, -1)
  return s
}

// 'c:/users/x' -> 'C:\users\x', for messages and for reading files.
const winOf = root => root.replace(/^([a-z]):/, (_, d) => `${d.toUpperCase()}:`).replace(/\//g, '\\')

function readPlain(file, what, max = MiB) {
  const st = lstatOrNull(file)
  if (!st) refuse(`${what} is missing (${file})`)
  if (!st.isFile()) refuse(`${what} is not a plain file (${file}); a link or a folder is not accepted`)
  if (st.size > max) refuse(`${what} is larger than ${Math.round(max / 1024)} KiB (${file})`)
  return fs.readFileSync(file)
}

// The text of buf. Bytes that are not valid UTF-8 are refused, so a hash of
// the bytes and a hash of the decoded text always agree.
function utf8Text(buf, what) {
  const text = buf.toString('utf8')
  if (!Buffer.from(text, 'utf8').equals(buf)) refuse(`${what} is not valid UTF-8 text; save it as UTF-8 and try again`)
  return text
}

const parseJson = buf => JSON.parse(buf.toString('utf8').replace(/^\uFEFF/, ''))

// register.tsx parses the approved sort.json without skipping a BOM.
const BOM = Buffer.from([0xef, 0xbb, 0xbf])
const stripBom = buf => (buf.subarray(0, 3).equals(BOM) ? buf.subarray(3) : buf)

function sameBytes(file, buf) {
  try {
    return fs.readFileSync(file).equals(buf)
  } catch {
    return false
  }
}

function writeUnder(dir, name, buf, flag = 'w') {
  const p = path.join(dir, ...name.split('/'))
  fs.mkdirSync(path.dirname(p), { recursive: true })
  fs.writeFileSync(p, buf, { flag })
}

function rmQuiet(p) {
  try {
    fs.rmSync(p, { recursive: true, force: true })
  } catch {
    // left behind; harmless
  }
}

// policy.sourcesSha256 and policy.coreSha256 (see the header).
function sourcesHash(files) {
  const items = [...files].sort(byName).map(f => `${f.name}\n${f.buf.toString('utf8')}`)
  return sha256(Buffer.from(JSON.stringify(items), 'utf8'))
}

// ---------------------------------------------------------------------------
// The state folder (read side)

// What approve depends on in S: approved.json and every approved sort.json.
// Compared again just before writing, so a change in between is refused.
function stateFingerprint() {
  const hashOf = f => {
    try {
      return sha256(fs.readFileSync(f))
    } catch {
      return null
    }
  }
  const parts = [['approved.json', hashOf(APPROVED)]]
  if (fs.existsSync(LIVE_PROJECTS)) {
    let names
    try {
      names = fs.readdirSync(LIVE_PROJECTS).sort()
    } catch (err) {
      refuse(`cannot list ${LIVE_PROJECTS} (${short(err)})`)
    }
    for (const n of names) parts.push([n, hashOf(path.join(LIVE_PROJECTS, n, 'sort.json'))])
  }
  return JSON.stringify(parts)
}

const AGAIN = 'Rename it (keep it to look at), then approve each project again.'

// approved.json as an object, or null when there is none. Anything this tool
// cannot update safely is refused.
function readApproved() {
  const st = lstatOrNull(APPROVED)
  if (!st) return null
  if (!st.isFile()) refuse(`${APPROVED} is not a plain file. ${AGAIN}`)
  return parseApproved(fs.readFileSync(APPROVED))
}

function parseApproved(buf) {
  let o
  try {
    o = parseJson(buf)
  } catch (err) {
    refuse(`${APPROVED} is not valid JSON (${short(err, 120)}). ${AGAIN}`)
  }
  if (!isObj(o) || o.version !== 2) refuse(`${APPROVED} is not a version 2 approval file. ${AGAIN}`)
  if (o.projects !== undefined && !isObj(o.projects)) refuse(`"projects" in ${APPROVED} is not an object. ${AGAIN}`)
  if (o.policy !== undefined && !isObj(o.policy)) refuse(`"policy" in ${APPROVED} is not an object. ${AGAIN}`)
  if (o.logOnly !== undefined && typeof o.logOnly !== 'boolean') refuse(`"logOnly" in ${APPROVED} is not true or false. ${AGAIN}`)
  return o
}

// register.tsx policyMjsPath: a relative dir is under S; '..' is not allowed.
function policyMjsPath(dir) {
  const d = String(dir).replace(/\//g, '\\').replace(/\\+$/, '')
  if (d.split('\\').some(s => s === '..')) return null
  return /^[a-zA-Z]:\\/.test(d) ? `${d}\\policy.mjs` : `${S}\\${d.replace(/^\\+/, '')}\\policy.mjs`
}

const modeWords = logOnly =>
  logOnly
    ? 'log-only (project rules are logged, not enforced; self-protection, and asking about commands bend-guard does not understand, stay on)'
    : 'enforcing (project rules and self-protection are enforced)'

// ---------------------------------------------------------------------------
// The state folder (write side)

function move(from, to) {
  for (let i = 0; ; i++) {
    try {
      return fs.renameSync(from, to)
    } catch (err) {
      // A virus scanner or indexer may hold a new file for a moment.
      if (i >= 8 || !['EPERM', 'EBUSY', 'EACCES'].includes(err && err.code)) throw err
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100 * (i + 1))
    }
  }
}

function writeSynced(file, text) {
  const buf = Buffer.from(text, 'utf8')
  const fd = fs.openSync(file, 'wx')
  try {
    for (let off = 0; off < buf.length; ) off += fs.writeSync(fd, buf, off, buf.length - off)
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
}

// Temp file in the same folder, then rename over the old file.
function writeAtomic(file, text) {
  const tmp = `${file}.${crypto.randomBytes(4).toString('hex')}.tmp`
  writeSynced(tmp, text)
  try {
    move(tmp, file)
  } catch (err) {
    rmQuiet(tmp)
    throw err
  }
}

// Writes the new live policy, the project's live folder and approved.json.
// Everything is written beside the live files first, then moved into place;
// approved.json is renamed last. Any failure puts the old files back.
// Returns a folder it could not clean up afterwards, or null.
function commit({ slug, policyFiles, projectFiles, approvedText }) {
  committing = true
  const tag = `${Date.now().toString(36)}-${crypto.randomBytes(4).toString('hex')}`
  const work = path.join(LIVE, `.approve-${tag}`) // outside live\projects, so gen.mjs never reads it
  const newPolicy = path.join(work, 'policy')
  const newProject = path.join(work, 'project')
  const oldPolicy = path.join(work, 'old-policy')
  const oldProject = path.join(work, 'old-project')
  const liveProject = path.join(LIVE_PROJECTS, slug)
  const tmpApproved = `${APPROVED}.${tag}.tmp`
  const made = []
  const undo = []
  try {
    for (const d of [S, LIVE, LIVE_PROJECTS]) {
      if (!fs.existsSync(d)) {
        fs.mkdirSync(d)
        made.push(d)
      }
    }
    fs.mkdirSync(work)
    for (const f of policyFiles) writeUnder(newPolicy, f.name, f.buf, 'wx')
    for (const f of projectFiles) writeUnder(newProject, f.name, f.buf, 'wx')
    writeSynced(tmpApproved, approvedText)

    if (fs.existsSync(LIVE_POLICY)) {
      move(LIVE_POLICY, oldPolicy)
      undo.push(() => move(oldPolicy, LIVE_POLICY))
    }
    move(newPolicy, LIVE_POLICY)
    undo.push(() => move(LIVE_POLICY, newPolicy))
    if (fs.existsSync(liveProject)) {
      move(liveProject, oldProject)
      undo.push(() => move(oldProject, liveProject))
    }
    move(newProject, liveProject)
    undo.push(() => move(liveProject, newProject))
    move(tmpApproved, APPROVED)
  } catch (err) {
    const stuck = []
    for (const f of undo.reverse()) {
      try {
        f()
      } catch (e) {
        stuck.push(short(e, 160))
      }
    }
    committing = false
    if (stuck.length > 0) {
      throw new StateError(
        `writing to ${S} failed (${short(err)}), and putting the old files back failed too (${stuck.join('; ')}). ` +
          `${work} holds the old files (old-policy, old-project). Run "node ${THIS_FILE} --status" to see what the mod will read.`,
        true,
      )
    }
    rmQuiet(work)
    rmQuiet(tmpApproved)
    for (const d of made.reverse()) {
      try {
        fs.rmdirSync(d)
      } catch {
        // not empty: leave it
      }
    }
    throw new StateError(`writing to ${S} failed (${short(err)}); the old files were put back.`, false)
  }
  committing = false
  try {
    fs.rmSync(work, { recursive: true, force: true })
    return null
  } catch {
    return work
  }
}

// ---------------------------------------------------------------------------
// Reading BEND_RULES.md, the draft and the laws

// Every "N. text" line (any indent): {n, text, at: line in the file}.
function numberedLines(text) {
  const out = []
  text
    .replace(/^\uFEFF/, '')
    .split(/\r\n|\n|\r/)
    .forEach((l, i) => {
      const m = /^\s*(\d{1,6})\.\s+(\S.*?)\s*$/.exec(l)
      if (m) out.push({ n: Number(m[1]), text: m[2], at: i + 1 })
    })
  return out
}

const squash = s => String(s).replace(/\s+/g, ' ').trim()
const clip = (s, n = 160) => (s.length > n ? s.slice(0, n) + '...' : s)

// sort.json "text" is the line without its "N. " (rules agent hand-off).
function matchDraft(numbered, entries) {
  const problems = []
  const at = new Map()
  for (const l of numbered) {
    if (at.has(l.n)) problems.push(`BEND_RULES.md has two lines numbered ${l.n} (lines ${at.get(l.n)} and ${l.at} of the file); give every rule its own number.`)
    else at.set(l.n, l.at)
  }
  const byLine = new Map(entries.map(e => [e.line, e]))
  for (const l of numbered) {
    const e = byLine.get(l.n)
    if (!e) problems.push(`Line ${l.n} has no entry in the draft: "${shown(l.text, 160)}"`)
    else if (squash(e.text) !== squash(l.text)) problems.push(`Line ${l.n} says "${shown(l.text, 160)}" in BEND_RULES.md, but the draft has "${shown(e.text, 160)}".`)
  }
  for (const e of entries) {
    if (!at.has(e.line)) problems.push(`The draft has an entry for line ${e.line} ("${shown(e.text, 160)}"), but BEND_RULES.md has no line numbered ${e.line}.`)
  }
  return problems
}

const SAYS_NO = /\b(never|do not|don't|don\u2019t)\b/i
const BACKTICKED = /`[^`]+`/g

// A line that looks hard but was not sorted as hard.
function checkThis(kind, text) {
  if (kind !== 'ask' && kind !== 'judgment') return null
  const named = text.match(BACKTICKED)
  const no = SAYS_NO.exec(text)
  if (!named || !no) return null
  return (
    `CHECK THIS: it names ${shown(named.join(', '), 200)} and says "${no[1]}", but it was sorted as ${kind}, ` +
    'so bend-guard will not enforce it. If it should be a hard rule, stop here and run /bend-guard:compile again.'
  )
}

// A name as a rule or a line spells it: lower case, / separators, no leading
// ./, no trailing / (or /* and /**).
function normName(s) {
  let t = String(s).trim().toLowerCase().replace(/\\/g, '/')
  while (t.startsWith('./')) t = t.slice(2)
  for (;;) {
    const u = t.replace(/\/\*+$/, '').replace(/\/+$/, '')
    if (u === t || u === '') break
    t = u
  }
  return t
}

const ruleValue = r => (typeof r.rel === 'string' ? r.rel : typeof r.branch === 'string' ? r.branch : typeof r.name === 'string' ? r.name : null)
const ruleWords = r => (ruleValue(r) === null ? r.kind : `${r.kind} ${ruleValue(r)}`)
const escRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// A hard line whose rules do not match what it names. No proof checks that a
// law says what the English line meant, so this compares the two by name:
// (a) every backticked path in the line must be a rule's folder or file, and
// (b) every rule's folder, file, branch or script must appear in the line as a
// whole name. A line naming `specs/` whose rule protects spec fails both.
function checkRules(kind, text, rules) {
  if (kind !== 'hard' || !Array.isArray(rules) || rules.length === 0) return null
  const values = rules.map(ruleValue).filter(v => v !== null)
  const known = new Set(values.map(normName))
  const rels = rules.filter(r => typeof r.rel === 'string').map(r => normName(r.rel))
  const problems = []
  for (const m of String(text).matchAll(/`([^`]+)`/g)) {
    const tok = m[1].trim()
    if (tok === '' || /\s/.test(tok) || !/[/\\.]/.test(tok)) continue // a command, a flag or a branch, not a path
    const n = normName(tok)
    if (!known.has(n)) problems.push(`it names \`${tok}\` but no rule on this line protects ${n}; the rules name ${rels.length ? rels.join(', ') : 'no folder or file'}`)
  }
  const line = String(text).toLowerCase().replace(/\\/g, '/').replace(/(?<![a-z0-9._/-])(?:\.\/)+/g, '')
  for (const r of rules) {
    const v = ruleValue(r)
    if (v === null) continue
    const n = normName(v)
    if (!new RegExp(`(?<![a-z0-9._/-])${escRe(n)}(/|(?![a-z0-9._-]))`).test(line)) {
      problems.push(`its rule ${ruleWords(r)} is about ${n}, which the line does not name`)
    }
  }
  if (problems.length === 0) return null
  return `CHECK THIS: ${problems.join('; ')}. If the rule protects the wrong thing, stop here and run /bend-guard:compile again.`
}

// The law names gen.mjs makes for a rule (gen.mjs LAW_KINDS; a test checks they agree).
const LAW_NAMES = {
  NoChange: ['rel', v => [`${lawStem(v)}_protected`]],
  NoReadOrChange: ['rel', v => [`${lawStem(v)}_protected`, `${lawStem(v)}_unreadable`]],
  TreeDeleteOnlyUnder: ['rel', v => [`tree_delete_only_${lawStem(v)}`]],
  NoForcePush: [null, () => ['force_push_denied']],
  NoPushTo: ['branch', v => [`push_${lawStem(v)}_denied`]],
}
function lawNamesOf(r) {
  const k = Object.hasOwn(LAW_NAMES, r.kind) ? LAW_NAMES[r.kind] : null
  if (!k) return [] // TrustScript makes no law
  if (k[0] === null) return k[1]()
  return typeof r[k[0]] === 'string' ? k[1](r[k[0]]) : []
}

const KIND_WORDS = { hard: 'hard (enforced)', ask: 'ask (asked about or a reminder)', judgment: 'judgment (advice only)' }

// The sort.json of this project's last approval: approved-sort.json (or, for
// an approval made before that file existed, sort.json) in live\projects\<slug>,
// used only when its hash is the one approved.json records. Null when there is
// none; this never refuses, it only decides whether a comparison is shown.
function lastApproved(ctx) {
  const { root, slug, prevProjects } = ctx
  const key = Object.keys(prevProjects).find(k => normPath(k) === root)
  if (key === undefined || !isObj(prevProjects[key])) return null
  const e = prevProjects[key]
  const want = typeof e.rulesJsonSha256 === 'string' ? e.rulesJsonSha256.toLowerCase() : null
  if (!want || !HEX64.test(want)) return null
  for (const name of ['approved-sort.json', 'sort.json']) {
    const file = path.join(LIVE_PROJECTS, slug, name)
    const st = lstatOrNull(file)
    if (!st || !st.isFile() || st.size > MiB) continue
    try {
      const buf = fs.readFileSync(file)
      if (sha256(buf) !== want) continue
      const o = parseJson(buf)
      if (!isObj(o) || !Array.isArray(o.lines)) continue
      const lines = o.lines.map(l => ({
        line: l.line,
        text: String(l.text),
        kind: l.kind,
        rules: l.kind === 'hard' && Array.isArray(l.rules) ? l.rules.filter(r => isObj(r) && typeof r.kind === 'string') : [],
      }))
      if (!lines.every(l => Number.isInteger(l.line) && KIND_WORDS[l.kind])) continue
      return { lines, approvedAt: typeof e.approvedAt === 'string' ? e.approvedAt : null, ask: isObj(e.ask) ? e.ask : null }
    } catch {
      // unreadable: no comparison
    }
  }
  return null
}

function whenWords(iso) {
  const t = Date.parse(iso ?? '')
  return Number.isNaN(t) ? 'time unknown' : `${new Date(t).toISOString().slice(0, 16).replace('T', ' ')} UTC`
}

// What changed in the rules since the last approval: lines matched by text
// first, then by number, so a renumbered line is not a change. Returns the
// lines to show and how many say LOOSENS.
function changesSince(old, newLines, askObj) {
  const out = []
  let loosens = 0
  const loosen = s => {
    loosens++
    out.push(`    LOOSENS: ${s}`)
  }
  const hardRules = lines => lines.filter(l => l.kind === 'hard').flatMap(l => l.rules ?? [])
  const newLaws = new Set(hardRules(newLines).flatMap(lawNamesOf))
  const oldTrusts = new Set(hardRules(old.lines).filter(r => r.kind === 'TrustScript').map(r => String(r.name)))
  const lawsGone = l => (l.kind === 'hard' ? l.rules.flatMap(lawNamesOf).filter(n => !newLaws.has(n)) : [])
  const goneWords = names => (names.length ? `law ${names.join(', law ')} ${names.length === 1 ? 'goes' : 'go'} away` : '')
  const rulesKey = l => (l.kind === 'hard' ? (l.rules ?? []).map(r => ruleWords(r).toLowerCase()).sort().join('|') : '')
  const quoted = l => `"${shown(l.text, 200)}"`

  const oldLeft = [...old.lines]
  const pairs = []
  const unmatched = []
  for (const n of newLines) {
    const i = oldLeft.findIndex(o => squash(o.text) === squash(n.text))
    if (i >= 0) pairs.push([oldLeft.splice(i, 1)[0], n])
    else unmatched.push(n)
  }
  const added = []
  for (const n of unmatched) {
    const i = oldLeft.findIndex(o => o.line === n.line)
    if (i >= 0) pairs.push([oldLeft.splice(i, 1)[0], n])
    else added.push(n)
  }
  const trustsAdded = n => (n.kind === 'hard' ? (n.rules ?? []).filter(r => r.kind === 'TrustScript' && !oldTrusts.has(String(r.name))) : [])

  let moved = 0
  for (const [o, n] of pairs.sort((a, b) => a[1].line - b[1].line)) {
    const sameText = squash(o.text) === squash(n.text)
    if (sameText && o.kind === n.kind && rulesKey(o) === rulesKey(n)) {
      if (o.line !== n.line) moved++
      continue
    }
    const parts = []
    if (!sameText) parts.push(`was ${quoted(o)}${o.line !== n.line ? ` (line ${o.line})` : ''}, now ${quoted(n)}`)
    else if (o.line !== n.line) parts.push(`was line ${o.line}`)
    if (o.kind !== n.kind) parts.push(`was ${KIND_WORDS[o.kind]}, now ${KIND_WORDS[n.kind]}`)
    else if (rulesKey(o) !== rulesKey(n)) parts.push(`rules were ${o.rules.map(r => shown(ruleWords(r), 200)).join(', ') || 'none'}, now ${(n.rules ?? []).map(r => shown(ruleWords(r), 200)).join(', ') || 'none'}`)
    out.push(`  - Line ${n.line} changed: ${parts.join('; ')}.`)
    const gone = lawsGone(o)
    if (o.kind === 'hard' && n.kind !== 'hard') loosen(`this hard line is now ${n.kind === 'ask' ? 'an ask or a reminder' : 'advice only'}${gone.length ? `; ${goneWords(gone)}` : ''}.`)
    else if (gone.length) loosen(`${goneWords(gone)}.`)
    for (const t of trustsAdded(n)) loosen(`npm run ${shown(t.name, 200)} will run without asking.`)
  }
  for (const o of oldLeft.sort((a, b) => a.line - b.line)) {
    out.push(`  - Line ${o.line} was removed (${o.kind}): ${quoted(o)}.`)
    if (o.kind === 'hard') {
      const gone = lawsGone(o)
      loosen(`a hard line goes away${gone.length ? `; ${goneWords(gone)}` : ' (its rules are still made by another line)'}.`)
    }
  }
  for (const n of added.sort((a, b) => a.line - b.line)) {
    out.push(`  - Line ${n.line} is new (${n.kind}): ${quoted(n)}.`)
    for (const t of trustsAdded(n)) loosen(`npm run ${shown(t.name, 200)} will run without asking.`)
  }
  const was = old.ask
  if (was) {
    if (was.newTopLevelDir === true && askObj.newTopLevelDir !== true) {
      out.push('  - Asks: a new top-level folder was asked about; now it is not.')
      loosen('new top-level folders are no longer asked about.')
    }
    if (was.npmInstall === true && askObj.npmInstall !== true) {
      out.push('  - Asks: npm install was asked about with the package names; now only the core policy asks.')
      loosen('npm install is no longer asked about because of BEND_RULES.md.')
    }
    for (const [k, what] of [['testBeforeDone', 'test'], ['lintBeforeDone', 'lint']]) {
      if ((was[k] ?? null) !== (askObj[k] ?? null)) {
        out.push(`  - The ${what} reminder at the end of a turn was ${was[k] ? `\`${shown(was[k], 200)}\`` : 'none'}, now ${askObj[k] ? `\`${shown(askObj[k], 200)}\`` : 'none'}.`)
      }
    }
  }
  const head = `Changed since your last approval (${whenWords(old.approvedAt)}):`
  if (out.length === 0) return { lines: [`${head} nothing${moved ? `; ${moved} line(s) only have a new number` : ''}.`], loosens }
  if (moved) out.push(`  (${moved} other line(s) only have a new number.)`)
  return { lines: [head, ...out], loosens }
}

// In log-only mode Guard turns every verdict on an understood call into
// Allow (Guard.bend relax), so the asks are logged, not asked.
function askWords(a, logOnly) {
  const asked = logOnly ? ' (in log-only mode this is logged, not asked)' : ''
  return [
    a.newTopLevelDir ? `New top-level folder in the project: the user is asked first${asked}.` : 'New top-level folders: no ask.',
    a.npmInstall
      ? `npm install: the user is asked first, with the package names${asked}.`
      : `npm install: no ask from BEND_RULES.md (the core policy still asks about every install${asked}).`,
    a.testBeforeDone
      ? `End of a turn that changed files: Claude is reminded to run \`${shown(a.testBeforeDone, 200)}\` and show that it passed.`
      : 'No test reminder at the end of a turn.',
    a.lintBeforeDone
      ? `End of a turn that changed files: Claude is reminded to run \`${shown(a.lintBeforeDone, 200)}\` and show that it passed.`
      : 'No lint reminder at the end of a turn.',
  ]
}

// Every .bend file under bend\core and bend\laws, as {name: 'core/Types.bend', buf}.
function readCoreSources() {
  const files = []
  const walk = (dir, rel) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name)
      if (ent.isSymbolicLink()) refuse(`the plugin's Bend folder holds a link, which is not accepted: ${p}`)
      if (ent.isDirectory()) walk(p, `${rel}/${ent.name}`)
      else if (ent.isFile() && ent.name.endsWith('.bend')) files.push({ name: `${rel}/${ent.name}`, buf: fs.readFileSync(p) })
    }
  }
  for (const part of ['core', 'laws']) {
    const dir = path.join(BEND_DIR, part)
    if (!isDir(dir)) refuse(`the plugin's Bend folder ${dir} is missing`)
    walk(dir, part)
  }
  return files
}

// The generated project\*.bend, as {name: 'project/Rules.bend', buf}.
function readProjectFiles(dir) {
  const files = fs
    .readdirSync(dir, { withFileTypes: true })
    .filter(ent => ent.isFile() && ent.name.endsWith('.bend'))
    .map(ent => ({ name: `project/${ent.name}`, buf: fs.readFileSync(path.join(dir, ent.name)) }))
  for (const want of ['Policy.bend', 'Rules.bend', 'LAWS.bend', 'PROOF.bend']) {
    if (!files.some(f => f.name === `project/${want}`)) refuse(`the generator did not write project/${want}`)
  }
  return files
}

// Each `law name:` in a LAWS.bend with the comment lines right above it.
function lawsIn(text) {
  const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/)
  const out = []
  lines.forEach((l, i) => {
    const m = /^law\s+([A-Za-z0-9_.]+)\s*:/.exec(l)
    if (!m) return
    const notes = []
    for (let j = i - 1; j >= 0 && /^\s*#/.test(lines[j]); j--) notes.unshift(lines[j].replace(/^\s*#\s?/, '').trim())
    let english = notes.join(' ').trim()
    if (!english) {
      let end = i
      while (end + 1 < lines.length && lines[end + 1].trim() !== '') end++
      english = `(no plain-English line; it states ${lines[end].trim()})`
    }
    out.push({ name: m[1], english })
  })
  return out
}

function coreLawLines(coreFiles, why) {
  const out = ['', `Core laws, proven for every rule table (${why}):`]
  for (const f of [...coreFiles].sort(byName)) {
    const m = /^laws\/([^/]+)\/LAWS\.bend$/.exec(f.name)
    if (!m) continue
    out.push(`  laws/${m[1]}:`)
    for (const law of lawsIn(f.buf.toString('utf8'))) out.push(`    ${law.name}: ${shown(law.english, 600)}`)
  }
  return out
}

function pinnedBendSha() {
  const text = readPlain(BEND_VERSION, 'BEND_VERSION', 64 * 1024).toString('utf8')
  const m = /^binary-sha256\b.*?\b([0-9a-f]{64})\s*$/m.exec(text)
  if (!m) refuse(`${BEND_VERSION} has no "binary-sha256 ...: <64 hex digits>" line`)
  return m[1]
}

// ---------------------------------------------------------------------------
// Asking the user

function askLine(question) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true })
    let done = false
    const end = answer => {
      if (done) return
      done = true
      rl.close()
      resolve(answer)
    }
    rl.on('SIGINT', () => {
      process.stdout.write('\n')
      end(null)
    })
    rl.on('close', () => end(null))
    rl.question(question, answer => end(answer))
  })
}

const typedApprove = answer => typeof answer === 'string' && answer.trim().toLowerCase() === 'approve'

// ---------------------------------------------------------------------------
// WSL and the probe run (argv arrays only, never a shell string)

// runWsl (wsl.mjs), with each stdout line passed to onLine as it arrives.
function runWslLive(script, args, { timeoutMs, onLine }) {
  const argv = ['-d', DISTRO, '-u', 'root', '--exec', 'bash', '-l', toWslPath(script), ...args.map(String)]
  return new Promise((resolve, reject) => {
    let carry = ''
    const child = execFile(WSL_EXE, argv, { timeout: timeoutMs, maxBuffer: 64 * MiB, encoding: 'utf8', windowsHide: true }, (err, stdout, stderr) => {
      if (carry.trim() !== '') onLine(carry)
      carry = ''
      if (err && typeof err.code === 'string') return reject(err) // could not start
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : -1) : 0, stdout: String(stdout), stderr: String(stderr), timedOut: Boolean(err && err.killed) })
    })
    child.stdout.on('data', chunk => {
      const parts = (carry + String(chunk)).split(/\r?\n/)
      carry = parts.pop()
      for (const l of parts) onLine(l)
    })
  })
}

function execText(file, argv, timeoutMs) {
  return new Promise(resolve => {
    execFile(file, argv, { timeout: timeoutMs, maxBuffer: 16 * MiB, encoding: 'utf8', windowsHide: true }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : -1) : 0, stdout: String(stdout), stderr: String(stderr), err })
    })
  })
}

// Prints "still <what>" when nothing was printed for 30 s.
function heartbeat(what) {
  const t0 = Date.now()
  let quiet = t0
  const timer = setInterval(() => {
    if (Date.now() - quiet >= 30000) {
      console.log(`  ... still ${what} (${took(t0)} so far)`)
      quiet = Date.now()
    }
  }, 5000)
  return {
    seen: () => {
      quiet = Date.now()
    },
    stop: () => {
      clearInterval(timer)
      return took(t0)
    },
  }
}

async function stageInWsl(name, bendDir, projectDir) {
  const build = `/root/bg-build/${name}`
  let r
  try {
    r = await runWsl(path.join(TOOLS, 'stage.sh'), [name, toWslPath(bendDir), toWslPath(projectDir)], { timeoutMs: 5 * MIN })
  } catch (err) {
    refuse(`WSL could not be started (${short(err)})`)
  }
  const out = outLines(r.stdout)
  if (r.code !== 0 || out[out.length - 1] !== build) {
    refuse(`staging in WSL failed${r.timedOut ? ' (it took too long)' : ''}`, outLines(`${r.stderr}\n${r.stdout}`).slice(-8))
  }
  return build
}

async function proveInWsl(build) {
  console.log('Proving every law in WSL (the bend checker, then the Lean-checked kernel). This takes several minutes.')
  const hb = heartbeat('proving')
  let r
  let elapsed
  try {
    // --no-cache: a line in prove.sh's cache is not evidence (any root process
    // in WSL can append one), so approval proves every law again.
    r = await runWslLive(path.join(TOOLS, 'prove.sh'), [build, '--no-cache'], {
      timeoutMs: 90 * MIN,
      onLine: l => {
        const s = l.replace(/\u0000/g, '').trimEnd()
        if (s.trim() === '') return
        hb.seen()
        console.log(`  ${s}`)
      },
    })
  } catch (err) {
    refuse(`WSL could not be started (${short(err)})`)
  } finally {
    elapsed = hb.stop()
  }
  const last = outLines(r.stdout).pop()
  if (r.code !== 0 || last !== 'BEND-GUARD CHECK OK') {
    refuse(
      r.timedOut ? 'the proof check took too long and was stopped' : `the proof check failed (its last line is "${last ?? 'nothing'}"); the lines above say which part`,
      outLines(r.stderr).slice(-6),
    )
  }
  console.log(`Proof check passed in ${elapsed}.`)
}

// Compiles inside the root-only WSL build folder and reads the bytes back
// with wsl cat, into memory: no Windows folder that another process of this
// user could write ever holds the policy between the compile and the
// fingerprint. compile.sh prints the sha256 of what bend wrote, and the
// bytes read back must have that hash (compiledMatches). Returns the bytes.
async function compileInWsl(build) {
  console.log('Compiling project/Policy.bend to policy.mjs ...')
  const out = `${build}/policy.mjs`
  const hb = heartbeat('compiling')
  let r
  let elapsed
  try {
    r = await runWsl(path.join(TOOLS, 'compile.sh'), [build, 'project/Policy.bend', out], { timeoutMs: 45 * MIN })
  } catch (err) {
    refuse(`WSL could not be started (${short(err)})`)
  } finally {
    elapsed = hb.stop()
  }
  if (r.code !== 0) {
    refuse(`compiling the policy failed${r.timedOut ? ' (it took too long)' : ''}`, outLines(`${r.stdout}\n${r.stderr}`).slice(0, 14))
  }
  const said = compiledSha(r.stdout)
  if (!said) refuse('compile.sh did not report the sha256 of the compiled policy', outLines(r.stdout).slice(-4))
  const c = await execBuf(WSL_EXE, ['-d', DISTRO, '-u', 'root', '--exec', 'cat', '--', out], 2 * MIN)
  if (c.code !== 0) refuse('could not read the compiled policy back from WSL', outLines(c.stderr).slice(-4))
  const m = compiledMatches(c.stdout, said)
  if (!m.ok) refuse(m.why)
  console.log(`Compiled in ${elapsed} (${c.stdout.length} bytes).`)
  return c.stdout
}

function execBuf(file, argv, timeoutMs) {
  return new Promise(resolve => {
    execFile(file, argv, { timeout: timeoutMs, maxBuffer: 64 * MiB, encoding: 'buffer', windowsHide: true }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : -1) : 0, stdout: Buffer.from(stdout ?? []), stderr: String(stderr ?? '') })
    })
  })
}

// The .bend files in the WSL build folder must be exactly the ones shown and
// hashed here.
async function verifyStaged(build, files) {
  const r = await execText(WSL_EXE, ['-d', DISTRO, '-u', 'root', '--exec', 'find', build, '-type', 'f', '-name', '*.bend', '-exec', 'sha256sum', '--', '{}', '+'], 2 * MIN)
  if (r.code !== 0) refuse('could not list the staged files in WSL', outLines(`${r.stderr}\n${r.stdout}`).slice(-4))
  const got = new Map()
  for (const l of outLines(r.stdout)) {
    const m = /^([0-9a-f]{64}) [ *](.+)$/.exec(l)
    if (!m || !m[2].startsWith(`${build}/`)) refuse(`unexpected line while hashing the staged files: ${clip(l)}`)
    got.set(m[2].slice(build.length + 1), m[1])
  }
  const problems = []
  for (const f of files) {
    const h = got.get(f.name)
    if (h === undefined) problems.push(`${f.name} is missing`)
    else if (h !== sha256(f.buf)) problems.push(`${f.name} differs from the copy shown here`)
  }
  for (const name of got.keys()) if (!files.some(f => f.name === name)) problems.push(`${name} should not be there`)
  if (problems.length > 0) refuse(`the staged Bend files in WSL (${build}) are not the ones checked here; was the build folder changed?`, problems.slice(0, 10))
}

// Runs the probes in a child node process, which loads the exact policy text
// from a data: URL the way host\host.mjs does. The child is this file with
// --probe-child, so the policy code never runs inside the approving process.
function runProbeChild(policyText, probes) {
  return new Promise(resolve => {
    const child = execFile(
      process.execPath,
      [THIS_FILE, '--probe-child'],
      { timeout: 5 * MIN, maxBuffer: 16 * MiB, encoding: 'utf8', windowsHide: true, env: { ...process.env, NODE_OPTIONS: '', NODE_PATH: '' } },
      (err, stdout, stderr) => {
        const last = outLines(stdout).pop() ?? ''
        try {
          const r = JSON.parse(last)
          if (isObj(r) && typeof r.ok === 'boolean' && Array.isArray(r.failures) && typeof r.ran === 'number') return resolve(r)
        } catch {
          // fall through
        }
        const why = err && err.killed ? 'it took too long' : short(String(stderr).trim() || (err ? err.message : 'no result'))
        resolve({ ok: false, ran: 0, failures: [{ name: 'probe run', expect: 'a result', got: 'none', reason: why }] })
      },
    )
    child.stdin.on('error', () => {})
    child.stdin.end(JSON.stringify({ policy: policyText, probes }))
  })
}

// The child side: the same check as probes.mjs runProbes (Policy.run with
// NoAnswer must give the expected Allow or Deny), on the text from stdin.
// It always answers with one JSON line.
async function probeChild() {
  try {
    await probeChildRun()
  } catch (err) {
    process.stdout.write(JSON.stringify({ ok: false, ran: 0, failures: [{ name: 'probe run', expect: 'ok', got: 'error', reason: short(err) }] }) + '\n')
  }
}

async function probeChildRun() {
  const emit = r => process.stdout.write(JSON.stringify(r) + '\n')
  const broken = (name, reason) => emit({ ok: false, ran: 0, failures: [{ name, expect: 'ok', got: 'error', reason }] })
  let req
  try {
    const chunks = []
    for await (const c of process.stdin) chunks.push(typeof c === 'string' ? Buffer.from(c, 'utf8') : c)
    req = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch (err) {
    return broken('probe request', short(err))
  }
  if (!isObj(req) || typeof req.policy !== 'string' || !Array.isArray(req.probes)) return broken('probe request', 'want { policy, probes }')
  let api
  try {
    api = (await import('data:text/javascript;base64,' + Buffer.from(req.policy, 'utf8').toString('base64'))).default
  } catch (err) {
    return broken('load policy.mjs', short(err))
  }
  const failures = []
  for (const k of KEYS) {
    if (!api || typeof api[k] !== 'function') failures.push({ name: `export ${k}`, expect: 'function', got: typeof api?.[k] })
  }
  if (failures.length > 0) return emit({ ok: false, ran: 0, failures })
  if (req.probes.length === 0) return emit({ ok: false, ran: 0, failures: [{ name: 'probes', expect: 'at least one probe', got: 'none' }] })
  let ran = 0
  for (const p of req.probes) {
    const want = p && p.expect === 'allow' ? 'Allow' : 'Deny'
    try {
      const v = api['Policy.run'](p.call, { $: 'NoAnswer' })
      ran++
      const got = v && typeof v === 'object' ? String(v.$) : String(v)
      if (got !== want) failures.push({ name: String(p.name), expect: want, got, reason: v && v.reason !== undefined ? String(v.reason) : undefined })
    } catch (err) {
      failures.push({ name: String(p && p.name), expect: want, got: 'error', reason: short(err) })
    }
  }
  emit({ ok: failures.length === 0 && ran > 0 && ran === req.probes.length, ran, failures })
}

// ---------------------------------------------------------------------------
// Approving a project

const again = () => (how === 'terminal' ? 'run approve again' : 'type /bend-guard approve again')

// A private temp folder for one approval, removed when the tool ends.
function privateWork() {
  let tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bend-guard-approve-'))
  cleanups.push(() => fs.rmSync(tmp, { recursive: true, force: true }))
  tmp = fs.realpathSync.native(tmp).replace(/^\\\\\?\\/, '') // long names, for the WSL path
  return { draftCopy: path.join(tmp, 'draft'), genOut: path.join(tmp, 'gen'), bendCopy: path.join(tmp, 'bend') }
}

// Steps 1 to 4: the project, a copy of the draft (only the copy is used from
// then on), the generated files and the check against BEND_RULES.md. `from`
// is the folder the draft is copied from (default D\<slug>). makeWork(slug)
// gives the folders for the copy (draftCopy), the generator's output
// (genOut) and the core sources to stage (bendCopy, or null); the compiled
// policy never lands in a Windows folder (compileInWsl). Lines for the user go to say.
function prepare(rootArg, { from = null, header, makeWork, say }) {
  const rootWin = path.resolve(rootArg)
  const root = normPath(rootWin)
  if (!/^[a-z]:\/[^/]/.test(root)) refuse(`${rootWin} is not a project folder; give the folder that holds BEND_RULES.md`)
  if (!isFolder(rootWin)) refuse(`there is no folder ${rootWin}`)
  const slug = slugOf(root)
  facts.root = rootWin
  facts.slug = slug
  const draftDir = from ?? path.join(D, slug)
  const mdFile = path.join(rootWin, 'BEND_RULES.md')
  say(header(rootWin))

  // What is approved now; a damaged approved.json stops here.
  const stateAtStart = stateFingerprint()
  const prev = readApproved()
  const prevProjects = isObj(prev?.projects) ? prev.projects : {}

  // 2. A private copy of the draft. Only the copy is used from here on.
  if (!isFolder(draftDir)) refuse(`there is no draft for this project (${draftDir}). In a Claude Code session in ${rootWin}, run /bend-guard:compile first.`)
  const { draftCopy, genOut, bendCopy } = makeWork(slug)
  const sortBuf = stripBom(readPlain(path.join(draftDir, 'sort.json'), "the draft's sort.json"))
  const askBuf = stripBom(readPlain(path.join(draftDir, 'ask.json'), "the draft's ask.json"))
  writeUnder(draftCopy, 'sort.json', sortBuf, 'wx')
  writeUnder(draftCopy, 'ask.json', askBuf, 'wx')
  say(`Draft: copied from ${draftDir}; changes made to it from now on are ignored.`)

  // 3. The project's Bend files, from the copy and every approved project.
  let g
  try {
    g = generate({ draftDir: draftCopy, outDir: genOut, projectsDir: fs.existsSync(LIVE_PROJECTS) ? LIVE_PROJECTS : null })
  } catch (err) {
    refuse(`the generator refused the draft: ${err instanceof GenError ? err.message : short(err)}`)
  }
  if (!sameBytes(path.join(draftCopy, 'sort.json'), sortBuf) || !sameBytes(path.join(draftCopy, 'ask.json'), askBuf)) {
    refuse(`the private copy of the draft changed while it was in use; ${again()}`)
  }
  if (g.root !== root) refuse(`the draft's sort.json is for ${winOf(g.root)}, not ${rootWin}`)
  for (const k of Object.keys(prevProjects)) {
    const r = normPath(k)
    if (r !== root && !g.projects.includes(r)) {
      refuse(
        `approved.json lists ${winOf(r)}, but its approved rules are missing (${path.join(LIVE_PROJECTS, slugOf(r), 'sort.json')}), ` +
          `so the new policy would drop them. Approve ${winOf(r)} again first.`,
      )
    }
  }
  const sortObj = parseJson(sortBuf)
  const askObj = parseJson(askBuf)
  const displayBuf = fs.readFileSync(path.join(genOut, 'display.json'))
  const probesBuf = fs.readFileSync(path.join(genOut, 'probes.json'))
  const display = parseJson(displayBuf)
  const probes = parseJson(probesBuf)
  const projectFiles = readProjectFiles(path.join(genOut, 'project'))
  const coreFiles = readCoreSources()
  if (bendCopy) for (const f of coreFiles) writeUnder(bendCopy, f.name, f.buf, 'wx')
  const coreSha256 = sourcesHash(coreFiles)
  // All the generator made, so /bend-guard confirm can check its own run made the same.
  const genSha256 = sourcesHash([{ name: 'display.json', buf: displayBuf }, { name: 'probes.json', buf: probesBuf }, ...projectFiles])

  // 4. Every numbered line of BEND_RULES.md, read here, not from the draft.
  const mdBuf = readPlain(mdFile, 'BEND_RULES.md')
  const numbered = numberedLines(utf8Text(mdBuf, mdFile))
  if (numbered.length === 0) refuse(`${mdFile} has no numbered lines ("1. ...") to approve`)
  const problems = matchDraft(numbered, display.lines)
  if (problems.length > 0) {
    refuse(`the draft does not match ${mdFile}. Run /bend-guard:compile again in a Claude Code session in ${rootWin}, then approve again.`, problems)
  }
  return {
    rootWin,
    root,
    slug,
    mdFile,
    stateAtStart,
    prev,
    prevProjects,
    sortBuf,
    askBuf,
    sortObj,
    askObj,
    g,
    display,
    displayBuf,
    probes,
    probesBuf,
    projectFiles,
    coreFiles,
    coreSha256,
    genSha256,
    mdBuf,
    numbered,
    genOut,
    bendCopy,
  }
}

// What the user reads before they say yes: every numbered line with its kind and
// laws (or why there is none), the CHECK THIS flags, the asks, the rule table,
// the mode and, at the first approval or when the core changed, the core
// laws. Returns the lines and the counts.
function showLines(ctx, logOnly) {
  const { mdFile, numbered, display, sortObj, askObj, g, root, prev, prevProjects, coreFiles, coreSha256 } = ctx
  const lines = []
  const say = s => lines.push(s)
  const entryOf = new Map(display.lines.map(e => [e.line, e]))
  const rulesOf = new Map(sortObj.lines.map(e => [e.line, e.rules]))
  const width = String(Math.max(...numbered.map(l => l.n))).length
  const pad = ' '.repeat(width + 2)
  const count = { hard: 0, ask: 0, judgment: 0, laws: 0, noLaw: 0, trustOnly: 0, enforced: 0, flagged: 0, loosens: null }
  say('')
  say(`${mdFile}: ${numbered.length} numbered lines, as sorted in the draft.`)
  for (const l of numbered) {
    const e = entryOf.get(l.n)
    count[e.kind]++
    say('')
    say(`${String(l.n).padStart(width)}. ${shown(l.text, 2000)}`)
    const rules = rulesOf.get(l.n) ?? []
    if (e.kind === 'hard') {
      const trusts = rules.filter(r => r.kind === 'TrustScript')
      if (e.laws.length === 0 && trusts.length === 0) {
        count.noLaw++
        say(`${pad}hard, but NO LAW was made: ${shown(e.reason)}${e.suggestion ? ` Suggestion: ${shown(e.suggestion)}` : ''}`)
      } else {
        say(`${pad}hard:`)
        for (const w of e.laws) say(`${pad}  law ${w.name}: ${w.english ? shown(w.english, 600) : '(no plain-English line)'}`)
        for (const t of trusts) say(`${pad}  trusts the package.json script "${shown(t.name, 200)}": running it is not asked about (no law; it only allows)`)
        count.laws += e.laws.length
        if (e.laws.length > 0) count.enforced++
        else count.trustOnly++
      }
    } else {
      say(`${pad}${e.kind}, no law: ${shown(e.reason)}`)
    }
    const flag = checkThis(e.kind, l.text) ?? checkRules(e.kind, l.text, rules)
    if (flag) {
      count.flagged++
      say(`${pad}${shown(flag, 2000)}`)
    }
  }
  say('')
  for (const w of display.projectLaws ?? []) say(`Whole project: law ${w.name}: ${shown(w.english, 600)}`)

  say('')
  say('Asks and reminders (ask.json):')
  for (const s of askWords(askObj, logOnly)) say(`  - ${s}`)

  say('')
  // gen.mjs puts every folder of live\projects in the table, listed in approved.json or not.
  const listed = new Set(Object.keys(prevProjects).map(normPath))
  const others = g.projects
    .filter(r => r !== root)
    .map(r => (listed.has(r) ? `${winOf(r)} (approved)` : `${winOf(r)} (its rules are in ${LIVE_PROJECTS}, but approved.json does not list it)`))
  say(`The new policy's rule table: ${winOf(root)} (this project)${others.length ? `, ${others.join(', ')}` : ''}.`)
  const prevPolicy = isObj(prev?.policy) && typeof prev.policy.dir === 'string' ? prev.policy : null
  const prevLogOnly = prev?.logOnly === true
  if (how === 'terminal') {
    say(`After approval bend-guard is ${modeWords(logOnly)}. This applies to every approved project.`)
    if (prevPolicy && prevLogOnly !== logOnly) {
      say(`Note: bend-guard is ${prevLogOnly ? 'log-only' : 'enforcing'} now; this approval switches every approved project to ${logOnly ? 'log-only' : 'enforcing'}.`)
    }
    if (logOnly) say('(Run with --enforce to enforce the project rules.)')
  } else {
    say(`After /bend-guard confirm, bend-guard is ${modeWords(true)}. After /bend-guard confirm --enforce it is enforcing. Either way this applies to every approved project.`)
    if (prevPolicy) {
      say(
        prevLogOnly
          ? 'Note: bend-guard is log-only now; /bend-guard confirm --enforce switches every approved project to enforcing.'
          : 'Note: bend-guard is enforcing now; /bend-guard confirm without --enforce switches every approved project to log-only.',
      )
    }
  }
  if (!prevPolicy) lines.push(...coreLawLines(coreFiles, 'shown because this is the first approval'))
  else if (typeof prevPolicy.coreSha256 !== 'string') lines.push(...coreLawLines(coreFiles, 'shown because the last approval did not record the core sources'))
  else if (prevPolicy.coreSha256 !== coreSha256) lines.push(...coreLawLines(coreFiles, 'shown because the core Bend sources changed since the last approval'))

  // First: the plain summary, then what changed since the last approval.
  const old = lastApproved(ctx)
  const changes = old ? changesSince(old, sortObj.lines, askObj) : { lines: ['No earlier approved copy to compare with.'], loosens: null }
  count.loosens = changes.loosens
  const extra = [count.trustOnly ? `${count.trustOnly} only trust a script` : '', count.noLaw ? `${count.noLaw} hard with NO LAW` : ''].filter(Boolean)
  const summary =
    `Summary: ${numbered.length} lines: ${count.enforced} enforced with proofs (${count.laws} laws), ${count.ask} asks and reminders, ` +
    `${count.judgment} advice${extra.map(s => `, ${s}`).join('')}; ${count.flagged} flagged CHECK THIS; ` +
    (changes.loosens === null ? 'no earlier approval to compare with.' : `${changes.loosens} loosen the rules.`)
  return { lines: ['', summary, '', ...changes.lines, ...lines], count, summary }
}

// The terminal flow: show everything, ask the user to type approve, then prove and write.
async function approveProject(opts) {
  const logOnly = !opts.enforce
  const ctx = prepare(opts.root, {
    header: rootWin => `bend-guard: approving the rules of ${rootWin}`,
    makeWork: privateWork,
    say: s => console.log(s),
  })
  const { lines, count } = showLines(ctx, logOnly)
  for (const l of lines) console.log(l)

  console.log('')
  const answer = await askLine('Type approve to prove and approve these rules, or anything else to stop: ')
  if (!typedApprove(answer)) {
    console.log(`Stopped. Nothing was written to ${S}.`)
    return 1
  }
  await proveAndCommit(ctx, logOnly, count)
  return 0
}

// Steps 5 to 8, once the user said yes: the pinned bend, the proofs, the compiled
// policy and the probes, then S, unless it changed meanwhile. Returns the
// one-line summary.
async function proveAndCommit(ctx, logOnly, count) {
  const { root, slug, prev, prevProjects, stateAtStart, sortBuf, askBuf, askObj, mdBuf, display, displayBuf, probes, probesBuf, projectFiles, coreFiles, coreSha256, genOut, bendCopy } = ctx

  // 5. The pinned bend.
  console.log('')
  const pinned = pinnedBendSha()
  let bendHash
  try {
    bendHash = await bendSha256()
  } catch (err) {
    refuse(`could not hash the bend program in WSL (${short(err)}); check that WSL (${DISTRO}) works`)
  }
  if (bendHash !== pinned) refuse(`the bend program in WSL is not the pinned one: its sha256 is ${bendHash}, but ${BEND_VERSION} pins ${pinned}`)
  console.log('bend: the WSL binary matches the pin in BEND_VERSION.')

  // 6. Stage, prove, compile, check the staged files, probe.
  console.log('Staging core, laws and the generated project in WSL ...')
  const build = await stageInWsl(`approve-${slug}`.replace(/[^A-Za-z0-9_.-]/g, '_'), bendCopy, path.join(genOut, 'project'))
  await proveInWsl(build)
  const mjsBuf = await compileInWsl(build)
  const staged = [...coreFiles, ...projectFiles]
  await verifyStaged(build, staged)
  const mjsText = utf8Text(mjsBuf, 'the compiled policy.mjs')
  console.log(`Running ${probes.length} probe calls on the compiled policy ...`)
  const pr = await runProbeChild(mjsText, probes)
  if (!pr.ok) {
    refuse(
      `${pr.failures.length} probe call(s) did not give the expected verdict, so the policy does not protect what the laws say`,
      pr.failures.slice(0, 10).map(f => `${f.name}: expected ${f.expect}, got ${f.got}${f.reason ? ` (${clip(String(f.reason), 200)})` : ''}`),
    )
  }
  console.log(`Probes: ${pr.ran} of ${probes.length} passed.`)

  // 7 and 8. Write S, unless it changed meanwhile.
  if (stateFingerprint() !== stateAtStart) refuse(`${S} changed while this approval ran (another approval?); ${again()}`)
  const now = new Date().toISOString()
  const policy = {
    dir: POLICY_DIR,
    mjsSha256: sha256(mjsBuf),
    sourcesSha256: sourcesHash(staged),
    coreSha256,
    bendSha256: bendHash,
    approvedAt: now,
  }
  const project = {
    slug,
    rulesJsonSha256: sha256(sortBuf),
    rulesMdSha256: sha256(mdBuf),
    approvedAt: now,
    ask: {
      newTopLevelDir: askObj.newTopLevelDir,
      npmInstall: askObj.npmInstall,
      testBeforeDone: askObj.testBeforeDone,
      lintBeforeDone: askObj.lintBeforeDone,
    },
  }
  const projects = {}
  for (const [k, v] of Object.entries(prevProjects)) if (normPath(k) !== root) projects[k] = v
  projects[root] = project
  const next = { ...(prev ?? {}), version: 2, logOnly, policy, projects }

  const left = commit({
    slug,
    policyFiles: [...staged, { name: 'policy.mjs', buf: mjsBuf }],
    projectFiles: [
      { name: 'sort.json', buf: sortBuf },
      { name: 'ask.json', buf: askBuf },
      { name: 'display.json', buf: displayBuf },
      { name: 'probes.json', buf: probesBuf },
      // what was approved, for the next preview's "Changed since your last approval"
      { name: 'approved-rules.md', buf: mdBuf },
      { name: 'approved-sort.json', buf: sortBuf },
      ...projectFiles.map(f => ({ name: f.name.slice('project/'.length), buf: f.buf })),
    ],
    approvedText: JSON.stringify(next, null, 2) + '\n',
  })

  const summary = `Approved: ${winOf(root)}, ${count.laws} laws from ${count.hard} hard lines (plus ${(display.projectLaws ?? []).length} for the whole project), all proven; ${pr.ran} probe calls passed.`
  console.log('')
  console.log(summary)
  console.log(`Wrote ${APPROVED}, ${LIVE_POLICY} and ${path.join(LIVE_PROJECTS, slug)}.`)
  console.log(`Approved projects: ${Object.keys(projects).map(winOf).join(', ')}.`)
  console.log(`bend-guard is ${modeWords(logOnly)}.`)
  if (logOnly) console.log(how === 'terminal' ? `To enforce: node "${THIS_FILE}" --enforce --mode-only` : 'To enforce: type /bend-guard enforce.')
  if (left) console.log(`(Could not remove the leftover folder ${left}; it is harmless and can be deleted.)`)
  console.log(how === 'terminal' ? RESTART : MOD_RELOAD)
  return summary
}

// ---------------------------------------------------------------------------
// The /bend-guard command: --preview (approve) and --snapshot (confirm)

// The last stdout line of a --preview or --snapshot run, which the mod reads.
function emitLast(obj) {
  return new Promise(resolve => {
    try {
      process.stdout.write(JSON.stringify(obj) + '\n', () => resolve())
    } catch {
      resolve()
    }
  })
}

// Copies more than a day old were never confirmed (the mod keeps one for 30
// minutes): remove them.
function dropStaleSnapshots(dir) {
  let names
  try {
    names = fs.readdirSync(dir)
  } catch {
    return
  }
  for (const n of names) {
    if (!SNAPSHOT_NAME.test(n)) continue
    const st = lstatOrNull(path.join(dir, n))
    if (st && st.isDirectory() && Date.now() - st.mtimeMs > SNAPSHOT_STALE_MS) rmQuiet(path.join(dir, n))
  }
}

// /bend-guard approve: steps 1 to 4 with the draft copied to
// D\<slug>\.approve-<random>\, which outlives this run for --snapshot, with
// preview.json: the hashes of everything shown. The display is what the
// terminal flow prints before it asks. Nothing is written to S.
async function previewProject(opts) {
  let snapshot = null
  let keep = false
  cleanups.push(() => {
    if (snapshot && !keep) fs.rmSync(snapshot, { recursive: true, force: true })
  })
  const lines = []
  const ctx = prepare(opts.root, {
    header: rootWin => `bend-guard: the rules of ${rootWin}, as /bend-guard confirm would approve them.`,
    makeWork: slug => {
      const dir = path.join(D, slug)
      if (!isDir(D) || !isDir(dir)) refuse(`${dir} must be a plain folder (a link is not accepted)`)
      dropStaleSnapshots(dir)
      snapshot = path.join(dir, `.approve-${crypto.randomBytes(8).toString('hex')}`)
      fs.mkdirSync(snapshot)
      return { draftCopy: snapshot, genOut: path.join(snapshot, 'gen'), bendCopy: null }
    },
    say: s => lines.push(s),
  })
  lines.push(...showLines(ctx, true).lines)
  const info = {
    version: 1,
    root: ctx.root,
    rootWin: ctx.rootWin,
    slug: ctx.slug,
    rulesMdSha256: sha256(ctx.mdBuf),
    sortSha256: sha256(ctx.sortBuf),
    askSha256: sha256(ctx.askBuf),
    coreSha256: ctx.coreSha256,
    genSha256: ctx.genSha256,
    state: ctx.stateAtStart,
    madeAt: new Date().toISOString(),
  }
  const infoText = JSON.stringify(info, null, 2) + '\n'
  writeSynced(path.join(snapshot, PREVIEW_FILE), infoText)
  keep = true
  await emitLast({
    ok: true,
    root: ctx.rootWin,
    slug: ctx.slug,
    snapshot,
    rulesMdSha256: info.rulesMdSha256,
    previewSha256: sha256(Buffer.from(infoText, 'utf8')),
    display: lines.join('\n'),
  })
  return 0
}

// The copy --preview made: D\<slug>\.approve-<16 hex digits>, plain folders
// all the way down (no link), holding preview.json, sort.json and ask.json.
function checkSnapshot(dirArg) {
  const dir = path.resolve(String(dirArg))
  const parts = path.relative(D, dir).split(path.sep)
  if (parts.length !== 2 || !/^[a-z0-9_][a-z0-9._ -]*$/.test(parts[0]) || !SNAPSHOT_NAME.test(parts[1])) {
    refuse(`${dir} is not a copy that /bend-guard approve made under ${D}; ${again()}`)
  }
  for (const p of [D, path.join(D, parts[0]), dir]) {
    if (!isDir(p)) refuse(`${p} is missing or is not a plain folder (a link is not accepted); ${again()}`)
  }
  for (const f of [PREVIEW_FILE, 'sort.json', 'ask.json']) {
    if (lstatOrNull(path.join(dir, f))?.isFile() !== true) refuse(`the copy ${dir} has no ${f}; ${again()}`)
  }
  return { dir, slug: parts[0] }
}

// /bend-guard confirm: steps 5 to 8 on exactly what --preview showed. The mod
// kept preview.json's hash in memory (--expect); the draft copy, BEND_RULES.md,
// the core sources, the generated files and what is approved must all still
// match preview.json. The copy is removed at the end, whatever happens.
async function approveSnapshot(opts) {
  const logOnly = !opts.enforce
  const snap = checkSnapshot(opts.snapshot)
  cleanups.push(() => fs.rmSync(snap.dir, { recursive: true, force: true }))
  const changed = `the copy of the draft you looked at was changed since; ${again()}`
  const rulesChanged = 'BEND_RULES.md changed since you looked; type /bend-guard approve again'
  const infoBuf = readPlain(path.join(snap.dir, PREVIEW_FILE), "the copy's preview.json", 64 * 1024)
  if (sha256(infoBuf) !== opts.expect) refuse(changed)
  let info
  try {
    info = parseJson(infoBuf)
  } catch {
    refuse(changed)
  }
  const hex = k => typeof info[k] === 'string' && HEX64.test(info[k])
  if (
    !isObj(info) ||
    info.version !== 1 ||
    typeof info.rootWin !== 'string' ||
    normPath(info.rootWin) !== info.root ||
    slugOf(info.root) !== snap.slug ||
    info.slug !== snap.slug ||
    typeof info.state !== 'string' ||
    !['rulesMdSha256', 'sortSha256', 'askSha256', 'coreSha256', 'genSha256'].every(hex)
  ) {
    refuse(changed)
  }

  // BEND_RULES.md must be the one the user looked at.
  if (sha256(readPlain(path.join(info.rootWin, 'BEND_RULES.md'), 'BEND_RULES.md')) !== info.rulesMdSha256) refuse(rulesChanged)

  // Steps 1 to 4 again, from the copy, in a private folder: all must match.
  const ctx = prepare(info.rootWin, {
    from: snap.dir,
    header: rootWin => `bend-guard: approving the rules of ${rootWin} (/bend-guard confirm${logOnly ? '' : ' --enforce'})`,
    makeWork: privateWork,
    say: s => console.log(s),
  })
  if (sha256(ctx.sortBuf) !== info.sortSha256 || sha256(ctx.askBuf) !== info.askSha256) refuse(changed)
  if (sha256(ctx.mdBuf) !== info.rulesMdSha256) refuse(rulesChanged)
  if (ctx.coreSha256 !== info.coreSha256) refuse(`bend-guard's own Bend files changed since you looked; ${again()}`)
  if (ctx.stateAtStart !== info.state) refuse(`what is approved changed since you looked (another approval, or a switch of mode); ${again()}`)
  if (ctx.genSha256 !== info.genSha256) refuse(`the generated Bend files are not the ones you looked at (were bend-guard's templates changed?); ${again()}`)
  const { count } = showLines(ctx, logOnly)
  const summary = await proveAndCommit(ctx, logOnly, count)
  await emitLast({ ok: true, message: `${summary} bend-guard is ${logOnly ? 'log-only' : 'enforcing'}.` })
  return 0
}

// ---------------------------------------------------------------------------
// --status and --mode-only

function status() {
  console.log(`bend-guard status (${APPROVED})`)
  const st = lstatOrNull(APPROVED)
  if (!st) {
    console.log('Nothing is approved, so bend-guard is inactive everywhere.')
    return 0
  }
  const broken = 'In a folder with a BEND_RULES.md, the mod refuses every tool call until this is fixed (run approve again).'
  let text
  try {
    text = fs.readFileSync(APPROVED).toString('utf8')
  } catch (err) {
    console.log(`Problem: it cannot be read (${short(err)}). ${broken}`)
    return 1
  }
  if (text.startsWith('\uFEFF')) console.log('Problem: it starts with a byte-order mark, which the mod cannot read. Run approve or --mode-only to rewrite it.')
  let o
  try {
    o = JSON.parse(text.replace(/^\uFEFF/, ''))
  } catch (err) {
    console.log(`Problem: it is not valid JSON (${short(err, 120)}). ${broken}`)
    return 1
  }
  if (!isObj(o) || o.version !== 2) {
    console.log(`Problem: it is not a version 2 approval file. ${broken}`)
    return 1
  }
  if (o.logOnly !== undefined && typeof o.logOnly !== 'boolean') console.log('Problem: "logOnly" is not true or false, so the mod reads the policy entry as broken.')
  console.log(`Mode: ${modeWords(o.logOnly === true)}.`)

  const p = o.policy
  if (!isObj(p) || typeof p.dir !== 'string' || !p.dir || typeof p.mjsSha256 !== 'string' || !HEX64.test(p.mjsSha256.toLowerCase())) {
    console.log('Policy: no valid policy entry, so the mod refuses every tool call in approved projects.')
  } else {
    const file = policyMjsPath(p.dir)
    let fp
    if (!file) fp = 'cannot be used: its folder contains ".."'
    else {
      try {
        fp = sha256(fs.readFileSync(file)) === p.mjsSha256.toLowerCase() ? 'matches its fingerprint' : 'DOES NOT match its fingerprint, so the mod refuses every tool call in approved projects'
      } catch {
        fp = `is missing (${file}), so the mod refuses every tool call in approved projects`
      }
    }
    console.log(`Policy: approved ${p.approvedAt ?? '(time unknown)'}; policy.mjs ${fp}.`)
  }

  const entries = isObj(o.projects) ? Object.entries(o.projects) : []
  if (entries.length === 0) {
    console.log('Approved projects: none.')
    return 0
  }
  console.log(`Approved projects (${entries.length}):`)
  for (const [key, e0] of entries) {
    const root = normPath(key)
    const e = isObj(e0) ? e0 : {}
    const notes = []
    try {
      const h = sha256(fs.readFileSync(path.join(winOf(root), 'BEND_RULES.md')))
      notes.push(typeof e.rulesMdSha256 === 'string' && h === e.rulesMdSha256.toLowerCase() ? 'BEND_RULES.md unchanged since approval' : 'BEND_RULES.md CHANGED since approval (run /bend-guard:compile, then approve)')
    } catch {
      notes.push('BEND_RULES.md is missing')
    }
    const slug = typeof e.slug === 'string' && e.slug ? e.slug : slugOf(root)
    if (!fs.existsSync(path.join(LIVE_PROJECTS, slug, 'sort.json'))) notes.push(`its approved rules are missing from ${path.join(LIVE_PROJECTS, slug)}`)
    console.log(`  ${winOf(root)}: approved ${e.approvedAt ?? '(time unknown)'}; ${notes.join('; ')}.`)
  }
  return 0
}

async function modeOnly(wantLogOnly, fromMod = false) {
  doing = 'mode'
  const st = lstatOrNull(APPROVED)
  if (!st) refuse(`nothing is approved yet (${APPROVED} does not exist); approve a project first`)
  if (!st.isFile()) refuse(`${APPROVED} is not a plain file. ${AGAIN}`)
  const before = fs.readFileSync(APPROVED)
  const o = parseApproved(before)
  const p = o.policy
  if (!isObj(p) || typeof p.dir !== 'string' || typeof p.mjsSha256 !== 'string' || !HEX64.test(p.mjsSha256.toLowerCase())) {
    refuse(`${APPROVED} has no valid policy entry; approve a project first`)
  }
  const cur = o.logOnly === true
  if (cur === wantLogOnly) {
    console.log(`bend-guard is already ${modeWords(cur)}. Nothing changed.`)
    return 0
  }
  const roots = isObj(o.projects) ? Object.keys(o.projects).map(k => winOf(normPath(k))) : []
  if (fromMod) {
    // The user typed /bend-guard enforce or /bend-guard log-only themselves: that is their yes.
    console.log(
      `Switching every approved project (${roots.length ? roots.join(', ') : 'none'}) from ${cur ? 'log-only' : 'enforcing'} ` +
        `to ${wantLogOnly ? 'log-only' : 'enforcing'}. Nothing else changes.`,
    )
  } else {
    console.log(`bend-guard is now ${modeWords(cur)}.`)
    console.log(`This switches it to ${modeWords(wantLogOnly)}.`)
    console.log(`It applies to every approved project: ${roots.length ? roots.join(', ') : 'none'}. Nothing else changes.`)
    const answer = await askLine(`Type approve to switch to ${wantLogOnly ? 'log-only' : 'enforcing'}, or anything else to stop: `)
    if (!typedApprove(answer)) {
      console.log(`Stopped. Nothing was written to ${S}.`)
      return 1
    }
  }
  if (!sameBytes(APPROVED, before)) refuse(`${APPROVED} changed while you were reading; run the command again`)
  o.logOnly = wantLogOnly
  committing = true
  try {
    writeAtomic(APPROVED, JSON.stringify(o, null, 2) + '\n')
  } catch (err) {
    committing = false
    throw new StateError(`writing ${APPROVED} failed (${short(err)}); it was left as it was.`, false)
  }
  committing = false
  console.log(`Done: bend-guard is ${modeWords(wantLogOnly)}.`)
  console.log(fromMod ? MOD_RELOAD : RESTART)
  return 0
}

// ---------------------------------------------------------------------------
// The /bend-guard handshake

// Reads and removes S\.approve-token. A --from-mod run does this before
// anything else, whether or not the token will match: a token is good for one
// try.
function takeTokenFile() {
  const st = lstatOrNull(TOKEN_FILE)
  if (!st) return { text: null, gone: true }
  let text = null
  if (st.isFile() && st.size <= 4096) {
    try {
      text = fs.readFileSync(TOKEN_FILE, 'utf8')
    } catch {
      text = null
    }
  }
  for (let i = 0; i < 8 && lstatOrNull(TOKEN_FILE); i++) {
    try {
      fs.unlinkSync(TOKEN_FILE)
    } catch (err) {
      // A virus scanner or indexer may hold a new file for a moment.
      if (!['EPERM', 'EBUSY', 'EACCES'].includes(err && err.code)) break
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100 * (i + 1))
    }
  }
  return { text, gone: lstatOrNull(TOKEN_FILE) === null }
}

// The first line on stdin, or null: a terminal, nothing within 10 s, or too long.
function readTokenLine() {
  return new Promise(resolve => {
    const input = process.stdin
    if (input.isTTY) return resolve(null)
    let text = ''
    let done = false
    const end = v => {
      if (done) return
      done = true
      clearTimeout(timer)
      try {
        input.destroy()
      } catch {
        // nothing more is read from it
      }
      resolve(v)
    }
    const timer = setTimeout(() => end(null), 10000)
    input.setEncoding('utf8')
    input.on('data', chunk => {
      text += chunk
      const i = text.search(/\r?\n/)
      if (i >= 0) end(text.slice(0, i))
      else if (text.length > 4096) end(null)
    })
    input.on('end', () => end(text === '' ? null : text))
    input.on('error', () => end(null))
  })
}

// The token on stdin must hash (sha256, hex) to the text the mod wrote to the
// token file, which takeTokenFile has already read and removed.
async function checkToken(taken) {
  if (!taken.gone) refuse(`the one-time token file ${TOKEN_FILE} could not be removed, so it was not used`)
  const token = await readTokenLine()
  const want = typeof taken.text === 'string' ? taken.text.trim().toLowerCase() : ''
  const t = typeof token === 'string' ? token.trim() : ''
  const ok =
    HEX64.test(want) &&
    t.length >= 32 &&
    t.length <= 512 &&
    crypto.timingSafeEqual(Buffer.from(sha256(Buffer.from(t, 'utf8')), 'ascii'), Buffer.from(want, 'ascii'))
  if (!ok) refuse('this run did not come from your own /bend-guard command (its one-time token is missing or does not match), so it was refused')
}

// ---------------------------------------------------------------------------
// Command line

function parseArgs(argv) {
  const o = { root: null, enforce: false, logOnly: false, status: false, modeOnly: false, preview: false, snapshot: null, expect: null, fromMod: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--enforce') o.enforce = true
    else if (a === '--log-only') o.logOnly = true
    else if (a === '--status') o.status = true
    else if (a === '--mode-only') o.modeOnly = true
    else if (a === '--preview') o.preview = true
    else if (a === '--from-mod') o.fromMod = true
    else if (a === '--snapshot' || a === '--expect') {
      const v = argv[++i]
      const key = a === '--snapshot' ? 'snapshot' : 'expect'
      if (v === undefined || v.startsWith('-') || o[key] !== null) return null
      o[key] = v
    } else if (a.startsWith('-')) return null
    else if (o.root === null) o.root = a
    else return null
  }
  if (o.enforce && o.logOnly) return null
  const modFlags = o.preview || o.snapshot !== null || o.expect !== null || o.fromMod
  if (o.status) return o.root === null && !o.enforce && !o.logOnly && !o.modeOnly && !modFlags ? o : null
  if (o.preview) return o.root !== null && !o.enforce && !o.logOnly && !o.modeOnly && o.snapshot === null && o.expect === null && !o.fromMod ? o : null
  if (o.snapshot !== null) return o.fromMod && o.root === null && !o.modeOnly && o.expect !== null && HEX64.test(o.expect) ? o : null
  if (o.expect !== null) return null
  if (o.modeOnly) return o.root === null && (o.enforce || o.logOnly) ? o : null
  if (o.fromMod) return null // only with --snapshot or --mode-only
  return o.root !== null ? o : null
}

async function main(argv) {
  if (argv.length === 1 && argv[0] === '--probe-child') {
    await probeChild()
    return null
  }
  // A run for the /bend-guard command takes its token file before anything else.
  const taken = argv.includes('--from-mod') ? takeTokenFile() : null
  if (argv.includes('--snapshot')) jsonOut = 'snapshot'
  else if (argv.includes('--preview')) jsonOut = 'preview'
  if (taken || jsonOut) how = 'mod'
  const o = parseArgs(argv)
  if (!o) {
    console.log(USAGE)
    if (jsonOut) refuse('approve.mjs was called with arguments it does not take')
    return 2
  }
  if (o.status) return status()
  if (o.preview) return previewProject(o)
  if (o.fromMod) {
    if (o.modeOnly) doing = 'mode'
    await checkToken(taken)
    return o.snapshot !== null ? approveSnapshot(o) : modeOnly(o.logOnly, true)
  }
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.log('approve.mjs must be run by the user in their own terminal: it asks them to type "approve". Nothing was written.')
    return 2
  }
  if (o.modeOnly) return modeOnly(o.logOnly)
  return approveProject(o)
}

process.on('SIGINT', () => {
  if (committing) {
    console.log('\nFinishing the write to the state folder; one moment.')
    return
  }
  console.log(`\nStopped. Nothing was written to ${S}.`)
  finish(130)
})

main(process.argv.slice(2)).then(
  code => {
    if (code === null) return // the probe child exits on its own
    finish(code)
  },
  async err => {
    const what = doing === 'mode' ? 'Not changed' : 'Not approved'
    const msg = err instanceof Refusal || err instanceof StateError ? err.message : `approve.mjs failed unexpectedly: ${short(err)}`
    const details = err instanceof Refusal ? err.details : []
    const dirty = err instanceof StateError && err.dirty
    if (jsonOut === 'preview') {
      await emitLast({ ok: false, root: facts.root, slug: facts.slug, snapshot: null, rulesMdSha256: null, display: '', error: [msg, ...details.slice(0, 20)].join('\n') })
      return finish(1)
    }
    console.log('')
    console.log(`${what}: ${msg}`)
    for (const d of details) console.log(`  ${d}`)
    if (!dirty) console.log(`Nothing was written to ${S}.`)
    if (jsonOut === 'snapshot') await emitLast({ ok: false, message: clip([msg, ...details.slice(0, 3)].join('; '), 1500) })
    finish(1)
  },
)
