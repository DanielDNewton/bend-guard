// bend-guard tests: build the compiled policy the tests run against.
//
//   node tests/lib/build.mjs [--prove] [--out <dir>] [--name <wsl build name>] [--bend <dir>]
//   (fixers working in parallel use their own --out and --name; tests pick the
//   policy with BG_POLICY=<dir>/policy.mjs, default tests/.build/policy.mjs)
//
// Generates the project files for the bend2_test fixture (bend/fixtures/
// bend2_test: rules.json, ask.json) as a draft would, stages core + laws +
// that project in WSL, optionally proves everything (prove.sh, cached), and
// compiles project/Policy.bend to tests/.build/policy.mjs. Never touches the
// real drafts or state folders.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { generate } from '../../tools/gen.mjs'
import { runWsl, toWslPath, WSL_EXE, DISTRO } from '../../tools/wsl.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const P = path.join(HERE, '..', '..')
const TOOLS = path.join(P, 'tools')
const FIXTURE = path.join(P, 'bend', 'fixtures', 'bend2_test')
export const OUT = path.join(P, 'tests', '.build')
export const POLICY = path.join(OUT, 'policy.mjs')
// A FIXTURE value, not this PC's: the root the bend2_test fixture is built for
// (the corpus and tests/lib/policy.mjs ROOT use the same layout on any PC).
export const FIXTURE_ROOT = 'c:/users/user/bend2_test'

const clean = t => String(t).replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim() !== '')

function wslRemove(p) {
  return new Promise(resolve => {
    execFile(WSL_EXE, ['-d', DISTRO, '-u', 'root', '--exec', 'rm', '-rf', '--', p], { windowsHide: true, timeout: 60000 }, err => resolve(!err))
  })
}

// bend: the Bend source folder to build (default the plugin's bend/; a
// builder working in a sandbox copy passes its own with --bend <dir>).
export async function buildPolicy({ prove = false, name = 'tests', out = OUT, bend = path.join(P, 'bend') } = {}) {
  const policy = path.join(out, 'policy.mjs')
  const draft = fs.mkdtempSync(path.join(os.tmpdir(), 'bg-test-draft-'))
  try {
    const fixture = path.join(bend, 'fixtures', 'bend2_test')
    const lines = JSON.parse(fs.readFileSync(path.join(fixture, 'rules.json'), 'utf8'))
    fs.writeFileSync(path.join(draft, 'sort.json'), JSON.stringify({ root: FIXTURE_ROOT, lines }, null, 2))
    fs.copyFileSync(path.join(fixture, 'ask.json'), path.join(draft, 'ask.json'))
    fs.rmSync(out, { recursive: true, force: true })
    fs.mkdirSync(out, { recursive: true })
    const g = generate({ draftDir: draft, outDir: out, projectsDir: null })

    const build = `/root/bg-build/${name}`
    const st = await runWsl(path.join(TOOLS, 'stage.sh'), [name, toWslPath(bend), toWslPath(path.join(out, 'project'))], { timeoutMs: 300000 })
    if (st.code !== 0 || clean(st.stdout).pop() !== build) throw new Error(`stage failed: ${clean(st.stderr + '\n' + st.stdout).slice(-6).join(' | ')}`)
    if (!(await wslRemove(`${build}/base`))) throw new Error('could not remove base from the build folder')

    let proof = 'not proved'
    if (prove) {
      const ck = await runWsl(path.join(TOOLS, 'prove.sh'), [build], { timeoutMs: 1800000 })
      const lines2 = clean(ck.stdout + '\n' + ck.stderr)
      if (ck.code !== 0 || !lines2.includes('BEND-GUARD CHECK OK')) throw new Error(`prove failed:\n${lines2.filter(l => /FAIL|forbidden/.test(l)).slice(0, 20).join('\n')}`)
      proof = 'BEND-GUARD CHECK OK'
    }

    const cp = await runWsl(path.join(TOOLS, 'compile.sh'), [build, 'project/Policy.bend', toWslPath(policy)], { timeoutMs: 1200000 })
    if (cp.code !== 0 || !fs.existsSync(policy)) throw new Error(`compile failed: ${clean(cp.stdout + '\n' + cp.stderr).slice(0, 12).join(' | ')}`)
    return { policy, bytes: fs.statSync(policy).size, laws: g.laws.length, proof }
  } finally {
    fs.rmSync(draft, { recursive: true, force: true })
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = k => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : undefined }
  buildPolicy({ prove: process.argv.includes('--prove'), out: arg('--out') ? path.resolve(arg('--out')) : OUT, name: arg('--name') ?? 'tests', bend: arg('--bend') ? path.resolve(arg('--bend')) : path.join(P, 'bend') })
    .then(r => console.log(`built ${r.policy} (${r.bytes} bytes, ${r.laws} project laws, ${r.proof})`))
    .catch(err => {
      console.log(`build failed: ${err.message}`)
      process.exit(1)
    })
}
