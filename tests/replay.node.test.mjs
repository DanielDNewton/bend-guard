// bend-guard tests: tools/replay.mjs, the noise replay.
//
//   node --test tests/replay.node.test.mjs
//
// Needs tests/.build/policy.mjs (node tests/lib/build.mjs); BG_POLICY=<file>
// tests another build. The transcripts are the synthetic fixture in
// tests/fixtures/transcripts (no real data): 10 calls, 6 in a main session and
// 4 in a subagent, one holding the secret sk-or-v1-SECRETSECRET. Every run uses
// a temp folder of its own as --temp and checks the run left it empty.

import { test, describe, before, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { shapeOf, reasonKey, segments, rebaser, judge, parseArgs, ArgError } from '../tools/replay.mjs'
import { load, call, ROOT } from './lib/policy.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const P = path.join(HERE, '..')
const REPLAY = path.join(P, 'tools', 'replay.mjs')
const FIX = path.join(HERE, 'fixtures', 'transcripts')
const POLICY = process.env.BG_POLICY ? path.resolve(process.env.BG_POLICY) : path.join(HERE, '.build', 'policy.mjs')

// Text that must never reach the report: the secret, the fixture's path
// arguments and folder, the project and home folders.
const NEVER = ['SECRETSECRET', 'fixture-arg', 'fixproj', 'C:\\work', 'C:/work', /users[\\/]+user\b/i, 'bend2_test', FIX]

let tmp
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bg-replay-test-')) })
after(() => { fs.rmSync(tmp, { recursive: true, force: true }) })

let runNo = 0
function replay(args, { policy = POLICY } = {}) {
  const dir = path.join(tmp, `run${++runNo}`)
  const temp = path.join(dir, 'temp')
  fs.mkdirSync(temp, { recursive: true })
  const json = path.join(dir, 'report.json')
  const r = spawnSync(process.execPath, [REPLAY, '--transcripts', FIX, '--policy', policy, '--temp', temp, '--json', json, ...args], { encoding: 'utf8', timeout: 120000 })
  const jsonText = fs.existsSync(json) ? fs.readFileSync(json, 'utf8') : ''
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, jsonText, rep: jsonText ? JSON.parse(jsonText) : null, tempLeft: fs.readdirSync(temp) }
}
const counts = s => ({ n: s.n, allow: s.allow.count, ask: s.ask.count, deny: s.deny.count, crash: s.crash.count, clef: s.clef.count, ...(s.understood ? { understood: s.understood.count, shell: s.understood.of } : {}) })
const noLeak = (text, what) => { for (const x of NEVER) assert.ok(x instanceof RegExp ? !x.test(text) : !text.includes(x), `${what} holds ${x}`) }

describe('replay over the fixture transcripts', () => {
  test('exact counts, main session with a person present', () => {
    const r = replay([])
    assert.equal(r.status, 0, r.stderr)
    const { rep } = r
    assert.deepEqual({ calls: rep.meta.calls, main: rep.meta.main, sub: rep.meta.sub, files: rep.meta.files, read: rep.meta.filesRead }, { calls: 10, main: 6, sub: 4, files: 2, read: 2 })
    assert.deepEqual(counts(rep.all), { n: 10, allow: 6, ask: 3, deny: 1, crash: 0, clef: 2, understood: 3, shell: 5 })
    assert.deepEqual(counts(rep.main), { n: 6, allow: 3, ask: 2, deny: 1, crash: 0, clef: 1, understood: 1, shell: 2 })
    assert.deepEqual(counts(rep.sub), { n: 4, allow: 3, ask: 1, deny: 0, crash: 0, clef: 1, understood: 2, shell: 3 })
    assert.deepEqual(counts(rep.tools.Bash), { n: 4, allow: 2, ask: 2, deny: 0, crash: 0, clef: 2, understood: 2, shell: 4 })
    assert.deepEqual(counts(rep.tools.PowerShell), { n: 1, allow: 1, ask: 0, deny: 0, crash: 0, clef: 0, understood: 1, shell: 1 })
    assert.deepEqual(counts(rep.tools.MCP), { n: 1, allow: 0, ask: 1, deny: 0, crash: 0, clef: 0 })
    assert.deepEqual(counts(rep.tools.other), { n: 4, allow: 3, ask: 0, deny: 1, crash: 0, clef: 0 })
    assert.equal(rep.all.ask.pct, 30)
    assert.equal(rep.all.clef.pct, 20)
    assert.equal(rep.crashes, 0)
    assert.deepEqual(rep.otherTools.map(x => x.key).sort(), ['Edit', 'Grep', 'Read', 'Write'])
    assert.deepEqual(rep.shapes.map(x => x.key).sort(), ['Bash: frobnicate --token', 'Bash: zorblax'])
    assert.deepEqual(rep.unknownReasons.map(x => x.key).sort(), ['Bash: the command frobnicate is not modelled', 'Bash: the command zorblax is not modelled', 'MCP: tool … not modelled'])
    assert.equal(rep.denies.length, 1)
    assert.match(rep.denies[0].key, /^Write: Write — bend-guard self-protection: … is bend-guard's own/)
    assert.match(r.stdout, /10 calls \(6 main, 4 subagent\)/)
    assert.match(r.stdout, /clef share \(calls that would go to Clef\): 20%/)
  })

  test('stdout and the --json file hold no secret, path argument or folder; the temp folder is gone', () => {
    const r = replay([])
    assert.equal(r.status, 0, r.stderr)
    noLeak(r.stdout, 'stdout')
    noLeak(r.jsonText, 'the --json file')
    noLeak(r.stderr, 'stderr')
    assert.deepEqual(r.tempLeft, [])
  })

  test('--agent-as-is replays subagent calls as agent calls', () => {
    const r = replay(['--agent-as-is'])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(r.rep.meta.agentAsIs, true)
    assert.deepEqual(counts(r.rep.sub), { n: 4, allow: 3, ask: 0, deny: 1, crash: 0, clef: 0, understood: 2, shell: 3 })
    assert.deepEqual(counts(r.rep.main), { n: 6, allow: 3, ask: 2, deny: 1, crash: 0, clef: 1, understood: 1, shell: 2 })
    assert.deepEqual(r.tempLeft, [])
  })

  test('--n takes half from main sessions and half from subagents, the same calls for the same seed', () => {
    const a = replay(['--n', '4', '--seed', '7'])
    const b = replay(['--n', '4', '--seed', '7'])
    assert.equal(a.status, 0, a.stderr)
    assert.deepEqual([a.rep.meta.main, a.rep.meta.sub], [2, 2])
    const strip = rep => { const { meta, msPerCall, ...rest } = rep; return rest }
    assert.deepEqual(strip(a.rep), strip(b.rep))
  })

  test('--per-file caps the calls taken from one transcript', () => {
    const r = replay(['--per-file', '2'])
    assert.equal(r.status, 0, r.stderr)
    assert.deepEqual([r.rep.meta.main, r.rep.meta.sub], [2, 2])
  })

  test('--before keeps only calls made before the date', () => {
    const r = replay(['--before', '2026-03-01'])
    assert.equal(r.status, 0, r.stderr)
    assert.deepEqual([r.rep.meta.main, r.rep.meta.sub], [6, 3])
    assert.equal(r.rep.tools.PowerShell, undefined)
    assert.equal(r.rep.meta.before, '2026-03-01T00:00:00.000Z')
  })

  test('--tool takes only that tool, still split between main sessions and subagents', () => {
    const r = replay(['--tool', 'Bash'])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(r.rep.meta.tool, 'Bash')
    assert.deepEqual(Object.keys(r.rep.tools), ['Bash'])
    assert.deepEqual(counts(r.rep.all), { n: 4, allow: 2, ask: 2, deny: 0, crash: 0, clef: 2, understood: 2, shell: 4 })
    assert.equal(r.rep.meta.main + r.rep.meta.sub, 4)
    assert.ok(r.rep.meta.main > 0 && r.rep.meta.sub > 0, 'both main and subagent calls are taken')
    assert.match(r.stdout, /tool Bash only/)
    const a = replay(['--tool', 'Bash', '--n', '2', '--seed', '3'])
    const b = replay(['--tool', 'Bash', '--n', '2', '--seed', '3'])
    assert.equal(a.status, 0, a.stderr)
    assert.deepEqual([a.rep.meta.main, a.rep.meta.sub], [1, 1])
    const strip = rep => { const { meta, msPerCall, ...rest } = rep; return rest }
    assert.deepEqual(strip(a.rep), strip(b.rep))
    const ps = replay(['--tool', 'PowerShell'])
    assert.equal(ps.status, 0, ps.stderr)
    assert.deepEqual(Object.keys(ps.rep.tools), ['PowerShell'])
    assert.equal(ps.rep.meta.calls, 1)
    const none = replay(['--tool', 'NoSuchTool'])
    assert.equal(none.status, 0, none.stderr)
    assert.equal(none.rep.meta.calls, 0)
    for (const x of [r, a, ps, none]) assert.deepEqual(x.tempLeft, [])
  })

  test('--tool needs a tool name', () => {
    for (const args of [['--tool'], ['--tool', '--n', '5'], ['--tool', 'Power Shell'], ['--tool', 'a/b'], ['--tool', '']]) {
      const r = replay(args)
      assert.equal(r.status, 2, JSON.stringify(args))
      assert.match(r.stderr, /usage: node tools\/replay\.mjs/)
      assert.deepEqual(r.tempLeft, [])
    }
    assert.throws(() => parseArgs(['--tool', '*']), /--tool must be a tool name/)
    assert.equal(parseArgs(['--tool', 'mcp__x__y']).tool, 'mcp__x__y')
    assert.equal(parseArgs([]).tool, null)
  })

  test('--show prints commands masked with the glue redact rules', () => {
    const r = replay(['--show'])
    assert.equal(r.status, 0, r.stderr)
    assert.ok(!r.stdout.includes('SECRETSECRET'))
    assert.match(r.stdout, /frobnicate --token sk-or-\*\*\*/)
    assert.ok(!r.jsonText.includes('SECRETSECRET'))
    assert.ok(!r.jsonText.includes('fixture-arg'), 'the --json file stays counts only with --show')
    assert.deepEqual(r.tempLeft, [])
  })

  test('a policy that fails to load: exit 1, no secret on stderr, the temp folder is gone', () => {
    const bad = path.join(tmp, 'bad-policy.mjs')
    fs.writeFileSync(bad, 'throw new Error("broken policy")\n')
    const r = replay([], { policy: bad })
    assert.equal(r.status, 1)
    assert.match(r.stderr, /broken policy/)
    assert.ok(!r.stderr.includes('SECRETSECRET'))
    assert.equal(r.jsonText, '')
    assert.deepEqual(r.tempLeft, [])
  })

  test('bad options exit 2 with the usage', () => {
    for (const args of [['--n', '0'], ['--frob'], ['--before', 'not a date'], ['--json']]) {
      const r = replay(args)
      assert.equal(r.status, 2, args.join(' '))
      assert.match(r.stderr, /usage: node tools\/replay\.mjs/)
      assert.deepEqual(r.tempLeft, [])
    }
    assert.throws(() => parseArgs(['--seed', '-1']), ArgError)
  })
})

describe('shapes and reasons hold no values', () => {
  test('shapeOf keeps the program, subcommand and flag names only', () => {
    assert.equal(shapeOf('git -C some/dir log --format=%H -n 5 -- src/a.ts'), 'git log -- --format= -C -n')
    assert.equal(shapeOf('mysql -pHunter2pass -u root db'), 'mysql -p… -u')
    assert.equal(shapeOf('mysql -psecretpw db'), 'mysql -p…')
    assert.equal(shapeOf('curl --header=Authorization:abc https://example.com/x'), 'curl --header=')
    assert.equal(shapeOf('rpc.mainnet.example.com --flag'), '… --flag')
    assert.equal(shapeOf('S=/c/Users/someone/scratchpad'), 'VAR=…')
    assert.equal(shapeOf('TOKEN=abc123 timeout 30 npm run build -- --watch'), 'VAR=… timeout npm run -- --watch')
    assert.equal(shapeOf('/c/tools/bin/mytool --x'), '…/mytool --x')
    assert.equal(shapeOf('node scripts/build.mjs secretword'), 'node')
    assert.equal(shapeOf('python3 -m pytest -q tests/'), 'python pytest -m -q')
    assert.equal(shapeOf("python -c 'print(1)'"), 'python -c')
    assert.equal(shapeOf('find . -name "*.ts" -maxdepth 2'), 'find -maxdepth -name')
    assert.equal(shapeOf('Get-ChildItem -Path C:\\x -Filter:*.ts', true), 'get-childitem -filter: -path')
    assert.equal(shapeOf('sk-or-v1-SECRETSECRET --x'), 'sk-or-*** --x')
  })

  test('reasonKey keeps the wording and drops paths and quoted values', () => {
    assert.equal(reasonKey('rm: cannot tell where the path C:/x/secret.txt points'), 'rm: cannot tell where the path … points')
    assert.equal(reasonKey("bend-guard: not understood (grep: the wildcard in 'src/*.ts' may name files)"), 'not understood (grep: the wildcard in … may name files)')
    assert.equal(reasonKey('tool mcp__x__y not modelled'), 'tool … not modelled')
    assert.equal(reasonKey('the token=abcdefghijklmnopqrstuvwxyz is here'), 'the … is here')
    assert.ok(reasonKey('word '.repeat(80)).length <= 172)
  })

  test('segments splits a command at the top level only', () => {
    assert.deepEqual(segments('a && b | c; d "e;f" (g; h)'), ['a', 'b', 'c', 'd "e;f" (g; h)'])
    assert.deepEqual(segments("cat <<'EOF'\nx; y\nEOF"), ["cat <<'EOF'"])
  })

  test('rebaser moves the session folder into the project in every spelling', () => {
    const f = rebaser('C:\\work\\fixproj', ROOT)
    assert.equal(f('C:\\work\\fixproj\\a'), ROOT + '\\a')
    assert.equal(f('c:/work/fixproj/a'), ROOT.replace(/\\/g, '/') + '/a')
    assert.equal(f('/c/work/fixproj/a'), '/c' + ROOT.replace(/\\/g, '/').slice(2) + '/a')
    assert.equal(f('C:\\\\work\\\\fixproj\\\\a'), ROOT.replace(/\\/g, '\\\\') + '\\\\a')
    assert.equal(f('C:/work/fixproj2/a'), 'C:/work/fixproj2/a')
  })
})

describe('the fast judge agrees with the public entries', () => {
  test('same verdict, Clef step and meaning on fixture-like calls', async () => {
    const P = await load(POLICY)
    const calls = [
      ['Bash', { command: 'git status' }], ['Bash', { command: 'frobnicate --x' }], ['Bash', { command: 'rm -rf node_modules' }],
      ['Bash', { command: 'rm -rf C:/Users/user/.claude/plugins' }], ['Bash', { command: 'git push origin main' }],
      ['Bash', { command: 'sed -n 1,5p a.txt | wc -l' }], ['Bash', { command: 'echo $HOME' }],
      ['PowerShell', { command: 'Get-ChildItem' }], ['PowerShell', { command: 'Remove-Item -Recurse x' }],
      ['Read', { file_path: ROOT + '\\a.txt' }], ['Write', { file_path: 'C:\\Users\\user\\.claude\\settings.json', content: '' }],
      ['mcp__x__y', { q: 'z' }], ['StructuredOutput', { a: 1 }],
    ]
    for (const [tool, input] of calls) {
      for (const agent of [false, true]) {
        const c = call(tool, input, { agent })
        assert.deepEqual(judge(P, c, true), judge(P, c, false), `${tool} ${JSON.stringify(input)} agent=${agent}`)
      }
    }
  })
})
