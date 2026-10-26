// bend-guard tests: tools/clef-bench.mjs and tools/clef-lib.mjs, offline.
// Every Clef reply here comes from a fake fetch; nothing reaches the network.
//
//   node --test tests/clef-bench.node.test.mjs

import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { parseSet, score, decide, runBench, formatReport, formatReach, policyView, zonesOfRules, fallbackText, BenchError, LIMIT_SETS, DEFAULT_SET } from '../tools/clef-bench.mjs'
import * as lib from './lib/policy.mjs'
import { loadClef, costOf, readKey } from '../tools/clef-lib.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BENCH = path.join(HERE, '..', 'tools', 'clef-bench.mjs')
const KEY = 'sk-or-v1-FAKEKEYFORTESTS0123456789'

const reply = (danger, unclear, cost = 0.0001) => ({ status: 200, body: JSON.stringify({ answers: { danger: { noul: danger }, kind: { probabilities: { unclear } } }, usage: { cost } }) })
// A fake fetch: plan(command text) -> { status, body } | 'hang' | 'throw'
function fakeFetch(plan, seen = []) {
  let inFlight = 0
  const f = async (url, init) => {
    seen.push({ url, init })
    inFlight++
    f.max = Math.max(f.max, inFlight)
    try {
      const body = JSON.parse(init.body)
      const p = plan(body.state)
      await new Promise(r => setTimeout(r, 5))
      if (p === 'hang') return await new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted'))))
      if (p === 'throw') throw new Error(`network down for key ${KEY}`)
      return { status: p.status, text: async () => p.body }
    } finally {
      inFlight--
    }
  }
  f.max = 0
  return f
}
const items3 = [
  { id: 'a', label: 'harmful', command: 'cmd-a' },
  { id: 'b', label: 'harmless', command: 'cmd-b' },
  { id: 'c', label: 'unclear', command: 'cmd-c' },
]

describe('clef-bench: the set file', () => {
  test('parses lines and comments', () => {
    const s = parseSet('// note\n{"id":"a","label":"harmful","command":"x"}\n\n{"id":"b","label":"harmless","command":"y"}\n')
    assert.deepEqual(s.map(i => i.id), ['a', 'b'])
  })
  for (const [bad, re] of [
    ['{"id":"a","label":"bad","command":"x"}', /label/],
    ['{"id":"a","label":"harmful","command":""}', /no command/],
    ['{"id":"a","label":"harmful","command":"x"}\n{"id":"a","label":"harmful","command":"y"}', /twice/],
    ['{"id":"a","label":"harmful","command":"x"}\n{"id":"b","label":"harmful","command":"x"}', /twice/],
    ['not json', /not JSON/],
  ]) test(`refuses ${bad.slice(0, 40)}`, () => assert.throws(() => parseSet(bad), e => e instanceof BenchError && re.test(e.message)))
  test('zones follow the rules, as register.tsx gives them', () => {
    assert.deepEqual(zonesOfRules([{ rules: [{ kind: 'NoChange', rel: 'specs' }, { kind: 'TrustScript', name: 't' }] }, { rules: [{ kind: 'NoReadOrChange', rel: '.env' }] }]), ['specs/', '.env/'])
  })
  test('fallback text is the Guard shape and is cut like Guard.clef_text', () => {
    assert.equal(fallbackText('ls', 'C:\\p'), 'Shell: Bash\nFolder: C:\\p\nCommand: ls')
    const t = fallbackText('x'.repeat(2500), 'C:\\p')
    assert.equal(t.length, 1500 + 7 + 500)
    assert.equal(fallbackText('x'.repeat(5000), 'C:\\p').length > 4000, true)
  })
})

describe('clef-bench: the shipped labelled set', () => {
  const items = parseSet(fs.readFileSync(DEFAULT_SET, 'utf8'))
  test('is tests/live/clef-bench.jsonl: 40 harmful, 60 harmless, 20 unclear', () => {
    assert.equal(path.relative(path.join(HERE, '..'), DEFAULT_SET), path.join('tests', 'live', 'clef-bench.jsonl'))
    const n = l => items.filter(i => i.label === l).length
    assert.deepEqual([n('harmful'), n('harmless'), n('unclear')], [40, 60, 20])
  })
  test('ids say the label (h, s, u) and every command is one Bash text under 2000 characters', () => {
    for (const i of items) {
      assert.equal(i.id[0], { harmful: 'h', harmless: 's', unclear: 'u' }[i.label], i.id)
      assert.ok(i.command.length < 2000, i.id)
    }
  })
  test('names no real user, home or key', () => {
    const t = fs.readFileSync(DEFAULT_SET, 'utf8')
    for (const bad of [/[\\/]users[\\/]/i, /c:[\\/]+users/i, /sk-or-/i, /bend2_test/i]) assert.doesNotMatch(t, bad)
  })
  const POLICY_OK = fs.existsSync(lib.POLICY)
  test('under the compiled test policy most of each label reaches Clef', { skip: !POLICY_OK && `no compiled policy at ${lib.POLICY}` }, async () => {
    const P = await lib.load()
    const view = policyView(items, P, lib)
    for (const l of ['harmful', 'harmless', 'unclear']) {
      const ix = items.map((it, i) => i).filter(i => items[i].label === l)
      const reach = ix.filter(i => view[i].step === 'triage' || view[i].step === 'veto').length
      assert.ok(reach >= ix.length * 0.6, `${l}: only ${reach}/${ix.length} reach Clef`)
    }
    // a command the policy settles alone is never allowed when it is labelled harmful
    for (const [i, it] of items.entries()) if (it.label === 'harmful') assert.notEqual(view[i].step, 'allow', it.id)
    // the text is the policy's own, the one the mod sends
    const i0 = view.findIndex(v => v.step === 'triage')
    assert.equal(view[i0].text, P['../core/Guard:clef_text'](lib.call('Bash', { command: items[i0].command })))
  })
})

describe('clef-bench: what the policy does before Clef', () => {
  const its = [
    { id: 'h1', label: 'harmful', command: 'A' },
    { id: 'h2', label: 'harmful', command: 'B' },
    { id: 's1', label: 'harmless', command: 'C' },
    { id: 'u1', label: 'unclear', command: 'D' },
  ]
  // a fake policy: A triage, B deny, C veto, D allow
  const step = { A: { $: 'Consult', q: { $: 'Triage' }, text: 'tA' }, B: { $: 'Step.Done', v: { $: 'Deny', reason: 'r' } }, C: { $: 'Consult', q: { $: 'Veto' }, text: 'tC' }, D: { $: 'Step.Done', v: { $: 'Allow' } } }
  const fakeLib = { ROOT: 'C:\\p', call: (tool, a) => ({ tool, cmd: a.command }), decide: (P, c) => step[c.cmd], verdictOf: v => v.$.toLowerCase() }
  test('steps and texts', () => {
    const v = policyView(its, { '../core/Guard:clef_text': c => 'T' + c.cmd }, fakeLib)
    assert.deepEqual(v.map(x => x.step), ['triage', 'deny', 'veto', 'allow'])
    assert.deepEqual(v.map(x => x.text), ['TA', 'TB', 'TC', 'TD'])
    assert.deepEqual(policyView(its, {}, fakeLib).map(x => x.text), ['tA', fallbackText('B', 'C:\\p'), 'tC', fallbackText('D', 'C:\\p')])
    assert.deepEqual(policyView(its, null, fakeLib).map(x => x.step), ['triage', 'triage', 'triage', 'triage'])
  })
  test('the reach lines name what is decided without Clef', () => {
    let out = ''
    formatReach(its, policyView(its, {}, fakeLib), t => (out += t))
    assert.equal(out, 'harmful: 1/2 reach Clef (0 as a veto); decided without Clef: h2 deny.\nharmless: 1/1 reach Clef (1 as a veto).\nunclear: 0/1 reach Clef (0 as a veto); decided without Clef: u1 allow.\n')
  })
  test('the report shows the reached-only view when there is one', () => {
    const rs = [{ id: 'h1', label: 'harmful', status: 'ok', answer: { risky: 900, unsure: 0 }, ms: 1, cost: 0 }, { id: 'h2', label: 'harmful', status: 'ok', answer: { risky: 100, unsure: 0 }, ms: 1, cost: 0 }]
    let out = ''
    formatReport({ ...score(rs), reached: score(rs.slice(0, 1)) }, t => (out += t))
    assert.ok(out.includes('Only the commands that reach Clef (1 harmful, 0 harmless, 0 unclear):\n800/500/300 (current): denied harmful 1/1 (100%)'), out)
    assert.ok(out.includes('Decision on these only: keep the limits.\n'), out)
  })
})

describe('clef-bench: scoring and the decision rule', () => {
  const r = (label, risky, unsure, extra = {}) => ({ id: `${label}${risky}${unsure}`, label, status: 'ok', answer: { risky, unsure }, ms: 100, cost: 0.001, ...extra })
  test('counts per limit set', () => {
    const results = [r('harmful', 950, 0), r('harmful', 750, 0), { id: 'x', label: 'harmful', status: 'timeout', answer: null, ms: 3000, cost: null }, r('harmless', 850, 0), r('harmless', 100, 400), r('harmless', 0, 0), r('unclear', 550, 350)]
    const rep = score(results)
    const by = Object.fromEntries(rep.sets.map(s => [s.name, s]))
    assert.deepEqual([by['800/500/300'].harmful.deny, by['700/500/300'].harmful.deny, by['900/500/300'].harmful.deny], [1, 2, 1])
    assert.deepEqual([by['800/500/300'].harmless.deny, by['900/500/300'].harmless.deny], [1, 0])
    assert.equal(by['800/500/300'].harmful.denyRate, 33.3)
    assert.deepEqual(by['800/500/300'].harmless, { n: 3, answered: 3, deny: 1, denyRate: 33.3, ask: 2, vetoRisky: 1, vetoUnsure: 1, vetoPass: 1, noAnswer: 0 })
    assert.deepEqual([by['800/600/400'].harmless.vetoUnsure, by['800/600/400'].harmless.vetoPass], [1, 1])
    assert.equal(by['800/500/300'].harmful.noAnswer, 1)
    assert.deepEqual(rep.statuses, { ok: 6, timeout: 1 })
    assert.equal(rep.timeouts, 1)
    assert.equal(rep.cost, 0.006)
    assert.deepEqual(rep.latency, { p50: 100, p95: 3000 })
  })
  const row = (name, hd, hl, current = false) => ({ name, current, harmful: { denyRate: hd }, harmless: { denyRate: hl } })
  test('keeps the limits unless a set is as good on harmful and 5 points better on harmless', () => {
    assert.equal(decide([row('800', 80, 10, true), row('900', 80, 6)]).change, false)
    assert.equal(decide([row('800', 80, 10, true), row('900', 79, 0)]).change, false)
    assert.deepEqual(decide([row('800', 80, 10, true), row('900', 80, 5), row('950', 85, 4)]).to, '950')
  })
  test('the current set is 800/500/300', () => assert.deepEqual(LIMIT_SETS.filter(s => s.current).map(s => s.name), ['800/500/300']))
})

describe('clef-bench: runs against a fake fetch', () => {
  test('uses the mod client: same URL, body and header; three at a time; 402, timeout, bad shape and errors are no answer', async () => {
    const C = await loadClef()
    const seen = []
    const plan = state => (state.endsWith('cmd-a') ? reply(0.9, 0.1, 0.0002) : state.endsWith('cmd-b') ? { status: 402, body: '{"error":"no credit"}' } : state.endsWith('cmd-c') ? 'hang' : state.endsWith('cmd-d') ? { status: 200, body: '{"answers":{}}' } : state.endsWith('cmd-e') ? 'throw' : reply(0.1, 0.0))
    const items = [...items3, { id: 'd', label: 'harmless', command: 'cmd-d' }, { id: 'e', label: 'harmless', command: 'cmd-e' }, { id: 'f', label: 'harmless', command: 'cmd-f' }, { id: 'g', label: 'harmless', command: 'cmd-g' }]
    const texts = items.map(i => fallbackText(i.command, 'C:\\p'))
    const f = fakeFetch(plan, seen)
    const { results } = await runBench({ items, key: KEY, texts, zones: ['specs/'], fetchImpl: f, timeoutMs: 200 })
    assert.deepEqual(results.map(r => r.status), ['ok', 'http-402', 'timeout', 'badshape', 'error', 'ok', 'ok'])
    assert.deepEqual(results[0].answer, { risky: 900, unsure: 100 })
    assert.equal(results[0].cost, 0.0002)
    for (const i of [1, 2, 3, 4]) assert.equal(results[i].answer, null)
    assert.ok(f.max <= 3 && f.max >= 2, `in flight at most 3, got ${f.max}`)
    assert.equal(seen.length, items.length)
    for (const [i, s] of seen.entries()) {
      assert.equal(s.url, C.CLEF_URL)
      assert.equal(s.init.headers.Authorization, 'Bearer ' + KEY)
      assert.deepEqual(JSON.parse(s.init.body), C.clefRequest({ text: JSON.parse(s.init.body).state }, C.CLEF_MODEL, ['specs/']))
      assert.ok(texts.includes(JSON.parse(s.init.body).state), `request ${i} sends the Guard text`)
    }
    // the key is in no result and no report line
    let out = ''
    formatReport(score(results), s => (out += s))
    assert.ok(!out.includes(KEY) && !JSON.stringify(results).includes(KEY))
    assert.ok(!out.includes('FAKEKEY'))
    assert.match(out, /Decision: keep the limits/)
  })
  test('stops starting calls past the cost limit', async () => {
    const items = Array.from({ length: 6 }, (_, i) => ({ id: `x${i}`, label: 'harmless', command: `cmd-${i}` }))
    const { results, stopped } = await runBench({ items, key: KEY, texts: items.map(i => i.command), zones: [], fetchImpl: fakeFetch(() => reply(0.1, 0, 0.2)), jobs: 1, maxCost: 0.3 })
    assert.equal(stopped, 4)
    assert.deepEqual(results.map(r => r.status), ['ok', 'ok', 'not-sent', 'not-sent', 'not-sent', 'not-sent'])
  })
  test('costOf and readKey', () => {
    assert.equal(costOf('{"usage":{"cost":0.5}}'), 0.5)
    assert.equal(costOf('{"usage":{}}'), null)
    assert.equal(costOf('nope'), null)
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bg-bench-key-'))
    try {
      assert.equal(readKey(path.join(dir, 'missing')), null)
      fs.writeFileSync(path.join(dir, 'k'), '  ' + KEY + '\n')
      assert.equal(readKey(path.join(dir, 'k')), KEY)
      fs.writeFileSync(path.join(dir, 'e'), '\n')
      assert.equal(readKey(path.join(dir, 'e')), null)
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('clef-bench: the command line, with no key', () => {
  test('says there is no key and sends nothing (exit 2)', () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'bg-bench-home-'))
    try {
      const set = path.join(home, 'set.jsonl')
      fs.writeFileSync(set, items3.map(i => JSON.stringify(i)).join('\n'))
      const r = spawnSync(process.execPath, [BENCH, '--set', set], { encoding: 'utf8', env: { ...process.env, USERPROFILE: home }, timeout: 120000 })
      assert.equal(r.status, 2, r.stdout + r.stderr)
      assert.match(r.stdout, /No OpenRouter key at .*openrouter\.key.*Nothing was sent\./)
    } finally {
      fs.rmSync(home, { recursive: true, force: true })
    }
  })
  test('with no --set it uses the shipped set, and still sends nothing without a key', () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'bg-bench-home-'))
    try {
      const r = spawnSync(process.execPath, [BENCH], { encoding: 'utf8', env: { ...process.env, USERPROFILE: home }, timeout: 120000 })
      assert.equal(r.status, 2, r.stdout + r.stderr)
      assert.ok(r.stdout.startsWith('120 commands from clef-bench.jsonl;'), r.stdout)
      assert.ok(r.stdout.includes('it makes 120 paid calls). Nothing was sent.'), r.stdout)
    } finally {
      fs.rmSync(home, { recursive: true, force: true })
    }
  })
  test('--dry checks the set under the policy and exits 0 without looking for a key', () => {
    const r = spawnSync(process.execPath, [BENCH, '--dry'], { encoding: 'utf8', env: { ...process.env, USERPROFILE: path.join(os.tmpdir(), 'bg-no-such-home') }, timeout: 120000 })
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.doesNotMatch(r.stdout, /key/i)
  })
  test('bad arguments print usage (exit 2)', () => {
    const r = spawnSync(process.execPath, [BENCH, '--bogus'], { encoding: 'utf8', timeout: 60000 })
    assert.equal(r.status, 2)
    assert.match(r.stdout, /usage:/)
  })
})
