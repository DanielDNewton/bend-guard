// bend-guard: which commands should Bend learn next? (plan Task 4.6)
//
// Reads the log files bend-guard writes, one tab-separated line per checked
// call: %USERPROFILE%\.claude\bend-guard\log\<date>.<session>.tsv, one file per
// session and UTC day (older logs: <date>.tsv). The columns are LOG_HEADER in
// hooks/glue.ts. It keeps the calls bend-guard did not
// understand, groups them by the command's first word (plus the subcommand
// for git and npm) and prints the most common groups, with how often Clef
// said safe, unsure or risky about them.
//
//   node suggest.mjs [--top 20] [--days N] [--dir <log folder>]
//
// Example: jq came up 41 times and Clef said safe 39 times, so jq is the first
// command to teach Bend. Calls inside a subagent, or by a tool other than Bash,
// PowerShell or Monitor, are counted too, but Clef is not asked about them.
//
// It reads the *.tsv files of that one folder and nothing else. It never opens
// openrouter.key or anything else in the state folder. Run it in your own
// terminal: bend-guard keeps Claude out of the state folder.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const DEFAULT_DIR = path.join(os.homedir(), '.claude', 'bend-guard', 'log')

// The columns, in the order hooks/glue.ts LOG_HEADER writes them. A header line
// in a file wins over this list, so a column added later does not break this.
const COLUMNS = ['time', 'session', 'agent', 'tool', 'verdict', 'enforceVerdict', 'reason', 'clefAsked', 'clefAnswer', 'latencyMs', 'cacheHit', 'command']

// Clef's limits per thousand: the starting values in bend/core/Guard.bend
// (T_TRIAGE, T_VETO, T_UNSURE). At or above RISKY, bend-guard refuses an
// unknown command. At or above MAYBE_RISKY or UNSURE, it asks.
const RISKY = 800
const MAYBE_RISKY = 500
const UNSURE = 300

const SHELL_TOOLS = new Set(['Bash', 'PowerShell', 'Monitor'])
const GIT_SKIPS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace']) // options that take the next word
const NPM_SKIPS = new Set(['--prefix'])

function usage(message) {
  const out = message ? console.error : console.log
  if (message) out(`suggest: ${message}`)
  out('usage: node suggest.mjs [--top 20] [--days N] [--dir <log folder>]')
  process.exit(message ? 2 : 0)
}

function parseArgs(argv) {
  const opts = { top: 20, days: 0, dir: DEFAULT_DIR }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const whole = () => {
      const n = Number(argv[++i])
      if (!Number.isInteger(n) || n < 1) usage(`${a} needs a whole number, 1 or more`)
      return n
    }
    if (a === '--top') opts.top = whole()
    else if (a === '--days') opts.days = whole()
    else if (a === '--dir') {
      if (i + 1 >= argv.length) usage('--dir needs a folder')
      opts.dir = argv[++i]
    } else if (a === '-h' || a === '--help') usage()
    else usage(`unknown option ${a}`)
  }
  return opts
}

// logLine in hooks/glue.ts writes \\ for a backslash, \t, \r and \n.
function unesc(s) {
  return s.replace(/\\([\\trn])/g, (_, c) => (c === 't' ? '\t' : c === 'r' ? '\r' : c === 'n' ? '\n' : '\\'))
}

// The files of the newest `days` dates if days is set (the date is the first
// 10 characters of a name; each session of a day has its own file). Only
// *.tsv files are opened.
function readLogs(dir, days) {
  let names
  try {
    names = fs.readdirSync(dir).filter(n => n.toLowerCase().endsWith('.tsv')).sort()
  } catch {
    return null
  }
  if (days > 0) {
    const dates = [...new Set(names.map(n => n.slice(0, 10)))].sort().slice(-days)
    names = names.filter(n => dates.includes(n.slice(0, 10)))
  }
  const rows = []
  let skipped = 0
  for (const name of names) {
    let text
    try {
      text = fs.readFileSync(path.join(dir, name), 'utf8').replace(/^﻿/, '')
    } catch {
      continue
    }
    let cols = COLUMNS
    for (const raw of text.split('\n')) {
      const line = raw.replace(/\r$/, '')
      if (line.trim() === '') continue
      const f = line.split('\t')
      if (f[0] === 'time') {
        if (f.includes('reason') && f.includes('command')) cols = f
        continue
      }
      if (f.length !== cols.length) {
        skipped++
        continue
      }
      const row = {}
      cols.forEach((c, i) => {
        row[c] = unesc(f[i])
      })
      rows.push(row)
    }
  }
  return { names, rows, skipped }
}

// The text inside "not understood (...)" in a reason, with balanced brackets.
function whyOf(reason) {
  const open = 'not understood ('
  const i = reason.indexOf(open)
  if (i < 0) return null
  const start = i + open.length
  let depth = 1
  let j = start
  for (; j < reason.length && depth > 0; j++) {
    if (reason[j] === '(') depth++
    else if (reason[j] === ')') depth--
  }
  return (depth === 0 ? reason.slice(start, j - 1) : reason.slice(start)).trim()
}

const CLEF_REFUSED = 'rates this command as risky'

// A call bend-guard did not understand, or one that Clef refused for that reason.
// A line starting "at call:" repeats a call already logged at check time.
function unknownWhy(row) {
  if (row.reason.startsWith('at call:')) return null
  const why = whyOf(row.reason)
  if (why !== null) return why || 'not understood'
  if (row.reason.includes(CLEF_REFUSED)) return 'Clef rated it risky'
  return null
}

// "cd dir && jq ." is about jq, not cd: leave leading cd steps out.
function wordsOf(command) {
  let s = command.trim()
  for (let k = 0; k < 5; k++) {
    const m = /^cd\s+(?:"[^"]*"|'[^']*'|[^\s;&|]+)\s*(?:&&|;)\s*/i.exec(s)
    if (!m) break
    s = s.slice(m[0].length)
  }
  const words = s.split(/\s+/).filter(Boolean)
  if (words[0] === '&' && words.length > 1) words.shift() // PowerShell call operator
  return words
}

function subcommand(words, skips) {
  for (let i = 1; i < words.length; i++) {
    if (skips.has(words[i])) {
      i++
      continue
    }
    if (!words[i].startsWith('-')) return words[i]
  }
  return ''
}

// The group a call belongs to: the first word, plus the subcommand for git and npm.
function groupOf(row) {
  if (!SHELL_TOOLS.has(row.tool)) return `${row.tool} (tool)`
  const words = wordsOf(row.command)
  if (words.length === 0) return `(empty ${row.tool} command)`
  let first = words[0].replace(/^.*[\\/]/, '') || words[0] // c:\tools\jq.exe -> jq.exe
  const assign = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(first)
  if (assign) first = `${assign[1]}=...` // VAR=value cmd: one group per variable, not per value
  if (row.tool === 'PowerShell') first = first.toLowerCase()
  const lower = first.toLowerCase()
  let key = first
  if (lower === 'git') key = `git ${subcommand(words, GIT_SKIPS)}`.trim()
  else if (lower === 'npm') key = `npm ${subcommand(words, NPM_SKIPS)}`.trim()
  return row.tool === 'Bash' ? key : `${key} [${row.tool}]`
}

// 'safe', 'unsure', 'risky' or 'none' (asked, no usable answer); null when Clef was not asked.
function clefBucket(row) {
  if (row.clefAsked !== 'yes') return null
  const m = /risky=(\d+)\s+unsure=(\d+)/.exec(row.clefAnswer)
  if (!m) return 'none'
  const risky = Number(m[1])
  const unsure = Number(m[2])
  if (risky >= RISKY) return 'risky'
  if (risky >= MAYBE_RISKY || unsure >= UNSURE) return 'unsure'
  return 'safe'
}

function main() {
  const opts = parseArgs(process.argv.slice(2))
  const logs = readLogs(opts.dir, opts.days)
  if (!logs) {
    console.log(`suggest: no log folder at ${opts.dir}`)
    console.log('bend-guard writes one line per checked call once it is running in an approved project.')
    return
  }
  if (logs.names.length === 0) {
    console.log(`suggest: no .tsv log files in ${opts.dir} yet.`)
    return
  }

  const verdicts = { allow: 0, ask: 0, deny: 0 }
  const groups = new Map()
  let unknown = 0
  for (const row of logs.rows) {
    if (row.verdict in verdicts) verdicts[row.verdict]++
    const why = unknownWhy(row)
    if (why === null) continue
    unknown++
    const key = groupOf(row)
    let g = groups.get(key)
    if (!g) groups.set(key, (g = { key, count: 0, clef: { safe: 0, unsure: 0, risky: 0, none: 0 }, whys: new Map() }))
    g.count++
    const bucket = clefBucket(row)
    if (bucket) g.clef[bucket]++
    g.whys.set(why, (g.whys.get(why) || 0) + 1)
  }

  const first = logs.names[0].slice(0, 10)
  const last = logs.names[logs.names.length - 1].slice(0, 10)
  console.log(`bend-guard suggest: read ${logs.rows.length} log lines from ${logs.names.length} file(s), ${first} to ${last}.`)
  console.log(`Verdicts: ${verdicts.allow} allow, ${verdicts.ask} ask, ${verdicts.deny} deny.${logs.skipped ? ` (${logs.skipped} damaged line(s) skipped.)` : ''}`)
  if (unknown === 0) {
    console.log('No calls that bend-guard did not understand. Nothing to teach Bend.')
    return
  }
  console.log(`${unknown} call(s) were not understood, in ${groups.size} group(s). The most common ${Math.min(opts.top, groups.size)}:`)
  console.log('')

  const top = [...groups.values()].sort((a, b) => b.count - a.count || (a.key < b.key ? -1 : 1)).slice(0, opts.top)
  const width = Math.min(34, Math.max(7, ...top.map(g => g.key.length)))
  const cut = (s, n) => (s.length > n ? s.slice(0, n - 3) + '...' : s)
  console.log(`${'#'.padStart(3)}  ${'command'.padEnd(width)}  ${'times'.padStart(5)}  ${'safe'.padStart(4)}  ${'unsure'.padStart(6)}  ${'risky'.padStart(5)}  ${'no answer'.padStart(9)}  usual reason`)
  top.forEach((g, i) => {
    const usual = [...g.whys.entries()].sort((a, b) => b[1] - a[1])[0][0]
    console.log(
      `${String(i + 1).padStart(3)}  ${cut(g.key, width).padEnd(width)}  ${String(g.count).padStart(5)}  ${String(g.clef.safe).padStart(4)}  ${String(g.clef.unsure).padStart(6)}  ${String(g.clef.risky).padStart(5)}  ${String(g.clef.none).padStart(9)}  ${cut(usual, 60)}`,
    )
  })
  console.log('')
  console.log('safe, unsure, risky and no answer count only the calls Clef was asked about.')
  console.log('Clef is not asked in subagents or for tools other than Bash, PowerShell and Monitor.')
  console.log('Teach Bend the top lines first, most of all those Clef calls safe every time.')
}

main()
