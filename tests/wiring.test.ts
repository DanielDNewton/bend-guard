// bend-guard wiring tests: hooks\register.tsx with the glue, checker and asks
// modules, run by Claude Code's own plugin test runner:
//   claude plugin test ~\.claude\local-plugins\bend-guard
// The world beneath the plugin (fs, process, clock, session) is tests\lib\kit.ts;
// the checker host is its fake policy. Expectations come from
// bend-guard's design notes, docs\design.md (components 6, 8, 10, 11,
// "Failure behaviour", "Settled choices", "Build notes").
//
// The engine's order (verified live, run 3467a4): tool.call fires first, and
// tool.check fires only inside tool.call's next(e), with the same tool_use_id;
// tool.call carries no approver. $.tool.call in this kit keeps that order. The
// tests marked "engine order" also play the permission step (kit engineSim), so
// bend-guard's tool.check sees the approver a real session gives. They are the
// regression tests for the 2026-10-26 rework for that order (the hooks had been
// written for the opposite one): tool.call judges once and refuses a Deny,
// tool.check answers ask or deny from the same judgment by its approver.

import { expect, test } from 'claude-code/testing'
import {
  A,
  ABSORB,
  APPROVE_MJS,
  ASK_NONE,
  CLEF_RISKY,
  CLEF_SAFE,
  ENGINE,
  HOME,
  HOST_ARGV,
  HOST_MJS,
  LOG_DIR,
  LOG_HEADER,
  LOG_PATH,
  NODE,
  PLUGIN,
  POLICY_TEXT,
  ROOT,
  ROOT_N,
  S,
  SESSION_ID,
  SLUG,
  SORT_LINE_1,
  SPECS_DENIED,
  SPECS_DENY,
  TOKEN_FILE,
  TURN,
  clefBody,
  defaultApproved,
  cwdsSent,
  hostAnswer,
  nextId,
  notUnderstood,
  refused,
  world,
} from './lib/kit'
import { sha256Hex } from '../hooks/sha256'
import { HOST_SOURCE } from '../hooks/checker'
import { CLEF_SESSION_CAP, QUESTIONS_VERSION, clefRequest } from '../hooks/clef'
import { HINTS, askFacts, explain, hintFor, meaningLines, namedNoChange, parseSortRules, ruleSuffix } from '../hooks/reasons'
import { placesOf, slugOf } from '../hooks/glue'

const START = { cwd: ROOT, surface: 'terminal', isInteractive: true }
const START_NOT_INTERACTIVE = { cwd: ROOT, surface: null, isInteractive: false }

// ---------------------------------------------------------------- activation

test('no approved.json: inactive, every hook passes and nothing is checked', async ($: any, on: any) => {
  const w = await world(on, { approved: null })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(r.deny).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'npm install left-pad' }, approver: 'person' })
  expect(c.decision).toBe('allow')
  expect(w.hostReqs.length).toBe(0)
  expect(w.writes.length).toBe(0)
  // a BEND_RULES.md that is not approved is named in a notice
  expect(w.toasts.join('\n')).toContain('BEND_RULES.md is not approved')
})

test('no approved.json and no BEND_RULES.md: inactive and silent', async ($: any, on: any) => {
  const w = await world(on, { approved: null, rulesMd: false })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Write', file_path: ROOT + '\\specs\\a.md', content: 'x' })
  expect(r.deny).toBeUndefined()
  expect(w.toasts.length).toBe(0)
  expect(w.hostReqs.length).toBe(0)
})

test('approved.json not JSON, BEND_RULES.md present: every call refused', async ($: any, on: any) => {
  const w = await world(on, { approved: '{ "version": 2, oops' })
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Read', input: { file_path: ROOT + '\\README.md' } })
  expect(c.decision).toBe('deny')
  expect(c.reason).toContain('approved.json is not valid')
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toBeDefined()
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostReqs.length).toBe(0)
  expect(w.toasts.join('\n')).toContain('refusing every tool call here')
})

test('approved.json of the wrong version, BEND_RULES.md present: every call refused', async ($: any, on: any) => {
  const w = await world(on, { approved: { version: 1, projects: {} } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('approved.json is not valid')
  expect(w.toolRuns.length).toBe(0)
})

test('approved.json exists but cannot be read, BEND_RULES.md present: every call refused', async ($: any, on: any) => {
  const w = await world(on, { approvedUnreadable: true })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('approved.json cannot be read')
  expect(w.toolRuns.length).toBe(0)
})

test('approved.json malformed, no BEND_RULES.md here or above: inactive', async ($: any, on: any) => {
  const w = await world(on, { approved: 'not json', rulesMd: false })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('policy.mjs does not match its fingerprint: every call refused, with the file named', async ($: any, on: any) => {
  const w = await world(on, { mjsSha256: 'a'.repeat(64) })
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Read', input: { file_path: ROOT + '\\README.md' }, approver: 'person' })
  expect(c.decision).toBe('deny')
  expect(c.reason).toContain('does not match its fingerprint')
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('does not match its fingerprint')
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostReqs.length).toBe(0)
  expect(w.toasts.join('\n')).toContain('refusing every tool call')
})

test('policy.mjs one byte changed after approval: refused', async ($: any, on: any) => {
  // approved.json records the hash of POLICY_TEXT; the file on disk differs by one byte
  const w = await world(on, { policyText: POLICY_TEXT + ' ', mjsSha256: await sha256Hex(POLICY_TEXT) })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('does not match its fingerprint')
  expect(w.toolRuns.length).toBe(0)
})

test('policy.mjs missing: every call refused', async ($: any, on: any) => {
  const w = await world(on, { policyText: null })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('cannot read')
  expect(w.toolRuns.length).toBe(0)
})

test('a policy folder with ".." in approved.json: every call refused', async ($: any, on: any) => {
  const w = await world(on, { policyDir: 'live\\..\\..\\elsewhere' })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toContain('not allowed')
  expect(w.toolRuns.length).toBe(0)
})

test('a session outside every approved project: inactive and silent', async ($: any, on: any) => {
  const w = await world(on, { cwd: HOME + '\\other' })
  await $.session.start({ cwd: HOME + '\\other', surface: 'terminal', isInteractive: true })
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(r.deny).toBeUndefined()
  expect(w.hostReqs.length).toBe(0)
  expect(w.toasts.length).toBe(0)
})

test('a session in a subfolder of the approved project is guarded', async ($: any, on: any) => {
  const sub = ROOT + '\\src'
  const w = await world(on, { cwd: sub })
  await $.session.start({ cwd: sub, surface: 'terminal', isInteractive: true })
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf ..\\specs' })
  expect(r.deny).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
  expect(w.toasts.join('\n')).toContain('guarding')
})

test('BEND_RULES.md changed since approval: a notice, and the old policy keeps guarding', async ($: any, on: any) => {
  const w = await world(on, { rulesMdText: '# Rules\n1. Never change specs/.\n2. new line\n' })
  await $.session.start(START)
  expect(w.toasts.join('\n')).toContain('changed since approval')
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ok.deny).toBeUndefined()
  const no = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(no.deny).toContain(SPECS_DENIED)
})

test('the start notice names the mode and a missing OpenRouter key', async ($: any, on: any) => {
  const w = await world(on, { logOnly: true })
  await $.session.start(START)
  const t = w.toasts.join('\n')
  expect(t).toContain('log-only')
  expect(t).toContain('No OpenRouter key')
})

test('the start notice says rules are enforced when not log-only, and nothing about a key that is there', async ($: any, on: any) => {
  const w = await world(on, { key: 'sk-or-v1-testkey0123456789' })
  await $.session.start(START)
  const t = w.toasts.join('\n')
  expect(t).toContain('rules enforced')
  expect(t).not.toContain('No OpenRouter key')
  expect(t).not.toContain('sk-or-v1-testkey0123456789')
})

test('after a hot reload (no session.start in this copy) the first hook loads the policy itself', async ($: any, on: any) => {
  const w = await world(on, { surfaces: ['terminal'] })
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(r.deny).toContain(SPECS_DENIED)
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ok.deny).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
  // and /bend-guard is registered again by that load
  expect(w.registered.some((e: any) => e.name === 'bend-guard')).toBe(true)
})

test('session.start registers /bend-guard even where bend-guard is inactive', async ($: any, on: any) => {
  const w = await world(on, { approved: null, rulesMd: false })
  await $.session.start(START)
  expect(w.registered.some((e: any) => e.name === 'bend-guard')).toBe(true)
})

// ---------------------------------------------------------------- checking

test('an Allow passes: the tool runs, and the checker host runs once for the call', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls -la', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
  expect(w.hostRuns.length).toBe(1)
})

test('the call sent to the checker is the Bend encoding of the event', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Grep', pattern: 'TODO', path: 'src', glob: ['*.ts', '*.tsx'], '-n': true, head_limit: 5 })
  const c = w.hostCalls()[0]
  expect(c.$).toBe('Call')
  expect(c.tool).toBe('Grep')
  expect(A(c.args)).toEqual([
    { $: 'Arg', key: 'pattern', value: 'TODO' },
    { $: 'Arg', key: 'path', value: 'src' },
    { $: 'Arg', key: 'glob', value: '*.ts' },
    { $: 'Arg', key: 'glob', value: '*.tsx' },
    { $: 'Arg', key: '-n', value: 'true' },
    { $: 'Arg', key: 'head_limit', value: '5' },
  ])
  expect(A(c.cwds)).toEqual([ROOT])
  expect(c.root).toBe(ROOT)
  expect(c.home).toBe(HOME)
  expect(c.links).toEqual({ $: 'Nil' })
  expect(c.agent).toBe(false)
  expect(c.mode).toBe('')
  expect(c.log_only).toBe(false)
  // tool_use_id never reaches the checker as an argument
  expect(A(c.args).some((a: any) => a.key === 'tool_use_id')).toBe(false)
})

test('the host is started by full node path, in the plugin folder, with the hashed policy text and no preload', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  const run = w.hostRuns[0]
  expect(run.argv).toEqual(HOST_ARGV)
  expect(run.argv[0]).toBe(NODE)
  expect(run.init.cwd).toBe(PLUGIN)
  expect(run.init.timeoutMs).toBeLessThanOrEqual(4000)
  expect(run.init.env).toEqual({ NODE_OPTIONS: '', NODE_PATH: '' })
  expect(w.hostReqs[0].policy).toBe(POLICY_TEXT)
})

// Backlog round 2, priority 3 A: an edit to host\host.mjs on disk cannot
// change a verdict, because the host program is built into checker.ts.
test('the checker runs HOST_SOURCE, not a file: no host.mjs is read or named, and checks still work', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  expect(w.files.has(HOST_MJS.toLowerCase())).toBe(false) // the kit's disk has no host.mjs
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  expect(refused(ok)).toBeUndefined()
  const no = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  expect(String(no.deny)).toContain(SPECS_DENIED)
  expect(w.hostRuns.length).toBe(2)
  for (const run of w.hostRuns) {
    expect(run.argv).toEqual([NODE, '--input-type=module', '-e', HOST_SOURCE])
    expect(run.argv.some((a: string) => /host\.mjs$/i.test(a))).toBe(false)
  }
  expect(w.reads.some(p => /host\.mjs$/i.test(p))).toBe(false)
  // the embedded text is the host program, backslashes as written
  expect(HOST_SOURCE.startsWith('// bend-guard: the checker host.')).toBe(true)
  expect(HOST_SOURCE).toContain("const url = 'data:text/javascript;base64,' + Buffer.from(req.policy, 'utf8').toString('base64')")
  expect(HOST_SOURCE).toContain("process.stdout.write(line + '\\n')")
  expect(HOST_SOURCE).toContain('docs\\build-brief.md of the bend2_test project')
  expect(HOST_SOURCE.endsWith("main().catch(err => fail('host: ' + short(err)))\n")).toBe(true)
})

test('a Deny is refused at tool.call: the tool never runs', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(r.deny).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
  const e = await $.tool.call({ tool: 'Edit', file_path: ROOT + '\\specs\\a.md', old_string: 'a', new_string: 'b' })
  expect(e.deny).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
})

test('a Deny at check wins over core allowing it beneath', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'rm -rf specs' }, approver: 'person' })
  expect(c.decision).toBe('deny')
  expect(w.checksBelow.length).toBe(0)
})

// ------------------------------------------------------------ engine order
// tool.call first; tool.check inside its next(e); see the header and kit engineSim.

const INSTALL_CMD = 'npm install left-pad'

test('engine order: a Deny is refused at tool.call; tool.check is never raised and the tool never runs', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  expect(typeof r.deny).toBe('string') // a tool.call hook's own refusal, not one from beneath
  expect(r.deny).toContain(SPECS_DENIED)
  expect(w.preToolUse.length).toBe(0)
  expect(w.engineChecks.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostRuns.length).toBe(1)
})

test('engine order: an Allow passes tool.call and tool.check, the tool runs, and the checker host runs once', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls -la', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  expect(w.engineChecks.length).toBe(1)
  expect(w.engineChecks[0].c.decision).toBe('allow')
  expect(w.toolRuns.length).toBe(1)
  expect(w.hostRuns.length).toBe(1)
})

test('engine order: several allowed calls cost one checker host run each', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Read', file_path: ROOT + '\\README.md', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Edit', file_path: ROOT + '\\src\\a.ts', old_string: 'a', new_string: 'b', tool_use_id: nextId() })
  expect(w.toolRuns.length).toBe(3)
  expect(w.hostRuns.length).toBe(3)
})

test('engine order: an Ask in the main loop goes through tool.call, and tool.check asks the user with bend-guard\'s reason', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const id = nextId()
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: id })
  // tool.call let it through to the permission step
  expect(w.preToolUse.length).toBe(1)
  expect(w.engineChecks.length).toBe(1)
  expect(w.engineChecks[0].e.tool_use_id).toBe(id)
  const c = w.engineChecks[0].c
  expect(c.decision).toBe('ask')
  expect(String(c.reason)).toContain('bend-guard: npm install runs package.json scripts')
  expect(String(c.reason)).toContain('Rule 8: installs left-pad')
  // The user was shown it and said yes: the tool ran and nothing refused it afterwards
  expect(w.dialogs.length).toBe(1)
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('engine order: the user says no to the ask: the tool never runs', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: nextId() })
  expect(w.dialogs.length).toBe(1)
  expect(refused(r)).toBeDefined()
  expect(w.toolRuns.length).toBe(0)
})

test('engine order: an IDE dialog (approver host, interactive session) is asked like a person', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'host', person: 'yes' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: nextId() })
  expect(w.engineChecks.length).toBe(1)
  expect(w.engineChecks[0].c.decision).toBe('ask')
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('engine order: the same Ask from an agent is refused and never asked', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, agentId: 'agent-7', tool_use_id: nextId() })
  expect(String(refused(r))).toContain('main session')
  expect(w.dialogs.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
})

test('engine order: the same Ask with nobody to answer (headless, no approver) is refused', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $ }, surfaces: [] })
  await $.session.start(START_NOT_INTERACTIVE)
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: nextId() })
  expect(String(refused(r))).toContain('bend-guard')
  expect(w.dialogs.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
})

test('engine order: a headless main-loop Ask is refused with one checker host run', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $ }, surfaces: [] })
  await $.session.start(START_NOT_INTERACTIVE)
  const r = await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: nextId() })
  // tool.call let it through (someone might answer); tool.check, told nobody
  // can, refused it from the same judgment
  expect(w.engineChecks.length).toBe(1)
  expect(w.engineChecks[0].c.decision).toBe('deny')
  expect(String(refused(r))).toContain('bend-guard')
  expect(w.dialogs.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostRuns.length).toBe(1)
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][2]).toBe('main (approver=none not-interactive)')
  expect(rows[0][4]).toBe('deny')
})

test('engine order: rule 4 (a new top-level folder) asks the user in the main loop', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'mkdir newdir', tool_use_id: nextId() })
  expect(w.engineChecks.length).toBe(1)
  expect(w.engineChecks[0].c.decision).toBe('ask')
  expect(String(w.engineChecks[0].c.reason)).toContain('rule 4')
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('engine order: inactive (no approved.json): every hook passes and the checker never runs', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { approved: null, engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  expect(w.engineChecks[0].c.decision).toBe('allow')
  expect(w.toolRuns.length).toBe(1)
  expect(w.hostRuns.length).toBe(0)
})

test('engine order: a broken approval (fingerprint mismatch) refuses at tool.call', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { mjsSha256: 'b'.repeat(64), engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Read', file_path: ROOT + '\\README.md', tool_use_id: nextId() })
  expect(String(r.deny)).toContain('does not match its fingerprint')
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostRuns.length).toBe(0)
})

test('engine order: the policy\'s Deny for a hook below bend-guard that rewrote the input', {
  plugins: [
    ABSORB,
    {
      name: 'rewriter-below',
      tier: 'append',
      register(on: any) {
        on('tool.call', ($: any, e: any, next: any) => next(e.command === 'ls' ? { ...e, command: 'rm -rf specs' } : e))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  // bend-guard's tool.call judged "ls"; what reaches the permission step and
  // the tool is "rm -rf specs". tool.check must judge what will run.
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
})

test('a Deny is still enforced at call when bend-guard never checked the call', {
  plugins: [
    {
      name: 'answers-checks',
      tier: 'prepend',
      register(on: any) {
        on('tool.check', () => ({ decision: 'allow' }))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(String(r.deny)).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
})

// Backlog round 2, priority 3 B. An administrator's prepend plugin can answer
// the permission step before bend-guard's tool.check is reached; nothing in a
// user plugin can stop that. bend-guard logs such a call once, by who answered,
// and tells the user when a call it would have asked about ran. (A test plugin's
// register runs on its own, so it cannot read a variable of this file.)
const ALLOWS_CHECKS = {
  plugins: [
    {
      name: 'answers-checks',
      tier: 'prepend',
      register(on: any) {
        on('tool.check', () => ({ decision: 'allow' }))
      },
    },
  ],
} as any
const DENIES_CHECKS = {
  plugins: [
    {
      name: 'answers-checks',
      tier: 'prepend',
      register(on: any) {
        on('tool.check', () => ({ decision: 'deny', reason: 'the other plugin says no' }))
      },
    },
  ],
} as any
const answersChecks = (decision: 'allow' | 'deny') => (decision === 'allow' ? ALLOWS_CHECKS : DENIES_CHECKS)

test('an Ask that runs because a prepend plugin answers tool.check is logged once as answered by another plugin, with a notice', answersChecks('allow'), async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const before = w.toasts.length
  const r = await $.tool.call({ tool: 'Bash', command: 'npm install left-pad', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
  expect(w.hostRuns.length).toBe(1)
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][2]).toBe('main (permission step answered by another plugin)')
  expect(rows[0][4]).toBe('ask')
  const notes = w.toasts.slice(before)
  expect(notes.length).toBe(1)
  expect(notes[0]).toContain("bend-guard: Bash ran without bend-guard's question; another plugin answered the permission step first. bend-guard would have asked: bend-guard: npm install runs package.json scripts")
})

test('an Allow whose check another plugin answered: one log line, no notice', answersChecks('allow'), async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const before = w.toasts.length
  const r = await $.tool.call({ tool: 'Bash', command: 'ls -la', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][2]).toBe('main (permission step answered by another plugin)')
  expect(rows[0][4]).toBe('allow')
  expect(w.toasts.length).toBe(before)
})

test('an Ask another plugin refused at the permission step: logged once, no notice, the tool never runs', answersChecks('deny'), async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const before = w.toasts.length
  const r = await $.tool.call({ tool: 'Bash', command: 'npm install left-pad', tool_use_id: nextId() })
  expect(refused(r)).toBeDefined()
  expect(w.toolRuns.length).toBe(0)
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][2]).toBe('main (permission step answered by another plugin)')
  expect(w.toasts.length).toBe(before)
})

test('a hook above bend-guard that rewrites the input: bend-guard judges the rewritten call', {
  plugins: [
    {
      name: 'rewriter',
      tier: 'prepend',
      register(on: any) {
        on('tool.call', ($: any, e: any, next: any) => next(e.command === 'ls' ? { ...e, command: 'rm -rf specs' } : e))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
})

// ------------------------------------------------- who can be asked (approver)

// npm install is an Ask in the policy; whether it stays an Ask depends on
// who can answer (Bend's can_ask: not an agent, approver person, interactive).
const INSTALL = { tool: 'Bash', input: { command: 'npm install left-pad' } }

test('approver person, session started not interactive: the user can still be asked', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START_NOT_INTERACTIVE)
  const c = await $.tool.check({ ...INSTALL, approver: 'person', tool_use_id: 'toolu_p1' })
  expect(c.decision).toBe('ask')
  const call = w.hostCalls()[0]
  expect(call.approver).toBe('person')
  expect(call.interactive).toBe(true)
  expect(call.agent).toBe(false)
})

test('approver host in an interactive session (an IDE dialog) counts as a person', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ ...INSTALL, approver: 'host', tool_use_id: 'toolu_h1' })
  expect(c.decision).toBe('ask')
  expect(w.hostCalls()[0].approver).toBe('person')
})

test('approver host after a hot reload with a surface attached counts as a person', async ($: any, on: any) => {
  const w = await world(on, { surfaces: ['vscode'] })
  const c = await $.tool.check({ ...INSTALL, approver: 'host', tool_use_id: 'toolu_h2' })
  expect(c.decision).toBe('ask')
  expect(w.hostCalls()[0].approver).toBe('person')
  expect(w.hostCalls()[0].interactive).toBe(true)
})

test('approver host with no surface (claude -p, the SDK) is a program: no ask', async ($: any, on: any) => {
  const w = await world(on, { surfaces: [] })
  const c = await $.tool.check({ ...INSTALL, approver: 'host', tool_use_id: 'toolu_h3' })
  expect(c.decision).toBe('deny')
  expect(w.hostCalls()[0].approver).toBe('host')
  expect(w.hostCalls()[0].interactive).toBe(false)
})

test('approver host, session started not interactive: no ask', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START_NOT_INTERACTIVE)
  const c = await $.tool.check({ ...INSTALL, approver: 'host', tool_use_id: 'toolu_h4' })
  expect(c.decision).toBe('deny')
  expect(w.hostCalls()[0].approver).toBe('host')
})

test('approver person after a hot reload in VS Code that sees no surface: the user can still be asked', async ($: any, on: any) => {
  const w = await world(on, { surfaces: [] })
  const c = await $.tool.check({ ...INSTALL, approver: 'person', tool_use_id: 'toolu_p2' })
  expect(c.decision).toBe('ask')
  expect(w.hostCalls()[0].interactive).toBe(true)
})

test('no approver: nobody can be asked, the Ask is refused', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ ...INSTALL, tool_use_id: 'toolu_n1' })
  expect(c.decision).toBe('deny')
  expect(w.hostCalls()[0].approver).toBe('')
})

test('an agent is never asked, even with approver person in an interactive session', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ ...INSTALL, approver: 'person', agentId: 'agent-7', tool_use_id: 'toolu_a1' })
  expect(c.decision).toBe('deny')
  expect(c.reason).toContain('main session')
  expect(w.hostCalls()[0].agent).toBe(true)
})

test('an agent with approver host stays host (never turned into a person)', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ ...INSTALL, approver: 'host', agentId: 'agent-7', tool_use_id: 'toolu_a2' })
  expect(c.decision).toBe('deny')
  expect(w.hostCalls()[0].approver).toBe('host')
  expect(w.hostCalls()[0].agent).toBe(true)
})

test('an agent with approver person in a non-interactive session is not counted as present', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START_NOT_INTERACTIVE)
  await $.tool.check({ ...INSTALL, approver: 'person', agentId: 'agent-7', tool_use_id: 'toolu_a3' })
  expect(w.hostCalls()[0].interactive).toBe(false)
})

test('an agent tool call that the policy asks about is refused, telling it to ask the user in the main session', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'npm install left-pad', agentId: 'agent-7' })
  expect(String(refused(r))).toContain('main session')
  expect(w.toolRuns.length).toBe(0)
})

// ------------------------------------------------------------ folder tracking

// Every host request for a command (at tool.call and at tool.check) must carry
// the same folders: the ones the shell may be in when that command runs.
function sentFolders(w: any, command: string, agent?: boolean): string[][] {
  const all = cwdsSent(w, command, agent)
  expect(all.length).toBeGreaterThan(0)
  return all
}

test('cd moves the folder of later calls of the same shell', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub' })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  for (const c of sentFolders(w, 'cd sub')) expect(c).toEqual([ROOT])
  // the tracked folder first, widened with the live session folder (here the
  // test's $.session.cwd() stays at ROOT)
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT + '\\sub', ROOT])
  // a relative path in the moved shell is judged from the new folder
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf ..\\specs' })
  expect(String(refused(r))).toContain(SPECS_DENIED)
})

test('engine order: cd is tracked across calls that each pass tool.call and tool.check', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'cd deeper', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'cd deeper')) expect(c).toEqual([ROOT + '\\sub', ROOT])
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT + '\\sub\\deeper', ROOT])
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf ..\\..\\specs', tool_use_id: nextId() })
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(3)
})

test('folders are shared by the shell tools of one agent, kept per agent; other tools use the session folder', async ($: any, on: any) => {
  // Bash, PowerShell and Monitor move one session folder in Claude Code (R1-01)
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub' })
  await $.tool.call({ tool: 'PowerShell', command: 'ls' })
  await $.tool.call({ tool: 'Bash', command: 'ls', agentId: 'agent-1' })
  await $.tool.call({ tool: 'Read', file_path: 'notes.md' })
  await $.tool.call({ tool: 'Monitor', command: 'pwd-check' })
  const ps = w.hostReqs.map(r => r.ops[0]?.call).filter((c: any) => c.tool === 'PowerShell').map((c: any) => A(c.cwds))
  expect(ps.length).toBeGreaterThan(0)
  for (const c of ps) expect(c).toEqual([ROOT + '\\sub', ROOT])
  for (const c of sentFolders(w, 'ls', true)) expect(c).toEqual([ROOT])
  const rd = w.hostReqs.map(r => r.ops[0]?.call).filter((c: any) => c.tool === 'Read').map((c: any) => A(c.cwds))
  for (const c of rd) expect(c).toEqual([ROOT])
  for (const c of sentFolders(w, 'pwd-check')) expect(c).toEqual([ROOT + '\\sub', ROOT])
})

test('R1-01: PowerShell, then Bash cd specs, then PowerShell deletes a file: judged in specs and refused', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: 'ls' })
  await $.tool.call({ tool: 'Bash', command: 'cd specs' })
  const r = await $.tool.call({ tool: 'PowerShell', command: 'rm -rf a.md' })
  const sent = sentFolders(w, 'rm -rf a.md')
  for (const c of sent) expect(c).toContain(ROOT + '\\specs')
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.filter((e: any) => e.command === 'rm -rf a.md').length).toBe(0)
})

test('R1-01 mirror: PowerShell cd specs, then Bash deletes a file: judged in specs and refused', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'PowerShell', command: 'cd specs' })
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf a.md' })
  for (const c of sentFolders(w, 'rm -rf a.md')) expect(c).toContain(ROOT + '\\specs')
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.filter((e: any) => e.command === 'rm -rf a.md').length).toBe(0)
})

test('R1-01: the live session folder is added to the tracked shell folders, never put in their place', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub' })
  // the session folder moved where bend-guard did not see it (another tool's cd)
  w.liveCwd = ROOT + '\\specs'
  const r = await $.tool.call({ tool: 'PowerShell', command: 'rm -rf a.md' })
  for (const c of sentFolders(w, 'rm -rf a.md')) expect(c).toEqual([ROOT + '\\sub', ROOT + '\\specs'])
  expect(String(refused(r))).toContain(SPECS_DENIED)
  // the live folder is not added twice
  w.liveCwd = ROOT + '\\sub'
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT + '\\sub'])
})

test('R1-01: a forgotten shell folder stays forgotten; the live folder does not narrow it', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'popd' })
  await $.tool.call({ tool: 'PowerShell', command: 'ls' })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([])
})

test('an agent\'s cd moves only that agent\'s shell', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub', agentId: 'agent-1' })
  await $.tool.call({ tool: 'Bash', command: 'ls', agentId: 'agent-1' })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  for (const c of sentFolders(w, 'ls', true)) expect(c).toEqual([ROOT + '\\sub', ROOT])
  for (const c of sentFolders(w, 'ls', false)) expect(c).toEqual([ROOT])
})

test('a folder the checker forgets (popd) is sent as no folder at all', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'popd' })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([])
})

test('a cd that was refused does not move the folder', async ($: any, on: any) => {
  const w = await world(on, {
    host: req => {
      // this policy refuses any cd
      const c = req.ops[0].call
      const cmd = A(c.args).find((a: any) => a.key === 'command')?.value ?? ''
      if (cmd.startsWith('cd ')) {
        const r = hostAnswer(req)
        const results = JSON.parse(r.stdout).results.map((x: any, i: number) => (req.ops[i].op === 'run' ? { $: 'Deny', reason: 'bend-guard: no cd here.' } : req.ops[i].op === 'decide' ? { $: 'Step.Done', v: { $: 'Deny', reason: 'bend-guard: no cd here.' } } : x))
        return { exitCode: 0, stdout: JSON.stringify({ ok: true, results }) }
      }
      return hostAnswer(req)
    },
  })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'cd sub' })
  expect(refused(r)).toBeDefined()
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT])
})

// ------------------------------------------------------------------- the log

test('engine order: one log line per call, each saying who could be asked', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() }) // allow
  await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() }) // deny
  await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, tool_use_id: nextId() }) // ask, the user says yes
  await $.tool.call({ tool: 'Bash', command: INSTALL_CMD, agentId: 'agent-7', tool_use_id: nextId() }) // agent: refused
  const rows = w.logLines().slice(1)
  expect(rows.map(r => r[11])).toEqual(['ls', 'rm -rf specs', INSTALL_CMD, INSTALL_CMD])
  expect(rows.map(r => r[4])).toEqual(['allow', 'deny', 'ask', 'deny'])
  // who could be asked: named on every line, never the misleading "no check seen"
  for (const r of rows) expect(r[2]).toMatch(/^(main|agent-7) \(.+\)$/)
  expect(rows[0][2]).toBe('main (approver=person)')
  expect(rows[2][2]).toBe('main (approver=person)')
  expect(rows[3][2].startsWith('agent-7 (')).toBe(true)
  // a refusal at tool.call says where it was refused
  expect(rows[1][2]).toBe('main (refused before the permission step)')
  expect(w.logText()).not.toContain('no check seen')
  for (const r of rows) expect(r[6].startsWith('at call:')).toBe(false)
})

test('engine order: log-only writes one line per call, with the enforce verdict', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { logOnly: true, engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  expect(refused(r)).toBeUndefined()
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][4]).toBe('allow')
  expect(rows[0][5]).toBe('deny')
  expect(rows[0][6]).toContain(SPECS_DENIED)
})

test('a log file of another session the same day is left untouched', async ($: any, on: any) => {
  const w = await world(on)
  const other = LOG_DIR + '\\2026-10-26.othersess.tsv'
  const otherText = LOG_HEADER + 'x\tother\tmain\tBash\tallow\tallow\t\tno\t\t1\tno\tls\n'
  w.files.set(other.toLowerCase(), otherText)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  expect(w.files.get(other.toLowerCase())).toBe(otherText)
  expect(w.writes.some(x => x.path.toLowerCase() === other.toLowerCase())).toBe(false)
  expect(w.logLines().length).toBe(2)
})

test('one log line per check, in the state log named by the UTC day and the session, with a header', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.writes.some(x => x.path === LOG_PATH)).toBe(true)
  const text = w.logText()
  expect(text.startsWith(LOG_HEADER)).toBe(true)
  const rows = w.logLines()
  expect(rows.length).toBe(2)
  const row = rows[1]
  expect(row.length).toBe(12)
  expect(row[0]).toBe('2026-10-26T23:30:00.000Z')
  expect(row[1]).toBe(SESSION_ID)
  expect(row[2].startsWith('main')).toBe(true)
  expect(row[3]).toBe('Bash')
  expect(row[4]).toBe('allow')
  expect(row[5]).toBe('allow')
  expect(row[7]).toBe('no')
  expect(row[11]).toBe('ls')
})

test('log lines are appended, the header written once', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  await $.tool.call({ tool: 'Read', file_path: ROOT + '\\README.md' })
  const rows = w.logLines()
  expect(rows.length).toBe(4)
  expect(rows.filter(r => r[0] === 'time').length).toBe(1)
  expect(rows[2][4]).toBe('deny')
  expect(rows[2][6]).toContain(SPECS_DENIED)
})

test('only log lines are written to the state folder during checks', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(w.writes.every(x => x.path === LOG_PATH)).toBe(true)
})

test('secrets in a command are masked in the log', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'curl -H "Authorization: Bearer abcdef0123456789xyz" https://api.example.com' })
  await $.tool.call({ tool: 'Bash', command: 'deploy --api_key=ZXCVBNMASDFGHJKL0987' })
  const t = w.logText()
  expect(t).not.toContain('abcdef0123456789xyz')
  expect(t).not.toContain('ZXCVBNMASDFGHJKL0987')
  expect(t).toContain('***')
})

test('a log that cannot be written changes no verdict', async ($: any, on: any) => {
  const w = await world(on, { failWrites: /\\log\\/ })
  await $.session.start(START)
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ok.deny).toBeUndefined()
  const no = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(String(no.deny)).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(1)
})

test('a tab or newline in a command cannot add a log column or line', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls\tfake-column\nfake\tline' })
  const rows = w.logLines()
  expect(rows.length).toBe(2)
  expect(rows[1].length).toBe(12)
})

test('the log says who could be asked', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START_NOT_INTERACTIVE)
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' }, approver: 'person', tool_use_id: 'toolu_l1' })
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' }, tool_use_id: 'toolu_l2' })
  const rows = w.logLines()
  expect(rows[1][2]).toBe('main (approver=person)')
  expect(rows[2][2]).toBe('main (approver=none not-interactive)')
})

// ------------------------------------------------------------------ log-only

test('log-only: a project rule is logged with its enforce verdict, not enforced', async ($: any, on: any) => {
  const w = await world(on, { logOnly: true })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
  // the checker is asked both ways: as logged (log_only) and as enforce would judge
  const flags = w.hostReqs.flatMap(q => q.ops.filter((o: any) => o.op === 'run').map((o: any) => o.call.log_only))
  expect(flags).toContain(true)
  expect(flags).toContain(false)
  const rows = w.logLines().slice(1)
  expect(rows.length).toBe(1)
  expect(rows[0][4]).toBe('allow')
  expect(rows[0][5]).toBe('deny')
  expect(rows[0][6]).toContain(SPECS_DENIED)
})

test('log-only: self-protection is still enforced', async ($: any, on: any) => {
  const w = await world(on, { logOnly: true })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Read', file_path: S + '\\openrouter.key' })
  expect(String(r.deny)).toContain('self-protection')
  expect(w.toolRuns.length).toBe(0)
})

test('log-only: rule 4 is only logged', async ($: any, on: any) => {
  const w = await world(on, { logOnly: true })
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'mkdir newdir' }, approver: 'person', tool_use_id: 'toolu_r4lo' })
  expect(c.decision).toBe('allow')
  const row = w.logLines()[1]
  expect(row[4]).toBe('allow')
  expect(row[5]).toBe('ask')
  expect(row[6]).toContain('rule 4')
})

// ------------------------------------------------------------- rules 4 and 8

test('rule 4: a new top-level folder asks the user', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'mkdir newdir' }, approver: 'person', tool_use_id: 'toolu_r4' })
  expect(c.decision).toBe('ask')
  expect(c.reason).toContain('rule 4')
  expect(c.reason).toContain('newdir')
  void w
})

test('rule 4: a Write that makes a new top-level folder asks the user', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Write', input: { file_path: ROOT + '\\tools\\x.ts', content: '' }, approver: 'person', tool_use_id: 'toolu_r4w' })
  expect(c.decision).toBe('ask')
  expect(c.reason).toContain('tools/')
})

test('rule 4: a file written straight in the root makes no folder', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Write', input: { file_path: ROOT + '\\x.ts', content: '' }, approver: 'person', tool_use_id: 'toolu_r4f' })
  expect(c.decision).toBe('allow')
})

test('rule 4: a folder that already exists passes', async ($: any, on: any) => {
  await world(on, { existing: [ROOT + '\\newdir'] })
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'mkdir newdir' }, approver: 'person', tool_use_id: 'toolu_r4e' })
  expect(c.decision).toBe('allow')
})

test('rule 4: nobody to ask (enforce mode) refuses', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'mkdir newdir' })
  expect(String(refused(r))).toContain('rule 4')
  expect(String(refused(r))).toContain('main session')
  expect(w.toolRuns.length).toBe(0)
})

test('rule 4 is off when the project\'s ask config turns it off', async ($: any, on: any) => {
  await world(on, { ask: ASK_NONE })
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'mkdir newdir' }, approver: 'person', tool_use_id: 'toolu_r4o' })
  expect(c.decision).toBe('allow')
})

test('rule 4 never loosens a Deny from the policy', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Write', input: { file_path: ROOT + '\\specs\\new\\a.md', content: '' }, approver: 'person', tool_use_id: 'toolu_r4d' })
  expect(c.decision).toBe('deny')
  expect(c.reason).toContain(SPECS_DENIED)
})

test('rule 8: the install ask names the packages', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'npm install left-pad is-odd' }, approver: 'person', tool_use_id: 'toolu_r8' })
  expect(c.decision).toBe('ask')
  expect(c.reason).toContain('Rule 8: installs left-pad, is-odd')
})

test('rule 8: a bare npm install says it installs package.json', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  const c = await $.tool.check({ tool: 'Bash', input: { command: 'npm install' }, approver: 'person', tool_use_id: 'toolu_r8b' })
  expect(c.decision).toBe('ask')
  expect(c.reason).toContain('packages in package.json')
})

// ------------------------------------------------------- rules 9 and 10

test('turn.complete: files changed and no test or lint since: a reminder is added', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt' })
  const r = await $.turn.complete(TURN)
  expect(r.text.startsWith('All done.')).toBe(true)
  expect(r.text).toContain('rules 9 and 10')
  expect(r.text).toContain('`npm test` and `npm run lint`')
})

test('turn.complete: test and lint passed after the last change: no reminder', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Edit', file_path: ROOT + '\\src\\a.ts', old_string: 'a', new_string: 'b' })
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  await $.tool.call({ tool: 'Bash', command: 'npm run lint' })
  const r = await $.turn.complete(TURN)
  expect(r.text).toBe('All done.')
})

test('turn.complete: a change after the test run asks again', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  await $.tool.call({ tool: 'Bash', command: 'npm run lint' })
  await $.tool.call({ tool: 'Bash', command: 'touch b.txt' })
  const r = await $.turn.complete(TURN)
  expect(r.text).toContain('rules 9 and 10')
})

test('turn.complete: a failing test run does not count as passed', async ($: any, on: any) => {
  await world(on, {
    toolResult: (e: any) => (e.command === 'npm test' ? { result: { stdout: '1 failing', stderr: '', interrupted: false }, text: '1 failing', isError: true } : { result: { stdout: 'ok', stderr: '', interrupted: false }, text: 'ok' }),
  })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt' })
  await $.tool.call({ tool: 'Bash', command: 'npm test' })
  await $.tool.call({ tool: 'Bash', command: 'npm run lint' })
  const r = await $.turn.complete(TURN)
  expect(r.text).toContain('`npm test`')
  expect(r.text).not.toContain('`npm run lint`')
})

test('turn.complete: no change, no reminder; the ledger resets each main turn', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt' })
  expect((await $.turn.complete(TURN)).text).toContain('rules 9 and 10')
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
})

test('turn.complete of an agent gets no reminder and keeps the main turn\'s ledger', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt', agentId: 'agent-1' })
  const a = await $.turn.complete({ ...TURN, agentId: 'agent-1' })
  expect(a.text).toBe('All done.')
  const m = await $.turn.complete(TURN)
  expect(m.text).toContain('rules 9 and 10')
})

test('turn.complete: a denied change is not counted', async ($: any, on: any) => {
  await world(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
})

test('turn.complete: no reminder when the project asks for no test or lint', async ($: any, on: any) => {
  await world(on, { ask: ASK_NONE })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt' })
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
})

test('turn.complete where bend-guard is inactive: untouched', async ($: any, on: any) => {
  await world(on, { approved: null })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch a.txt' })
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
})

// ------------------------------------------------- checker host failures

function bad(stdout: string, extra: Partial<{ exitCode: number; isStdoutTruncated: boolean }> = {}) {
  return () => ({ exitCode: extra.exitCode ?? 0, stdout, stderr: 'boom', isStdoutTruncated: extra.isStdoutTruncated })
}

const FAILURES: [string, any][] = [
  ['exits non-zero', bad('', { exitCode: 1 })],
  ['prints something that is not JSON', bad('Segmentation fault')],
  ['answers ok:false', bad(JSON.stringify({ ok: false, error: 'policy did not load' }))],
  ['gives the wrong number of results', bad(JSON.stringify({ ok: true, results: [] }))],
  ['has its output cut', (req: any) => ({ ...hostAnswer(req), isStdoutTruncated: true })],
  ['is stopped at its deadline', () => 'refuse'],
  [
    'answers an unknown verdict',
    (req: any) => {
      const r = JSON.parse(hostAnswer(req).stdout)
      r.results = r.results.map((x: any, i: number) => (req.ops[i].op === 'run' ? { $: 'Maybe' } : x))
      return { exitCode: 0, stdout: JSON.stringify(r) }
    },
  ],
  [
    'answers a meaning of the wrong shape',
    (req: any) => {
      const r = JSON.parse(hostAnswer(req).stdout)
      r.results = r.results.map((x: any, i: number) => (req.ops[i].op === 'meaning' ? { $: 'Known', actions: [{ $: 'Read', path: 'c:/x' }] } : x))
      return { exitCode: 0, stdout: JSON.stringify(r) }
    },
  ],
  [
    'answers next_cwds that is not a list',
    (req: any) => {
      const r = JSON.parse(hostAnswer(req).stdout)
      r.results = r.results.map((x: any, i: number) => (req.ops[i].op === 'next_cwds' ? ['c:/x'] : x))
      return { exitCode: 0, stdout: JSON.stringify(r) }
    },
  ],
  [
    'answers a step of the wrong shape',
    (req: any) => {
      const r = JSON.parse(hostAnswer(req).stdout)
      r.results = r.results.map((x: any, i: number) => (req.ops[i].op === 'decide' ? { $: 'Done', v: { $: 'Allow' } } : x))
      return { exitCode: 0, stdout: JSON.stringify(r) }
    },
  ],
]

for (const [what, host] of FAILURES) {
  test(`the checker host ${what}: the call is refused, never let through`, async ($: any, on: any) => {
    const w = await world(on, { host })
    await $.session.start(START)
    const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
    expect(String(refused(r))).toContain('bend-guard')
    expect(w.toolRuns.length).toBe(0)
    const c = await $.tool.check({ tool: 'Read', input: { file_path: ROOT + '\\README.md' }, approver: 'person' })
    expect(c.decision).toBe('deny')
  })
}

test('a host failure at call time (no prior check) refuses too', {
  plugins: [
    {
      name: 'answers-checks',
      tier: 'prepend',
      register(on: any) {
        on('tool.check', () => ({ decision: 'allow' }))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  const w = await world(on, { host: bad('', { exitCode: 3 }) })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(refused(r))).toContain('bend-guard')
  expect(w.toolRuns.length).toBe(0)
})

// ------------------------------------------------------------------- Clef
// Clef (OpenRouter, mocked through http.fetch) can only make a verdict
// stricter. The fake policy: an unknown shell command consults Clef (Triage)
// over a base Ask, and risky >= 800 makes it a Deny; `cat specs/...` consults
// (Veto) over a base Allow, and risky >= 500 makes it an Ask.

const KEY = 'sk-or-v1-wiringtestkey0123456789abcdef'
const UNKNOWN = 'jq . package.json'
const CLEF_URL = 'https://openrouter.ai/api/alpha/decisions'

function checkUnknown($: any, command = UNKNOWN, extra: Record<string, unknown> = {}) {
  return $.tool.check({ tool: 'Bash', input: { command }, approver: 'person', tool_use_id: nextId(), ...extra })
}

type ClefCase = [string, any, 'ask' | 'deny', string]
const CLEF_CASES: ClefCase[] = [
  ['answers safe (200)', () => ({ status: 200, text: CLEF_SAFE }), 'ask', 'ok risky=20 unsure=10'],
  ['answers risky (200)', () => ({ status: 200, text: CLEF_RISKY }), 'deny', 'ok risky=930 unsure=50'],
  ['says credit is used up (402)', () => ({ status: 402, text: '{"error":"insufficient credits"}' }), 'ask', 'clef-credit-exhausted'],
  ['is rate limited (429)', () => ({ status: 429, text: '{"error":"rate limited"}' }), 'ask', 'http-429'],
  ['fails (500)', () => ({ status: 500, text: 'oops' }), 'ask', 'http-500'],
  ['answers garbage (200)', () => ({ status: 200, text: '<html>gateway</html>' }), 'ask', 'badshape'],
  ['answers a probability out of range (200)', () => ({ status: 200, text: clefBody(1.7, 0.1) }), 'ask', 'badshape'],
  ['cannot be reached', () => 'refuse', 'ask', 'error'],
]

for (const [what, fetch, decision, label] of CLEF_CASES) {
  test(`Clef ${what}: the unknown command is a ${decision}, never an allow`, async ($: any, on: any) => {
    const w = await world(on, { key: KEY, fetch })
    await $.session.start(START)
    const c = await checkUnknown($)
    expect(c.decision).toBe(decision)
    expect(w.fetches.length).toBe(1)
    const row = w.logLines()[1]
    expect(row[7]).toBe('yes')
    expect(row[8]).toBe(label)
    expect(w.logText()).not.toContain(KEY)
    expect(w.toasts.join('\n')).not.toContain(KEY)
  })
}

test('Clef times out (3 s): the unknown command asks, never allows', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => 'hang' })
  await $.session.start(START)
  const p = checkUnknown($)
  await w.clock.settle()
  await w.clock.advance(3000)
  const c = await p
  expect(c.decision).toBe('ask')
  expect(w.logLines()[1][8]).toBe('timeout')
  await w.clock.advance(60000)
})

test('Clef is sent the command with the key in the header only, to the decisions endpoint', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  await checkUnknown($, 'jq . package.json --arg t "Bearer abcdef0123456789xyz"')
  const f = w.fetches[0]
  expect(f.url).toBe(CLEF_URL)
  expect(String(f.init?.method).toUpperCase()).toBe('POST')
  expect(JSON.stringify(f.init?.headers ?? {})).toContain('Bearer ' + KEY)
  const body = String(f.init?.body ?? '')
  expect(body).not.toContain(KEY)
  expect(body).toContain('cloudflare/clef-flash')
  expect(body).toContain('jq . package.json')
  // a secret-looking string in the command is masked before it leaves
  expect(body).not.toContain('abcdef0123456789xyz')
})

test('Clef: credit used up is shown once per session, not on every call', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 402, text: '{}' }) })
  await $.session.start(START)
  await checkUnknown($, 'jq . a.json')
  await checkUnknown($, 'jq . b.json')
  expect(w.toasts.filter(t => t.includes('credit')).length).toBe(1)
})

test('Clef: the same command twice is asked once (the answer is cached)', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  await checkUnknown($)
  const c = await checkUnknown($)
  expect(c.decision).toBe('ask')
  expect(w.fetches.length).toBe(1)
  expect(w.logLines()[2][10]).toBe('yes')
})

test('Clef: a failed answer is not cached; the next call asks again', async ($: any, on: any) => {
  let n = 0
  const w = await world(on, { key: KEY, fetch: () => (++n === 1 ? { status: 429, text: '' } : { status: 200, text: CLEF_RISKY }) })
  await $.session.start(START)
  expect((await checkUnknown($)).decision).toBe('ask')
  expect((await checkUnknown($)).decision).toBe('deny')
  expect(w.fetches.length).toBe(2)
})

test('Clef: no key file means no request at all, and the unknown command asks', async ($: any, on: any) => {
  const w = await world(on, { fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  const c = await checkUnknown($)
  expect(c.decision).toBe('ask')
  expect(w.fetches.length).toBe(0)
  expect(w.logLines()[1][8]).toBe('nokey')
})

test('Clef: a safe answer never lets an agent\'s unknown command through', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  const c = await checkUnknown($, UNKNOWN, { agentId: 'agent-7' })
  expect(c.decision).toBe('deny')
  void w
})

test('Clef veto: a risky answer turns an allowed read of specs/ into an ask', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: clefBody(0.6, 0.1) }) })
  await $.session.start(START)
  const c = await checkUnknown($, 'cat specs/a.md')
  expect(c.decision).toBe('ask')
  expect(String(c.reason)).toContain('bend-guard')
  void w
})

test('Clef veto: a safe answer leaves the allowed read allowed', async ($: any, on: any) => {
  await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  const c = await checkUnknown($, 'cat specs/a.md')
  expect(c.decision).toBe('allow')
})

test('engine order: an unknown command asks Clef once, then the user', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }), engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: UNKNOWN, tool_use_id: nextId() })
  expect(w.fetches.length).toBe(1)
  expect(w.dialogs.length).toBe(1)
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('engine order: a risky Clef answer refuses the unknown command; the tool never runs', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_RISKY }), engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: UNKNOWN, tool_use_id: nextId() })
  expect(String(refused(r))).toContain('risky')
  expect(w.dialogs.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
})

// ---------------------------------------------------- the /bend-guard command

const COMPOSER = { kind: 'composer' }
const SNAPSHOT = HOME + '\\.claude\\bend-guard-drafts\\' + SLUG + '\\.approve-1a2b3c'
const PREVIEW_SHA = 'ab'.repeat(32)
const DISPLAY = 'BEND_RULES.md, line by line:\n  1. Never change specs/.   NoChange specs/   law rule_1_protected'
const PREVIEW = { ok: true, root: ROOT, snapshot: SNAPSHOT, previewSha256: PREVIEW_SHA, display: DISPLAY }
const previewOut = (o: Record<string, unknown> = PREVIEW) => ({ exitCode: 0, stdout: 'reading drafts...\nproving 3 laws...\n' + JSON.stringify(o) + '\n' })

function cmd($: any, args: string, origin: any = COMPOSER) {
  return $.command.run(origin === null ? { command: 'bend-guard', args } : { command: 'bend-guard', args, origin })
}

// Claude Code shows a command's text under the plugin's name: no line of the
// text may start with the name again.
function noDoubledPrefix(text: string) {
  for (const line of String(text).split('\n')) expect(line.startsWith('bend-guard:')).toBe(false)
}

const approveMock = (argv: string[]) => {
  if (argv.includes('--preview')) return previewOut()
  if (argv.includes('--status')) return { exitCode: 0, stdout: 'mode: log-only\napproved: ' + ROOT_N + '\n' }
  if (argv.includes('--mode-only')) return { exitCode: 0, stdout: 'now enforcing in every approved project\n' }
  return { exitCode: 1, stdout: '' }
}

const tokenWrites = (w: any) => w.writes.filter((x: any) => x.path.toLowerCase() === TOKEN_FILE.toLowerCase())

test('/bend-guard refuses every origin that is not a person typing, and does nothing', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  const origins = [null, { kind: 'plugin', name: 'other' }, { kind: 'peer' }, { kind: 'task-notification' }, { kind: 'scheduled-trigger' }, { kind: 'coordinator' }, { kind: 'auto-continuation' }, { kind: 'channel' }]
  for (const origin of origins) {
    for (const args of ['approve', 'confirm', 'enforce', 'log-only', 'status']) {
      let text = ''
      try {
        text = String((await cmd($, args, origin))?.text ?? '')
      } catch {
        text = 'answers only your own typing (the engine refused the origin)'
      }
      expect(text).toContain('answers only your own typing')
      noDoubledPrefix(text)
    }
  }
  expect(w.runs.length).toBe(0)
  expect(w.spawns.length).toBe(0)
  expect(tokenWrites(w).length).toBe(0)
})

test('/bend-guard with no or unknown words shows the usage, without a doubled "bend-guard:"', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  for (const args of ['', 'help', 'frobnicate', 'approve now', 'status please']) {
    const r = await cmd($, args)
    const text = String(r?.text ?? '')
    for (const sub of ['/bend-guard approve', '/bend-guard confirm', '/bend-guard status', '/bend-guard enforce', '/bend-guard log-only']) expect(text).toContain(sub)
    noDoubledPrefix(text)
  }
  expect(w.runs.length).toBe(0)
})

test('/bend-guard confirm with an unknown flag shows the usage, without a doubled "bend-guard:"', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  const r = await cmd($, 'confirm --force')
  const text = String(r?.text ?? '')
  expect(text).toContain('--enforce')
  noDoubledPrefix(text)
  expect(w.spawns.length).toBe(0)
})

test('/bend-guard approve runs approve.mjs --preview and shows what it would approve', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  const r = await cmd($, 'approve')
  const text = String(r?.text ?? '')
  expect(text).toContain(DISPLAY)
  expect(text).toContain('/bend-guard confirm')
  noDoubledPrefix(text)
  expect(w.runs.length).toBe(1)
  expect(w.runs[0].argv).toEqual([NODE, APPROVE_MJS, '--preview', ROOT])
  expect(w.runs[0].init.cwd).toBe(PLUGIN)
  // looking changes nothing: no token, no write to the state folder
  expect(tokenWrites(w).length).toBe(0)
  expect(w.writes.length).toBe(0)
})

type BadPreview = [string, any, string]
const BAD_PREVIEWS: BadPreview[] = [
  ['says it cannot approve', () => previewOut({ ok: false, error: 'line 3 is not sorted yet' }), 'line 3 is not sorted yet'],
  ['prints no JSON', () => ({ exitCode: 2, stdout: 'Error: cannot find module\n' }), 'gave no answer'],
  ['answers for another folder', () => previewOut({ ...PREVIEW, root: HOME + '\\other' }), 'shape this command does not know'],
  ['gives a fingerprint that is not hex', () => previewOut({ ...PREVIEW, previewSha256: 'zz' }), 'shape this command does not know'],
  ['gives no snapshot', () => previewOut({ ...PREVIEW, snapshot: '' }), 'shape this command does not know'],
  ['cannot run', () => 'refuse', 'could not run'],
]

for (const [what, approve, says] of BAD_PREVIEWS) {
  test(`/bend-guard approve when approve.mjs ${what}: says so, and there is nothing to confirm`, async ($: any, on: any) => {
    const w = await world(on, { approve })
    await $.session.start(START)
    const r = await cmd($, 'approve')
    expect(String(r?.text ?? '')).toContain(says)
    noDoubledPrefix(String(r?.text ?? ''))
    const c = await cmd($, 'confirm')
    expect(String(c?.text ?? '')).toContain('nothing to confirm')
    expect(w.spawns.length).toBe(0)
    expect(tokenWrites(w).length).toBe(0)
  })
}

test('/bend-guard approve where there is no BEND_RULES.md: nothing to approve, approve.mjs not run', async ($: any, on: any) => {
  const w = await world(on, { approved: null, rulesMd: false, approve: approveMock })
  await $.session.start(START)
  const r = await cmd($, 'approve')
  expect(String(r?.text ?? '')).toContain('nothing to approve')
  noDoubledPrefix(String(r?.text ?? ''))
  expect(w.runs.length).toBe(0)
})

const spawnOk = () => ({ chunks: [{ stream: 'stdout' as const, text: 'proving rule_1_protected...\n' }, { stream: 'stdout' as const, text: '{"ok":true}\n' }], code: 0 })

test('/bend-guard confirm writes the token\'s hash, starts approve.mjs with the token on its input, and says when it is done', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk })
  await $.session.start(START)
  await cmd($, 'approve')
  const r = await cmd($, 'confirm')
  const text = String(r?.text ?? '')
  expect(text).toContain('Approving')
  noDoubledPrefix(text)
  await w.clock.settle()
  // the token file holds sha256(token), written before the spawn
  const tw = tokenWrites(w)
  expect(tw.length).toBe(1)
  expect(tw[0].text).toMatch(/^[0-9a-f]{64}$/)
  expect(w.spawns.length).toBe(1)
  const s = w.spawns[0]
  expect(s.argv).toEqual([NODE, APPROVE_MJS, '--snapshot', SNAPSHOT, '--expect', PREVIEW_SHA, '--from-mod', '--log-only'])
  expect(s.cwd).toBe(PLUGIN)
  const input = String(s.input ?? '')
  expect(input.endsWith('\n')).toBe(true)
  const token = input.trim()
  expect(token.length).toBeGreaterThanOrEqual(32)
  expect(await sha256Hex(token)).toBe(tw[0].text)
  // the token itself is never shown, logged or put on a command line
  expect(text).not.toContain(token)
  expect(s.argv.join(' ')).not.toContain(token)
  expect(w.toasts.join('\n')).not.toContain(token)
  expect(w.statuses.join('\n')).not.toContain(token)
  expect(w.logText()).not.toContain(token)
  // the end is a notice
  expect(w.toasts.join('\n')).toContain('are live (log-only)')
})

test('/bend-guard confirm --enforce asks approve.mjs to enforce', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk })
  await $.session.start(START)
  await cmd($, 'approve')
  await cmd($, 'confirm --enforce')
  await w.clock.settle()
  expect(w.spawns[0].argv[w.spawns[0].argv.length - 1]).toBe('--enforce')
  expect(w.toasts.join('\n')).toContain('are live (enforcing)')
})

test('/bend-guard confirm when approve.mjs fails: a notice says why, and the rules are not called live', async ($: any, on: any) => {
  const w = await world(on, {
    approve: approveMock,
    spawn: () => ({ chunks: [{ stream: 'stdout', text: 'proving...\n{"ok":false,"message":"the proof of rule_1_protected failed"}\n' }], code: 1 }),
  })
  await $.session.start(START)
  await cmd($, 'approve')
  await cmd($, 'confirm')
  await w.clock.settle()
  const t = w.toasts.join('\n')
  expect(t).toContain('was not approved')
  expect(t).toContain('the proof of rule_1_protected failed')
  expect(t).not.toContain('are live')
})

test('/bend-guard confirm without approve first: nothing to confirm, no token, nothing started', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk })
  await $.session.start(START)
  const r = await cmd($, 'confirm')
  expect(String(r?.text ?? '')).toContain('nothing to confirm')
  expect(tokenWrites(w).length).toBe(0)
  expect(w.spawns.length).toBe(0)
})

test('/bend-guard confirm more than 30 minutes after approve: refused, approve again', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk })
  await $.session.start(START)
  await cmd($, 'approve')
  await w.clock.advance(31 * 60 * 1000)
  const r = await cmd($, 'confirm')
  expect(String(r?.text ?? '')).toContain('more than 30 minutes old')
  expect(tokenWrites(w).length).toBe(0)
  expect(w.spawns.length).toBe(0)
})

test('/bend-guard confirm when the token file cannot be written: nothing started', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk, failWrites: /approve-token/ })
  await $.session.start(START)
  await cmd($, 'approve')
  const r = await cmd($, 'confirm')
  expect(String(r?.text ?? '')).toContain('could not write the one-time token')
  noDoubledPrefix(String(r?.text ?? ''))
  expect(w.spawns.length).toBe(0)
})

test('/bend-guard confirm is used up: a second confirm does not start a second approval', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk })
  await $.session.start(START)
  await cmd($, 'approve')
  await cmd($, 'confirm')
  await w.clock.settle()
  const r = await cmd($, 'confirm')
  expect(String(r?.text ?? '')).toContain('nothing to confirm')
  expect(w.spawns.length).toBe(1)
})

test('/bend-guard status shows approve.mjs --status and starts nothing that writes', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  const r = await cmd($, 'status')
  const text = String(r?.text ?? '')
  expect(text).toContain('mode: log-only')
  expect(w.runs.length).toBe(1)
  expect(w.runs[0].argv).toEqual([NODE, APPROVE_MJS, '--status'])
  expect(w.runs[0].init.stdin).toBeUndefined()
  expect(tokenWrites(w).length).toBe(0)
})

test('/bend-guard status after approve says a confirm is waiting', async ($: any, on: any) => {
  await world(on, { approve: approveMock })
  await $.session.start(START)
  await cmd($, 'approve')
  const r = await cmd($, 'status')
  expect(String(r?.text ?? '')).toContain('/bend-guard confirm within 30 minutes')
})

test('/bend-guard enforce: the token handshake, then approve.mjs --mode-only with the token on its input; the next call reloads', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  const readsBefore = w.reads.filter(p => p.toLowerCase().endsWith('approved.json')).length
  const r = await cmd($, 'enforce')
  expect(String(r?.text ?? '')).toContain('now enforcing')
  const tw = tokenWrites(w)
  expect(tw.length).toBe(1)
  expect(w.runs.length).toBe(1)
  expect(w.runs[0].argv).toEqual([NODE, APPROVE_MJS, '--mode-only', '--from-mod', '--enforce'])
  const stdin = String(w.runs[0].init.stdin ?? '')
  expect(await sha256Hex(stdin.trim())).toBe(tw[0].text)
  expect(String(r?.text ?? '')).not.toContain(stdin.trim())
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.reads.filter(p => p.toLowerCase().endsWith('approved.json')).length).toBeGreaterThan(readsBefore)
})

test('/bend-guard log-only asks approve.mjs for log-only', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock })
  await $.session.start(START)
  await cmd($, 'log-only')
  expect(w.runs[0].argv).toEqual([NODE, APPROVE_MJS, '--mode-only', '--from-mod', '--log-only'])
})

test('/bend-guard is served where bend-guard is inactive, so the user can approve the first time', async ($: any, on: any) => {
  const w = await world(on, { approved: null, approve: approveMock })
  await $.session.start(START)
  const r = await cmd($, 'approve')
  expect(String(r?.text ?? '')).toContain(DISPLAY)
  void w
})

// ------------------------------------- bookkeeping after a refusal beneath
// Under the engine's order a call can pass bend-guard's tool.call and still be
// refused beneath it (bend-guard's own tool.check, the user's "no", another plugin).
// What tool.call's next(e) then returns is an errored result, not { deny }:
// the tool never ran, so it must not move the shell's folder or count as a change.

// The user's "no" comes back as an errored result, which cannot be told apart from
// a tool that ran and failed. So the safe answer is both folders: the old one
// is kept, never replaced by the cd's target.
test('engine order: a cd the user refused at the permission step keeps the old folder among the possible ones', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'cdask sub', tool_use_id: nextId() })
  expect(refused(r)).toBeDefined()
  expect(w.toolRuns.length).toBe(0)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) expect(c).toContain(ROOT)
})

test('engine order: a cd whose command then fails with "denied" in its text: later calls are checked in both folders', ENGINE, async ($: any, on: any) => {
  // e.g. `cd sub && ls denied`: the cd ran, ls failed, and the error text says
  // "denied". The folder may have moved, so the new one must be among those sent.
  const w = await world(on, {
    engine: { $, approver: 'person' },
    toolResult: (e: any) =>
      e.command === 'cd sub' ? { result: { stdout: '', stderr: 'ls: cannot access denied', interrupted: false }, text: 'ls: cannot access denied: No such file or directory', isError: true } : { result: { stdout: 'ok', stderr: '', interrupted: false }, text: 'ok' },
  })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cd sub', tool_use_id: nextId() })
  expect(w.toolRuns.length).toBe(1)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) {
    expect(c).toContain(ROOT + '\\sub')
    expect(c).toContain(ROOT)
  }
})

test('engine order: an errored call after a forgotten folder keeps the folders forgotten', ENGINE, async ($: any, on: any) => {
  const w = await world(on, {
    engine: { $, approver: 'person' },
    toolResult: (e: any) => (e.command === 'cd sub' ? { result: { stdout: '', stderr: 'x', interrupted: false }, text: 'failed', isError: true } : { result: { stdout: 'ok', stderr: '', interrupted: false }, text: 'ok' }),
  })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'popd', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'cd sub', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([])
})

test('engine order: bend-guard\'s own tool.check refusal of an input rewritten beneath leaves the folders unchanged', {
  plugins: [
    ABSORB,
    {
      name: 'rewriter-below',
      tier: 'append',
      register(on: any) {
        on('tool.call', ($: any, e: any, next: any) => next(e.command === 'cd away' ? { ...e, command: 'cd sub' } : e))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  // bend-guard's tool.call judges "cd away" (allowed, would move to away); what
  // reaches the permission step is "cd sub", which this policy refuses.
  const w = await world(on, {
    engine: { $, approver: 'person' },
    host: req => {
      const c = req.ops[0].call
      const cmd = A(c.args).find((a: any) => a.key === 'command')?.value ?? ''
      if (cmd === 'cd sub') {
        const results = JSON.parse(hostAnswer(req).stdout).results.map((x: any, i: number) => (req.ops[i].op === 'run' ? { $: 'Deny', reason: 'bend-guard: no cd to sub.' } : req.ops[i].op === 'decide' ? { $: 'Step.Done', v: { $: 'Deny', reason: 'bend-guard: no cd to sub.' } } : x))
        return { exitCode: 0, stdout: JSON.stringify({ ok: true, results }) }
      }
      return hostAnswer(req)
    },
  })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'cd away', tool_use_id: nextId() })
  expect(String(refused(r))).toContain('no cd to sub')
  expect(w.toolRuns.length).toBe(0)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT])
  // and a relative path is still judged from the real folder
  const d = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  expect(String(refused(d))).toContain(SPECS_DENIED)
})

test('engine order: a cd the user approved moves the folder', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cdask sub', tool_use_id: nextId() })
  expect(w.toolRuns.length).toBe(1)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT + '\\sub', ROOT])
})

test('engine order: a change refused at the permission step is not counted for rules 9 and 10', ENGINE, async ($: any, on: any) => {
  // rule 4 asks about the new folder; the user says no, so nothing was written
  const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'touch newdir/x.txt', tool_use_id: nextId() })
  expect(w.dialogs.length).toBe(1)
  expect(refused(r)).toBeDefined()
  expect(w.toolRuns.length).toBe(0)
  expect((await $.turn.complete(TURN)).text).toBe('All done.')
})

test('engine order: a change the user approved counts for rules 9 and 10', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'touch newdir/x.txt', tool_use_id: nextId() })
  expect(w.toolRuns.length).toBe(1)
  expect((await $.turn.complete(TURN)).text).toContain('rules 9 and 10')
})

// ------------------------------------------------------- the OpenRouter key

test('the OpenRouter key never reaches the checker host, a command line or a log', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  await checkUnknown($)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.hostReqs.length).toBeGreaterThan(0)
  expect(JSON.stringify(w.hostReqs)).not.toContain(KEY)
  expect(JSON.stringify(w.hostRuns)).not.toContain(KEY)
  expect(w.logText()).not.toContain(KEY)
  expect(w.writes.some(x => x.text.includes(KEY))).toBe(false)
})

test('/bend-guard approve from a subfolder approves the project folder that holds BEND_RULES.md', async ($: any, on: any) => {
  const sub = ROOT + '\\src'
  const w = await world(on, { cwd: sub, approve: approveMock })
  await $.session.start({ cwd: sub, surface: 'terminal', isInteractive: true })
  const r = await cmd($, 'approve')
  expect(String(r?.text ?? '')).toContain(DISPLAY)
  expect(w.runs[0].argv).toEqual([NODE, APPROVE_MJS, '--preview', ROOT])
})

test('engine order: a cd another plugin refuses at its tool.check does not move the folder', {
  plugins: [
    ABSORB,
    {
      name: 'denies-cd',
      tier: 'append',
      register(on: any) {
        on('tool.check', ($: any, e: any, next: any) => (String(e.input?.command ?? '').startsWith('cd ') ? { decision: 'deny', reason: 'no cd today' } : next(e)))
      },
    },
  ],
} as any, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'cd sub', tool_use_id: nextId() })
  expect(String(refused(r))).toContain('no cd today')
  expect(w.toolRuns.length).toBe(0)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  for (const c of sentFolders(w, 'ls')) expect(c).toEqual([ROOT])
})

// ---------------------------------------------------------------- slug
// glue.ts slugOf must give the same folder name as tools/gen.mjs slugOf
// (tests/tools.node.test.mjs checks gen's side with the same values).
test('glue slugOf matches gen.mjs slugOf: : / . and space become -', async () => {
  expect(slugOf('c:/users/user/my.app')).toBe('c--users-user-my-app')
  expect(slugOf('c:/users/user/my app')).toBe('c--users-user-my-app')
  expect(slugOf('c:/users/user/bend2_test')).toBe('c--users-user-bend2_test')
})

// ---------------------------------------------------- Clef: cap and wording
// Backlog round 2, priority 3 C.

test('the 201st Clef-bound call in a session is not sent to Clef and shows one toast', async ($: any, on: any) => {
  const w = await world(on, { key: KEY, fetch: () => ({ status: 200, text: CLEF_SAFE }), approve: approveMock })
  await $.session.start(START)
  for (let i = 0; i < CLEF_SESSION_CAP; i++) {
    const c = await checkUnknown($, `frob ${i}`)
    expect(c.decision).toBe('ask')
  }
  expect(w.fetches.length).toBe(CLEF_SESSION_CAP)
  const before = w.toasts.length
  const c201 = await checkUnknown($, 'frob 201')
  const c202 = await checkUnknown($, 'frob 202')
  // never an allow: past the cap an unknown call is asked (or refused) as with no answer
  expect(c201.decision).toBe('ask')
  expect(c202.decision).toBe('ask')
  expect(w.fetches.length).toBe(CLEF_SESSION_CAP)
  const notes = w.toasts.slice(before)
  expect(notes).toEqual(['bend-guard: Clef limit for this session reached (200); unknown calls are asked or refused without a second opinion.'])
  const rows = w.logLines().slice(1)
  expect(rows[rows.length - 1][8]).toBe('capped')
  expect(rows[rows.length - 2][8]).toBe('capped')
  // a cached answer still costs nothing and is still used
  const again = await checkUnknown($, 'frob 3')
  expect(again.decision).toBe('ask')
  expect(w.logLines().slice(-1)[0][8]).toBe('cache risky=20 unsure=10')
  // the count is in /bend-guard status
  const s = await cmd($, 'status')
  expect(String(s?.text ?? '')).toContain('calls sent in this session: 200 of at most 200')
})

test('Clef questions v2 name Claude Code and bend-guard settings, shell profiles, startup files and git hooks', async () => {
  expect(QUESTIONS_VERSION).toBe('v2')
  const q = clefRequest({ text: 'frob' }, 'cloudflare/clef-flash', ['specs/']).questions as any
  const danger = String(q.danger.instructions)
  expect(danger).toContain('any file under specs/')
  expect(danger).toContain("Claude Code's or bend-guard's own settings")
  expect(danger).toContain('shell profile or startup file')
  expect(danger).toContain('git hooks or git config')
})

// ---------------------------------------------------- reasons that help
// Backlog round 2, priority 12. Display only: the verdict never changes and
// the Bend reason stays in the text as it was.

const SORT = parseSortRules(
  JSON.stringify({
    root: ROOT_N,
    lines: [
      { line: 1, text: SORT_LINE_1, kind: 'hard', rules: [{ kind: 'NoChange', rel: 'specs' }] },
      { line: 3, text: 'Never edit generated files in `specs/` either.', kind: 'hard', rules: [{ kind: 'NoChange', rel: 'specs' }] },
      { line: 7, text: 'Never run `rm -rf` on anything outside `tmp/`.', kind: 'hard', rules: [{ kind: 'TreeDeleteOnlyUnder', rel: 'tmp' }] },
    ],
  }),
  ROOT,
)

const BL = (xs: any[]): any => xs.reduceRight((t: any, h: any) => ({ $: 'Con', head: h, tail: t }), { $: 'Nil' })
const projectPath = (rel: string) => ({ $: 'Path', drive: ROOT_N[0], segs: BL([...ROOT_N.slice(3).split('/'), ...rel.split('/')]) })

test('engine order: the ask for `cat README.md && jq . package.json` shows the read and the jq part', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'cat README.md && jq . package.json', tool_use_id: nextId() })
  const c = w.engineChecks[0].c
  expect(c.decision).toBe('ask')
  const lines = String(c.reason).split('\n')
  // the Bend reason first, unchanged
  expect(lines[0]).toBe('bend-guard: not understood (the command jq is not modelled). The user can approve; or use a known command.')
  expect(String(c.reason)).toContain('What bend-guard read: reads readme.md; not understood: `jq . package.json`.')
})

test('engine order: `rm -rf specs` is refused naming BEND_RULES.md line 1, in the reason and the log', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person' } })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  const why = String(r.deny)
  expect(why.startsWith(SPECS_DENY + ' (BEND_RULES.md line 1: "Never delete or edit files in `specs/`.')).toBe(true)
  expect(why).toContain('What bend-guard read: deletes the tree specs.')
  expect(why).not.toContain('Hint:')
  expect(w.logLines()[1][6]).toContain('(BEND_RULES.md line 1: "Never delete or edit files in')
  expect(w.logLines()[1][6]).not.toContain('What bend-guard read')
})

test('a rule reason names every BEND_RULES.md line on that folder, cut to 120 characters', async () => {
  const s = ruleSuffix(SPECS_DENY, SORT)
  expect(s.startsWith(' (BEND_RULES.md line 1: "')).toBe(true)
  expect(s).toContain('; line 3: "Never edit generated files in `specs/` either."')
  const quoted = /line 1: "([^"]*)"/.exec(s)![1]!
  expect(quoted.length).toBe(120)
  expect(quoted.endsWith('...')).toBe(true)
  const tree = `bend-guard rule (BEND_RULES.md): recursive deletes for ${ROOT_N} are allowed only under ${ROOT_N}/tmp. Delete single files instead, or ask the user.`
  expect(ruleSuffix(tree, SORT)).toBe(' (BEND_RULES.md line 7: "Never run `rm -rf` on anything outside `tmp/`.")')
})

test('a reason matching no BEND_RULES.md line passes unchanged', async () => {
  const other = `bend-guard rule (BEND_RULES.md): ${HOME.replace(/\\/g, '/').toLowerCase()}/other/specs may not be changed. Leave it as it is, or ask the user to change BEND_RULES.md.`
  expect(ruleSuffix(other, SORT)).toBe('')
  expect(ruleSuffix('bend-guard: not understood (the command jq is not modelled). The user can approve; or use a known command.', SORT)).toBe('')
  expect(ruleSuffix(SPECS_DENY, null)).toBe('')
  expect(explain({ decision: 'deny', reason: other, tool: 'Read', input: {}, meaning: undefined, base: ROOT, sort: SORT })).toBe(other)
})

test("engine order: a 3,000-character command's Ask names its length and its lines", ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'yes' } })
  await $.session.start(START)
  const command = 'frob ' + 'a'.repeat(2000) + '\n' + 'b'.repeat(994)
  expect(command.length).toBe(3000)
  await $.tool.call({ tool: 'Bash', command, tool_use_id: nextId() })
  const reason = String(w.engineChecks[0].c.reason)
  expect(w.engineChecks[0].c.decision).toBe('ask')
  expect(reason).toContain('The command is 3,000 characters; the dialog may show only the start.')
  expect(reason).toContain('The command has 2 lines.')
  // the facts come before what bend-guard read
  expect(reason.indexOf('3,000 characters')).toBeLessThan(reason.indexOf('What bend-guard read'))
})

test('a refusal (Deny) carries what bend-guard read but no dialog facts', async () => {
  const command = 'frob ' + 'a'.repeat(2995)
  const meaning: any = { $: 'Unknown', why: 'the command frob is not modelled', known: { $: 'Nil' } }
  const reason = 'bend-guard: no person can answer an ask here, so this is refused. Ask the user in the main session. (x)'
  const shown = explain({ decision: 'deny', reason, tool: 'Bash', input: { command }, meaning, base: ROOT, sort: SORT })
  expect(shown.startsWith(reason + '\n')).toBe(true)
  expect(shown).not.toContain('characters;')
  expect(shown).toContain('not understood: `frob ')
})

test("engine order: an MCP tool's Ask says what it may do and shows its text arguments", ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
  await $.session.start(START)
  const long = 'x'.repeat(500)
  await $.tool.call({ tool: 'mcp__claude-in-chrome__javascript_tool', action: 'javascript_exec', text: 'document.title = "' + long + '"', tabId: 3, tool_use_id: nextId() })
  const c = w.engineChecks[0].c
  expect(c.decision).toBe('ask')
  const lines = String(c.reason).split('\n')
  expect(lines[1]).toBe('This MCP tool runs JavaScript in your browser.')
  expect(lines[2]).toBe('action: javascript_exec')
  expect(lines[3]!.startsWith('text: document.title = "xxx')).toBe(true)
  expect(lines[3]!.length).toBe('text: '.length + 200)
  expect(String(c.reason)).toContain('not understood: the tool mcp__claude-in-chrome__javascript_tool')
  expect(askFacts('mcp__desktop__computer', {}, undefined)).toEqual(['This MCP tool controls your desktop.'])
  expect(askFacts('mcp__srv__run_terminal_cmd', {}, undefined)).toEqual(['This MCP tool may run commands.'])
  expect(askFacts('mcp__srv__list_pages', {}, undefined)).toEqual([])
})

// Each hint, through the hooks: the unknown command's Ask ends with it.
const HINT_CASES: [string, string, string][] = [
  ['Bash', 'grep -A 3 foo src/a.ts', HINTS.grepContext],
  ['Bash', 'grep -rn -C2 foo src', HINTS.grepContext],
  ['Bash', 'sed -n 1,10p a.txt', HINTS.readRange],
  ['Bash', 'find . -name "*.ts"', HINTS.find],
  ['Bash', 'for f in a b; do cat $f; done', HINTS.loop],
  ['Bash', "python -c \"open('a.txt', 'w').write('x')\"", HINTS.editCode],
  ['Bash', 'cat > notes.txt <<END\nhello\nEND', HINTS.editCode],
  ['Bash', 'T=$(pwd); ls $T', HINTS.variable],
  ['PowerShell', 'Get-ChildItem | Where-Object { $_.Name -like "*.ts" }', HINTS.scriptBlock],
]

for (const [tool, command, hint] of HINT_CASES) {
  test(`engine order: hint for ${tool} \`${command.split('\n')[0]}\``, ENGINE, async ($: any, on: any) => {
    const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
    await $.session.start(START)
    await $.tool.call({ tool, command, tool_use_id: nextId() })
    const c = w.engineChecks[0].c
    expect(c.decision).toBe('ask')
    const lines = String(c.reason).split('\n')
    expect(lines[lines.length - 1]).toBe(hint)
    expect(lines[0]!.startsWith('bend-guard: not understood (')).toBe(true)
  })
}

test('the part not understood is named: a $( ), a keyword, an assignment', async () => {
  const syntax = (command: string) =>
    meaningLines({ $: 'Unknown', why: 'the command text uses shell syntax that bend-guard does not read (such as variables, $(...), a comma list)', known: { $: 'Nil' } } as any, ROOT, 'Bash', command)
  expect(syntax('T=$(pwd); ls $T')).toEqual(['not understood: `T=$(pwd)`'])
  const part = (command: string) =>
    meaningLines(
      { $: 'Unknown', why: 'the command line has a part that is not modelled (an empty command, a shell keyword, a variable assignment or a redirect without a file)', known: { $: 'Nil' } } as any,
      ROOT,
      'Bash',
      command,
    )
  expect(part('while true; do ls; done')).toEqual(['not understood: `while`'])
  expect(part('x=1')).toEqual(['not understood: `x=1`'])
})

test('what bend-guard read is at most four items, Windows paths, relative to the folder', async () => {
  const acts = ['a', 'b', 'c', 'd', 'e'].map(x => ({ $: 'Read', path: projectPath('src/' + x + '.ts') }))
  const known = meaningLines({ $: 'Known', actions: BL(acts) } as any, ROOT, 'Bash', 'cat src/a.ts')
  expect(known).toEqual(['reads src\\a.ts', 'reads src\\b.ts', 'reads src\\c.ts', 'and 2 more'])
  const unknown = meaningLines({ $: 'Unknown', why: 'the command jq is not modelled', known: BL([{ $: 'DeleteTree', path: projectPath('tmp/x') }, ...acts]) } as any, ROOT, 'Bash', 'rm -rf tmp/x && jq . a')
  expect(unknown.length).toBe(4)
  expect(unknown[0]).toBe('deletes the tree tmp\\x')
  expect(unknown[3]).toBe('not understood: `jq . a`')
  const outside = meaningLines({ $: 'Known', actions: BL([{ $: 'Read', path: { $: 'Path', drive: 'c', segs: BL(['windows', 'win.ini']) } }]) } as any, ROOT, 'Read', undefined)
  expect(outside).toEqual(['reads C:\\windows\\win.ini'])
})

test('no hint for a known command, a rule reason, a self-protection reason or a commit message', async () => {
  const unknown: any = { $: 'Unknown', why: 'the command find is not modelled', known: { $: 'Nil' } }
  expect(hintFor('Bash', 'find . -name x', unknown, 'bend-guard: not understood (x). The user can approve; or use a known command.')).toBe(HINTS.find)
  expect(hintFor('Bash', 'find . -name x', unknown, `bend-guard self-protection: ${HOME.replace(/\\/g, '/').toLowerCase()}/.claude/settings.json is protected.`)).toBeNull()
  expect(hintFor('Bash', 'find . -name x', unknown, SPECS_DENY)).toBeNull()
  expect(hintFor('Bash', 'ls', { $: 'Known', actions: { $: 'Nil' } } as any, 'bend-guard: x')).toBeNull()
  expect(hintFor('Bash', "git commit -m \"$(cat <<'END'\nmsg\nEND\n)\"", { ...unknown, why: 'shell syntax' }, 'bend-guard: not understood (x).')).toBeNull()
})

// ------------------------------- NoChange folders a not-understood call names
// Backlog round 3, priority 3 (reason text). Display only; the same boundary
// rules as Guard.bend's no-read check.

const UNKNOWN_PY: any = { $: 'Unknown', why: 'the command python is not modelled', known: { $: 'Nil' } }
const PY_ASK = notUnderstood('the command python is not modelled')
const SORT_Z = parseSortRules(
  JSON.stringify({
    root: ROOT_N,
    lines: [
      { line: 1, text: 'Never edit `specs/`.', rules: [{ kind: 'NoChange', rel: 'specs' }] },
      { line: 2, text: 'Never read `.env`.', rules: [{ kind: 'NoReadOrChange', rel: '.env' }] },
      { line: 3, text: 'Never edit `build/` or `dist/`.', rules: [{ kind: 'NoChange', rel: 'build' }, { kind: 'NoChange', rel: 'dist' }] },
      { line: 9, text: 'Never edit `build/` by hand.', rules: [{ kind: 'NoChange', rel: 'build' }] },
      { line: 12, text: 'Never edit `docs/signed/`.', rules: [{ kind: 'NoChange', rel: 'docs/signed' }] },
    ],
  }),
  ROOT,
)
const zonesOf = (command: string, base = ROOT) => namedNoChange(command, SORT_Z, base)

test('an Ask for a not-understood command names the NoChange folders it mentions, with their rule lines', async () => {
  expect(zonesOf('python x.py specs/a.md')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py SPECS\\a.md')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py ./specs')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py "specs."')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py --out=specs/x')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py ' + ROOT + '\\specs\\a.md')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py ' + ROOT_N.replace(/^([a-z]):/, '/$1') + '//specs')).toEqual(['specs\\ (rule 1)'])
  // from src: ../specs; from docs: signed/x names docs\signed
  expect(zonesOf('python x.py ../specs/a.md', ROOT + '\\src')).toEqual(['specs\\ (rule 1)'])
  expect(zonesOf('python x.py signed/x', ROOT + '\\docs')).toEqual(['docs\\signed\\ (rule 12)'])
  expect(zonesOf('python x.py docs/signed/x')).toEqual(['docs\\signed\\ (rule 12)'])
  // one folder on several lines, and several folders
  expect(zonesOf('python x.py build dist specs')).toEqual(['specs\\ (rule 1)', 'build\\ (rules 3 and 9)', 'dist\\ (rule 3)'])
  // not at a boundary, a no-read zone (Bend refuses those), from inside the zone
  for (const c of ['python x.py my-specs.txt', 'python x.py specsx', 'python x.py prespecs/a', 'python x.py specs-old', 'python x.py docs/signedx', 'python x.py .env'])
    expect(zonesOf(c)).toEqual([])
  expect(zonesOf('python x.py a.md', ROOT + '\\specs')).toEqual([])
  expect(namedNoChange('python x.py specs', null, ROOT)).toEqual([])
})

test('the folders line is on an Ask for a not-understood shell command only', async () => {
  const args = (over: any) => ({ decision: 'ask' as const, reason: PY_ASK, tool: 'Bash', input: { command: 'python x.py specs/a.md' }, meaning: UNKNOWN_PY, base: ROOT, sort: SORT_Z, ...over })
  const lines = explain(args({})).split('\n')
  expect(lines[0]).toBe(PY_ASK)
  expect(lines[1]).toBe('It mentions specs\\ (rule 1).')
  expect(explain(args({ decision: 'deny' }))).not.toContain('It mentions')
  expect(explain(args({ meaning: { $: 'Known', actions: { $: 'Nil' } } }))).not.toContain('It mentions')
  expect(explain(args({ tool: 'mcp__srv__run', input: { text: 'specs/a.md' }, meaning: { ...UNKNOWN_PY, why: 'tool mcp__srv__run not modelled' } }))).not.toContain('It mentions')
  expect(explain(args({ sort: null }))).not.toContain('It mentions')
})

test('engine order: the Ask for `python x.py specs/a.md` says it mentions specs\\ (rule 1)', ENGINE, async ($: any, on: any) => {
  const w = await world(on, { engine: { $, approver: 'person', person: 'no' } })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'python x.py specs/a.md', tool_use_id: nextId() })
  const c = w.engineChecks[0].c
  expect(c.decision).toBe('ask')
  const lines = String(c.reason).split('\n')
  expect(lines[0]).toBe(PY_ASK)
  expect(lines[1]).toBe('It mentions specs\\ (rule 1).')
  // the log's reason column holds the Bend reason only
  expect(w.logLines()[1][6]).not.toContain('It mentions')
})

test('what an Ask or a Deny adds below the reason is masked', async () => {
  const command = 'frob --token=abcdefghijklmnopqrstuvwxyz0123 https://user:hunter2@example.com'
  const frob: any = { $: 'Unknown', why: 'the command frob is not modelled', known: { $: 'Nil' } }
  for (const decision of ['ask', 'deny'] as const) {
    const shown = explain({ decision, reason: notUnderstood('the command frob is not modelled'), tool: 'Bash', input: { command }, meaning: frob, base: ROOT, sort: SORT })
    expect(shown).toContain('not understood: `frob --token=***')
    expect(shown).not.toContain('abcdefghijklmnopqrstuvwxyz0123')
    expect(shown).not.toContain('hunter2')
  }
  const mcp = explain({
    decision: 'ask',
    reason: notUnderstood('tool mcp__srv__fetch not modelled'),
    tool: 'mcp__srv__fetch',
    input: { header: 'Authorization: Bearer abcdef0123456789xyz' },
    meaning: { $: 'Unknown', why: 'tool mcp__srv__fetch not modelled', known: { $: 'Nil' } } as any,
    base: ROOT,
    sort: SORT,
  })
  expect(mcp).toContain('header: Authorization: Bearer ***')
  expect(mcp).not.toContain('abcdef0123456789xyz')
})

test("no hint text names bend-guard's files or approval", async () => {
  for (const h of Object.values(HINTS)) {
    expect(h).not.toContain('.claude')
    expect(h).not.toContain('bend-guard\\')
    expect(h.toLowerCase()).not.toContain('approve')
  }
})

test('formatting a reason adds under 5 ms per call', async () => {
  const path = projectPath('src/a.ts')
  const meaning: any = { $: 'Unknown', why: 'the command jq is not modelled', known: BL([{ $: 'Read', path }, { $: 'DeleteTree', path }]) }
  const command = 'cat src/a.ts && rm -rf src/a.ts && jq . package.json ' + 'x'.repeat(1500)
  const n = 500
  const t0 = performance.now()
  for (let i = 0; i < n; i++) {
    explain({ decision: 'ask', reason: SPECS_DENY, tool: 'Bash', input: { command }, meaning, base: ROOT, sort: SORT })
    explain({ decision: 'deny', reason: 'bend-guard: not understood (x).', tool: 'mcp__a__javascript_tool', input: { text: command }, meaning, base: ROOT, sort: SORT })
  }
  const perCall = (performance.now() - t0) / (2 * n)
  expect(perCall).toBeLessThan(5)
})

// ------------------------------------------------ round 3: a portable install
// Backlog round 3, priority 5: the home folder comes from USERPROFILE and the
// plugin's folder from $.plugin.root (the folder the test runner loads, PLUGIN).
// Anything else is the broken state wherever bend-guard is meant to guard.

const OTHER = 'C:\\Users\\other'
const OTHER_STATE = OTHER + '\\.claude\\bend-guard'
const USER_STATE = HOME.toLowerCase() + '\\.claude\\bend-guard'

test('a plugin folder outside <home>\\.claude\\local-plugins\\bend-guard: every call refused where BEND_RULES.md is, naming the expected folder', async ($: any, on: any) => {
  const w = await world(on, { home: OTHER })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  expect(String(r.deny)).toContain(OTHER + '\\.claude\\local-plugins\\bend-guard')
  expect(String(r.deny)).toContain('loaded from ' + PLUGIN)
  const c = await $.tool.check({ tool: 'Read', input: { file_path: ROOT + '\\README.md' }, approver: 'person' })
  expect(c.decision).toBe('deny')
  expect(w.toolRuns.length).toBe(0)
  expect(w.hostReqs.length).toBe(0)
  expect(w.toasts.join('\n')).toContain('refusing every tool call here')
  // nothing of the user's state folder is read: the state folder follows USERPROFILE
  expect(w.reads.some(p => p.toLowerCase().startsWith(USER_STATE))).toBe(false)
  expect(w.reads.some(p => p.toLowerCase() === (OTHER_STATE + '\\approved.json').toLowerCase())).toBe(true)
  expect(w.writes.length).toBe(0)
})

test('a plugin folder outside the expected one, in a project approved in that home but with no BEND_RULES.md: refused', async ($: any, on: any) => {
  const w = await world(on, { home: OTHER, rulesMd: false })
  w.files.set((OTHER_STATE + '\\approved.json').toLowerCase(), JSON.stringify(await defaultApproved({}, POLICY_TEXT)))
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(r.deny)).toContain('not installed correctly')
  expect(w.toolRuns.length).toBe(0)
})

test('a plugin folder outside the expected one, far from any rules or approved project: inactive and silent', async ($: any, on: any) => {
  const w = await world(on, { home: OTHER, rulesMd: false, cwd: 'C:\\elsewhere' })
  await $.session.start({ cwd: 'C:\\elsewhere', surface: 'terminal', isInteractive: true })
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(r.deny).toBeUndefined()
  expect(w.toasts.length).toBe(0)
  expect(w.hostReqs.length).toBe(0)
})

test('USERPROFILE not set: refused where BEND_RULES.md is, with no fixed folder tried', async ($: any, on: any) => {
  const w = await world(on, { home: null })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(r.deny)).toContain('USERPROFILE is not set')
  expect(w.toolRuns.length).toBe(0)
  expect(w.reads.some(p => /\.claude/i.test(p))).toBe(false)
})

test('USERPROFILE not set, no BEND_RULES.md here or above: inactive', async ($: any, on: any) => {
  const w = await world(on, { home: null, rulesMd: false })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(r.deny).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

test('a home folder that is not on drive C:: refused where BEND_RULES.md is', async ($: any, on: any) => {
  const w = await world(on, { home: 'D:\\Users\\user' })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(r.deny)).toContain('not a folder on drive C:')
  expect(w.toolRuns.length).toBe(0)
})

test('USERPROFILE in another spelling (lower case, a trailing backslash) finds the same folders and guards as before', async ($: any, on: any) => {
  const w = await world(on, { home: HOME.toLowerCase() + '\\' })
  await $.session.start(START)
  const no = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(String(no.deny)).toContain(SPECS_DENIED)
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ok.deny).toBeUndefined()
  expect(w.hostCalls()[0].home).toBe(HOME.slice(0, 1).toUpperCase() + HOME.slice(1).toLowerCase())
  expect(w.hostRuns[0].init.cwd).toBe(PLUGIN)
})

test('/bend-guard approve, confirm, status and the mode switches refuse to run when the install is wrong', async ($: any, on: any) => {
  const w = await world(on, { home: OTHER, approve: approveMock })
  await $.session.start(START)
  for (const args of ['approve', 'confirm', 'status', 'enforce', 'log-only']) {
    const text = String((await cmd($, args))?.text ?? '')
    expect(text).toContain('cannot run')
    expect(text).toContain(OTHER + '\\.claude\\local-plugins\\bend-guard')
    noDoubledPrefix(text)
  }
  expect(w.runs.length).toBe(0)
  expect(w.spawns.length).toBe(0)
  expect(w.writes.length).toBe(0)
})

test('/bend-guard doctor runs tools\\doctor.mjs from the tools folder and shows what it printed; nothing is written', async ($: any, on: any) => {
  const seen: string[][] = []
  const w = await world(on, {
    run: (argv: string[]) => {
      seen.push(argv)
      return { exitCode: 1, stdout: 'ok    node 22.11.0\nproblem  WSL distro Ubuntu-24.04 not found. Fix: wsl --install -d Ubuntu-24.04\n' }
    },
  })
  await $.session.start(START)
  const text = String((await cmd($, 'doctor'))?.text ?? '')
  expect(text).toContain('WSL distro Ubuntu-24.04 not found')
  expect(seen).toEqual([[NODE, PLUGIN + '\\tools\\doctor.mjs']])
  expect(w.runs[0].init.cwd).toBe(PLUGIN)
  expect(w.writes.length).toBe(0)
})

// ------------------------------------- round 3: /bend-guard why and test
// Backlog round 3, priority 10: explain verdicts to the user without the log.

test('/bend-guard why lists the last calls of this session, masked, with both verdicts and the rule line', async ($: any, on: any) => {
  const w = await world(on, { logOnly: true })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'rm -rf specs', tool_use_id: nextId() })
  await $.tool.call({ tool: 'Bash', command: 'deploy --api_key=ZXCVBNMASDFGHJKL0987', tool_use_id: nextId() })
  const writesBefore = w.writes.length
  const text = String((await cmd($, 'why'))?.text ?? '')
  noDoubledPrefix(text)
  expect(text).toContain('log-only')
  expect(text).toContain('1. Bash: ls -> allow.')
  expect(text).toContain('2. Bash: rm -rf specs -> allow (enforce mode: deny).')
  expect(text).toContain(SPECS_DENIED)
  expect(text).toContain('BEND_RULES.md line 1')
  expect(text).toContain('3. Bash: deploy --api_key=***')
  expect(text).not.toContain('ZXCVBNMASDFGHJKL0987')
  // why only reads
  expect(w.writes.length).toBe(writesBefore)
  const two = String((await cmd($, 'why 2'))?.text ?? '')
  expect(two).toContain('1. Bash: rm -rf specs')
  expect(two).toContain('2. Bash: deploy')
  expect(two).not.toContain('3. ')
  expect(String((await cmd($, 'why 0'))?.text ?? '')).toContain('1 to 20')
})

test('/bend-guard why shows at most 20 calls, and a long command cut to 120 characters', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  for (let i = 0; i < 22; i++) await $.tool.call({ tool: 'Bash', command: `ls ${i} ${'x'.repeat(200)}`, tool_use_id: nextId() })
  const text = String((await cmd($, 'why 50'))?.text ?? '')
  const lines = text.split('\n').filter(l => /^\d+\. /.test(l))
  expect(lines.length).toBe(20)
  expect(lines[0]).toContain('ls 2 x')
  for (const l of lines) expect(l.length).toBeLessThan(200)
  void w
})

test('/bend-guard why after a hot reload reads this session\'s log file', async ($: any, on: any) => {
  const w = await world(on, { surfaces: ['terminal'] })
  const line = ['2026-10-26T23:10:00.000Z', SESSION_ID, 'main (approver=person)', 'Bash', 'allow', 'deny', 'bend-guard rule (BEND_RULES.md): ' + ROOT_N + '/specs may not be changed.', 'no', '', '12', 'no', 'rm -rf specs\\nsecond line'].join('\t')
  w.files.set(LOG_PATH.toLowerCase(), LOG_HEADER + line + '\n')
  const text = String((await cmd($, 'why'))?.text ?? '')
  expect(text).toContain('1. Bash: rm -rf specs second line -> allow (enforce mode: deny).')
  expect(text).toContain('specs may not be changed')
})

test('/bend-guard why where bend-guard is inactive says so', async ($: any, on: any) => {
  const w = await world(on, { approved: null })
  await $.session.start(START)
  const text = String((await cmd($, 'why'))?.text ?? '')
  expect(text).toContain('not guarding')
  void w
})

test('/bend-guard test: cat README.md is allowed in both modes, with what bend-guard read', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const text = String((await cmd($, 'test cat README.md'))?.text ?? '')
  noDoubledPrefix(text)
  expect(text).toContain('enforce mode: allow')
  expect(text).toContain('log-only mode: allow')
  expect(text.toLowerCase()).toContain('reads readme.md')
  expect(text).toContain('enforce mode now')
  expect(w.hostCalls()[0].tool).toBe('Bash')
  expect(w.hostCalls()[0].approver).toBe('person')
  expect(w.hostCalls()[0].agent).toBe(false)
})

test('/bend-guard test: rm -rf specs is refused in enforce mode and only logged in log-only mode', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const text = String((await cmd($, 'test rm -rf specs'))?.text ?? '')
  expect(text).toContain('enforce mode: deny.')
  expect(text).toContain(SPECS_DENIED)
  expect(text).toContain('BEND_RULES.md line 1')
  expect(text).toContain('log-only mode: allow (logged: enforce mode would deny)')
  expect(text).toContain('deletes the tree specs')
  void w
})

test('/bend-guard test: an unknown command says Clef would be asked, and Clef is not called', async ($: any, on: any) => {
  const w = await world(on, { key: 'sk-or-v1-testkey0123456789', fetch: () => ({ status: 200, text: CLEF_SAFE }) })
  await $.session.start(START)
  const text = String((await cmd($, 'test jq .'))?.text ?? '')
  expect(text).toContain('Clef would be asked')
  expect(text).toContain('not understood')
  expect(w.fetches.length).toBe(0)
})

test('/bend-guard test writes no log line and leaves the possible folders unchanged', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const text = String((await cmd($, 'test Bash cd src'))?.text ?? '')
  expect(text).toContain('goes to the folder src')
  expect(text).toContain('Nothing ran, and nothing was logged.')
  expect(w.writes.length).toBe(0)
  expect(w.toolRuns.length).toBe(0)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  expect(cwdsSent(w, 'ls')).toEqual([[ROOT]])
  // and why does not list the test
  const why = String((await cmd($, 'why'))?.text ?? '')
  expect(why).toContain('1. Bash: ls')
  expect(why).not.toContain('cd src')
})

test('/bend-guard test PowerShell judges a PowerShell call; the text shown is masked', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  const text = String((await cmd($, 'test PowerShell deploy --api_key=ZXCVBNMASDFGHJKL0987'))?.text ?? '')
  expect(w.hostCalls()[0].tool).toBe('PowerShell')
  expect(text).toContain('PowerShell call')
  expect(text).not.toContain('ZXCVBNMASDFGHJKL0987')
  expect(String((await cmd($, 'test'))?.text ?? '')).toContain('test needs a command')
  expect(String((await cmd($, 'test Bash'))?.text ?? '')).toContain('test needs a command')
})

test('/bend-guard why, test and doctor answer only a person typing', async ($: any, on: any) => {
  const w = await world(on, { run: () => ({ exitCode: 0, stdout: 'ok' }) })
  await $.session.start(START)
  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: nextId() })
  const hostBefore = w.hostReqs.length
  for (const origin of [null, { kind: 'plugin', name: 'other' }, { kind: 'peer' }, { kind: 'task-notification' }, { kind: 'auto-continuation' }]) {
    for (const args of ['why', 'test cat README.md', 'doctor']) {
      let text = ''
      try {
        text = String((await cmd($, args, origin))?.text ?? '')
      } catch {
        text = 'answers only your own typing (the engine refused the origin)'
      }
      expect(text).toContain('answers only your own typing')
      expect(text).not.toContain('1. Bash')
    }
  }
  expect(w.hostReqs.length).toBe(hostBefore)
  expect(w.runs.length).toBe(0)
})

test('placesOf: the folders follow USERPROFILE; the local-plugins folder and Claude Code\'s plugin cache copy are accepted, nothing else', async () => {
  const v = placesOf('C:\\Users\\other', 'C:\\Users\\other\\.claude\\local-plugins\\bend-guard')
  expect(v).toEqual({
    ok: true,
    p: { home: 'C:\\Users\\other', state: 'C:\\Users\\other\\.claude\\bend-guard', tools: 'C:\\Users\\other\\.claude\\local-plugins\\bend-guard', pluginRoot: 'C:\\Users\\other\\.claude\\local-plugins\\bend-guard' },
  })
  // the plugin cache copy Claude Code makes on install; the tools stay in local-plugins
  const c = placesOf('C:\\Users\\other', 'c:/users/other/.claude/plugins/cache/local-mods/bend-guard/0.1.0')
  expect(c.ok).toBe(true)
  if (c.ok) expect(c.p.tools).toBe('C:\\Users\\other\\.claude\\local-plugins\\bend-guard')
  for (const root of [
    'C:\\Users\\user\\.claude\\local-plugins\\bend-guard', // another user's
    'C:\\Users\\other\\Downloads\\bend-guard',
    'C:\\Users\\other\\.claude\\plugins\\cache\\local-mods\\other\\0.1.0',
    'C:\\Users\\other\\.claude\\plugins\\cache\\local-mods\\bend-guard\\0.1.0\\x',
    'C:\\Users\\other\\.claude\\plugins\\cache\\..\\bend-guard\\0.1.0',
    '',
  ]) expect(placesOf('C:\\Users\\other', root).ok).toBe(false)
  expect(placesOf(undefined, PLUGIN).ok).toBe(false)
  expect(placesOf('D:\\Users\\other', 'D:\\Users\\other\\.claude\\local-plugins\\bend-guard').ok).toBe(false)
  expect(placesOf('C:\\Users\\..\\other', PLUGIN).ok).toBe(false)
  // The user's own install is unchanged
  const d = placesOf(HOME, PLUGIN)
  expect(d.ok).toBe(true)
  if (d.ok) expect(d.p.state).toBe(HOME + '\\.claude\\bend-guard')
})

// ------------------------------------------------- review round 1 (hooks)

// R1-02: a session.start that comes again (reload, enable, worker restart)
// must leave no moment where a call passes unchecked. Swept over how far the
// load has got when the call arrives.
const RACE_TICKS = [0, 1, 2, 3, 5, 8, 13, 20, 30, 40, 60, 80, 120, 200]
for (const k of RACE_TICKS) {
  test(`R1-02: a call ${k} ticks into a second session.start is checked and refused, never run unchecked`, async ($: any, on: any) => {
    const w = await world(on)
    await $.session.start(START)
    const before = w.hostReqs.length
    const again = $.session.start(START)
    for (let i = 0; i < k; i++) await Promise.resolve()
    const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
    await again
    expect(String(refused(r))).toContain(SPECS_DENIED)
    expect(w.hostReqs.length).toBeGreaterThan(before)
    expect(w.toolRuns.length).toBe(0)
  })
  test(`R1-02: a call ${k} ticks into the first session.start is checked and refused, never run unchecked`, async ($: any, on: any) => {
    const w = await world(on)
    const first = $.session.start(START)
    for (let i = 0; i < k; i++) await Promise.resolve()
    const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
    await first
    expect(String(refused(r))).toContain(SPECS_DENIED)
    expect(w.hostReqs.length).toBeGreaterThan(0)
    expect(w.toolRuns.length).toBe(0)
  })
}

test('R1-02: a second session.start reloads the policy: a call after it is still checked', async ($: any, on: any) => {
  const w = await world(on)
  await $.session.start(START)
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(String(refused(r))).toContain(SPECS_DENIED)
  const ok = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(refused(ok)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

// R1-03: origins the engine does not attest as a person (sdk, unclassified)
// may run confirm, enforce and log-only only after a yes in the dialog.
type Dialog = 'yes' | 'no' | 'dismissed'
function dialogWorld(answer: Dialog) {
  return (e: any) => {
    if (e.tool !== 'AskUserQuestion') return { result: { stdout: 'ran', stderr: '', interrupted: false }, text: 'ok' }
    if (answer === 'dismissed') return { deny: 'the dialog was dismissed (no one to ask)' }
    const q = e.questions?.[0]?.question ?? ''
    const label = answer === 'yes' ? 'Yes, go ahead' : 'No'
    return { result: { questions: e.questions, answers: { [q]: label } }, text: `User has answered your questions: "${q}"="${label}".` }
  }
}
const dialogs = (w: any) => w.toolRuns.filter((e: any) => e.tool === 'AskUserQuestion')
const modeRuns = (w: any) => w.runs.filter((r: any) => r.argv.includes('--mode-only'))

for (const kind of ['sdk', 'unclassified']) {
  for (const answer of ['no', 'dismissed'] as Dialog[]) {
    test(`R1-03: /bend-guard confirm from "${kind}", dialog ${answer}: nothing approved, no token`, async ($: any, on: any) => {
      const w = await world(on, { approve: approveMock, spawn: spawnOk, toolResult: dialogWorld(answer) })
      await $.session.start(START)
      await cmd($, 'approve', { kind })
      const r = await cmd($, 'confirm', { kind })
      const text = String(r?.text ?? '')
      expect(text).toContain('nothing was done')
      noDoubledPrefix(text)
      await w.clock.settle()
      expect(dialogs(w).length).toBe(1)
      expect(w.spawns.length).toBe(0)
      expect(tokenWrites(w).length).toBe(0)
    })
    for (const mode of ['log-only', 'enforce']) {
      test(`R1-03: /bend-guard ${mode} from "${kind}", dialog ${answer}: the mode is not switched, no token`, async ($: any, on: any) => {
        const w = await world(on, { approve: approveMock, toolResult: dialogWorld(answer) })
        await $.session.start(START)
        const r = await cmd($, mode, { kind })
        const text = String(r?.text ?? '')
        expect(text).toContain('nothing was done')
        noDoubledPrefix(text)
        expect(dialogs(w).length).toBe(1)
        expect(modeRuns(w).length).toBe(0)
        expect(tokenWrites(w).length).toBe(0)
      })
    }
  }
  test(`R1-03: /bend-guard log-only from "${kind}" with a yes in the dialog switches the mode`, async ($: any, on: any) => {
    const w = await world(on, { approve: approveMock, toolResult: dialogWorld('yes') })
    await $.session.start(START)
    await cmd($, 'log-only', { kind })
    expect(dialogs(w).length).toBe(1)
    expect(modeRuns(w).length).toBe(1)
    expect(modeRuns(w)[0].argv).toContain('--log-only')
    expect(tokenWrites(w).length).toBe(1)
  })
  test(`R1-03: /bend-guard confirm from "${kind}" with a yes in the dialog starts the approval`, async ($: any, on: any) => {
    const w = await world(on, { approve: approveMock, spawn: spawnOk, toolResult: dialogWorld('yes') })
    await $.session.start(START)
    await cmd($, 'approve', { kind })
    const r = await cmd($, 'confirm', { kind })
    expect(String(r?.text ?? '')).toContain('Approving')
    await w.clock.settle()
    expect(dialogs(w).length).toBe(1)
    expect(w.spawns.length).toBe(1)
  })
  test(`R1-03: read-only /bend-guard commands from "${kind}" need no dialog`, async ($: any, on: any) => {
    const w = await world(on, { approve: approveMock, toolResult: dialogWorld('no') })
    await $.session.start(START)
    await cmd($, 'status', { kind })
    await cmd($, 'approve', { kind })
    expect(dialogs(w).length).toBe(0)
  })
}

test('R1-03: a person typing (composer) gets no extra dialog for confirm or a mode switch', async ($: any, on: any) => {
  const w = await world(on, { approve: approveMock, spawn: spawnOk, toolResult: dialogWorld('no') })
  await $.session.start(START)
  await cmd($, 'approve')
  await cmd($, 'confirm')
  await w.clock.settle()
  await cmd($, 'log-only')
  expect(dialogs(w).length).toBe(0)
  expect(w.spawns.length).toBe(1)
  expect(modeRuns(w).length).toBe(1)
})

// R1-06: a failing $.fs.exists is not "approved.json is absent".
test('R1-06: $.fs.exists fails for approved.json: it is read anyway, and guarding stays on', async ($: any, on: any) => {
  const w = await world(on, { existsFails: /approved\.json$/i })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(String(refused(r))).toContain(SPECS_DENIED)
  expect(w.toolRuns.length).toBe(0)
})

test('R1-06: $.fs.exists fails and approved.json cannot be read, BEND_RULES.md present: every call refused', async ($: any, on: any) => {
  const w = await world(on, { existsFails: /approved\.json$/i, approvedUnreadable: true })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(refused(r))).toContain('approved.json cannot be read')
  expect(w.toolRuns.length).toBe(0)
})

test('R1-06: $.fs.exists fails for BEND_RULES.md and approved.json: still refused where the rules file can be read', async ($: any, on: any) => {
  const w = await world(on, { existsFails: /(approved\.json|BEND_RULES\.md)$/i, approvedUnreadable: true })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String(refused(r))).toContain('approved.json cannot be read')
  expect(w.toolRuns.length).toBe(0)
})

test('R1-06: no approved.json at all (exists says no) and no BEND_RULES.md: still inactive', async ($: any, on: any) => {
  const w = await world(on, { approved: null, rulesMd: false })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf specs' })
  expect(refused(r)).toBeUndefined()
  expect(w.toolRuns.length).toBe(1)
})

// R1-07: Clef's cache is keyed by the unmasked command.
test('R1-07: two commands that mask to the same text do not share a cached Clef answer', async ($: any, on: any) => {
  let n = 0
  const w = await world(on, { key: KEY, fetch: () => (++n === 1 ? { status: 200, text: CLEF_SAFE } : { status: 200, text: clefBody(0.9, 0.05) }) })
  await $.session.start(START)
  const a = await checkUnknown($, 'cat specs/a.md password=aaa')
  const b = await checkUnknown($, 'cat specs/a.md password=bbb')
  expect(w.fetches.length).toBe(2)
  expect(a.decision).toBe('allow')
  expect(b.decision).toBe('ask')
  // Clef is still sent only the masked text
  for (const f of w.fetches) {
    const body = JSON.parse(String(f.init?.body ?? '{}'))
    expect(body.state).toContain('password=***')
    expect(body.state).not.toContain('aaa')
    expect(body.state).not.toContain('bbb')
  }
  // the same command again is a cache hit
  await checkUnknown($, 'cat specs/a.md password=bbb')
  expect(w.fetches.length).toBe(2)
})
