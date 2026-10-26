// bend-guard: fixed probe calls for a project, built from its rule table
// (never from Claude's text), and a runner that puts them through a compiled
// policy.mjs. A probe is a real tool call the policy must deny (or allow);
// it catches a table or compile that type-checks but does not protect.
// Plan: docs/plan.md Task 3.1; brief: docs/build-brief.md.
//
//   NoChange{rel}            Edit rel/__probe__ -> deny, rm -rf rel -> deny
//   NoReadOrChange{rel}      Read rel/__probe__ -> deny, cat rel -> deny
//   TreeDeleteOnlyUnder{rel} rm -rf __probe_outside__ -> deny,
//                            rm -rf rel/__probe__ -> allow
//   NoForcePush              git push -f -> deny
//   NoPushTo{b}              git push origin HEAD:b -> deny
//   every project            cat README.md -> allow
//   built in, every project  node <plugin>/tools/approve.mjs ... -> deny,
//                            Skill bend-guard confirm -> deny
//
// The two built-in probes are part of the approval gate, not tests: they
// prove the compiled policy carries the default rule that only the user runs the
// approve step (ModelGit.approve.*, denied by the self_protection law).
//
// Each probe is run at check time (AtCheck) in the main session with a person
// to ask, outside log-only mode, with no Clef answer (NoAnswer).

import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { homeDir, expectedPluginDir, fwd } from './home.mjs'

// The home folder of the person running the tool (os.homedir()): the probe
// calls carry it as the call's home, as the mod does with %USERPROFILE%.
export const HOME = homeDir()
export const KEYS = ['Policy.decide', 'Policy.run', 'Policy.meaning', 'Policy.next_cwds', 'Policy.paths']

// node <home>/.claude/local-plugins/bend-guard/tools/approve.mjs <root>
export function approveRun(root, home = HOME) {
  return `node ${fwd(path.win32.join(expectedPluginDir(home), 'tools', 'approve.mjs'))} ${fwd(root)}`
}

const NIL = { $: 'Nil' }
const NO_ANSWER = { $: 'NoAnswer' }

function bendList(xs) {
  let l = NIL
  for (let i = xs.length - 1; i >= 0; i--) l = { $: 'Con', head: xs[i], tail: l }
  return l
}

// 'c:/users/user/app' -> 'C:\users\user\app'
export function winPath(normRoot) {
  const m = /^([a-z]):\/(.*)$/.exec(normRoot)
  if (!m) throw new Error(`probes: not a normalised root: ${normRoot}`)
  return `${m[1].toUpperCase()}:\\${m[2].replace(/\//g, '\\')}`
}

// A BendCall (hooks/glue.ts) as the glue would send it for a call in the
// project's root folder.
export function probeCall(root, tool, args) {
  return {
    $: 'Call',
    tool,
    args: bendList(Object.entries(args).map(([key, value]) => ({ $: 'Arg', key, value }))),
    cwds: bendList([root]),
    root,
    home: HOME,
    links: NIL,
    agent: false,
    approver: 'person',
    interactive: true,
    mode: '',
    stage: { $: 'AtCheck' },
    log_only: false,
  }
}

// a lies under b (both relative, '/'-separated), or is b
function relUnder(a, b) {
  return a === b || a.startsWith(b + '/')
}

// rules: [{kind, rel?, branch?, name?, line?}] in table order, already
// validated by gen.mjs. Returns [{name, line, expect: 'allow'|'deny', call}].
export function buildProbes(normRoot, rules) {
  const root = winPath(normRoot)
  const zones = rules.filter(r => r.kind === 'NoChange' || r.kind === 'NoReadOrChange').map(r => r.rel)
  const inZone = rel => zones.some(z => relUnder(rel, z) || relUnder(z, rel))
  const file = rel => `${root}\\${rel.replace(/\//g, '\\')}`
  const bash = command => probeCall(root, 'Bash', { command })
  const out = []
  const add = (r, what, expect, call) =>
    out.push({ name: `${r ? `rule ${r.line ?? '?'} ${r.kind}: ` : ''}${what} -> ${expect}`, line: r ? r.line ?? null : null, expect, call })

  // Built in, whatever the rules: Claude never runs the approve step.
  const approve = approveRun(root)
  add(null, `built-in: ${approve}`, 'deny', bash(approve))
  add(null, 'built-in: Skill bend-guard confirm', 'deny', probeCall(root, 'Skill', { skill: 'bend-guard', args: 'confirm' }))

  for (const r of rules) {
    switch (r.kind) {
      case 'NoChange':
        add(r, `Edit ${r.rel}/__probe__`, 'deny', probeCall(root, 'Edit', { file_path: file(`${r.rel}/__probe__`), old_string: 'a', new_string: 'b' }))
        add(r, `rm -rf ${r.rel}`, 'deny', bash(`rm -rf ${r.rel}`))
        break
      case 'NoReadOrChange':
        add(r, `Read ${r.rel}/__probe__`, 'deny', probeCall(root, 'Read', { file_path: file(`${r.rel}/__probe__`) }))
        add(r, `cat ${r.rel}`, 'deny', bash(`cat ${r.rel}`))
        break
      case 'TreeDeleteOnlyUnder':
        add(r, 'rm -rf __probe_outside__', 'deny', bash('rm -rf __probe_outside__'))
        // Another rule's zone over rel/__probe__ would rightly deny it.
        if (!inZone(`${r.rel}/__probe__`)) add(r, `rm -rf ${r.rel}/__probe__`, 'allow', bash(`rm -rf ${r.rel}/__probe__`))
        break
      case 'NoForcePush':
        add(r, 'git push -f', 'deny', bash('git push -f'))
        break
      case 'NoPushTo':
        add(r, `git push origin HEAD:${r.branch}`, 'deny', bash(`git push origin HEAD:${r.branch}`))
        break
      default:
        break // TrustScript only allows; no probe
    }
  }
  if (!inZone('readme.md')) add(null, 'cat README.md', 'allow', bash('cat README.md'))
  return out
}

function short(err) {
  const s = err && typeof err === 'object' && 'message' in err ? String(err.message) : String(err)
  return s.length > 300 ? s.slice(0, 300) + '...' : s
}

// Imports the compiled policy and runs every probe through Policy.run with
// NoAnswer. Resolves {ok, failures: [{name, expect, got, reason?}], ran}.
export async function runProbes(policyMjsPath, probes) {
  const failures = []
  let api
  try {
    api = (await import(pathToFileURL(policyMjsPath).href)).default
  } catch (err) {
    return { ok: false, failures: [{ name: 'load policy.mjs', expect: 'module', got: 'error', reason: short(err) }], ran: 0 }
  }
  for (const k of KEYS) {
    if (!api || typeof api[k] !== 'function') failures.push({ name: `export ${k}`, expect: 'function', got: typeof api?.[k] })
  }
  if (failures.length > 0) return { ok: false, failures, ran: 0 }
  if (!Array.isArray(probes) || probes.length === 0) {
    return { ok: false, failures: [{ name: 'probes', expect: 'at least one probe', got: 'none' }], ran: 0 }
  }
  let ran = 0
  for (const p of probes) {
    const want = p.expect === 'allow' ? 'Allow' : 'Deny'
    try {
      const v = api['Policy.run'](p.call, NO_ANSWER)
      ran++
      const got = v && typeof v === 'object' ? v.$ : String(v)
      if (got !== want) failures.push({ name: p.name, expect: want, got, reason: v && v.reason })
    } catch (err) {
      failures.push({ name: p.name, expect: want, got: 'error', reason: short(err) })
    }
  }
  return { ok: failures.length === 0, failures, ran }
}
