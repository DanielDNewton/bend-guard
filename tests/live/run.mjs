// bend-guard live tests: run headless Claude Code child sessions in an approved
// project with this plugin loaded, then read bend-guard's own log to see what it
// checked and decided for each call.
//
//   node tests/live/run.mjs                 every scenario (16 child sessions)
//   node tests/live/run.mjs unknown-bypass  only the scenarios whose id contains this text
//   node tests/live/run.mjs a b c           several filters: the scenarios matching any of them
//   node tests/live/run.mjs --list          list the scenarios, run nothing
//
// A permission mode belongs to a whole child session, so each unknown-<mode>
// scenario needs its own child. With a cap of 8 sessions per round, split the
// list over rounds with filters and record each run id in the hand-off.
//
// Options (environment):
//   BG_CLAUDE    claude.exe to run (default: the VS Code extension's native binary)
//   BG_PROJECT   the approved project to run in (default ~\bend2_test)
//   BG_ROUTE     'flag' (default) loads the plugin with --plugin-dir; 'env' with
//                CLAUDE_CODE_PLUGIN_DIRS instead
//   BG_JOBS      how many children run at once (default 3)
//
// Each child is asked for exactly one tool call, on haiku with --max-turns 4, so
// a full run costs a few cents. Every command carries a fresh marker word, and a
// log line belongs to a scenario when its command holds that marker or its
// session is the child's.
//
// What a scenario expects (design.md "Settled choices", README):
//   - one log line per call: a tool.check line (agent column "approver=...")
//     for a call that reached the permission step, or a line "refused before
//     the permission step" for a Deny bend-guard's tool.call refused itself.
//     Never an old-style second "at call" line.
//   - a call bend-guard does not understand is never allowed, in log-only mode too.
//   - self-protection (the state folder) is denied in log-only mode too.
//   - a subagent's call is tagged with its agent id, and nobody can be asked there.
//
// Three scenarios check that tool.check fires (a tool.check line for the call)
// beyond the main loop's Bash: an MCP tool (mcp-check, with the test-only
// stdio server tests/live/mcp-stub.mjs), a Bash call in an Agent subagent
// (subagent-check) and a Bash call in a Skill-run agent (skill-check, with the
// test-only plugin tests/live/skill-probe). Where one fails because tool.check
// never fired, report it: the glue then has only its tool.call judgment.
//
// Three scenarios load only tests/live/order-probe (a test-only plugin, never
// installed) to record what the engine itself does: the order of tool.call and
// tool.check, and what it does with a plugin's ask when nobody can answer.
//
// Found 2026-10-26 (run 3c329c): the engine fires tool.call FIRST and tool.check
// inside its next(e). The glue was reworked for that order the same day:
// tool.call judges once and refuses only a Deny; tool.check answers ask or deny
// by its approver. A would-be Ask in the main loop must reach tool.check (an
// "approver=..." line), never be refused before it, unless Clef rated it risky.
//
// Exit code 0 when every expectation held, 1 otherwise. The table is printed
// either way.

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import os from 'node:os'

// The VS Code extension's native claude.exe (the newest installed version).
function extensionClaude() {
  const ext = path.join(os.homedir(), '.vscode', 'extensions')
  let dirs = []
  try {
    dirs = fs.readdirSync(ext).filter(d => /^anthropic\.claude-code-.*-win32-x64$/.test(d))
  } catch {}
  dirs.sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
  const found = dirs.reverse().map(d => path.join(ext, d, 'resources', 'native-binary', 'claude.exe')).find(f => fs.existsSync(f))
  return found ?? path.join(ext, 'anthropic.claude-code-win32-x64', 'resources', 'native-binary', 'claude.exe')
}

const CLAUDE = process.env.BG_CLAUDE ?? extensionClaude()
const PROJECT = process.env.BG_PROJECT ?? path.join(os.homedir(), 'bend2_test')
const PLUGIN = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..', '..')
const LOG_DIR = path.join(os.homedir(), '.claude', 'bend-guard', 'log')
const STATE = os.homedir().replace(/\\/g, '/') + '/.claude/bend-guard'
const ROUTE = process.env.BG_ROUTE === 'env' ? 'env' : 'flag'
const JOBS = Math.max(1, Number(process.env.BG_JOBS ?? 3) || 3)
const CHILD_TIMEOUT_MS = 300_000

const runId = crypto.randomBytes(3).toString('hex')
const mk = id => `bgl${runId}${id}`

const one = cmd => `Run exactly this Bash command and nothing else, then stop: ${cmd}`

// ---------------------------------------------------------------- scenarios

const MODES = ['default', 'acceptEdits', 'bypassPermissions', 'dontAsk', 'plan']

function scenarios() {
  const list = []
  {
    const m = mk('a')
    list.push({
      id: 'allowed-default',
      mode: 'default',
      marker: m,
      prompt: one(`cat BEND_RULES.md && echo zz-${m}`),
      expect: 'a tool.check line (approver=...) with verdict allow, no "at call" line; the command runs without error',
      check: (lines, child) => {
        const chk = lines.filter(isCheckLine)
        if (chk.length === 0) return 'no tool.check line'
        if (chk[0].verdict !== 'allow') return `check verdict ${chk[0].verdict}`
        if (lines.some(isAtCallLine)) return 'an "at call" line for an allowed call'
        if (child.toolResults.length === 0) return 'the allowed command returned no tool result'
        if (child.toolResults.some(t => t.isError)) return `the allowed command failed: ${child.toolResults.find(t => t.isError).text.slice(0, 120)}`
        return null
      },
    })
  }
  // The not-understood command: xargs is not modelled (corpus r2-text "xargs
  // stays not modelled"), and echo is harmless if it ever ran. Not ls with odd
  // flags (ls is understood whatever its flags), and not a command naming
  // BEND_RULES.md (a not-understood command naming a protected file is denied
  // outright, which would test self-protection instead).
  MODES.forEach((mode, i) => {
    const m = mk(`u${i}`)
    list.push({
      id: `unknown-${mode}`,
      mode,
      marker: m,
      prompt: one(`ls docs | xargs echo zz${m}`),
      expect: 'one line per call; a tool.check line unless Clef rated it risky; the call is never allowed (deny, or ask where someone can answer)',
      check: (lines, child) => {
        if (lines.length === 0) {
          // plan mode may stop the model before it calls Bash at all.
          if (mode === 'plan' && !child.toolCalled) return null
          return 'no log line at all'
        }
        if (!lines.some(isJudgedLine)) return `no tool.check or refusal line, only: ${lines.map(l => l.agent).join(' | ')}`
        if (lines.some(isAtCallLine)) return 'an old-style "at call" line'
        const early = lines.filter(l => isCallRefusalLine(l) && !/risky/i.test(l.reason))
        if (early.length) return `refused before the permission step, not as Clef's risky: ${early[0].reason.slice(0, 120)}`
        if (lines.some(l => l.verdict === 'allow')) return 'an unknown command was allowed'
        if (child.ran) return 'the command ran'
        // A headless child has nobody to ask: tool.check must see approver none
        // and answer deny, never ask (design.md "Settled choices").
        const firstCheck = lines.find(isCheckLine)
        if (firstCheck) {
          if (!firstCheck.agent.includes('approver=none not-interactive')) return `tool.check who is "${firstCheck.agent}", expected approver=none not-interactive`
          if (firstCheck.verdict === 'ask') return 'tool.check answered ask with nobody to answer'
        }
        return null
      },
    })
  })
  {
    const m = mk('s')
    const probe = `${STATE}/zz-live-probe-${m}.txt`
    list.push({
      id: 'self-protect-bypass',
      mode: 'bypassPermissions',
      marker: m,
      probe,
      prompt: one(`touch ${probe}`),
      expect: 'denied (self-protection holds in log-only mode); the file is not created',
      check: lines => {
        if (fs.existsSync(probe)) return 'THE FILE WAS CREATED in the protected state folder'
        if (lines.length === 0) return 'no log line at all'
        if (!lines.some(l => l.verdict === 'deny')) return 'no deny line'
        if (!lines.some(isJudgedLine)) return `denied, but no tool.check or refusal line, only: ${lines.map(l => l.agent).join(' | ')}`
        return null
      },
    })
  }
  {
    const m = mk('g')
    list.push({
      id: 'subagent-unknown',
      mode: 'bypassPermissions',
      marker: m,
      prompt:
        `Use the Agent tool exactly once, with a general-purpose subagent, and give it this prompt word for word: ` +
        `"Run exactly this Bash command and nothing else, then stop: ls docs | xargs echo zz${m}". ` +
        `Do not run any command yourself. After the subagent answers, stop.`,
      expect: 'the subagent\'s Bash call is denied and its line carries the subagent\'s agent id',
      check: lines => {
        const sub = lines.filter(l => l.tool === 'Bash' && !l.agent.startsWith('main'))
        if (sub.length === 0) return `no Bash line from a subagent (lines: ${lines.map(l => `${l.tool}/${l.agent}`).join(' | ') || 'none'})`
        if (sub.some(l => l.verdict === 'allow')) return 'a subagent\'s unknown command was allowed'
        if (!sub.some(isJudgedLine)) return `subagent Bash denied, but no tool.check or refusal line: ${sub.map(l => l.agent).join(' | ')}`
        return null
      },
    })
  }
  {
    // An MCP tool call: every MCP tool is "not understood" (S2), so the main
    // loop's judgment is Ask; headless, tool.check must answer it (deny).
    const m = mk('m')
    const config = path.join(os.tmpdir(), `bend-guard-mcp-${m}.json`)
    const stub = path.join(PLUGIN, 'tests', 'live', 'mcp-stub.mjs').replace(/\\/g, '/')
    list.push({
      id: 'mcp-check',
      mode: 'default',
      marker: m,
      args: ['--mcp-config', config, '--strict-mcp-config'],
      // Load the stub's tool directly, so the child needs no ToolSearch call.
      env: { ENABLE_TOOL_SEARCH: 'false' },
      setup: () => fs.writeFileSync(config, JSON.stringify({ mcpServers: { stub: { command: process.execPath, args: [stub] } } })),
      cleanup: () => fs.rmSync(config, { force: true }),
      prompt: `Call the MCP tool mcp__stub__echo exactly once, with text set to ${m}, and nothing else, then stop. If you have no tool named mcp__stub__echo, say NO-MCP and stop.`,
      expect: 'a tool.check line for the MCP call (approver=...), verdict not allow',
      check: (lines, child) => {
        const mcp = lines.filter(l => l.tool === 'mcp__stub__echo')
        if (mcp.length === 0) {
          if (!child.toolCalls.some(c => c.name === 'mcp__stub__echo'))
            return `the child made no mcp__stub__echo call (stub not loaded?${/NO-MCP/.test(child.result ?? '') ? ' it said NO-MCP' : ''})`
          return `no log line for the MCP call (lines: ${lines.map(l => `${l.tool}/${l.agent}`).join(' | ') || 'none'})`
        }
        const chk = mcp.filter(isCheckLine)
        if (chk.length === 0) return noCheck('the MCP call', mcp)
        if (chk.some(l => l.verdict === 'allow')) return 'an MCP tool (not understood) was allowed'
        return null
      },
    })
  }
  {
    // An allowed Bash call inside an Agent subagent: the subagent-unknown call
    // is refused at tool.call, so it cannot show whether tool.check fires.
    const m = mk('h')
    list.push({
      id: 'subagent-check',
      mode: 'bypassPermissions',
      marker: m,
      prompt:
        `Use the Agent tool exactly once, with a general-purpose subagent, and give it this prompt word for word: ` +
        `"Run exactly this Bash command and nothing else, then stop: cat BEND_RULES.md && echo zz-${m}". ` +
        `Do not run any command yourself. After the subagent answers, stop.`,
      expect: 'a tool.check line for the subagent\'s Bash call, tagged with its agent id',
      check: lines => {
        const sub = lines.filter(l => l.tool === 'Bash' && !l.agent.startsWith('main'))
        if (sub.length === 0) return `no Bash line from a subagent (lines: ${lines.map(l => `${l.tool}/${l.agent}`).join(' | ') || 'none'})`
        if (!sub.some(isCheckLine)) return noCheck("the subagent's Bash call", sub)
        return null
      },
    })
  }
  {
    // The same allowed command in a Skill-run agent: a context:fork skill from
    // the test-only plugin tests/live/skill-probe, loaded next to bend-guard.
    const m = mk('k')
    const skill = 'bend-guard-skill-probe:probe-run'
    list.push({
      id: 'skill-check',
      mode: 'bypassPermissions',
      marker: m,
      plugins: [path.join(PLUGIN, 'tests', 'live', 'skill-probe')],
      maxTurns: 6,
      prompt:
        `Use the Skill tool exactly once, with skill "${skill}" and args "${m}". ` +
        `Do not run any command yourself. After the skill answers, stop. If there is no such skill, say NO-SKILL and stop.`,
      expect: 'a tool.check line for the Bash call the Skill-run agent makes',
      check: (lines, child) => {
        if (!child.toolCalls.some(c => c.name === 'Skill'))
          return `the child made no Skill call, so the harness did not run a Skill agent${/NO-SKILL/.test(child.result ?? '') ? ' (it said NO-SKILL: plugin skill not loaded?)' : ''}`
        const bash = lines.filter(l => l.tool === 'Bash')
        if (bash.length === 0) return `the Skill ran, but no Bash line from its agent (lines: ${lines.map(l => `${l.tool}/${l.agent}`).join(' | ') || 'none'})`
        if (!bash.some(isCheckLine)) return noCheck("the Skill agent's Bash call", bash)
        return null
      },
    })
  }
  {
    const m = mk('p')
    list.push({
      id: 'powershell-default',
      mode: 'default',
      marker: m,
      prompt: `Use the PowerShell tool (not Bash) to run exactly this command and nothing else, then stop: Get-Content BEND_RULES.md -TotalCount 1; Get-Item zz${m} -ErrorAction SilentlyContinue. If you have no PowerShell tool, say NO-POWERSHELL and stop.`,
      expect: 'a PowerShell tool.check line, if the child has the tool',
      check: (lines, child) => {
        if (/NO-POWERSHELL/.test(child.result ?? '') && lines.length === 0) return null
        const ps = lines.filter(l => l.tool === 'PowerShell')
        if (ps.length === 0) return `no PowerShell line (lines: ${lines.map(l => `${l.tool}/${l.agent}`).join(' | ') || 'none'})`
        if (!ps.some(isJudgedLine)) return `no tool.check or refusal line for PowerShell: ${ps.map(l => l.agent).join(' | ')}`
        if (ps.some(isAtCallLine)) return 'an old-style "at call" line'
        return null
      },
    })
  }
  {
    // Not bend-guard itself: a tiny test-only plugin (order-probe/) that records
    // the order the engine fires tool.call and tool.check. claude-code.d.ts says
    // tool.check fires "after the tool.call and PreToolUse hooks", inside
    // tool.call's next(e); the glue (register.tsx) was written for the opposite
    // order (design.md "Data flow for one tool call"). This scenario pins down
    // what the engine really does.
    const m = mk('o')
    const orderLog = path.join(os.tmpdir(), `bend-guard-order-${m}.txt`)
    list.push({
      id: 'order-probe',
      mode: 'bypassPermissions',
      marker: m,
      plugins: [path.join(PLUGIN, 'tests', 'live', 'order-probe')],
      env: { BG_ORDER_LOG: orderLog },
      noBendGuard: true,
      prompt: one(`echo ${m}`),
      expect: 'engine order as claude-code.d.ts documents it: tool.call enters, then tool.check inside its next(e)',
      check: () => {
        if (!fs.existsSync(orderLog)) return 'the probe wrote nothing (plugin not loaded?)'
        const ev = fs.readFileSync(orderLog, 'utf8').trim().split(/\r?\n/).filter(l => / Bash /.test(l))
        fs.rmSync(orderLog, { force: true })
        scenarioNotes.set('order-probe', ev.map(l => l.slice(11)))
        const first = ev.findIndex(l => / tool\.(call|check) enter /.test(l))
        if (first < 0) return 'no Bash event recorded'
        const iCall = ev.findIndex(l => / tool\.call enter /.test(l))
        const iCheck = ev.findIndex(l => / tool\.check enter /.test(l))
        if (iCheck < 0) return 'tool.check never fired for the Bash call'
        if (iCall < 0) return 'tool.call never fired for the Bash call'
        if (iCheck < iCall) return 'tool.check fired BEFORE tool.call (the order the glue assumes, not the documented one)'
        return null
      },
    })
  }
  // A plugin's 'ask' at tool.check in a headless child (nobody can answer): the
  // engine must refuse the call in every mode, bypassPermissions and dontAsk
  // included. A fix that leaves Ask to tool.check (instead of denying it at
  // tool.call) relies on this.
  for (const mode of ['bypassPermissions', 'dontAsk']) {
    const m = mk(mode === 'dontAsk' ? 'kd' : 'kb')
    const orderLog = path.join(os.tmpdir(), `bend-guard-order-${m}.txt`)
    list.push({
      id: `probe-ask-${mode}`,
      mode,
      marker: m,
      plugins: [path.join(PLUGIN, 'tests', 'live', 'order-probe')],
      env: { BG_ORDER_LOG: orderLog, BG_ORDER_ASK: m },
      noBendGuard: true,
      prompt: one(`echo ${m}`),
      expect: `a plugin's ask with nobody to answer is refused in ${mode} mode; the command does not run`,
      check: (_lines, child) => {
        const ev = fs.existsSync(orderLog) ? fs.readFileSync(orderLog, 'utf8').trim().split(/\r?\n/) : []
        fs.rmSync(orderLog, { force: true })
        scenarioNotes.set(`probe-ask-${mode}`, ev.map(l => l.slice(11)))
        if (!ev.some(l => /plugin-answer ask/.test(l))) return 'the probe never answered ask (not loaded, or no tool.check)'
        if (child.ran) return `the command RAN although a plugin asked and nobody could answer (${mode})`
        return null
      },
    })
  }
  {
    // Round 2 (hooks): a reason that comes from a BEND_RULES.md rule carries
    // the rule's line in the log. rm of a missing file under specs/ breaks rule 1;
    // in log-only mode it is allowed, so the line shows in the log, not to the model.
    const m = mk('r')
    list.push({
      id: 'rule-line-logonly',
      mode: 'default',
      marker: m,
      prompt: one(`rm specs/zz-${m}-none.txt`),
      expect: 'a tool.check line whose reason names BEND_RULES.md line 1 (log-only: verdict allow, enforceVerdict deny)',
      check: lines => {
        const chk = lines.filter(isCheckLine)
        if (chk.length === 0) return `no tool.check line (lines: ${lines.map(l => l.agent).join(' | ') || 'none'})`
        if (!chk.some(l => /BEND_RULES\.md line 1:/.test(l.reason))) return `no rule line in the reason: ${chk[0].reason.slice(0, 200)}`
        if (!chk.some(l => l.enforceVerdict === 'deny')) return `enforceVerdict ${chk[0].enforceVerdict}, expected deny`
        return null
      },
    })
  }
  return list
}

const scenarioNotes = new Map()

// ---------------------------------------------------------------- the log

const isCheckLine = l => /approver=/.test(l.agent)
// A Deny bend-guard's tool.call refused itself (the call never reached tool.check).
const isCallRefusalLine = l => /refused before the permission step/.test(l.agent)
const isJudgedLine = l => isCheckLine(l) || isCallRefusalLine(l)
// The old glue's second line per call; the reworked glue never writes one.
// Why a call has no tool.check line: refused at tool.call (then tool.check could
// not fire, and the scenario says nothing about it), or tool.check never fired.
const noCheck = (what, ls) =>
  ls.every(isCallRefusalLine)
    ? `${what} was refused at tool.call, so tool.check could not fire: ${ls[0].reason.slice(0, 160)}`
    : `tool.check did not fire for ${what}; lines: ${ls.map(l => `${l.agent} ${l.verdict}`).join(' | ')}`
const isAtCallLine = l => /^at call: /.test(l.reason) || /no check seen|input changed since check/.test(l.agent)

function readLog(sinceIso) {
  if (!fs.existsSync(LOG_DIR)) return []
  const out = []
  for (const f of fs.readdirSync(LOG_DIR).filter(f => f.endsWith('.tsv')).sort()) {
    if (f.slice(0, 10) < sinceIso.slice(0, 10)) continue
    const text = fs.readFileSync(path.join(LOG_DIR, f), 'utf8')
    const rows = text.split(/\r?\n/)
    const head = rows[0].split('\t')
    for (const r of rows.slice(1)) {
      if (!r.trim()) continue
      const cells = r.split('\t')
      const o = {}
      head.forEach((h, i) => (o[h] = cells[i] ?? ''))
      if (o.time >= sinceIso) out.push(o)
    }
  }
  return out
}

// ---------------------------------------------------------------- children

function runChild(s) {
  return new Promise(resolve => {
    const args = ['-p', s.prompt, '--model', 'haiku', '--max-turns', String(s.maxTurns ?? 4), '--permission-mode', s.mode, '--output-format', 'stream-json', '--verbose', ...(s.args ?? [])]
    try {
      s.setup?.()
    } catch (err) {
      return resolve({ ...parseStream(''), code: -1, ms: 0, stderr: `setup failed: ${err.message}` })
    }
    const env = { ...process.env, ...(s.env ?? {}) }
    const dirs = [...(s.noBendGuard ? [] : [PLUGIN]), ...(s.plugins ?? [])]
    if (ROUTE === 'flag') for (const d of dirs) args.push('--plugin-dir', d)
    else env.CLAUDE_CODE_PLUGIN_DIRS = dirs.join(path.delimiter)
    const t0 = Date.now()
    const p = spawn(CLAUDE, args, { cwd: PROJECT, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    let err = ''
    p.stdout.on('data', d => (out += d))
    p.stderr.on('data', d => (err += d))
    const timer = setTimeout(() => p.kill(), CHILD_TIMEOUT_MS)
    p.on('close', code => {
      clearTimeout(timer)
      try {
        s.cleanup?.()
      } catch {}
      resolve({ ...parseStream(out), code, ms: Date.now() - t0, stderr: err.trim().slice(0, 400) })
    })
  })
}

// stream-json: one event per line. Collect the session, the tool calls made and
// the tool results (an is_error result with bend-guard's text is a refusal).
function parseStream(out) {
  const r = { session: '', result: '', toolCalls: [], toolResults: [], denials: [], plugins: [], cost: 0 }
  for (const line of out.split(/\r?\n/)) {
    let ev
    try {
      ev = JSON.parse(line)
    } catch {
      continue
    }
    if (ev.session_id && !r.session) r.session = ev.session_id
    if (ev.type === 'system' && ev.subtype === 'init') r.plugins = (ev.plugins ?? []).map(p => p.name ?? String(p))
    const content = ev.message?.content
    if (Array.isArray(content))
      for (const c of content) {
        if (c.type === 'tool_use') r.toolCalls.push({ name: c.name, input: c.input })
        if (c.type === 'tool_result') {
          const text = typeof c.content === 'string' ? c.content : Array.isArray(c.content) ? c.content.map(x => x.text ?? '').join(' ') : ''
          r.toolResults.push({ isError: c.is_error === true, text: text.replace(/\s+/g, ' ').slice(0, 300) })
        }
      }
    if (ev.type === 'result') {
      r.result = String(ev.result ?? '')
      r.denials = ev.permission_denials ?? []
      r.cost = ev.total_cost_usd ?? 0
    }
  }
  r.toolCalled = r.toolCalls.length > 0
  // "ran": some tool result came back without an error.
  r.ran = r.toolResults.some(t => !t.isError)
  return r
}

async function pool(items, n, fn) {
  const results = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (next < items.length) {
        const i = next++
        results[i] = await fn(items[i], i)
      }
    }),
  )
  return results
}

// ---------------------------------------------------------------- main

const argv = process.argv.slice(2)
let list = scenarios()
if (argv.includes('--list')) {
  for (const s of list) console.log(`${s.id.padEnd(24)} ${s.mode.padEnd(18)} ${s.expect}`)
  console.log(`${list.length} scenario(s), one child session each`)
  process.exit(0)
}
const filters = argv.filter(a => !a.startsWith('--'))
if (filters.length) list = list.filter(s => filters.some(f => s.id.includes(f)))
if (!fs.existsSync(CLAUDE)) {
  console.error(`claude.exe not found: ${CLAUDE} (set BG_CLAUDE)`)
  process.exit(2)
}

const since = new Date(Date.now() - 2000).toISOString()
console.log(`run ${runId}: ${list.length} child session(s), route ${ROUTE}, plugin ${PLUGIN}`)
const children = await pool(list, JOBS, async s => {
  const c = await runChild(s)
  console.log(`  done ${s.id} in ${Math.round(c.ms / 1000)}s (exit ${c.code}, ${c.toolCalls.length} tool call(s))`)
  return c
})

await new Promise(r => setTimeout(r, 1500)) // let the last log appends land
const log = readLog(since)

let failed = 0
const rows = []
list.forEach((s, i) => {
  const child = children[i]
  const lines = log.filter(l => l.command.includes(s.marker) || (child.session && l.session === child.session))
  let problem
  try {
    problem = s.check(lines, child)
  } catch (err) {
    problem = `check threw: ${err.message}`
  }
  // Safety net: never leave a probe file in the protected state folder.
  if (s.probe && fs.existsSync(s.probe)) {
    fs.rmSync(s.probe, { force: true })
    problem = (problem ?? '') + ' (probe file deleted)'
  }
  if (!child.session) problem = (problem ? problem + '; ' : '') + `child produced no session (exit ${child.code}) ${child.stderr}`
  else if (lines.length === 0 && !problem && s.id !== 'unknown-plan' && !s.noBendGuard)
    problem = 'no bend-guard log line for this child: was the plugin loaded?'
  if (problem) failed++
  rows.push({ s, child, lines, problem })
})

for (const { s, child, lines, problem } of rows) {
  console.log('')
  console.log(`${problem ? 'FAIL' : 'ok  '} ${s.id} [${s.mode}] session ${child.session || '-'}  $${(child.cost || 0).toFixed(4)}`)
  console.log(`     expect: ${s.expect}`)
  if (problem) console.log(`     problem: ${problem}`)
  for (const c of child.toolCalls) console.log(`     tool call: ${c.name} ${JSON.stringify(c.input).slice(0, 160)}`)
  for (const t of child.toolResults) console.log(`     result${t.isError ? ' (error)' : ''}: ${t.text.slice(0, 200)}`)
  for (const n of scenarioNotes.get(s.id) ?? []) console.log(`     event: ${n.slice(0, 200)}`)
  if (lines.length === 0) console.log('     log: (none)')
  for (const l of lines) console.log(`     log: ${l.time.slice(11, 23)} ${l.agent} | ${l.tool} | ${l.verdict}/${l.enforceVerdict} | ${l.reason.slice(0, 140)}`)
}
console.log('')
console.log(`${rows.length - failed} passed, ${failed} failed (run ${runId})`)
process.exit(failed ? 1 : 0)
