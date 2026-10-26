// bend-guard: check a draft before the user approves it (plan Task 3.1, used by
// /bend-guard:compile). Generates the project files from the draft's data,
// proves them in WSL, compiles the policy and runs the probe calls.
//
//   node draft-check.mjs <slug>
//
// Draft: %USERPROFILE%\.claude\bend-guard-drafts\<slug>\ (sort.json, ask.json).
// Writes only into <draft>\.check\ (project\*.bend, display.json,
// probes.json, policy.mjs) and the WSL build folder /root/bg-build/draft-<slug>.
// Approved projects are read (never written) from
// %USERPROFILE%\.claude\bend-guard\live\projects when it exists.
// Last line: BEND-GUARD CHECK OK (exit 0) or BEND-GUARD CHECK FAILED (exit 1).

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { generate, slugOf, GenError } from './gen.mjs'
import { runProbes } from './probes.mjs'
import { runWsl, toWslPath, WSL_EXE, DISTRO } from './wsl.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BEND_DIR = path.join(HERE, '..', 'bend')
const DRAFTS = path.join(os.homedir(), '.claude', 'bend-guard-drafts')
const LIVE_PROJECTS = path.join(os.homedir(), '.claude', 'bend-guard', 'live', 'projects')

function failed(lines) {
  for (const l of lines) console.log(l)
  console.log('BEND-GUARD CHECK FAILED')
  process.exit(1)
}

function clean(text) {
  return String(text).replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim() !== '')
}

// rm -rf of one path inside the build folder, as an argv (no shell).
function wslRemove(p) {
  return new Promise(resolve => {
    execFile(WSL_EXE, ['-d', DISTRO, '-u', 'root', '--exec', 'rm', '-rf', '--', p], { windowsHide: true, timeout: 60000 }, err =>
      resolve(!err),
    )
  })
}

function isLink(p) {
  try {
    return fs.lstatSync(p).isSymbolicLink()
  } catch {
    return false
  }
}

async function main(argv) {
  if (argv.length !== 1 || !/^[a-z0-9_-]+$/.test(argv[0])) {
    console.log('usage: node draft-check.mjs <slug>   (slug: a-z 0-9 _ -)')
    process.exit(2)
  }
  const slug = argv[0]
  const draftDir = path.join(DRAFTS, slug)
  const checkDir = path.join(draftDir, '.check')
  if (!fs.existsSync(draftDir) || !fs.lstatSync(draftDir).isDirectory()) failed([`draft: no draft folder ${draftDir}`])
  if (isLink(checkDir)) failed([`draft: ${checkDir} is a link; remove it`])
  fs.rmSync(checkDir, { recursive: true, force: true })
  fs.mkdirSync(checkDir, { recursive: true })

  // 1. Generate from sort.json and ask.json only.
  let g
  try {
    const projectsDir = fs.existsSync(LIVE_PROJECTS) ? LIVE_PROJECTS : null
    g = generate({ draftDir, outDir: checkDir, projectsDir })
  } catch (err) {
    failed([`gen: ${err instanceof GenError ? err.message : String(err && err.message ? err.message : err).slice(0, 300)}`])
  }
  if (slugOf(g.root) !== slug) failed([`gen: sort.json root ${g.root} belongs to the draft ${slugOf(g.root)}, not ${slug}`])
  console.log(`gen: ok (${g.laws.length} laws, ${g.probes} probes, table of ${g.projects.length} project(s))`)

  // 2. Stage core, laws and the project in WSL (base is not part of a draft).
  const name = `draft-${slug}`
  const build = `/root/bg-build/${name}`
  const st = await runWsl(path.join(HERE, 'stage.sh'), [name, toWslPath(BEND_DIR), toWslPath(path.join(checkDir, 'project'))], { timeoutMs: 300000 })
  if (st.code !== 0 || clean(st.stdout).pop() !== build) failed(['stage: failed', ...clean(st.stderr + '\n' + st.stdout).slice(-8)])
  if (!(await wslRemove(`${build}/base`))) failed([`stage: could not remove ${build}/base`])

  // 3. Prove: prove.sh (checker and kernel on every law folder; unchanged proofs reuse the cache).
  const ck = await runWsl(path.join(HERE, 'prove.sh'), [build], { timeoutMs: 1800000 })
  const ckLines = clean(ck.stdout + '\n' + ck.stderr)
  if (ck.code !== 0 || !ckLines.includes('BEND-GUARD CHECK OK')) {
    const i = ckLines.findIndex(l => /: FAIL|^forbidden form|^check\.sh:|^nothing checked/.test(l))
    failed([ck.timedOut ? 'check: timed out' : 'check: failed', ...(i >= 0 ? ckLines.slice(i, i + 14) : ckLines.slice(-14))])
  }
  console.log(`check: ok (${ckLines.filter(l => /: ok$/.test(l)).length} steps)`)

  // 4. Compile project/Policy.bend to <draft>\.check\policy.mjs.
  const mjs = path.join(checkDir, 'policy.mjs')
  const cp = await runWsl(path.join(HERE, 'compile.sh'), [build, 'project/Policy.bend', toWslPath(mjs)], { timeoutMs: 1200000 })
  const cpLines = clean(cp.stdout + '\n' + cp.stderr)
  if (cp.code !== 0 || !fs.existsSync(mjs)) failed([cp.timedOut ? 'compile: timed out' : 'compile: failed', ...cpLines.slice(0, 14)])
  console.log(`compile: ok (${fs.statSync(mjs).size} bytes)`)

  // 5. Probe calls through the compiled policy.
  const probes = JSON.parse(fs.readFileSync(path.join(checkDir, 'probes.json'), 'utf8'))
  const pr = await runProbes(mjs, probes)
  if (!pr.ok) {
    const f = pr.failures[0]
    failed([
      `probes: ${pr.failures.length} of ${probes.length} failed`,
      `first: ${f.name}: expected ${f.expect}, got ${f.got}${f.reason ? ` (${String(f.reason).slice(0, 200)})` : ''}`,
    ])
  }
  console.log(`probes: ok (${pr.ran} passed)`)
  console.log('BEND-GUARD CHECK OK')
}

main(process.argv.slice(2)).catch(err => {
  failed([`draft-check: ${String(err && err.message ? err.message : err).slice(0, 300)}`])
})
