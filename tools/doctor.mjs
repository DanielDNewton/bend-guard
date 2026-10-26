// bend-guard doctor: is bend-guard set up right on this PC? Read-only.
//
//   node tools/doctor.mjs [--skip-wsl] [--clef]
//
// One line per check: "ok", "PROBLEM" (with the fix), "note" (something
// optional is missing; not a problem) or "skipped". Checks:
// Node's version; where the home folder and the plugin are; whether the copy
// Claude Code installed and runs matches this folder; the Ubuntu-24.04
// WSL distro; the bend program in WSL against the pin in BEND_VERSION;
// approved.json; policy.mjs against its fingerprint in approved.json; each
// approved project's BEND_RULES.md against its approval; the Clef key file
// (present or not: it is never read here, and never printed).
//
// --skip-wsl  leaves out the two WSL checks (they take a few seconds).
// --clef      also makes ONE paid Clef call (a fraction of a cent) with a
//             harmless command, to see that the key and OpenRouter work. This
//             is the only time the doctor reads the key or uses the network.
//
// It never writes anything. Exit 0 when nothing is a problem (notes do not
// count), 1 otherwise,
// 2 for bad arguments.

import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFile } from 'node:child_process'
import { PLUGIN_DIR, homeDir, stateDir, keyFile, expectedPluginDir, layoutProblems } from './home.mjs'
import { DISTRO, WSL_EXE, bendSha256 } from './wsl.mjs'

const MIN_NODE = 22
const sha256 = buf => crypto.createHash('sha256').update(buf).digest('hex')
const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v)
const HEX64 = /^[0-9a-f]{64}$/

const lines = []
let problems = 0
const ok = (what, detail) => lines.push(`ok       ${what}: ${detail}`)
const problem = (what, detail, fix) => {
  problems++
  lines.push(`PROBLEM  ${what}: ${detail}${fix ? ` Fix: ${fix}` : ''}`)
}
const skipped = (what, detail) => lines.push(`skipped  ${what}: ${detail}`)
const note = (what, detail) => lines.push(`note     ${what}: ${detail}`)
const KEY_SECTION = 'README "The OpenRouter key, and what is sent"'
const short = (err, n = 160) => {
  const s = String(err && typeof err === 'object' && 'message' in err ? err.message : err)
  return s.length > n ? s.slice(0, n) + '...' : s
}

function checkNode() {
  const major = Number(process.versions.node.split('.')[0])
  if (major >= MIN_NODE) ok('node', `version ${process.versions.node}`)
  else problem('node', `version ${process.versions.node} is too old.`, `install Node ${MIN_NODE} or newer.`)
}

function checkLayout(home) {
  const ps = layoutProblems({ home, plugin: PLUGIN_DIR })
  if (ps.length === 0) ok('plugin location', `${PLUGIN_DIR} (home ${home})`)
  else problem('plugin location', ps.join('; ') + '.', `put the plugin folder at ${expectedPluginDir(home)}, with your home folder on C: (README "Install on another PC").`)
}

// wsl.exe -l -q prints UTF-16LE text.
function wslList() {
  return new Promise(resolve => {
    if (!WSL_EXE) return resolve({ err: 'the Windows folder is unknown (%SystemRoot% is not set)' })
    execFile(WSL_EXE, ['-l', '-q'], { encoding: 'buffer', windowsHide: true, timeout: 30000 }, (err, stdout) => {
      if (err && !stdout?.length) return resolve({ err: short(err) })
      const text = Buffer.from(stdout).toString('utf16le').replace(/\0/g, '')
      resolve({ names: text.split(/\r?\n/).map(s => s.trim()).filter(Boolean) })
    })
  })
}

async function checkWsl() {
  const r = await wslList()
  if (r.err) {
    problem('WSL', `WSL could not be asked for its distros (${r.err}).`, `install WSL and the ${DISTRO} distro: wsl --install -d ${DISTRO}`)
    return false
  }
  if (!r.names.some(n => n.toLowerCase() === DISTRO.toLowerCase())) {
    problem('WSL', `the ${DISTRO} distro is not installed.`, `wsl --install -d ${DISTRO}`)
    return false
  }
  ok('WSL', `the ${DISTRO} distro is installed`)
  return true
}

function pinnedBend() {
  const text = fs.readFileSync(path.join(PLUGIN_DIR, 'BEND_VERSION'), 'utf8')
  const m = /^binary-sha256\b.*?\b([0-9a-f]{64})\s*$/m.exec(text)
  const v = /^version:\s*(\S+)/m.exec(text)
  return { sha: m ? m[1] : null, version: v ? v[1] : '(unknown)' }
}

async function checkBend() {
  let pin
  try {
    pin = pinnedBend()
  } catch (err) {
    problem('bend', `BEND_VERSION cannot be read (${short(err)}).`, 'reinstall the plugin folder.')
    return
  }
  if (!pin.sha) {
    problem('bend', 'BEND_VERSION has no binary-sha256 line.', 'reinstall the plugin folder.')
    return
  }
  let got
  try {
    got = await bendSha256()
  } catch (err) {
    problem('bend', `the bend program in WSL could not be found or hashed (${short(err)}).`, `install bend ${pin.version} in ${DISTRO} (README "Install on another PC").`)
    return
  }
  if (got === pin.sha) ok('bend', `the WSL bend program is the pinned ${pin.version}`)
  else problem('bend', `the WSL bend program is not the pinned one (sha256 ${got.slice(0, 12)}..., pinned ${pin.sha.slice(0, 12)}...).`, `install bend ${pin.version} in ${DISTRO}; approvals refuse any other build.`)
}

// approved.json, as register.tsx reads it. Returns the object or null.
function checkApproved(S) {
  const file = path.join(S, 'approved.json')
  let text
  try {
    text = fs.readFileSync(file).toString('utf8')
  } catch (err) {
    if (err && err.code === 'ENOENT') problem('approved.json', `${file} does not exist, so nothing is approved and bend-guard checks nothing.`, 'approve a project: write its BEND_RULES.md, then type /bend-guard approve in Claude Code.')
    else problem('approved.json', `${file} cannot be read (${short(err)}).`, 'check the file, then approve again.')
    return null
  }
  let o
  try {
    o = JSON.parse(text)
  } catch (err) {
    problem('approved.json', `it is not valid JSON${text.startsWith('\uFEFF') ? ' (it starts with a byte-order mark)' : ''}, so the mod refuses every tool call in a folder with a BEND_RULES.md.`, 'rename it and approve each project again.')
    return null
  }
  if (!isObj(o) || o.version !== 2) {
    problem('approved.json', 'it is not a version 2 approval file, so the mod refuses every tool call in a folder with a BEND_RULES.md.', 'rename it and approve each project again.')
    return null
  }
  const n = isObj(o.projects) ? Object.keys(o.projects).length : 0
  ok('approved.json', `readable; ${n} approved project${n === 1 ? '' : 's'}, ${o.logOnly === true ? 'log-only' : 'enforcing'}`)
  return o
}

// register.tsx policyMjsPath: a relative dir is under S; '..' is not allowed.
function policyFile(S, dir) {
  const d = String(dir).replace(/\//g, '\\').replace(/\\+$/, '')
  if (!d || d.split('\\').some(s => s === '..')) return null
  return /^[a-zA-Z]:\\/.test(d) ? path.join(d, 'policy.mjs') : path.join(S, d.replace(/^\\+/, ''), 'policy.mjs')
}

function checkPolicy(S, o) {
  const p = o.policy
  if (!isObj(p) || typeof p.dir !== 'string' || typeof p.mjsSha256 !== 'string' || !HEX64.test(p.mjsSha256.toLowerCase())) {
    problem('policy.mjs', 'approved.json has no valid policy entry, so the mod refuses every tool call in approved projects.', 'approve a project again.')
    return
  }
  const file = policyFile(S, p.dir)
  if (!file) {
    problem('policy.mjs', 'the policy folder in approved.json is not allowed (it contains "..").', 'approve a project again.')
    return
  }
  let buf
  try {
    buf = fs.readFileSync(file)
  } catch {
    problem('policy.mjs', `${file} is missing, so the mod refuses every tool call in approved projects.`, 'approve a project again.')
    return
  }
  if (sha256(buf) === p.mjsSha256.toLowerCase()) ok('policy.mjs', 'matches its fingerprint in approved.json')
  else problem('policy.mjs', `${file} does not match its fingerprint in approved.json, so the mod refuses every tool call in approved projects.`, 'approve a project again (never edit the state folder by hand).')
}

// 'c:/users/x/app' -> 'C:\users\x\app'
const winOf = root => String(root).replace(/^([a-z]):/, (_, d) => `${d.toUpperCase()}:`).replace(/\//g, '\\')

function checkProjects(o) {
  const entries = isObj(o.projects) ? Object.entries(o.projects) : []
  for (const [root, e0] of entries) {
    const e = isObj(e0) ? e0 : {}
    const md = path.join(winOf(root), 'BEND_RULES.md')
    let buf
    try {
      buf = fs.readFileSync(md)
    } catch {
      problem(`project ${winOf(root)}`, 'its BEND_RULES.md is missing, so bend-guard no longer checks calls there.', 'put BEND_RULES.md back, or ignore this if the project is gone.')
      continue
    }
    if (typeof e.rulesMdSha256 === 'string' && sha256(buf) === e.rulesMdSha256.toLowerCase()) ok(`project ${winOf(root)}`, 'BEND_RULES.md unchanged since its approval')
    else problem(`project ${winOf(root)}`, 'BEND_RULES.md changed since its approval, so the mod refuses every tool call there.', 'run /bend-guard:compile, then /bend-guard approve, or undo the change.')
  }
  if (entries.length === 0) ok('projects', 'none approved yet')
}

// The copy Claude Code really loads. `claude plugin install` copies the plugin
// into <home>\.claude\plugins\cache\<marketplace>\bend-guard\<version> and
// runs it from there; a later change to this folder does not reach that copy
// while the version stays the same. Compares the files the engine loads
// (hooks\, commands\, .claude-plugin\plugin.json) by hash.
const LOADED = ['hooks', 'commands', path.join('.claude-plugin', 'plugin.json')]

function loadedFiles(root) {
  const out = []
  const walk = rel => {
    const abs = path.join(root, rel)
    let st
    try {
      st = fs.statSync(abs)
    } catch {
      return
    }
    if (st.isDirectory()) for (const e of fs.readdirSync(abs).sort()) walk(path.join(rel, e))
    else if (st.isFile()) out.push(rel)
  }
  for (const r of LOADED) walk(r)
  return out
}

function checkInstalledCopy(home) {
  const what = 'installed copy'
  const file = path.join(home, '.claude', 'plugins', 'installed_plugins.json')
  let o
  try {
    o = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    skipped(what, `Claude Code has no readable ${file}, so there is no installed copy to compare`)
    return
  }
  const plugins = isObj(o) && isObj(o.plugins) ? o.plugins : {}
  const paths = []
  for (const [id, list] of Object.entries(plugins)) {
    if (!/^bend-guard@/.test(id) || !Array.isArray(list)) continue
    for (const e of list) if (isObj(e) && typeof e.installPath === 'string' && e.installPath) paths.push({ id, dir: e.installPath })
  }
  if (paths.length === 0) {
    skipped(what, 'Claude Code has no bend-guard install recorded (claude plugin install bend-guard@local-mods installs it)')
    return
  }
  const same = (a, b) => path.resolve(a).replace(/[\\/]+$/, '').toLowerCase() === path.resolve(b).replace(/[\\/]+$/, '').toLowerCase()
  const src = loadedFiles(PLUGIN_DIR)
  for (const { id, dir } of paths) {
    if (same(dir, PLUGIN_DIR)) {
      ok(what, `${id} runs from this folder`)
      continue
    }
    const differ = []
    for (const rel of src) {
      let a, b
      try {
        a = sha256(fs.readFileSync(path.join(PLUGIN_DIR, rel)))
        b = sha256(fs.readFileSync(path.join(dir, rel)))
      } catch {
        differ.push(rel)
        continue
      }
      if (a !== b) differ.push(rel)
    }
    const extra = loadedFiles(dir).filter(rel => !src.includes(rel))
    const all = [...differ, ...extra].map(r => r.replace(/\//g, '\\'))
    if (all.length === 0) ok(what, `${id} at ${dir} matches this folder`)
    else {
      const shown = all.slice(0, 5).join(', ') + (all.length > 5 ? ` and ${all.length - 5} more` : '')
      problem(
        what,
        `Claude Code runs ${id} from ${dir}, which is not the same as ${PLUGIN_DIR} (${all.length} file${all.length === 1 ? '' : 's'} differ: ${shown}), so the hooks that run are not the ones here.`,
        `with bend-guard disabled, in your own terminal: claude plugin uninstall ${id}, delete ${dir} if it is still there, then claude plugin install ${id} and claude plugin enable ${id}, and restart Claude Code (if claude is not on your PATH, run it by its full path from the VS Code extension, $env:USERPROFILE\\.vscode\\extensions\\anthropic.claude-code-<version>-win32-x64\\resources\\native-binary\\claude.exe, or use /plugin in Claude Code).`,
      )
    }
  }
}

// Present or not, by its size only: the doctor never reads the key here. The
// key is optional, so a missing key file is a note, not a problem.
function checkKey(home) {
  const file = keyFile(home)
  let st
  try {
    st = fs.lstatSync(file)
  } catch {
    note('Clef key', `optional, and there is no key file at ${file}, so Clef never answers and every shell command bend-guard does not understand asks you. To add one, save your OpenRouter API key, alone on one line, in that file (${KEY_SECTION}).`)
    return false
  }
  if (!st.isFile() || st.size === 0) {
    problem('Clef key', `${file} is ${st.isFile() ? 'empty' : 'not a plain file'}.`, `save your OpenRouter API key, alone on one line, in that file (${KEY_SECTION}), or delete the file.`)
    return false
  }
  ok('Clef key', `the key file exists (${file}); its contents are not shown`)
  return true
}

// One paid call with a harmless command, through the mod's own client.
async function checkClef(home) {
  const { readKey, loadClef, nodeDollar } = await import('./clef-lib.mjs')
  const key = readKey(keyFile(home))
  if (!key) {
    problem('Clef call', 'not made: there is no usable key file.', 'see the Clef key line above.')
    return
  }
  let C
  try {
    C = await loadClef()
  } catch (err) {
    problem('Clef call', `the mod's Clef client could not be loaded (${short(err)}).`, `use Node ${MIN_NODE}.15 or newer, and reinstall the plugin folder.`)
    return
  }
  const t0 = Date.now()
  const r = await C.askClef(nodeDollar(), { text: 'Shell: Bash\nFolder: (doctor)\nCommand: ls -la' }, { key, model: C.CLEF_MODEL, timeoutMs: C.CLEF_TIMEOUT_MS, zones: [] }, new Map())
  const ms = Date.now() - t0
  if (r.status === 'ok') ok('Clef call', `answered in ${ms} ms (risky ${r.answer.risky}, unsure ${r.answer.unsure} per thousand for "ls -la")`)
  else {
    const why = r.status === 'http-401' ? 'the key was refused (401)' : r.status === 'http-402' ? 'the OpenRouter account has no credit (402)' : r.status === 'timeout' ? `no answer within ${C.CLEF_TIMEOUT_MS} ms` : `status ${r.status}`
    problem('Clef call', `no answer: ${why}, so Clef cannot help and those calls ask you.`, 'check the key and the account at openrouter.ai, then run the doctor with --clef again.')
  }
}

async function main(argv) {
  const known = new Set(['--skip-wsl', '--clef'])
  const bad = argv.filter(a => !known.has(a))
  if (bad.length) {
    console.log('usage: node tools/doctor.mjs [--skip-wsl] [--clef]')
    return 2
  }
  const home = homeDir()
  const S = stateDir(home)
  console.log(`bend-guard doctor (home ${home}, state folder ${S})`)
  checkNode()
  checkLayout(home)
  checkInstalledCopy(home)
  if (argv.includes('--skip-wsl')) {
    skipped('WSL', '--skip-wsl')
    skipped('bend', '--skip-wsl')
  } else if (await checkWsl()) await checkBend()
  else skipped('bend', 'needs the WSL distro first')
  const o = checkApproved(S)
  if (o) {
    checkPolicy(S, o)
    checkProjects(o)
  }
  checkKey(home)
  if (argv.includes('--clef')) await checkClef(home)
  for (const l of lines) console.log(l)
  console.log(problems === 0 ? 'No problems found.' : `${problems} problem${problems === 1 ? '' : 's'} found.`)
  return problems === 0 ? 0 : 1
}

main(process.argv.slice(2)).then(
  code => process.exit(code),
  err => {
    console.log(`doctor failed unexpectedly: ${short(err, 300)}`)
    process.exit(1)
  },
)
