// bend-guard tests: the tools in tools/ (gen.mjs, probes.mjs, approve.mjs,
// draft-check.mjs, wsl.mjs, suggest.mjs, stage.sh + prove.sh).
//
//   node --test tests/tools.node.test.mjs
//   node --test --test-name-pattern=gen tests/tools.node.test.mjs
//   BG_SKIP_WSL=1 node --test tests/tools.node.test.mjs   (skips the prove.sh tests)
//
// Needs tests/.build/policy.mjs (node tests/lib/build.mjs) for the probe runs.
//
// Safety: nothing here writes to the live state folder
// ~\.claude\bend-guard. The real approve.mjs is only run without
// a terminal (refused), with --status, or with --preview (which writes one
// snapshot under the drafts folder; the test removes it). The /bend-guard
// handshake (--from-mod, --mode-only, --snapshot) is tested on a SANDBOX copy
// of approve.mjs whose state and drafts folders are temp folders; the test
// checks the copy no longer names the real folders before it runs it. The WSL
// tests use their own build name, tools-test-prove.

import { test, describe, before, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { generate, GenError, lawTexts, lawStem, slugOf } from '../tools/gen.mjs'
import { buildProbes, runProbes, probeCall, winPath } from '../tools/probes.mjs'
import { toWslPath, runWsl, compiledSha, compiledMatches } from '../tools/wsl.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const P = path.join(HERE, '..')
const TOOLS = path.join(P, 'tools')
const FIXTURE = path.join(P, 'bend', 'fixtures', 'bend2_test')
const FIXTURE_ROOT = 'c:/users/user/bend2_test'
const POLICY = process.env.BG_POLICY ? path.resolve(process.env.BG_POLICY) : path.join(HERE, '.build', 'policy.mjs')

// The real state and drafts folders of whoever runs the tests (never written).
const LIVE_S = path.join(os.homedir(), '.claude', 'bend-guard')
const LIVE_D = path.join(os.homedir(), '.claude', 'bend-guard-drafts')
const LIVE_APPROVED = path.join(LIVE_S, 'approved.json')
const LIVE_TOKEN = path.join(LIVE_S, '.approve-token')

const fixtureLines = () => JSON.parse(fs.readFileSync(path.join(FIXTURE, 'rules.json'), 'utf8'))
const fixtureAsk = () => JSON.parse(fs.readFileSync(path.join(FIXTURE, 'ask.json'), 'utf8'))
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex')

const temps = []
function tmpDir(prefix) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  temps.push(d)
  return d
}
after(() => {
  for (const d of temps) fs.rmSync(d, { recursive: true, force: true })
})

// A draft folder holding sort.json and ask.json (objects, or raw text).
const NONE = Symbol('none') // leave the file out
function draft(sort, ask = fixtureAsk()) {
  const d = tmpDir('bg-tools-draft-')
  if (sort !== NONE) fs.writeFileSync(path.join(d, 'sort.json'), typeof sort === 'string' ? sort : JSON.stringify(sort, null, 2))
  if (ask !== NONE) fs.writeFileSync(path.join(d, 'ask.json'), typeof ask === 'string' ? ask : JSON.stringify(ask, null, 2))
  return d
}

function gen(sort, ask, projectsDir = null) {
  const d = draft(sort, ask)
  const out = tmpDir('bg-tools-out-')
  const r = generate({ draftDir: d, outDir: out, projectsDir })
  return { ...r, out, read: f => fs.readFileSync(path.join(out, f), 'utf8') }
}

// One hard line with the given rules, at the fixture root.
const hard = (rules, extra = {}) => ({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a rule', kind: 'hard', reason: 'r', rules, ...extra }] })

function refuses(sort, re, ask) {
  assert.throws(() => gen(sort, ask), err => {
    assert.ok(err instanceof GenError, `expected a GenError, got ${err && err.constructor && err.constructor.name}: ${err && err.message}`)
    assert.match(err.message, re)
    return true
  })
}

const node = (script, args, opts = {}) =>
  spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', timeout: opts.timeout ?? 120000, input: opts.input, cwd: opts.cwd ?? P, windowsHide: true })

const bytesOrNull = f => {
  try {
    return fs.readFileSync(f)
  } catch {
    return null
  }
}

// ===========================================================================
// gen.mjs

describe('gen: refusals', () => {
  test('rel "../x" is refused', () => refuses(hard([{ kind: 'NoChange', rel: '../x' }]), /holds "\.\."/))
  test('rel "a/../b" is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'a/../b' }]), /holds "\.\."/))
  test('rel "." is refused', () => refuses(hard([{ kind: 'NoChange', rel: '.' }]), /holds "\."/))
  test('rel "Specs" (upper case) is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'Specs' }]), /not plain lower-case names/))
  test('rel "a b" (space) is refused', () => refuses(hard([{ kind: 'NoReadOrChange', rel: 'a b' }]), /not plain lower-case names/))
  test('rel with a leading / is refused', () => refuses(hard([{ kind: 'NoChange', rel: '/specs' }]), /starts with \//))
  test('rel with a trailing / is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'specs/' }]), /not plain lower-case names/))
  test('rel with a backslash is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'specs\\x' }]), /not plain lower-case names/))
  test('rel starting with - is refused', () => refuses(hard([{ kind: 'NoChange', rel: '-rf' }]), /not plain lower-case names/))
  test('rel ending in . is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'specs.' }]), /not plain lower-case names/))
  test('empty rel is refused', () => refuses(hard([{ kind: 'NoChange', rel: '' }]), /non-empty string/))
  test('rel that is not a string is refused', () => refuses(hard([{ kind: 'TreeDeleteOnlyUnder', rel: ['tmp'] }]), /non-empty string/))
  test('unknown rule kind is refused', () => refuses(hard([{ kind: 'AllowEverything' }]), /unknown rule kind "AllowEverything"/))
  test('a rule with an extra key is refused', () => refuses(hard([{ kind: 'NoChange', rel: 'specs', also: 'x' }]), /unknown key "also"/))
  test('NoForcePush with a key is refused', () => refuses(hard([{ kind: 'NoForcePush', branch: 'main' }]), /unknown key "branch"/))
  test('NoPushTo without a branch is refused', () => refuses(hard([{ kind: 'NoPushTo' }]), /"branch" is missing/))
  for (const b of ['main"}', '-f', 'ma in', 'main;rm', 'HEAD:main', 'm\u00e4in', 'main\n', '$(id)', '']) {
    test(`branch ${JSON.stringify(b)} is refused`, () => refuses(hard([{ kind: 'NoPushTo', branch: b }]), /branch .* must match/s))
  }
  test('branch longer than 200 characters is refused', () => refuses(hard([{ kind: 'NoPushTo', branch: 'a'.repeat(201) }]), /must match/))
  for (const n of ['build && rm -rf /', 'test"}', '--inspect', 'a`b`', 'x{y}']) {
    test(`script name ${JSON.stringify(n)} is refused`, () => refuses(hard([{ kind: 'TrustScript', name: n }]), /name .* must match/s))
  }
  test('Bend text in rel is refused', () =>
    refuses(hard([{ kind: 'NoChange', rel: 'x"}, T.NoForcePush{}]}, T.Project{T.Path{"c", []}, [T.NoChange{"y' }]), /not plain lower-case names/))
  test('Bend text in a root folder name is refused', () =>
    refuses({ root: 'c:/users/x"}, []}/y', lines: [] }, /folder name/))
  test('missing root is refused', () => refuses({ lines: [] }, /"root" is missing/))
  test('root that is not normalised is refused (upper case)', () => refuses({ root: 'C:/Users/user/bend2_test', lines: [] }, /not a normalised/))
  test('root with backslashes is refused', () => refuses({ root: 'c:\\users\\user', lines: [] }, /not a normalised/))
  test('root "c:/" with no folder is refused', () => refuses({ root: 'c:/', lines: [] }, /not a normalised/))
  test('root with a ".." folder is refused', () => refuses({ root: 'c:/users/../windows', lines: [] }, /folder name/))
  test('root ending in / is refused', () => refuses({ root: 'c:/users/user/', lines: [] }, /folder name ""/))
  test('duplicate line numbers are refused', () =>
    refuses(
      {
        root: FIXTURE_ROOT,
        lines: [
          { line: 2, text: 'a', kind: 'judgment', reason: 'r', rules: [] },
          { line: 2, text: 'b', kind: 'judgment', reason: 'r', rules: [] },
        ],
      },
      /line 2 appears twice/,
    ))
  test('line 0 is refused', () => refuses({ root: FIXTURE_ROOT, lines: [{ line: 0, text: 'a', kind: 'ask', reason: 'r', rules: [] }] }, /positive whole number/))
  test('line 1.5 is refused', () => refuses({ root: FIXTURE_ROOT, lines: [{ line: 1.5, text: 'a', kind: 'ask', reason: 'r', rules: [] }] }, /positive whole number/))
  test('unknown line kind is refused', () => refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a', kind: 'soft', reason: 'r', rules: [] }] }, /is not hard, ask or judgment/))
  test('rules on an ask line are refused', () =>
    refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a', kind: 'ask', reason: 'r', rules: [{ kind: 'NoForcePush' }] }] }, /only a hard line may carry rules/))
  test('a line break in the text is refused', () =>
    refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a\nlaw evil:', kind: 'judgment', reason: 'r', rules: [] }] }, /control character or line break/))
  test('an escape character in the reason is refused', () =>
    refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a', kind: 'judgment', reason: '\u001b[2Jhidden', rules: [] }] }, /control character/))
  test('a line break in the suggestion is refused', () =>
    refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a', kind: 'judgment', reason: 'r', suggestion: 'x\ny', rules: [] }] }, /suggestion: holds a control/))
  test('an unknown key on a line is refused', () =>
    refuses({ root: FIXTURE_ROOT, lines: [{ line: 1, text: 'a', kind: 'judgment', reason: 'r', rules: [], bend: 'law x:' }] }, /unknown key "bend"/))
  test('an unknown top-level key in sort.json is refused', () => refuses({ root: FIXTURE_ROOT, lines: [], laws: 'law x:' }, /unknown key "laws"/))
  test('sort.json that is not JSON is refused', () => refuses('{ root: ', /not valid JSON/))
  test('a missing sort.json is refused', () => refuses(NONE, /sort.json: .* is missing/))
  test('a missing ask.json is refused', () => refuses(hard([]), /ask.json: .* is missing/, NONE))
  test('ask.json with a missing key is refused', () => refuses(hard([]), /"lintBeforeDone" is missing/, { newTopLevelDir: true, npmInstall: true, testBeforeDone: null }))
  test('ask.json with a blank test command is refused', () =>
    refuses(hard([]), /must be a command or null/, { newTopLevelDir: true, npmInstall: true, testBeforeDone: '  ', lintBeforeDone: null }))
  test('ask.json with a line break in a command is refused', () =>
    refuses(hard([]), /control character/, { newTopLevelDir: true, npmInstall: true, testBeforeDone: 'npm test\nrm -rf /', lintBeforeDone: null }))
  test('ask.json with a string where a boolean belongs is refused', () =>
    refuses(hard([]), /must be true or false/, { newTopLevelDir: 'yes', npmInstall: true, testBeforeDone: null, lintBeforeDone: null }))

  test('the command line refuses a wrong argument count and unknown options (exit 1)', () => {
    const a = node(path.join(TOOLS, 'gen.mjs'), ['only-one'])
    assert.equal(a.status, 1)
    assert.match(a.stderr, /usage: node gen.mjs/)
    const b = node(path.join(TOOLS, 'gen.mjs'), ['a', 'b', '--bogus'])
    assert.equal(b.status, 1)
    assert.match(b.stderr, /unknown option --bogus/)
  })
})

describe('gen: Bend text smuggled into the free-text fields stays out of the Bend files', () => {
  test('text, reason and suggestion never reach a .bend file', () => {
    const evil = 'x"}]} law evil: {{ROOT}} import ../../etc/passwd.bend as E #'
    const g = gen({
      root: FIXTURE_ROOT,
      lines: [
        { line: 1, text: `Never edit \`specs/\`. ${evil}`, kind: 'hard', reason: `reason ${evil}`, suggestion: `sugg ${evil}`, rules: [{ kind: 'NoChange', rel: 'specs' }] },
        { line: 2, text: evil, kind: 'judgment', reason: evil, rules: [] },
      ],
    })
    for (const f of ['Rules.bend', 'Policy.bend', 'LAWS.bend', 'PROOF.bend']) {
      const t = g.read(`project/${f}`)
      assert.ok(!t.includes('evil'), `${f} holds the smuggled text`)
      assert.ok(!t.includes('passwd'), `${f} holds the smuggled import`)
    }
    const d = JSON.parse(g.read('display.json'))
    assert.equal(d.lines[1].text, evil, 'display.json keeps the text as data')
    assert.deepEqual(g.laws.sort(), ['reads_allowed', 'specs_protected'])
  })
})

describe('gen: output on the fixture', () => {
  let g
  before(() => {
    g = gen({ root: FIXTURE_ROOT, lines: fixtureLines() })
  })

  test('writes exactly the four project .bend files, display.json and probes.json', () => {
    assert.deepEqual(fs.readdirSync(path.join(g.out, 'project')).sort(), ['LAWS.bend', 'PROOF.bend', 'Policy.bend', 'Rules.bend'])
    assert.ok(fs.existsSync(path.join(g.out, 'display.json')))
    assert.ok(fs.existsSync(path.join(g.out, 'probes.json')))
  })

  test('no template placeholder is left in any generated file', () => {
    for (const f of ['Rules.bend', 'Policy.bend', 'LAWS.bend', 'PROOF.bend']) assert.ok(!g.read(`project/${f}`).includes('{{'), f)
  })

  test('display.json law text equals the generated LAWS.bend text', () => {
    const laws = g.read('project/LAWS.bend')
    const lines = laws.split('\n')
    const d = JSON.parse(g.read('display.json'))
    const shown = [...d.lines.flatMap(l => l.laws), ...d.projectLaws]
    assert.ok(shown.length >= 9, `only ${shown.length} laws shown`)
    for (const w of shown) {
      assert.ok(laws.includes(w.bend + '\n') || laws.endsWith(w.bend), `law ${w.name}: its display text is not in LAWS.bend`)
      const i = lines.indexOf(`law ${w.name}:`)
      assert.ok(i > 0, `law ${w.name} is not declared in LAWS.bend`)
      assert.equal(`# ${w.english}`, lines[i - 1], `law ${w.name}: english differs from the comment above it`)
      assert.equal(w.bend.split('\n')[0], `law ${w.name}:`)
    }
    // and every law in LAWS.bend is shown to the user exactly once
    const declared = [...laws.matchAll(/^law ([A-Za-z0-9_]+):$/gm)].map(m => m[1]).sort()
    assert.deepEqual(shown.map(w => w.name).sort(), declared)
    assert.deepEqual([...lawTexts(laws).keys()].sort(), declared)
  })

  test('display.json keeps every line, with its kind, reason and suggestion', () => {
    const d = JSON.parse(g.read('display.json'))
    const src = fixtureLines()
    assert.equal(d.root, FIXTURE_ROOT)
    assert.deepEqual(d.lines.map(l => l.line), src.map(l => l.line).sort((a, b) => a - b))
    for (const s of src) {
      const l = d.lines.find(x => x.line === s.line)
      assert.equal(l.text, s.text)
      assert.equal(l.kind, s.kind)
      assert.equal(l.reason, s.reason)
      assert.equal(l.suggestion, s.suggestion)
      if (s.kind !== 'hard') assert.deepEqual(l.laws, [])
    }
    assert.equal(d.lines.find(l => l.line === 2).laws.map(w => w.name).join(','), 'env_protected,env_unreadable,secrets_protected,secrets_unreadable')
  })

  test('every law in LAWS.bend has a def of the same name in PROOF.bend', () => {
    const proof = g.read('project/PROOF.bend')
    for (const name of lawTexts(g.read('project/LAWS.bend')).keys()) {
      assert.match(proof, new RegExp(`^def ([A-Za-z0-9_]+\\.)*${name}\\s*\\(`, 'm'), `no def for ${name}`)
    }
  })

  test('probes.json is built from the rule table', () => {
    const probes = JSON.parse(g.read('probes.json'))
    const rules = []
    for (const l of fixtureLines()) if (l.kind === 'hard') for (const r of l.rules) rules.push({ ...r, line: l.line })
    assert.deepEqual(probes, JSON.parse(JSON.stringify(buildProbes(FIXTURE_ROOT, rules))))
  })

  test('the generator is deterministic', () => {
    const g2 = gen({ root: FIXTURE_ROOT, lines: fixtureLines() })
    for (const f of ['project/Rules.bend', 'project/LAWS.bend', 'project/PROOF.bend', 'project/Policy.bend', 'display.json', 'probes.json']) {
      assert.equal(g2.read(f), g.read(f), f)
    }
  })

  test('the line order in sort.json does not matter', () => {
    const g2 = gen({ root: FIXTURE_ROOT, lines: fixtureLines().reverse() })
    for (const f of ['project/Rules.bend', 'project/LAWS.bend', 'display.json', 'probes.json']) assert.equal(g2.read(f), g.read(f), f)
  })

  test('a stale .bend file in the output project folder is removed', () => {
    const d = draft({ root: FIXTURE_ROOT, lines: fixtureLines() })
    const out = tmpDir('bg-tools-out-')
    fs.mkdirSync(path.join(out, 'project'))
    fs.writeFileSync(path.join(out, 'project', 'Evil.bend'), 'law evil:\n')
    generate({ draftDir: d, outDir: out })
    assert.ok(!fs.existsSync(path.join(out, 'project', 'Evil.bend')))
  })
})

describe('gen: names and the table of approved projects', () => {
  test('lawStem', () => {
    assert.equal(lawStem('specs'), 'specs')
    assert.equal(lawStem('.env'), 'env')
    assert.equal(lawStem('a-b/c.d'), 'a_b_c_d')
    assert.equal(lawStem('2024'), 'x2024')
    assert.equal(lawStem('...'), 'x')
  })

  test('two rules whose names collide get distinct law names', () => {
    const g = gen(hard([{ kind: 'NoChange', rel: 'a-b' }, { kind: 'NoChange', rel: 'a_b' }, { kind: 'NoChange', rel: 'a-b' }]))
    assert.deepEqual(g.laws.sort(), ['a_b_protected', 'a_b_protected_2', 'a_b_protected_3', 'reads_allowed'])
  })

  test('slugOf', () => {
    assert.equal(slugOf('c:/users/user/bend2_test'), 'c--users-user-bend2_test')
    assert.equal(slugOf('c:/users/user/my.app'), 'c--users-user-my-app')
    assert.equal(slugOf('c:/users/user/my app'), 'c--users-user-my-app')
  })

  test('--projects: a draft whose slug equals an approved project with another root is refused', () => {
    const live = tmpDir('bg-tools-live-')
    fs.mkdirSync(path.join(live, 'c--users-x-a-b'))
    fs.writeFileSync(path.join(live, 'c--users-x-a-b', 'sort.json'), JSON.stringify({ root: 'c:/users/x/a-b', lines: [] }))
    assert.throws(
      () => gen({ root: 'c:/users/x/a/b', lines: [] }, undefined, live),
      err => err instanceof GenError && /same draft name \(c--users-x-a-b\) as the approved project c:\/users\/x\/a-b/.test(err.message),
    )
    // the same root is not a collision: the draft replaces its old entry
    assert.deepEqual(gen({ root: 'c:/users/x/a-b', lines: [] }, undefined, live).projects, ['c:/users/x/a-b'])
  })

  test('--projects: other approved projects go in the table, sorted by root; the draft replaces its own old entry', () => {
    const live = tmpDir('bg-tools-live-')
    const put = (root, rules) => {
      const dir = path.join(live, slugOf(root))
      fs.mkdirSync(dir)
      fs.writeFileSync(path.join(dir, 'sort.json'), JSON.stringify({ root, lines: [{ line: 1, text: 't', kind: 'hard', reason: 'r', rules }] }))
    }
    put('c:/aaa/first', [{ kind: 'NoChange', rel: 'one' }])
    put('c:/zzz/last', [{ kind: 'NoForcePush' }])
    put(FIXTURE_ROOT, [{ kind: 'NoChange', rel: 'old_rule_from_before' }])
    const g = gen({ root: FIXTURE_ROOT, lines: fixtureLines() }, undefined, live)
    assert.deepEqual(g.projects, ['c:/aaa/first', FIXTURE_ROOT, 'c:/zzz/last'])
    const rules = g.read('project/Rules.bend')
    assert.ok(rules.includes('T.NoChange{"one"}'))
    assert.ok(rules.includes('T.Path{"c", ["zzz", "last"]}'))
    assert.ok(!rules.includes('old_rule_from_before'), 'the old entry for the draft root must be replaced')
    assert.ok(rules.indexOf('"aaa"') < rules.indexOf('"bend2_test"') && rules.indexOf('"bend2_test"') < rules.indexOf('"zzz"'))
  })

  test('--projects: a folder whose sort.json root does not match its name is refused', () => {
    const live = tmpDir('bg-tools-live-')
    fs.mkdirSync(path.join(live, 'c--aaa-first'))
    fs.writeFileSync(path.join(live, 'c--aaa-first', 'sort.json'), JSON.stringify({ root: 'c:/zzz/other', lines: [] }))
    assert.throws(() => gen({ root: FIXTURE_ROOT, lines: fixtureLines() }, undefined, live), /does not match the folder name/)
  })

  test('--projects: a bad approved project is refused like a bad draft', () => {
    const live = tmpDir('bg-tools-live-')
    fs.mkdirSync(path.join(live, 'c--aaa-first'))
    fs.writeFileSync(path.join(live, 'c--aaa-first', 'sort.json'), JSON.stringify({ root: 'c:/aaa/first', lines: [{ line: 1, text: 't', kind: 'hard', reason: 'r', rules: [{ kind: 'NoChange', rel: '../x' }] }] }))
    assert.throws(() => gen({ root: FIXTURE_ROOT, lines: fixtureLines() }, undefined, live), /approved project c--aaa-first: .*holds "\.\."/)
  })

  test('--projects: a missing folder is refused', () => {
    assert.throws(() => gen({ root: FIXTURE_ROOT, lines: fixtureLines() }, undefined, path.join(os.tmpdir(), 'bg-no-such-folder-x9')), /does not exist/)
  })
})

// ===========================================================================
// probes.mjs

describe('probes: buildProbes', () => {
  const rulesOf = lines => {
    const out = []
    for (const l of lines) if (l.kind === 'hard') for (const r of l.rules) out.push({ ...r, line: l.line })
    return out
  }

  test('winPath', () => {
    assert.equal(winPath('c:/users/user/bend2_test'), 'C:\\users\\user\\bend2_test')
    assert.throws(() => winPath('C:\\x'), /not a normalised root/)
  })

  test('the fixture table gives one probe set per rule plus the built-ins', () => {
    const probes = buildProbes(FIXTURE_ROOT, rulesOf(fixtureLines()))
    const names = probes.map(p => `${p.expect} ${p.name}`)
    const want = [
      new RegExp('^' + `deny built-in: node ${os.homedir().replace(/\\/g, '/')}/.claude/local-plugins/bend-guard/tools/approve.mjs C:/users/user/bend2_test -> deny`.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$'),
      /^deny built-in: Skill bend-guard confirm/,
      /^deny rule 1 NoChange: Edit specs\/__probe__/,
      /^deny rule 1 NoChange: rm -rf specs/,
      /^deny rule 2 NoReadOrChange: Read \.env\/__probe__/,
      /^deny rule 2 NoReadOrChange: cat \.env/,
      /^deny rule 2 NoReadOrChange: cat secrets/,
      /^deny rule 3 NoChange: Edit dist\/__probe__/,
      /^deny rule 5 NoForcePush: git push -f/,
      /^deny rule 6 NoPushTo: git push origin HEAD:main/,
      /^deny rule 7 TreeDeleteOnlyUnder: rm -rf __probe_outside__/,
      /^allow rule 7 TreeDeleteOnlyUnder: rm -rf tmp\/__probe__/,
      /^allow cat README\.md/,
    ]
    for (const re of want) assert.ok(names.some(n => re.test(n)), `no probe matching ${re}\n${names.join('\n')}`)
    for (const p of probes) {
      assert.equal(p.call.$, 'Call')
      assert.equal(p.call.root, 'C:\\users\\user\\bend2_test')
      assert.equal(p.call.log_only, false, 'probes run outside log-only mode')
      assert.equal(p.call.agent, false)
      assert.equal(p.call.approver, 'person')
    }
  })

  test('a TreeDeleteOnlyUnder folder inside a protected zone gets no allow probe', () => {
    const probes = buildProbes(FIXTURE_ROOT, [{ kind: 'NoChange', rel: 'specs', line: 1 }, { kind: 'TreeDeleteOnlyUnder', rel: 'specs/tmp', line: 2 }])
    assert.ok(!probes.some(p => p.expect === 'allow' && p.name.includes('specs/tmp')))
    assert.ok(probes.some(p => p.expect === 'deny' && p.name.includes('__probe_outside__')))
  })

  test('a rule protecting readme.md drops the cat README.md allow probe', () => {
    const probes = buildProbes(FIXTURE_ROOT, [{ kind: 'NoReadOrChange', rel: 'readme.md', line: 1 }])
    assert.ok(!probes.some(p => p.name.startsWith('cat README.md')))
  })

  test('TrustScript adds no probe', () => {
    assert.equal(buildProbes(FIXTURE_ROOT, [{ kind: 'TrustScript', name: 'build', line: 1 }]).length, buildProbes(FIXTURE_ROOT, []).length)
  })
})

describe('probes: runProbes against the compiled fixture policy', { skip: !fs.existsSync(POLICY) && `no compiled policy at ${POLICY}` }, () => {
  const tableRules = () => {
    const out = []
    for (const l of fixtureLines()) if (l.kind === 'hard') for (const r of l.rules) out.push({ ...r, line: l.line })
    return out
  }

  test('every fixture probe passes', async () => {
    const probes = buildProbes(FIXTURE_ROOT, tableRules())
    const r = await runProbes(POLICY, probes)
    assert.deepEqual(r.failures, [])
    assert.equal(r.ok, true)
    assert.equal(r.ran, probes.length)
  })

  test('a table that names the wrong folder (NoChange "spec" for the rule about specs) is caught', async () => {
    const r = await runProbes(POLICY, buildProbes(FIXTURE_ROOT, [{ kind: 'NoChange', rel: 'spec', line: 1 }]))
    assert.equal(r.ok, false)
    assert.ok(r.failures.some(f => f.name.includes('Edit spec/__probe__') && f.expect === 'Deny' && f.got === 'Allow'), JSON.stringify(r.failures))
  })

  test('a table rule the policy does not carry (NoReadOrChange "docs") is caught', async () => {
    const r = await runProbes(POLICY, buildProbes(FIXTURE_ROOT, [{ kind: 'NoReadOrChange', rel: 'docs', line: 1 }]))
    assert.equal(r.ok, false)
    assert.ok(r.failures.some(f => f.name.includes('cat docs')))
  })

  test('a push rule for another branch is caught', async () => {
    const r = await runProbes(POLICY, buildProbes(FIXTURE_ROOT, [{ kind: 'NoPushTo', branch: 'release', line: 1 }]))
    assert.equal(r.ok, false)
    assert.ok(r.failures.some(f => f.name.includes('HEAD:release')))
  })

  test('no probes at all is a failure, not a pass', async () => {
    const r = await runProbes(POLICY, [])
    assert.equal(r.ok, false)
  })

  test('a probe for a different project root is not satisfied by this policy', async () => {
    const r = await runProbes(POLICY, buildProbes('c:/users/user/other_project', [{ kind: 'NoChange', rel: 'specs', line: 1 }]))
    assert.equal(r.ok, false)
  })
})

describe('probes: runProbes against fake policies', () => {
  const fake = body => {
    const d = tmpDir('bg-tools-fake-')
    const f = path.join(d, 'policy.mjs')
    fs.writeFileSync(f, body)
    return f
  }
  const probes = () => buildProbes(FIXTURE_ROOT, [{ kind: 'NoChange', rel: 'specs', line: 1 }, { kind: 'TreeDeleteOnlyUnder', rel: 'tmp', line: 2 }])
  const api = verdict => `const f = () => (${verdict}); export default { 'Policy.decide': f, 'Policy.run': f, 'Policy.meaning': f, 'Policy.next_cwds': f, 'Policy.paths': f }\n`

  test('a policy that allows everything fails the deny probes', async () => {
    const r = await runProbes(fake(api(`{ $: 'Allow' }`)), probes())
    assert.equal(r.ok, false)
    assert.ok(r.failures.every(f => f.expect === 'Deny'))
    assert.ok(r.failures.some(f => f.name.includes('built-in')), 'the self-protection probes must fail too')
  })

  test('a policy that denies everything fails the allow probes', async () => {
    const r = await runProbes(fake(api(`{ $: 'Deny', reason: 'no' }`)), probes())
    assert.equal(r.ok, false)
    assert.ok(r.failures.length >= 2 && r.failures.every(f => f.expect === 'Allow'))
  })

  test('a policy that asks about everything fails', async () => {
    const r = await runProbes(fake(api(`{ $: 'Ask', reason: 'hm' }`)), probes())
    assert.equal(r.ok, false)
  })

  test('a policy missing an export fails before running', async () => {
    const r = await runProbes(fake(`export default { 'Policy.run': () => ({ $: 'Deny' }) }\n`), probes())
    assert.equal(r.ok, false)
    assert.equal(r.ran, 0)
    assert.ok(r.failures.some(f => f.name === 'export Policy.decide'))
  })

  test('a policy that throws fails, with the error', async () => {
    const r = await runProbes(fake(`const f = () => { throw new Error('boom') }; export default { 'Policy.decide': f, 'Policy.run': f, 'Policy.meaning': f, 'Policy.next_cwds': f, 'Policy.paths': f }\n`), probes())
    assert.equal(r.ok, false)
    assert.ok(r.failures.every(f => f.got === 'error' && /boom/.test(f.reason)))
  })

  test('a file that is not a module fails', async () => {
    const r = await runProbes(fake('this is not javascript ((('), probes())
    assert.equal(r.ok, false)
    assert.equal(r.failures[0].name, 'load policy.mjs')
  })

  test('probeCall builds the glue shape', () => {
    const c = probeCall('C:\\x', 'Bash', { command: 'ls' })
    assert.deepEqual(c.args, { $: 'Con', head: { $: 'Arg', key: 'command', value: 'ls' }, tail: { $: 'Nil' } })
    assert.deepEqual(c.cwds, { $: 'Con', head: 'C:\\x', tail: { $: 'Nil' } })
    assert.deepEqual(c.stage, { $: 'AtCheck' })
  })
})

// ===========================================================================
// wsl.mjs

describe('wsl: toWslPath', () => {
  const cases = [
    ['C:\\Users\\user\\x', '/mnt/c/Users/user/x'],
    ['c:/Users/user/x/', '/mnt/c/Users/user/x'],
    ['D:\\a b\\c', '/mnt/d/a b/c'],
    ['C:\\', '/mnt/c'],
    ['C:', '/mnt/c'],
    ['C:\\x\\\\', '/mnt/c/x'],
    ['/root/bg-build/x', '/root/bg-build/x'],
    ['rel\\dir', 'rel/dir'],
    ['C:\\Users\\user\\AppData\\Local\\Temp\\bend-guard-approve-AbC\\draft', '/mnt/c/Users/user/AppData/Local/Temp/bend-guard-approve-AbC/draft'],
  ]
  for (const [win, want] of cases) test(`${JSON.stringify(win)} -> ${want}`, () => assert.equal(toWslPath(win), want))
})

// ===========================================================================
// draft-check.mjs (argument refusals only; a real check runs WSL for minutes)

describe('draft-check: argument refusals', () => {
  const DC = path.join(TOOLS, 'draft-check.mjs')
  for (const args of [[], ['../x'], ['..'], ['A'], ['a b'], ['a/b'], ['a\\b'], ['a.b'], ['a', 'b'], ['']]) {
    test(`refuses ${JSON.stringify(args)} with usage (exit 2)`, () => {
      const before = fs.readdirSync(LIVE_D).sort()
      const r = node(DC, args)
      assert.equal(r.status, 2, r.stdout + r.stderr)
      assert.match(r.stdout, /usage: node draft-check\.mjs <slug>/)
      assert.deepEqual(fs.readdirSync(LIVE_D).sort(), before, 'nothing may be created in the drafts folder')
    })
  }

  test('a good slug with no draft folder fails cleanly and creates nothing', () => {
    const slug = 'zz-tools-test-no-such-draft'
    const r = node(DC, [slug])
    assert.equal(r.status, 1)
    assert.match(r.stdout, /no draft folder/)
    assert.match(r.stdout.trim().split(/\r?\n/).pop(), /^BEND-GUARD CHECK FAILED$/)
    assert.ok(!fs.existsSync(path.join(LIVE_D, slug)))
  })

  test('every root gen.mjs accepts has a slug draft-check accepts', () => {
    for (const root of ['c:/users/user/my.app', 'c:/users/user/my app']) {
      const g = gen({ root, lines: [] })
      assert.equal(g.root, root)
      assert.match(slugOf(root), /^[a-z0-9_-]+$/, `slug ${slugOf(root)} of ${root}`)
    }
    assert.equal(slugOf('c:/users/user/my.app'), 'c--users-user-my-app')
  })

  test('the new slug form (from a folder with . or space) passes the usage check', () => {
    const slug = slugOf('c:/users/user/zz.tools test-no-such-draft')
    assert.equal(slug, 'c--users-user-zz-tools-test-no-such-draft')
    const r = node(DC, [slug])
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /no draft folder/)
    assert.ok(!fs.existsSync(path.join(LIVE_D, slug)))
  })
})

// ===========================================================================
// suggest.mjs

describe('suggest: on a fixture log', () => {
  const SUG = path.join(TOOLS, 'suggest.mjs')
  const HEAD = 'time\tsession\tagent\ttool\tverdict\tenforceVerdict\treason\tclefAsked\tclefAnswer\tlatencyMs\tcacheHit\tcommand'
  const row = (tool, verdict, reason, clef, command) =>
    ['2026-10-26T10:00:00Z', 's1', '', tool, verdict, verdict, reason, clef ? 'yes' : 'no', clef ?? '', '12', 'no', command].join('\t')
  const NU = why => `bend-guard: not understood (${why}). The user can approve; or use a known command.`
  let dir
  before(() => {
    dir = tmpDir('bg-tools-log-')
    const day1 = [
      HEAD,
      row('Bash', 'ask', NU('unknown command jq'), 'ok risky=10 unsure=0', 'jq . a.json'),
      row('Bash', 'ask', NU('unknown command jq'), 'ok risky=20 unsure=50', 'cd sub && jq .x b.json'),
      row('Bash', 'deny', 'bend-guard: Clef (the second opinion) rates this command as risky. Rewrite it with known commands, or ask the user to run it.', 'ok risky=900 unsure=0', 'jq -r . c.json'),
      row('Bash', 'ask', NU('git subcommand (rebase) not modelled'), 'ok risky=600 unsure=0', 'git -C sub rebase main'),
      row('Bash', 'deny', 'at call: ' + NU('unknown command jq'), '', 'jq . a.json'),
      row('Bash', 'allow', 'bend-guard: reads only', '', 'cat README.md'),
      row('PowerShell', 'ask', NU('unknown cmdlet (x)'), 'timeout', 'Get-Thing -Path x'),
      'this line is damaged',
    ].join('\n')
    fs.writeFileSync(path.join(dir, '2026-10-25.tsv'), day1 + '\n')
    fs.writeFileSync(path.join(dir, '2026-10-26.tsv'), [HEAD, row('Bash', 'ask', NU('unknown command yq'), '', 'yq . x.yaml')].join('\n') + '\n')
    fs.writeFileSync(path.join(dir, 'notes.txt'), row('Bash', 'ask', NU('unknown command zz'), '', 'zz') + '\n')
  })

  test('groups the not-understood calls and counts Clef answers', () => {
    const r = node(SUG, ['--dir', dir])
    assert.equal(r.status, 0, r.stderr)
    const out = r.stdout
    assert.match(out, /read 8 log lines from 2 file\(s\), 2026-10-25 to 2026-10-26/)
    assert.match(out, /\(1 damaged line\(s\) skipped\.\)/)
    // jq x3 (one refused by Clef), git rebase, Get-Thing, yq; the "at call:" repeat is not counted
    assert.match(out, /6 call\(s\) were not understood, in 4 group\(s\)/)
    const jq = out.split(/\r?\n/).find(l => /^\s+1\s+jq\s/.test(l))
    assert.ok(jq, `jq is not first:\n${out}`)
    assert.match(jq, /jq\s+3\s+2\s+0\s+1\s+0/) // times safe unsure risky none: 10/0 safe, 20/50 safe, 900 risky
    assert.match(out, /git rebase\s+1\s+0\s+1\s+0\s+0/)
    assert.match(out, /get-thing \[PowerShell\]\s+1\s+0\s+0\s+0\s+1/)
    assert.ok(!/\bzz\b/.test(out), 'only .tsv files are read')
    assert.ok(!/cat/.test(out.split('usual reason')[1] ?? ''), 'an understood call is not listed')
  })

  test('--days 1 reads only the newest file', () => {
    const r = node(SUG, ['--dir', dir, '--days', '1'])
    assert.equal(r.status, 0)
    assert.match(r.stdout, /from 1 file\(s\), 2026-10-26 to 2026-10-26/)
    assert.match(r.stdout, /yq/)
    assert.ok(!/\bjq\b/.test(r.stdout))
  })

  test('suggest --days 1 counts both session files of the newest day and none of the day before', () => {
    // bend-guard writes one log file per session and UTC day: <date>.<session>.tsv
    const d = tmpDir('bg-tools-log-sessions-')
    fs.writeFileSync(path.join(d, '2026-10-25.aaaa1111.tsv'), [HEAD, row('Bash', 'ask', NU('unknown command jq'), '', 'jq . a.json')].join('\n') + '\n')
    fs.writeFileSync(path.join(d, '2026-10-26.bbbb2222.tsv'), [HEAD, row('Bash', 'ask', NU('unknown command yq'), '', 'yq . x.yaml')].join('\n') + '\n')
    fs.writeFileSync(path.join(d, '2026-10-26.cccc3333.tsv'), [HEAD, row('Bash', 'ask', NU('unknown command yq'), '', 'yq . y.yaml')].join('\n') + '\n')
    const r = node(SUG, ['--dir', d, '--days', '1'])
    assert.equal(r.status, 0, r.stderr)
    assert.match(r.stdout, /read 2 log lines from 2 file\(s\), 2026-10-26 to 2026-10-26/)
    assert.match(r.stdout, /yq\s+2\s/)
    assert.ok(!/\bjq\b/.test(r.stdout), r.stdout)
  })

  test('--top 1 lists one group', () => {
    const r = node(SUG, ['--dir', dir, '--top', '1'])
    assert.match(r.stdout, /The most common 1:/)
    assert.ok(!/^\s+2\s/m.test(r.stdout))
  })

  test('bad options exit 2 with usage', () => {
    for (const args of [['--top', '0'], ['--top', 'x'], ['--days', '-1'], ['--dir'], ['--bogus']]) {
      const r = node(SUG, args)
      assert.equal(r.status, 2, `${args.join(' ')}: ${r.stdout}${r.stderr}`)
      assert.match(r.stderr, /usage: node suggest\.mjs/)
    }
  })

  test('a missing folder and an empty folder are reported, not crashed on', () => {
    const a = node(SUG, ['--dir', path.join(dir, 'nope')])
    assert.equal(a.status, 0)
    assert.match(a.stdout, /no log folder at/)
    const empty = tmpDir('bg-tools-log-empty-')
    const b = node(SUG, ['--dir', empty])
    assert.equal(b.status, 0)
    assert.match(b.stdout, /no \.tsv log files/)
  })
})

// ===========================================================================
// approve.mjs, the real one: only refusals, --status and --preview

describe('approve: the real tool, without a terminal', () => {
  const AP = path.join(TOOLS, 'approve.mjs')
  let approvedBefore
  before(() => {
    approvedBefore = bytesOrNull(LIVE_APPROVED)
    assert.ok(!fs.existsSync(LIVE_TOKEN), 'a live .approve-token exists; these tests will not run beside it')
  })
  after(() => {
    const now = bytesOrNull(LIVE_APPROVED)
    assert.ok(approvedBefore === null ? now === null : now !== null && now.equals(approvedBefore), 'approved.json changed during the approve tests')
  })
  const unchanged = () => {
    const now = bytesOrNull(LIVE_APPROVED)
    assert.ok(approvedBefore === null ? now === null : now !== null && now.equals(approvedBefore), 'approved.json changed')
  }

  test('no TTY: exit 2 and nothing written', () => {
    for (const args of [['C:\\Users\\user\\bend2_test'], ['C:\\Users\\user\\bend2_test', '--enforce'], ['C:\\Users\\user\\bend2_test', '--log-only']]) {
      const r = node(AP, args, { input: 'approve\n' })
      assert.equal(r.status, 2, r.stdout)
      assert.match(r.stdout, /must be run by the user in their own terminal/)
      unchanged()
    }
  })

  const bad = [[], ['--enforce', '--log-only', 'C:\\x'], ['--status', 'C:\\x'], ['--status', '--enforce'], ['--bogus'], ['C:\\a', 'C:\\b'], ['--expect', 'a'.repeat(64)], ['--enforce']]
  for (const args of bad) {
    test(`bad arguments ${JSON.stringify(args)} print usage (exit 2)`, () => {
      const r = node(AP, args)
      assert.equal(r.status, 2, r.stdout + r.stderr)
      assert.match(r.stdout, /^usage:/m)
      unchanged()
    })
  }

  test('--preview with another option is refused with a JSON line', () => {
    const r = node(AP, ['--preview', 'C:\\Users\\user\\bend2_test', '--enforce'])
    assert.equal(r.status, 1)
    const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(last.ok, false)
    assert.match(last.error, /arguments it does not take/)
    unchanged()
  })

  test('--status works without a TTY', () => {
    const r = node(AP, ['--status'])
    assert.equal(r.status, 0, r.stdout)
    assert.match(r.stdout, /^bend-guard status \(/)
    if (approvedBefore) assert.match(r.stdout, /Mode: /)
    unchanged()
  })

  test('--preview on a folder that does not exist ends with ok:false', () => {
    const r = node(AP, ['--preview', path.join(os.tmpdir(), 'bg-no-such-project-x9')])
    assert.equal(r.status, 1)
    const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(last.ok, false)
    assert.match(last.error, /there is no folder/)
    unchanged()
  })

  // Runs against the real bend2_test project in the home folder of whoever
  // runs the tests, with its draft; skipped where that project or draft is not there.
  const LIVE_PROJECT = path.join(os.homedir(), 'bend2_test')
  const LIVE_SLUG = slugOf(LIVE_PROJECT.replace(/\\/g, '/').toLowerCase())
  const livePreview = fs.existsSync(path.join(LIVE_PROJECT, 'BEND_RULES.md')) && fs.existsSync(path.join(LIVE_D, LIVE_SLUG, 'sort.json'))
  test('--preview on bend2_test prints the JSON line with the display and leaves a snapshot (removed by this test)', { skip: !livePreview && `no ${LIVE_PROJECT} with a draft on this PC` }, () => {
    const slugDir = path.join(LIVE_D, LIVE_SLUG)
    const before = new Set(fs.readdirSync(slugDir))
    const r = node(AP, ['--preview', LIVE_PROJECT])
    let snap = null
    try {
      const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
      snap = last.snapshot
      assert.equal(last.ok, true, last.error)
      assert.equal(r.status, 0)
      assert.equal(last.slug, LIVE_SLUG)
      assert.equal(last.root, LIVE_PROJECT)
      assert.match(last.rulesMdSha256, /^[0-9a-f]{64}$/)
      assert.match(last.previewSha256, /^[0-9a-f]{64}$/)
      assert.equal(last.rulesMdSha256, sha256(fs.readFileSync(path.join(LIVE_PROJECT, 'BEND_RULES.md'))))
      assert.match(last.display, /BEND_RULES\.md: \d+ numbered lines/)
      assert.match(last.display, /law specs_protected: /)
      assert.match(last.display, /Summary: \d+ lines: \d+ enforced with proofs \(\d+ laws\), \d+ asks and reminders, \d+ advice/)
      assert.match(last.display, /After \/bend-guard confirm/)
      assert.equal(path.dirname(snap), slugDir)
      assert.match(path.basename(snap), /^\.approve-[0-9a-f]{16}$/)
      for (const f of ['preview.json', 'sort.json', 'ask.json']) assert.ok(fs.existsSync(path.join(snap, f)), f)
      assert.equal(sha256(fs.readFileSync(path.join(snap, 'preview.json'))), last.previewSha256, 'previewSha256 is the hash of preview.json')
      assert.deepEqual(fs.readFileSync(path.join(snap, 'sort.json')), fs.readFileSync(path.join(slugDir, 'sort.json')))
      unchanged()
    } finally {
      // remove only the snapshot this run made
      for (const n of fs.readdirSync(slugDir)) if (!before.has(n) && /^\.approve-[0-9a-f]{16}$/.test(n)) fs.rmSync(path.join(slugDir, n), { recursive: true, force: true })
    }
    assert.ok(!snap || !fs.existsSync(snap))
  })
})

// ===========================================================================
// approve.mjs in a sandbox: the /bend-guard handshake, against temp folders

describe('approve: sandbox copy (state and drafts in temp folders)', () => {
  let box, AP, S, D
  const ok64 = 'f'.repeat(64)

  before(() => {
    box = tmpDir('bg-tools-sandbox-')
    const plugin = path.join(box, 'plugin')
    fs.cpSync(path.join(P, 'tools'), path.join(plugin, 'tools'), { recursive: true })
    fs.cpSync(path.join(P, 'bend'), path.join(plugin, 'bend'), { recursive: true })
    fs.copyFileSync(path.join(P, 'BEND_VERSION'), path.join(plugin, 'BEND_VERSION'))
    S = path.join(box, 'state')
    D = path.join(box, 'drafts')
    fs.mkdirSync(S)
    fs.mkdirSync(D)
    AP = path.join(plugin, 'tools', 'approve.mjs')
    let src = fs.readFileSync(AP, 'utf8')
    const n0 = src.length
    src = src.replace(/^const S = .*$/m, `const S = ${JSON.stringify(S)}`).replace(/^const D = .*$/m, `const D = ${JSON.stringify(D)}`)
    assert.notEqual(src.length, n0)
    // the real folders come from the home folder; the copy must not use them
    for (const real of ['const S = stateDir()', 'const D = draftsDir()']) assert.ok(!src.includes(real), `the sandbox copy still has ${real}`)
    assert.ok(src.includes(`const S = ${JSON.stringify(S)}`) && src.includes(`const D = ${JSON.stringify(D)}`))
    fs.writeFileSync(AP, src)
  })

  const approvedText = logOnly => JSON.stringify({ version: 2, logOnly, policy: { dir: 'live\\policy', mjsSha256: ok64 }, projects: {} }, null, 2) + '\n'
  const setToken = token => fs.writeFileSync(path.join(S, '.approve-token'), sha256(Buffer.from(token, 'utf8')))
  const liveUnchanged = (() => {
    const b = bytesOrNull(LIVE_APPROVED)
    return () => {
      const now = bytesOrNull(LIVE_APPROVED)
      assert.ok(b === null ? now === null : now !== null && now.equals(b), 'the LIVE approved.json changed')
      assert.ok(!fs.existsSync(LIVE_TOKEN))
    }
  })()

  test('--from-mod with no token file is refused and writes nothing', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    const before = fs.readFileSync(path.join(S, 'approved.json'))
    const r = node(AP, ['--mode-only', '--from-mod', '--enforce'], { input: 'a'.repeat(64) + '\n' })
    assert.equal(r.status, 1, r.stdout)
    assert.match(r.stdout, /did not come from your own \/bend-guard command/)
    assert.match(r.stdout, /Nothing was written to /)
    assert.ok(fs.readFileSync(path.join(S, 'approved.json')).equals(before))
    liveUnchanged()
  })

  test('--from-mod with a wrong token is refused, writes nothing and uses up the token file', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    const before = fs.readFileSync(path.join(S, 'approved.json'))
    setToken('r'.repeat(48))
    const r = node(AP, ['--mode-only', '--from-mod', '--enforce'], { input: 'w'.repeat(48) + '\n' })
    assert.equal(r.status, 1, r.stdout)
    assert.match(r.stdout, /did not come from your own \/bend-guard command/)
    assert.ok(fs.readFileSync(path.join(S, 'approved.json')).equals(before))
    assert.ok(!fs.existsSync(path.join(S, '.approve-token')), 'the token file is good for one try')
    liveUnchanged()
  })

  test('--from-mod with no token on stdin is refused', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    setToken('r'.repeat(48))
    const r = node(AP, ['--mode-only', '--from-mod', '--enforce'], { input: '' })
    assert.equal(r.status, 1)
    assert.match(r.stdout, /did not come from your own/)
    assert.equal(JSON.parse(fs.readFileSync(path.join(S, 'approved.json'), 'utf8')).logOnly, true)
  })

  test('a token shorter than 32 characters is refused even when it matches', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    setToken('short')
    const r = node(AP, ['--mode-only', '--from-mod', '--enforce'], { input: 'short\n' })
    assert.equal(r.status, 1)
    assert.equal(JSON.parse(fs.readFileSync(path.join(S, 'approved.json'), 'utf8')).logOnly, true)
  })

  test('the right token switches the mode once; the same token again is refused', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    const tok = crypto.randomBytes(32).toString('hex')
    setToken(tok)
    const r = node(AP, ['--mode-only', '--from-mod', '--enforce'], { input: tok + '\n' })
    assert.equal(r.status, 0, r.stdout)
    assert.match(r.stdout, /Done: bend-guard is /)
    assert.equal(JSON.parse(fs.readFileSync(path.join(S, 'approved.json'), 'utf8')).logOnly, false)
    assert.ok(!fs.existsSync(path.join(S, '.approve-token')))
    const r2 = node(AP, ['--mode-only', '--from-mod', '--log-only'], { input: tok + '\n' })
    assert.equal(r2.status, 1)
    assert.equal(JSON.parse(fs.readFileSync(path.join(S, 'approved.json'), 'utf8')).logOnly, false)
    liveUnchanged()
  })

  test('--from-mod alone, or with a root, prints usage and still uses up the token file', () => {
    setToken('r'.repeat(48))
    const r = node(AP, ['--from-mod', 'C:\\x'], { input: 'r'.repeat(48) + '\n' })
    assert.equal(r.status, 2)
    assert.match(r.stdout, /^usage:/m)
    assert.ok(!fs.existsSync(path.join(S, '.approve-token')))
  })

  test('--mode-only without --from-mod and without a TTY is refused', () => {
    fs.writeFileSync(path.join(S, 'approved.json'), approvedText(true))
    const r = node(AP, ['--mode-only', '--enforce'], { input: 'approve\n' })
    assert.equal(r.status, 2)
    assert.match(r.stdout, /must be run by the user in their own terminal/)
    assert.equal(JSON.parse(fs.readFileSync(path.join(S, 'approved.json'), 'utf8')).logOnly, true)
  })

  test('--snapshot outside the drafts folder is refused with a JSON line, even with the right token', () => {
    const tok = crypto.randomBytes(32).toString('hex')
    setToken(tok)
    const evil = tmpDir('bg-tools-evil-snap-')
    const r = node(AP, ['--snapshot', evil, '--expect', ok64, '--from-mod'], { input: tok + '\n' })
    assert.equal(r.status, 1, r.stdout)
    const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(last.ok, false)
    assert.match(last.message, /is not a copy that \/bend-guard approve made/)
    liveUnchanged()
  })

  test('--snapshot with a malformed --expect is refused with a JSON line', () => {
    const r = node(AP, ['--snapshot', path.join(D, 'x', '.approve-0123456789abcdef'), '--expect', 'nothex', '--from-mod'], { input: 'x\n' })
    assert.equal(r.status, 1)
    const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(last.ok, false)
  })

  // A small project of our own, under the temp folder.
  function project(mdText, lines, ask = fixtureAsk()) {
    const rootWin = tmpDir('bg-tools-proj-')
    const root = rootWin.toLowerCase().replace(/\\/g, '/')
    fs.writeFileSync(path.join(rootWin, 'BEND_RULES.md'), mdText)
    const dd = path.join(D, slugOf(root))
    fs.mkdirSync(dd, { recursive: true })
    fs.writeFileSync(path.join(dd, 'sort.json'), JSON.stringify({ root, lines }))
    fs.writeFileSync(path.join(dd, 'ask.json'), JSON.stringify(ask))
    return { rootWin, root, dd }
  }
  const preview = rootWin => {
    const r = node(AP, ['--preview', rootWin])
    return { r, last: JSON.parse(r.stdout.trim().split(/\r?\n/).pop()) }
  }

  test('--preview on a project of our own shows each line with its law and writes nothing to S', () => {
    const { rootWin } = project('# Rules\n\n1. Never edit files in `specs/`.\n2. Do it nicely.\n', [
      { line: 1, text: 'Never edit files in `specs/`.', kind: 'hard', reason: 'protects specs', rules: [{ kind: 'NoChange', rel: 'specs' }] },
      { line: 2, text: 'Do it nicely.', kind: 'judgment', reason: 'a matter of taste', rules: [] },
    ])
    fs.rmSync(path.join(S, 'approved.json'), { force: true }) // nothing approved yet in the sandbox
    const sBefore = fs.readdirSync(S).sort()
    const { r, last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    assert.equal(r.status, 0)
    assert.match(last.display, /law specs_protected: Rule 1: .*\/specs is denied/)
    assert.match(last.display, /judgment, no law: a matter of taste/)
    assert.match(last.display, /first approval/, 'the core laws are shown at the first approval')
    assert.deepEqual(fs.readdirSync(S).sort(), sBefore)
  })

  test('--preview refuses a draft whose text does not match BEND_RULES.md', () => {
    const { rootWin } = project('1. Never edit files in `specs/`.\n', [
      { line: 1, text: 'Never edit files in `docs/`.', kind: 'hard', reason: 'r', rules: [{ kind: 'NoChange', rel: 'docs' }] },
    ])
    const { r, last } = preview(rootWin)
    assert.equal(r.status, 1)
    assert.equal(last.ok, false)
    assert.match(last.error, /does not match/)
  })

  test('--preview flags a line that says never but was sorted as judgment', () => {
    const { rootWin } = project('1. Never edit `specs/`.\n', [{ line: 1, text: 'Never edit `specs/`.', kind: 'judgment', reason: 'r', rules: [] }])
    const { last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    assert.match(last.display, /^\s*CHECK THIS: /m)
    assert.match(last.display, /1 flagged CHECK THIS;/)
  })

  test('--preview flags a hard line whose rule protects a folder the line does not name (spec for `specs/`)', () => {
    const { rootWin } = project('1. Never edit files in `specs/`.\n', [
      { line: 1, text: 'Never edit files in `specs/`.', kind: 'hard', reason: 'protects specs', rules: [{ kind: 'NoChange', rel: 'spec' }] },
    ])
    const { last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    assert.match(last.display, /^\s*CHECK THIS: it names `specs\/` but no rule on this line protects specs; the rules name spec\b/m)
    assert.match(last.display, /its rule NoChange spec is about spec, which the line does not name/)
    assert.match(last.display, /1 flagged CHECK THIS;/)
  })

  // ---- P4: the cross-check, the summary and "Changed since your last approval"

  const mdOf = lines => lines.map(l => `${l.line}. ${l.text}`).join('\n') + '\n'
  const fx = nums => fixtureLines().filter(l => nums.includes(l.line))
  const renumber = lines => lines.map((l, i) => ({ ...l, line: i + 1 }))
  const summaryOf = display => {
    const m = /^Summary: (\d+) lines: (\d+) enforced with proofs \((\d+) laws\), (\d+) asks and reminders, (\d+) advice(?:, (\d+) only trust a script)?(?:, (\d+) hard with NO LAW)?; (\d+) flagged CHECK THIS; (?:(\d+) loosen the rules|no earlier approval to compare with)\.$/m.exec(display)
    assert.ok(m, `no summary line in:\n${display.slice(0, 1500)}`)
    const [lines, enforced, laws, asks, advice, trust, noLaw, flagged, loosens] = m.slice(1).map(x => (x === undefined ? null : Number(x)))
    return { lines, enforced, laws, asks, advice, trust: trust ?? 0, noLaw: noLaw ?? 0, flagged, loosens, at: m.index }
  }
  // An earlier approval in the sandbox state folder: approved.json lists the
  // project and live\projects\<slug> holds the approved sort.json, plus
  // approved-sort.json unless `old` (an approval made before that file existed).
  function approvedEarlier(root, lines, { old = false, ask = fixtureAsk() } = {}) {
    const sortBuf = Buffer.from(JSON.stringify({ root, lines }))
    const dir = path.join(S, 'live', 'projects', slugOf(root))
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, 'sort.json'), sortBuf)
    if (!old) fs.writeFileSync(path.join(dir, 'approved-sort.json'), sortBuf)
    const entry = { slug: slugOf(root), rulesJsonSha256: sha256(sortBuf), approvedAt: '2026-10-20T09:30:00.000Z', ask }
    fs.writeFileSync(path.join(S, 'approved.json'), JSON.stringify({ version: 2, logOnly: true, policy: { dir: 'live\\policy', mjsSha256: ok64 }, projects: { [root]: entry } }, null, 2) + '\n')
    return dir
  }
  const forget = () => {
    fs.rmSync(path.join(S, 'live'), { recursive: true, force: true })
    fs.rmSync(path.join(S, 'approved.json'), { force: true })
  }
  // A project whose BEND_RULES.md and draft are `now`, approved earlier as `then`.
  function changed(then, now, opts, nowAsk) {
    const { rootWin, root } = project(mdOf(now), now, nowAsk)
    approvedEarlier(root, then, opts)
    try {
      const { r, last } = preview(rootWin)
      assert.equal(last.ok, true, last.error)
      assert.equal(r.status, 0)
      return last.display
    } finally {
      forget()
    }
  }

  test('--preview: the bend2_test lines 1-3 and 5-7 with their real rules are not flagged', () => {
    const lines = fx([1, 2, 3, 5, 6, 7])
    assert.equal(lines.length, 6)
    const { rootWin } = project(mdOf(lines), lines)
    forget()
    const { last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    assert.match(last.display, /; 0 flagged CHECK THIS;/)
    assert.doesNotMatch(last.display, /CHECK THIS: /)
  })

  test('--preview flags each kind of name mismatch, and a branch or script the line does not name', () => {
    const lines = [
      { line: 1, text: 'Never edit `docs/specs/` or `.env.local`.', kind: 'hard', reason: 'r', rules: [{ kind: 'NoChange', rel: 'specs' }, { kind: 'NoReadOrChange', rel: '.env.local' }] },
      { line: 2, text: 'Never push to `main`.', kind: 'hard', reason: 'r', rules: [{ kind: 'NoPushTo', branch: 'master' }] },
      { line: 3, text: 'Never edit `./build/**` or `dist\\`.', kind: 'hard', reason: 'r', rules: [{ kind: 'NoChange', rel: 'build' }, { kind: 'NoChange', rel: 'dist' }] },
    ]
    const { rootWin } = project(mdOf(lines), lines)
    forget()
    const { last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    const flags = last.display.split(/\r?\n/).filter(l => /^\s*CHECK THIS: /.test(l))
    assert.equal(flags.length, 2, flags.join('\n'))
    assert.match(flags[0], /it names `docs\/specs\/` but no rule on this line protects docs\/specs; the rules name specs, \.env\.local; its rule NoChange specs is about specs, which the line does not name/)
    assert.doesNotMatch(flags[0], /\.env\.local`/, '.env.local is named and has its rule')
    assert.match(flags[1], /its rule NoPushTo master is about master, which the line does not name/)
    assert.equal(summaryOf(last.display).flagged, 2, './build/** and dist\\ name build and dist')
  })

  test('--preview with no earlier approval says so, and its summary leads and matches display.json', () => {
    const lines = fixtureLines()
    const { rootWin } = project(mdOf(lines), lines)
    forget()
    const { last } = preview(rootWin)
    assert.equal(last.ok, true, last.error)
    assert.match(last.display, /^No earlier approved copy to compare with\.$/m)
    const s = summaryOf(last.display)
    assert.ok(s.at < last.display.indexOf('numbered lines, as sorted'), 'the summary comes before the lines')
    const display = JSON.parse(fs.readFileSync(path.join(last.snapshot, 'gen', 'display.json'), 'utf8'))
    const of = k => display.lines.filter(l => l.kind === k)
    assert.equal(s.lines, display.lines.length)
    assert.equal(s.enforced, of('hard').filter(l => l.laws.length > 0).length)
    assert.equal(s.laws, of('hard').reduce((n, l) => n + l.laws.length, 0))
    assert.equal(s.asks, of('ask').length)
    assert.equal(s.advice, of('judgment').length)
    assert.equal(s.lines, s.enforced + s.asks + s.advice + s.trust + s.noLaw)
    assert.equal(s.loosens, null)
  })

  test('--preview after an approval: a deleted hard line (the rest renumbered) is listed and LOOSENS', () => {
    const then = fx([1, 2, 3, 5, 6, 7])
    const display = changed(then, renumber(fx([2, 3, 5, 6, 7])))
    assert.match(display, /^Changed since your last approval \(2026-10-20 09:30 UTC\):$/m)
    assert.match(display, /^ {2}- Line 1 was removed \(hard\): "Never delete or edit files in `specs\/`\./m)
    assert.match(display, /^ {4}LOOSENS: a hard line goes away; law specs_protected goes away\.$/m)
    assert.doesNotMatch(display, /Line \d+ changed/, 'renumbered lines are not changes')
    assert.match(display, /5 other line\(s\) only have a new number/)
    assert.equal(summaryOf(display).loosens, 1)
    assert.ok(display.indexOf('Changed since your last approval') < display.indexOf('numbered lines, as sorted'), 'the changes come before the lines')
  })

  test('--preview after an approval: an added TrustScript LOOSENS ("npm run test will run without asking")', () => {
    const then = fx([1, 2, 3])
    const trust = { line: 4, text: 'Running `npm run test` needs no question.', kind: 'hard', reason: 'r', rules: [{ kind: 'TrustScript', name: 'test' }] }
    const display = changed(then, [...then, trust])
    assert.match(display, /^ {2}- Line 4 is new \(hard\): "Running `npm run test` needs no question\."\.$/m)
    assert.match(display, /^ {4}LOOSENS: npm run test will run without asking\.$/m)
    assert.equal(summaryOf(display).loosens, 1)
    assert.equal(summaryOf(display).trust, 1)
  })

  test('--preview after an approval: lines only reordered and renumbered do not loosen anything', () => {
    const then = fixtureLines()
    const now = renumber([...then].reverse())
    const display = changed(then, now)
    assert.match(display, /^Changed since your last approval \(2026-10-20 09:30 UTC\): nothing; \d+ line\(s\) only have a new number\.$/m)
    assert.doesNotMatch(display, /LOOSENS/)
    assert.equal(summaryOf(display).loosens, 0)
  })

  test('--preview after an approval: a hard line re-sorted as judgment, a dropped rule and a dropped ask each LOOSEN', () => {
    const then = fx([1, 2, 3, 4])
    const now = then.map(l =>
      l.line === 1 ? { ...l, kind: 'judgment', rules: [] } : l.line === 3 ? { ...l, rules: [{ kind: 'NoChange', rel: 'build' }] } : l,
    )
    const display = changed(then, now, undefined, { ...fixtureAsk(), npmInstall: false, lintBeforeDone: null })
    assert.match(display, /^ {2}- Line 1 changed: was hard \(enforced\), now judgment \(advice only\)\.$/m)
    assert.match(display, /^ {4}LOOSENS: this hard line is now advice only; law specs_protected goes away\.$/m)
    assert.match(display, /^ {2}- Line 3 changed: rules were NoChange build, NoChange dist, now NoChange build\.$/m)
    assert.match(display, /^ {4}LOOSENS: law dist_protected goes away\.$/m)
    assert.match(display, /^ {4}LOOSENS: npm install is no longer asked about because of BEND_RULES.md.$/m)
    assert.match(display, /^ {2}- The lint reminder at the end of a turn was `npm run lint`, now none.$/m)
    assert.equal(summaryOf(display).loosens, 3)
    assert.doesNotMatch(display, /Line 2 changed|Line 4 changed/)
  })

  test('--preview after an approval: every law of a removed hard line is named (approve.mjs agrees with gen.mjs on law names)', () => {
    const then = fixtureLines()
    const now = then.filter(l => l.kind !== 'hard')
    const display = changed(then, now)
    const g = gen({ root: FIXTURE_ROOT, lines: then })
    const names = JSON.parse(g.read('display.json')).lines.flatMap(l => l.laws.map(w => w.name))
    assert.ok(names.length >= 10, names.join(' '))
    const loosens = display.split(/\r?\n/).filter(l => /^\s*LOOSENS: /.test(l)).join('\n')
    for (const n of names) assert.match(loosens, new RegExp(`\\blaw ${n}\\b`), `law ${n} is not named:\n${loosens}`)
  })

  test('--preview after an approval made before approved-sort.json existed compares with the hash-checked sort.json', () => {
    const then = fx([1, 2])
    const display = changed(then, fx([2]).map(l => ({ ...l, line: 1 })), { old: true })
    assert.match(display, /LOOSENS: a hard line goes away; law specs_protected goes away\./)
  })

  test('--preview does not compare with a saved copy whose hash approved.json does not record', () => {
    const then = fx([1, 2])
    const { rootWin, root } = project(mdOf(fx([2])), fx([2]))
    const dir = approvedEarlier(root, then)
    try {
      for (const f of ['sort.json', 'approved-sort.json']) fs.writeFileSync(path.join(dir, f), JSON.stringify({ root, lines: fx([2]) }))
      const { last } = preview(rootWin)
      assert.equal(last.ok, true, last.error)
      assert.match(last.display, /^No earlier approved copy to compare with\.$/m)
      assert.doesNotMatch(last.display, /LOOSENS/)
    } finally {
      forget()
    }
  })
})

// ===========================================================================
// A real /bend-guard confirm in the sandbox (stage, prove --no-cache, compile
// and probes in WSL, several minutes): it saves the approved BEND_RULES.md and
// sort.json, and the next preview compares with them.

describe('approve: sandbox confirm saves the approved copy', { skip: process.env.BG_SKIP_WSL === '1' && 'BG_SKIP_WSL=1' }, () => {
  let box, AP, S, D, root, rootWin, build
  before(() => {
    box = tmpDir('bg-tools-sandbox2-')
    const plugin = path.join(box, 'plugin')
    fs.cpSync(path.join(P, 'tools'), path.join(plugin, 'tools'), { recursive: true })
    fs.cpSync(path.join(P, 'bend'), path.join(plugin, 'bend'), { recursive: true })
    fs.copyFileSync(path.join(P, 'BEND_VERSION'), path.join(plugin, 'BEND_VERSION'))
    S = path.join(box, 'state')
    D = path.join(box, 'drafts')
    fs.mkdirSync(S)
    fs.mkdirSync(D)
    AP = path.join(plugin, 'tools', 'approve.mjs')
    let src = fs.readFileSync(AP, 'utf8')
    src = src.replace(/^const S = .*$/m, `const S = ${JSON.stringify(S)}`).replace(/^const D = .*$/m, `const D = ${JSON.stringify(D)}`)
    // the real folders come from the home folder; the copy must not use them
    for (const real of ['const S = stateDir()', 'const D = draftsDir()']) assert.ok(!src.includes(real), `the sandbox copy still has ${real}`)
    assert.ok(src.includes(`const S = ${JSON.stringify(S)}`) && src.includes(`const D = ${JSON.stringify(D)}`))
    fs.writeFileSync(AP, src)
    rootWin = tmpDir('bg-tools-proj-')
    root = rootWin.toLowerCase().replace(/\\/g, '/')
    build = `/root/bg-build/${`approve-${slugOf(root)}`.replace(/[^A-Za-z0-9_.-]/g, '_')}`
  })
  after(async () => {
    const { execFileSync } = await import('node:child_process')
    try {
      execFileSync('C:\\Windows\\System32\\wsl.exe', ['-d', 'Ubuntu-24.04', '-u', 'root', '--exec', 'rm', '-rf', '--', build], { windowsHide: true, timeout: 60000 })
    } catch {
      // best effort
    }
  })

  const draftFor = lines => {
    fs.writeFileSync(path.join(rootWin, 'BEND_RULES.md'), lines.map(l => `${l.line}. ${l.text}`).join('\n') + '\n')
    const dd = path.join(D, slugOf(root))
    fs.mkdirSync(dd, { recursive: true })
    fs.writeFileSync(path.join(dd, 'sort.json'), JSON.stringify({ root, lines }))
    fs.writeFileSync(path.join(dd, 'ask.json'), JSON.stringify(fixtureAsk()))
  }
  const previewNow = () => {
    const r = node(AP, ['--preview', rootWin])
    const last = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(last.ok, true, last.error)
    return last
  }

  test('confirm writes approved-rules.md and approved-sort.json; deleting line 1 then shows LOOSENS', () => {
    const lines = fixtureLines().filter(l => [1, 2, 3, 5, 6, 7].includes(l.line))
    draftFor(lines)
    const first = previewNow()
    assert.match(first.display, /^No earlier approved copy to compare with\.$/m)
    const tok = crypto.randomBytes(32).toString('hex')
    fs.writeFileSync(path.join(S, '.approve-token'), sha256(Buffer.from(tok, 'utf8')))
    const r = node(AP, ['--snapshot', first.snapshot, '--expect', first.previewSha256, '--from-mod'], { input: tok + '\n', timeout: 60 * 60000 })
    const done = JSON.parse(r.stdout.trim().split(/\r?\n/).pop())
    assert.equal(done.ok, true, `${done.message}\n${r.stdout.slice(-2000)}`)
    const live = path.join(S, 'live', 'projects', slugOf(root))
    assert.ok(fs.readFileSync(path.join(live, 'approved-rules.md')).equals(fs.readFileSync(path.join(rootWin, 'BEND_RULES.md'))))
    assert.ok(fs.readFileSync(path.join(live, 'approved-sort.json')).equals(fs.readFileSync(path.join(live, 'sort.json'))))
    assert.match(previewNow().display, /^Changed since your last approval \([^)]+\): nothing\.$/m)
    draftFor(lines.filter(l => l.line !== 1).map((l, i) => ({ ...l, line: i + 1 })))
    const after = previewNow().display
    assert.match(after, /^ {2}- Line 1 was removed \(hard\): /m)
    assert.match(after, /^ {4}LOOSENS: a hard line goes away; law specs_protected goes away\.$/m)
  })
})

// ===========================================================================
// Two TreeDeleteOnlyUnder rules ("never rm -rf outside tmp/ or build/"):
// either gen.mjs refuses the table with a clear reason, or the compiled
// policy passes its own probes. Today each rule denies what the other allows,
// so draft-check fails with a probe failure Claude cannot fix. Compiles a
// policy in WSL (about a minute), build name tools-test-tdo.

describe('gen: one TreeDeleteOnlyUnder per project', () => {
  const tdoLine = (line, rel) => ({ line, text: `Never run rm -rf outside ${rel}/.`, kind: 'hard', reason: 'r', rules: [{ kind: 'TreeDeleteOnlyUnder', rel }] })
  test('two on different lines are refused with the line numbers', () => {
    refuses({ root: FIXTURE_ROOT, lines: [tdoLine(7, 'tmp'), tdoLine(9, 'build')] }, /lines 7 and 9 both have a TreeDeleteOnlyUnder rule \(tmp, build\).*one folder per project only/)
  })
  test('two on one line are refused', () => {
    refuses(hard([{ kind: 'TreeDeleteOnlyUnder', rel: 'tmp' }, { kind: 'TreeDeleteOnlyUnder', rel: 'build' }]), /line 1 has two TreeDeleteOnlyUnder rules/)
  })
  test('one still generates its law', () => {
    const g = gen({ root: FIXTURE_ROOT, lines: [tdoLine(7, 'tmp')] })
    assert.ok(g.laws.includes('tree_delete_only_tmp'), g.laws.join(' '))
  })
  test('an approved project with two is refused too (readLive uses the same check)', () => {
    const live = tmpDir('bg-tools-live-')
    fs.mkdirSync(path.join(live, 'c--aaa-first'))
    fs.writeFileSync(path.join(live, 'c--aaa-first', 'sort.json'), JSON.stringify({ root: 'c:/aaa/first', lines: [tdoLine(1, 'tmp'), tdoLine(2, 'build')] }))
    assert.throws(() => gen({ root: FIXTURE_ROOT, lines: fixtureLines() }, undefined, live), /approved project c--aaa-first: .*TreeDeleteOnlyUnder/)
  })
})

describe('gen + probes: two TreeDeleteOnlyUnder rules', { skip: process.env.BG_SKIP_WSL === '1' && 'BG_SKIP_WSL=1' }, () => {
  test('are refused by gen.mjs, or compile to a policy that passes its probes', async () => {
    const sort = {
      root: FIXTURE_ROOT,
      lines: [{ line: 1, text: 'Never run `rm -rf` outside `tmp/` or `build/`.', kind: 'hard', reason: 'r', rules: [{ kind: 'TreeDeleteOnlyUnder', rel: 'tmp' }, { kind: 'TreeDeleteOnlyUnder', rel: 'build' }] }],
    }
    let g
    try {
      g = gen(sort)
    } catch (err) {
      assert.ok(err instanceof GenError)
      assert.match(err.message, /TreeDeleteOnlyUnder/)
      return
    }
    const name = 'tools-test-tdo'
    const st = await runWsl(path.join(TOOLS, 'stage.sh'), [name, toWslPath(path.join(P, 'bend')), toWslPath(path.join(g.out, 'project'))], { timeoutMs: 300000 })
    assert.equal(st.code, 0, st.stderr)
    const mjs = path.join(g.out, 'policy.mjs')
    const cp = await runWsl(path.join(TOOLS, 'compile.sh'), [`/root/bg-build/${name}`, 'project/Policy.bend', toWslPath(mjs)], { timeoutMs: 1200000 })
    assert.equal(cp.code, 0, (cp.stdout + cp.stderr).slice(-600))
    const r = await runProbes(mjs, JSON.parse(g.read('probes.json')))
    assert.deepEqual(r.failures, [], 'a faithful table for "only under tmp/ or build/" fails its own probes')
  })
})

// ===========================================================================
// prove.sh decides "passed" on a result's first line only. A failed proof's
// result is "<label> <mode>: FAIL" plus bend's output, which names the law
// ("Location: okta_protected") and so contains ": ok".

describe('prove.sh: a failed proof is never read as ok', () => {
  const src = () => fs.readFileSync(path.join(TOOLS, 'prove.sh'), 'utf8')

  test('every pass decision uses the first line, not a loose grep', () => {
    const s = src()
    assert.ok(!/grep -q\w* ': ok/.test(s), "prove.sh still greps for ': ok' anywhere in a result")
    assert.match(s, /passed "\$work\/\$j\.\$mode" "\$\{labels\[\$j\]\} \$mode" \|\| fail=1/)
    assert.match(s, /passed "\$work\/pol" "\$\(rel "\$pol"\) check-only" \|\| fail=1/)
    assert.match(s, /if \[ "\$\(head -n 1 -- "\$res"\)" = "\$label \$mode: ok" \]; then echo "\$k \$mode" >> "\$CACHE"/)
  })

  test("passed(): FAIL with 'Location: okta_protected' fails; exact ok lines pass", { skip: process.env.BG_SKIP_WSL === '1' && 'BG_SKIP_WSL=1' }, async () => {
    const d = tmpDir('bg-tools-passed-')
    const script = path.join(d, 'passed-test.sh')
    fs.writeFileSync(
      script,
      [
        '#!/bin/bash',
        'set -eu',
        'eval "$(sed -n \'/^passed() {/,/^}/p\' "$1")"',
        'w=$(mktemp -d); trap \'rm -rf "$w"\' EXIT',
        'printf "%s\\n" "laws/okta checker: FAIL" "Location: okta_protected" "SOME PROOFS FAIL" > "$w/a"',
        'printf "%s\\n" "project/Policy.bend check-only: FAIL" "Error: x: ok" > "$w/b"',
        'printf "%s\\n" "laws/okta checker: ok" > "$w/c"',
        'printf "%s\\n" "laws/okta kernel: ok (cached proof)" > "$w/d"',
        'printf "%s\\n" "laws/other checker: ok" > "$w/e"',
        'for f in a b c d e; do case $f in a) l="laws/okta checker";; b) l="project/Policy.bend check-only";; c) l="laws/okta checker";; d) l="laws/okta kernel";; e) l="laws/okta checker";; esac',
        '  if passed "$w/$f" "$l"; then echo "$f pass"; else echo "$f fail"; fi; done',
        '',
      ].join('\n'),
    )
    const r = await runWsl(script, [toWslPath(path.join(TOOLS, 'prove.sh'))], { timeoutMs: 120000 })
    assert.equal(r.code, 0, r.stderr + r.stdout)
    const got = String(r.stdout).replace(/\r/g, '').trim().split('\n')
    assert.deepEqual(got, ['a fail', 'b fail', 'c pass', 'd pass', 'e fail'])
  })
})

// ===========================================================================
// approve: the compiled policy never sits in a Windows folder another process
// of this user could write between the compile and the fingerprint (R1-04).

describe('approve: the compiled policy is read back from WSL and checked', () => {
  const policyBytes = Buffer.from('export default { "Policy.run": () => ({ $: "Allow" }) }\n')

  test('compiledSha reads the line compile.sh prints', () => {
    const h = sha256(policyBytes)
    assert.equal(compiledSha(`sha256 ${h}\ncompiled /root/bg-build/x/policy.mjs (55 bytes)\n`), h)
    assert.equal(compiledSha(`sha256 ${h}\r\ncompiled x\r\n`), h)
    assert.equal(compiledSha('compiled x (55 bytes)\n'), null)
    assert.equal(compiledSha(`sha256 ${h.toUpperCase()}\n`), null)
  })

  test('a policy.mjs changed after compile is refused; the same bytes pass', () => {
    const said = sha256(policyBytes)
    assert.deepEqual(compiledMatches(policyBytes, said), { ok: true })
    const backdoored = Buffer.concat([policyBytes, Buffer.from('globalThis.x = 1\n')])
    const r = compiledMatches(backdoored, said)
    assert.equal(r.ok, false)
    assert.match(r.why, /changed after bend wrote it/)
    assert.equal(compiledMatches(Buffer.alloc(0), said).ok, false)
    assert.equal(compiledMatches(policyBytes, null).ok, false)
  })

  test('approve.mjs compiles into the WSL build folder, reads it with wsl cat and checks the hash', () => {
    const src = fs.readFileSync(path.join(TOOLS, 'approve.mjs'), 'utf8')
    const body = src.slice(src.indexOf('async function compileInWsl('), src.indexOf('function execBuf('))
    assert.match(body, /const out = `\$\{build\}\/policy\.mjs`/)
    assert.match(body, /\[build, 'project\/Policy\.bend', out\]/)
    assert.ok(!/toWslPath|readFileSync|tmpdir/.test(body), 'compileInWsl still goes through a Windows path')
    assert.match(body, /'--exec', 'cat', '--', out\]/)
    assert.match(body, /compiledMatches\(c\.stdout, said\)[\s\S]*if \(!m\.ok\) refuse\(m\.why\)/)
    assert.match(src, /const mjsBuf = await compileInWsl\(build\)/)
    assert.ok(!/mjsFile/.test(src), 'approve.mjs still has a Windows policy.mjs path')
    const cs = fs.readFileSync(path.join(TOOLS, 'compile.sh'), 'utf8')
    assert.match(cs, /\necho "sha256 \$\(sha256sum -- "\$out" \| cut -d' ' -f1\)"\necho "compiled \$out/)
  })
})

// ===========================================================================
// stage.sh + prove.sh in WSL (own build name), cached proofs

describe('prove.sh: cached proofs', { skip: process.env.BG_SKIP_WSL === '1' && 'BG_SKIP_WSL=1' }, () => {
  const NAME = 'tools-test-prove'
  const BUILD = `/root/bg-build/${NAME}`
  let mini
  const lawsFile = () => path.join(mini, 'laws', 'verdict', 'LAWS.bend')
  const clean = t => String(t).replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim() !== '')
  const stage = async () => {
    const st = await runWsl(path.join(TOOLS, 'stage.sh'), [NAME, toWslPath(mini)], { timeoutMs: 120000 })
    assert.equal(st.code, 0, st.stderr + st.stdout)
    assert.equal(clean(st.stdout).pop(), BUILD)
  }
  const prove = async () => {
    const r = await runWsl(path.join(TOOLS, 'prove.sh'), [BUILD], { timeoutMs: 900000 })
    return { ...r, lines: clean(r.stdout + '\n' + r.stderr) }
  }
  const nonce = () => `# tools test nonce ${crypto.randomBytes(8).toString('hex')}\n`

  before(() => {
    mini = tmpDir('bg-tools-mini-')
    fs.mkdirSync(path.join(mini, 'core'))
    fs.mkdirSync(path.join(mini, 'laws', 'verdict'), { recursive: true })
    for (const f of ['Types.bend', 'Verdict.bend']) fs.copyFileSync(path.join(P, 'bend', 'core', f), path.join(mini, 'core', f))
    for (const f of ['LAWS.bend', 'PROOF.bend']) fs.copyFileSync(path.join(P, 'bend', 'laws', 'verdict', f), path.join(mini, 'laws', 'verdict', f))
    // a fresh comment, so the first run cannot hit an old cache entry
    fs.appendFileSync(lawsFile(), nonce())
  })
  after(async () => {
    const { execFileSync } = await import('node:child_process')
    try {
      execFileSync('C:\\Windows\\System32\\wsl.exe', ['-d', 'Ubuntu-24.04', '-u', 'root', '--exec', 'rm', '-rf', '--', BUILD], { windowsHide: true, timeout: 60000 })
    } catch {
      // best effort
    }
  })

  test('prove.sh refuses a second argument other than --no-cache, and a third argument', async () => {
    for (const args of [[BUILD, '--bogus'], [BUILD, '--no-cache', 'x'], []]) {
      const r = await runWsl(path.join(TOOLS, 'prove.sh'), args, { timeoutMs: 60000 })
      assert.equal(r.code, 2, `${args.join(' ')}: ${r.stdout}${r.stderr}`)
      assert.match(r.stderr, /usage: prove\.sh <build-dir> \[--no-cache\]/)
    }
  })

  test('stage.sh refuses a bad build name', async () => {
    const st = await runWsl(path.join(TOOLS, 'stage.sh'), ['../x', toWslPath(path.join(P, 'bend'))], { timeoutMs: 60000 })
    assert.equal(st.code, 2)
    assert.match(st.stderr, /bad build name/)
  })

  test('first run proves, second run says (cached proof), a changed byte proves that folder again', async () => {
    await stage()
    const a = await prove()
    assert.equal(a.code, 0, a.lines.join('\n'))
    assert.equal(a.lines.at(-1), 'BEND-GUARD CHECK OK')
    assert.ok(a.lines.includes('laws/verdict checker: ok'), a.lines.join('\n'))
    assert.ok(a.lines.includes('laws/verdict kernel: ok'), a.lines.join('\n'))

    const b = await prove()
    assert.equal(b.code, 0, b.lines.join('\n'))
    assert.ok(b.lines.includes('laws/verdict checker: ok (cached proof)'), b.lines.join('\n'))
    assert.ok(b.lines.includes('laws/verdict kernel: ok (cached proof)'), b.lines.join('\n'))

    // one byte of the law file changes (the nonce's last hex digit)
    const t = fs.readFileSync(lawsFile(), 'utf8')
    const i = t.lastIndexOf('\n', t.length - 2) // the nonce line
    const last = t[t.length - 2]
    fs.writeFileSync(lawsFile(), t.slice(0, t.length - 2) + (last === '0' ? '1' : '0') + '\n')
    assert.equal(fs.readFileSync(lawsFile(), 'utf8').length, t.length)
    assert.ok(i > 0)
    await stage()
    const c = await prove()
    assert.equal(c.code, 0, c.lines.join('\n'))
    assert.ok(c.lines.includes('laws/verdict checker: ok'), `not proven again:\n${c.lines.join('\n')}`)
    assert.ok(c.lines.includes('laws/verdict kernel: ok'), `not proven again:\n${c.lines.join('\n')}`)
  })

  test('--no-cache proves again even when the cache holds the folder', async () => {
    await stage()
    const warm = await prove()
    assert.equal(warm.code, 0, warm.lines.join('\n'))
    const r = await runWsl(path.join(TOOLS, 'prove.sh'), [BUILD, '--no-cache'], { timeoutMs: 900000 })
    const lines = clean(r.stdout + '\n' + r.stderr)
    assert.equal(r.code, 0, lines.join('\n'))
    assert.equal(lines.at(-1), 'BEND-GUARD CHECK OK')
    assert.ok(!lines.some(l => l.includes('(cached proof)')), lines.join('\n'))
    assert.ok(lines.includes('laws/verdict checker: ok') && lines.includes('laws/verdict kernel: ok'), lines.join('\n'))
  })

  test('a changed core file also proves the law folder again', async () => {
    fs.appendFileSync(path.join(mini, 'core', 'Verdict.bend'), nonce())
    await stage()
    const r = await prove()
    assert.equal(r.code, 0, r.lines.join('\n'))
    assert.ok(r.lines.includes('laws/verdict checker: ok'), r.lines.join('\n'))
  })

  test('a failing proof is reported and never cached', async () => {
    const good = fs.readFileSync(lawsFile(), 'utf8')
    // max_ge_left claims the opposite: the proof no longer checks
    const badText = good.replace(
      '{Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == True{} : Bool}',
      '{Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == False{} : Bool}',
    )
    assert.notEqual(badText, good)
    try {
      fs.writeFileSync(lawsFile(), badText + nonce())
      await stage()
      const a = await prove()
      assert.equal(a.code, 1)
      assert.equal(a.lines.at(-1), 'BEND-GUARD CHECK FAILED')
      assert.ok(a.lines.some(l => l === 'laws/verdict checker: FAIL'), a.lines.join('\n'))
      const b = await prove()
      assert.equal(b.code, 1)
      assert.ok(!b.lines.some(l => /laws\/verdict (checker|kernel): ok/.test(l)), `a failed proof came back as ok:\n${b.lines.join('\n')}`)
    } finally {
      fs.writeFileSync(lawsFile(), good)
    }
  })

  // approve.mjs proves with whatever script and arguments its proveInWsl uses.
  // A line in /root/.bend-guard-proofs is not evidence: any root process in
  // WSL can append one. design.md "How it works" 4: the approve tool
  // "regenerates and re-checks everything (with --verdict)".
  test("the approve tool's proof step cannot be satisfied by a forged cache line", async () => {
    const src = fs.readFileSync(path.join(TOOLS, 'approve.mjs'), 'utf8')
    const body = src.slice(src.indexOf('async function proveInWsl('), src.indexOf('async function compileInWsl('))
    const m = /runWslLive\(path\.join\(TOOLS, '([\w.-]+)'\), \[build((?:, '[^']*')*)\]/.exec(body)
    assert.ok(m, 'could not find how approve.mjs runs its proof script')
    const script = m[1]
    const extra = [...m[2].matchAll(/'([^']*)'/g)].map(x => x[1])

    const good = fs.readFileSync(lawsFile(), 'utf8')
    const badText = good.replace(
      '{Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == True{} : Bool}',
      '{Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == False{} : Bool}',
    )
    const forger = path.join(tmpDir('bg-tools-forge-'), 'forge.sh')
    // computes prove.sh's own cache key (its rel() and key() functions, read
    // from prove.sh) for one folder and appends "ok" lines for it, or removes them
    fs.writeFileSync(
      forger,
      [
        '#!/bin/bash',
        'set -eu',
        'prove=$1; dir=$(realpath -e -- "$2"); folder="$dir/$3"; what=$4',
        'BENDSUM=$(sha256sum "$(command -v bend)" | cut -d" " -f1)',
        'eval "$(sed -n \'/^rel() {/,/^}/p\' "$prove")"',
        'eval "$(sed -n \'/^key() {/,/^}/p\' "$prove")"',
        'k=$(key "$folder")',
        'if [ "$what" = add ]; then printf "%s checker\\n%s kernel\\n" "$k" "$k" >> /root/.bend-guard-proofs; else sed -i "/^$k /d" /root/.bend-guard-proofs; fi',
        'echo "$k"',
        '',
      ].join('\n'),
    )
    const forge = what => runWsl(forger, [toWslPath(path.join(TOOLS, 'prove.sh')), BUILD, 'laws/verdict', what], { timeoutMs: 120000 })
    try {
      fs.writeFileSync(lawsFile(), badText + nonce())
      await stage()
      const f = await forge('add')
      assert.equal(f.code, 0, f.stderr + f.stdout)
      const r = await runWsl(path.join(TOOLS, script), [BUILD, ...extra], { timeoutMs: 900000 })
      const lines = clean(r.stdout + '\n' + r.stderr)
      assert.ok(r.code !== 0 && lines.at(-1) === 'BEND-GUARD CHECK FAILED', `${script} ${extra.join(' ')} passed a false law because of a forged cache line:\n${lines.join('\n')}`)
    } finally {
      await forge('remove').catch(() => {})
      fs.writeFileSync(lawsFile(), good)
    }
  })

  test('forbidden forms are refused before any proof runs', async () => {
    const good = fs.readFileSync(lawsFile(), 'utf8')
    try {
      fs.writeFileSync(lawsFile(), good.replace('import Base\n', 'import Base\nimport ../../../../etc/x.bend as X\n'))
      await stage()
      const a = await prove()
      assert.equal(a.code, 1)
      assert.ok(a.lines.some(l => /^forbidden form: laws\/verdict\/LAWS\.bend: import .* leaves the build folder/.test(l)), a.lines.join('\n'))
      fs.writeFileSync(lawsFile(), good + '\ndef sneaky(x: Nat) -> Nat:\n  ?\n')
      await stage()
      const b = await prove()
      assert.equal(b.code, 1)
      assert.ok(b.lines.some(l => /^forbidden form: .*\? \(a hole/.test(l)), b.lines.join('\n'))
    } finally {
      fs.writeFileSync(lawsFile(), good)
    }
  })
})

describe('policy: shell folders after cd', { skip: !fs.existsSync(POLICY) && `no compiled policy at ${POLICY}` }, () => {
  // lost-cwd-absolute-paths-unknown: from a folder that is not known, a cd to
  // an absolute path keeps the folder not known (the cd may have failed)
  test('cd to an absolute path from an unknown folder stays unknown', async () => {
    const lib = await import(new URL('./lib/policy.mjs', import.meta.url).href)
    const Pol = await lib.load(POLICY)
    assert.deepEqual(lib.nextCwds(Pol, lib.call('Bash', { command: 'cd /c/Users/user/bend2_test' }, { cwds: [] })), [])
    assert.deepEqual(lib.nextCwds(Pol, lib.call('Bash', { command: 'cd /c/Users/user/bend2_test/src' })), ['c:/users/user/bend2_test/src', 'c:/users/user/bend2_test'])
  })
})

// ---------------------------------------------------------------------------
// doctor.mjs: read-only, run with USERPROFILE pointed at a sandbox home

describe('doctor: a sandbox home', () => {
  const KEY = 'sk-or-v1-DOCTORTESTKEY0123456789'
  const doctor = (script, home, args = ['--skip-wsl']) =>
    spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', timeout: 120000, env: { ...process.env, USERPROFILE: home, HOME: home }, windowsHide: true })
  // every file under dir with its sha256, to show the doctor wrote nothing
  const tree = dir => {
    const out = {}
    const walk = d => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name)
        if (e.isDirectory()) walk(p)
        else out[path.relative(dir, p)] = sha256(fs.readFileSync(p))
      }
    }
    walk(dir)
    return out
  }

  test('an empty home: each missing piece is reported, and nothing is written', () => {
    const home = tmpDir('bg-doctor-empty-')
    const r = doctor(path.join(TOOLS, 'doctor.mjs'), home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /^ok {7}node: version /m)
    assert.match(r.stdout, /^PROBLEM {2}plugin location: the plugin is at .* but bend-guard needs it at .*local-plugins\\bend-guard\./m)
    assert.match(r.stdout, /^PROBLEM {2}approved\.json: .* does not exist, so nothing is approved/m)
    // the key is optional: a note pointing at the key section, not a problem
    assert.match(r.stdout, /^note {5}Clef key: optional, and there is no key file at .*openrouter\.key.*\(README "The OpenRouter key, and what is sent"\)\.$/m)
    assert.ok(!/^PROBLEM {2}Clef key/m.test(r.stdout), r.stdout)
    assert.match(r.stdout, /^2 problems found\.$/m)
    assert.match(r.stdout, /^skipped  WSL: --skip-wsl$/m)
    assert.deepEqual(fs.readdirSync(home), [])
  })

  describe('a full install in a sandbox home', () => {
    let home, plugin, S, proj, policyText, mdText, DOC
    before(() => {
      home = tmpDir('bg-doctor-full-')
      plugin = path.join(home, '.claude', 'local-plugins', 'bend-guard')
      fs.cpSync(TOOLS, path.join(plugin, 'tools'), { recursive: true })
      fs.cpSync(path.join(P, 'hooks'), path.join(plugin, 'hooks'), { recursive: true })
      fs.copyFileSync(path.join(P, 'BEND_VERSION'), path.join(plugin, 'BEND_VERSION'))
      DOC = path.join(plugin, 'tools', 'doctor.mjs')
      S = path.join(home, '.claude', 'bend-guard')
      fs.mkdirSync(path.join(S, 'live', 'policy'), { recursive: true })
      policyText = 'export default {}\n'
      fs.writeFileSync(path.join(S, 'live', 'policy', 'policy.mjs'), policyText)
      proj = path.join(home, 'app')
      fs.mkdirSync(proj)
      mdText = '1. Never edit `specs/`.\n'
      fs.writeFileSync(path.join(proj, 'BEND_RULES.md'), mdText)
      const root = proj.toLowerCase().replace(/\\/g, '/')
      fs.writeFileSync(
        path.join(S, 'approved.json'),
        JSON.stringify({ version: 2, logOnly: true, policy: { dir: 'live\\policy', mjsSha256: sha256(policyText) }, projects: { [root]: { slug: 'app', rulesMdSha256: sha256(mdText) } } }),
      )
      fs.writeFileSync(path.join(S, 'openrouter.key'), KEY + '\n')
    })

    test('everything in place: no problems, the key is never shown, nothing is written', () => {
      const before = tree(home)
      const r = doctor(DOC, home)
      assert.equal(r.status, 0, r.stdout + r.stderr)
      assert.match(r.stdout, /^ok {7}plugin location: /m)
      assert.match(r.stdout, /^ok {7}approved\.json: readable; 1 approved project, log-only$/m)
      assert.match(r.stdout, /^ok {7}policy\.mjs: matches its fingerprint/m)
      assert.match(r.stdout, /^ok {7}project .*app: BEND_RULES\.md unchanged/m)
      assert.match(r.stdout, /^ok {7}Clef key: the key file exists .*its contents are not shown$/m)
      assert.match(r.stdout, /^skipped  installed copy: Claude Code has no readable .*installed_plugins\.json/m)
      assert.match(r.stdout, /No problems found\.$/m)
      assert.ok(!(r.stdout + r.stderr).includes('DOCTORTESTKEY'))
      assert.deepEqual(tree(home), before)
    })

    test('a changed policy.mjs and a changed BEND_RULES.md are problems', () => {
      const pf = path.join(S, 'live', 'policy', 'policy.mjs')
      const md = path.join(proj, 'BEND_RULES.md')
      fs.writeFileSync(pf, policyText + '// changed\n')
      fs.writeFileSync(md, mdText + '2. More.\n')
      try {
        const r = doctor(DOC, home)
        assert.equal(r.status, 1)
        assert.match(r.stdout, /^PROBLEM {2}policy\.mjs: .* does not match its fingerprint/m)
        assert.match(r.stdout, /^PROBLEM {2}project .*app: BEND_RULES\.md changed since its approval/m)
        assert.match(r.stdout, /2 problems found\.$/m)
      } finally {
        fs.writeFileSync(pf, policyText)
        fs.writeFileSync(md, mdText)
      }
    })

    test('--clef with an empty key file makes no call', () => {
      const kf = path.join(S, 'openrouter.key')
      fs.writeFileSync(kf, '')
      try {
        const r = doctor(DOC, home, ['--skip-wsl', '--clef'])
        assert.equal(r.status, 1)
        assert.match(r.stdout, /^PROBLEM {2}Clef key: .* is empty\./m)
        assert.match(r.stdout, /^PROBLEM {2}Clef call: not made: there is no usable key file\./m)
      } finally {
        fs.writeFileSync(kf, KEY + '\n')
      }
    })

    // Claude Code runs the copy `claude plugin install` made, not this folder;
    // a copy left from an older install runs old hooks.
    test('the installed copy: an older copy is a problem, a matching one or this folder is ok', () => {
      const pluginsDir = path.join(home, '.claude', 'plugins')
      const cache = path.join(pluginsDir, 'cache', 'local-mods', 'bend-guard', '0.1.0')
      const record = installPath =>
        fs.writeFileSync(path.join(pluginsDir, 'installed_plugins.json'), JSON.stringify({ version: 2, plugins: { 'other@x': [{ installPath: 'C:\\nowhere' }], 'bend-guard@local-mods': [{ scope: 'user', installPath, version: '0.1.0' }] } }))
      fs.mkdirSync(pluginsDir, { recursive: true })
      fs.cpSync(path.join(plugin, 'hooks'), path.join(cache, 'hooks'), { recursive: true })
      try {
        record(cache)
        fs.appendFileSync(path.join(cache, 'hooks', 'register.tsx'), '\n// older\n')
        fs.writeFileSync(path.join(cache, 'hooks', 'gone.ts'), 'export {}\n')
        let r = doctor(DOC, home)
        assert.equal(r.status, 1, r.stdout + r.stderr)
        assert.match(r.stdout, /^PROBLEM {2}installed copy: Claude Code runs bend-guard@local-mods from .*0\.1\.0, which is not the same as .* \(2 files differ: hooks\\register\.tsx, hooks\\gone\.ts\), so the hooks that run are not the ones here\. Fix: with bend-guard disabled, .*claude plugin uninstall bend-guard@local-mods, delete .* if it is still there, then claude plugin install bend-guard@local-mods and claude plugin enable bend-guard@local-mods, and restart Claude Code \(if claude is not on your PATH, run it by its full path from the VS Code extension, .*claude\.exe, or use \/plugin in Claude Code\)\.$/m)
        assert.match(r.stdout, /1 problem found\.$/m)
        fs.rmSync(path.join(cache, 'hooks'), { recursive: true })
        fs.cpSync(path.join(plugin, 'hooks'), path.join(cache, 'hooks'), { recursive: true })
        r = doctor(DOC, home)
        assert.equal(r.status, 0, r.stdout + r.stderr)
        assert.match(r.stdout, /^ok {7}installed copy: bend-guard@local-mods at .*0\.1\.0 matches this folder$/m)
        record(plugin)
        r = doctor(DOC, home)
        assert.equal(r.status, 0, r.stdout + r.stderr)
        assert.match(r.stdout, /^ok {7}installed copy: bend-guard@local-mods runs from this folder$/m)
      } finally {
        fs.rmSync(pluginsDir, { recursive: true, force: true })
      }
    })

    test('a missing key file is only a note: exit 0 when nothing else is wrong', () => {
      const kf = path.join(S, 'openrouter.key')
      fs.rmSync(kf)
      try {
        const r = doctor(DOC, home)
        assert.equal(r.status, 0, r.stdout + r.stderr)
        assert.match(r.stdout, /^note {5}Clef key: optional, and there is no key file at /m)
        assert.match(r.stdout, /No problems found\.$/m)
      } finally {
        fs.writeFileSync(kf, KEY + '\n')
      }
    })

    test('bad arguments print usage (exit 2)', () => {
      const r = doctor(DOC, home, ['--bogus'])
      assert.equal(r.status, 2)
      assert.match(r.stdout, /^usage: /)
    })

    test('the WSL checks: distro and pinned bend', { skip: process.env.BG_SKIP_WSL === '1' && 'BG_SKIP_WSL=1' }, () => {
      const r = doctor(DOC, home, [])
      assert.equal(r.status, 0, r.stdout + r.stderr)
      assert.match(r.stdout, /^ok {7}WSL: the Ubuntu-24.04 distro is installed$/m)
      assert.match(r.stdout, /^ok {7}bend: the WSL bend program is the pinned /m)
    })
  })
})

// ---------------------------------------------------------------------------
// Portability: no user name in code (comments excluded). tools/ is checked
// here, and so are hooks/, host/ and bend/core/ (backlog P5) and the
// compile command.

describe('portability: no hard-coded user name', () => {
  // A fixed folder under Users: C:\Users\<name>, c:/users/<name>, /c/Users/<name>,
  // /mnt/c/Users/<name> (Public, Default and All Users are not a person's).
  const USER_DIR = /(?:\b[a-z]:|\/mnt\/[a-z]|(?:^|[\s"'`(=])\/[a-z])[\\/]+users[\\/]+(?!(?:public|default|all users)\b)[a-z0-9]/i
  const stripComments = (text, ext) => {
    const lines = String(text).split(/\r?\n/)
    if (ext === '.sh' || ext === '.bend') return lines.filter(l => !/^\s*#/.test(l)).map(l => l.replace(/\s#\s.*$/, '')).join('\n')
    let s = lines.join('\n').replace(/\/\*[\s\S]*?\*\//g, '')
    return s.split('\n').filter(l => !/^\s*\/\//.test(l)).map(l => l.replace(/\s\/\/\s.*$/, '')).join('\n')
  }
  const hits = dirs => {
    const out = []
    const walk = d => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name)
        if (e.isDirectory()) walk(p)
        else if (/\.(mjs|js|ts|tsx|sh|bend)$/.test(e.name)) {
          const code = stripComments(fs.readFileSync(p, 'utf8'), path.extname(e.name))
          code.split('\n').forEach((l, i) => {
            if (USER_DIR.test(l)) out.push(`${path.relative(P, p)}: ${l.trim().slice(0, 100)}`)
          })
        }
      }
    }
    for (const d of dirs) walk(path.join(P, d))
    return out
  }
  test('tools/', () => assert.deepEqual(hits(['tools']), []))
  test('hooks/, host/, bend/core/', () => assert.deepEqual(hits(['hooks', 'host', path.join('bend', 'core')]), []))
  // The compile command tells Claude where to write and what to run; its
  // permission rule and the draft-check line must work for any user.
  test('commands/compile.md names no user and runs the draft check from ~', () => {
    const md = fs.readFileSync(path.join(P, 'commands', 'compile.md'), 'utf8')
    // its examples use the placeholder folder C:\Users\user only
    const named = [...md.matchAll(/users(?:[\\/]+|-)([a-z0-9._-]+)/gi)].map(m => m[1].toLowerCase().replace(/[-.].*$/, ''))
    assert.ok(named.length > 0 && named.every(n => n === 'user'), `compile.md names a user folder: ${named.join(', ')}`)
    assert.match(md, /^allowed-tools: .*Bash\(node ~\/\.claude\/local-plugins\/bend-guard\/tools\/draft-check\.mjs \*\)$/m)
    assert.match(md, /^node ~\/\.claude\/local-plugins\/bend-guard\/tools\/draft-check\.mjs <slug>$/m)
  })
})

// The README must match what the code writes and what exists on disk.
describe('README matches the code', () => {
  const readme = fs.readFileSync(path.join(P, 'README.md'), 'utf8')
  const reg = fs.readFileSync(path.join(P, 'hooks', 'register.tsx'), 'utf8')
  test('the log-column note is the one register.tsx writes', () => {
    assert.ok(reg.includes("'permission step answered by another plugin'"))
    assert.ok(readme.includes('main (permission step answered by another plugin)'))
    assert.ok(!readme.includes('permission step not seen'))
  })
  test('it points to no decision brief that is not in the plugin', () => {
    assert.ok(!readme.includes('decisions-r3'))
    if (readme.includes('decision-brief.md')) assert.ok(fs.existsSync(path.join(P, 'docs', 'decision-brief.md')), 'README names docs\\decision-brief.md, which is not in the plugin')
  })
  test('it tells the user to approve again, where the claude command is, and how to turn it off', () => {
    assert.match(readme, /approve again/)
    assert.match(readme, /claude plugin marketplace add/)
    assert.match(readme, /anthropic\.claude-code-[^\n]*claude\.exe/)
    assert.match(readme, /\*\*Turning it off\.\*\*/)
    assert.match(readme, /order-probe/)
  })
  test('confirm message names both flags', () => {
    assert.ok(reg.includes('confirm takes only --enforce or --log-only.'))
  })
})
