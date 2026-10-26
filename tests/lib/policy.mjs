// bend-guard tests: call the compiled policy the way the glue does.
//
//   import { load, call, run, decide, meaning, nextCwds, verdictOf } from './lib/policy.mjs'
//   const P = await load()                       // tests/.build/policy.mjs (node tests/lib/build.mjs)
//   const c = call('Bash', { command: 'rm -rf specs' })
//   verdictOf(run(P, c))                         // 'deny'
//
// Calls are built exactly like hooks/glue.ts toBendCall + flattenArgs: Windows
// root and folders, home C:\Users\user, links always Nil, mode "".
//
// ROOT and HOME are FIXTURE values, not this PC's: the compiled test policy is
// built for the bend2_test fixture (bend/fixtures/bend2_test, root
// c:/users/user/bend2_test) and the corpus is written for that layout, so the
// tests give the same results on any PC. Another user's home is tested with
// opts.home (call('Edit', {...}, { home: 'C:\\Users\\other' }); in a corpus
// line, "opts": { "home": "C:\\Users\\other" }).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const POLICY = process.env.BG_POLICY ? path.resolve(process.env.BG_POLICY) : path.join(HERE, '..', '.build', 'policy.mjs')
export const ROOT = 'C:\\Users\\user\\bend2_test'
export const HOME = 'C:\\Users\\user'
export const NIL = { $: 'Nil' }
export const NO_ANSWER = { $: 'NoAnswer' }
export const answer = (risky, unsure = 0) => ({ $: 'Answer', risky, unsure })

export async function load(file = POLICY) {
  if (!fs.existsSync(file)) throw new Error(`no compiled policy at ${file}: run node tests/lib/build.mjs first`)
  const m = await import(pathToFileURL(file).href)
  return m.default
}

export function list(xs) {
  let l = NIL
  for (let i = xs.length - 1; i >= 0; i--) l = { $: 'Con', head: xs[i], tail: l }
  return l
}

export function fromList(l) {
  const out = []
  while (l && l.$ === 'Con') {
    out.push(l.head)
    l = l.tail
  }
  return out
}

// Same as hooks/glue.ts flattenArgs: arrays become repeated keys in order,
// plain objects JSON text, numbers and booleans text; undefined/null skipped.
export function flattenArgs(input) {
  const out = []
  const scalar = v => {
    if (v === undefined || v === null) return undefined
    if (typeof v === 'string') return v
    if (typeof v === 'number' || typeof v === 'boolean') return String(v)
    return JSON.stringify(v)
  }
  for (const key of Object.keys(input ?? {})) {
    const v = input[key]
    if (Array.isArray(v)) {
      for (const el of v) {
        const t = scalar(el)
        if (t !== undefined) out.push({ key, value: t })
      }
    } else {
      const t = scalar(v)
      if (t !== undefined) out.push({ key, value: t })
    }
  }
  return out
}

// opts: cwds (array, default [ROOT]), root, home, agent, approver ('person'),
// interactive (true), stage ('check' | { asked, consent }), logOnly (false).
export function call(tool, args = {}, opts = {}) {
  const st = opts.stage === undefined || opts.stage === 'check' ? { $: 'AtCheck' } : { $: 'AtCall', asked: opts.stage.asked === true, consent: opts.stage.consent ?? '' }
  return {
    $: 'Call',
    tool,
    args: list(flattenArgs(args).map(a => ({ $: 'Arg', key: a.key, value: a.value }))),
    cwds: list(opts.cwds ?? [ROOT]),
    root: opts.root ?? ROOT,
    home: opts.home ?? HOME,
    links: NIL,
    agent: opts.agent === true,
    approver: opts.approver ?? 'person',
    interactive: opts.interactive ?? true,
    mode: '',
    stage: st,
    log_only: opts.logOnly === true,
  }
}

export const decide = (P, c) => P['Policy.decide'](c)
export const run = (P, c, a = NO_ANSWER) => P['Policy.run'](c, a)
export const meaning = (P, c) => P['Policy.meaning'](c)
export const nextCwds = (P, c) => fromList(P['Policy.next_cwds'](c))
export const paths = (P, c) => fromList(P['Policy.paths'](c))

// 'allow' | 'ask' | 'deny'
export function verdictOf(v) {
  if (!v || typeof v.$ !== 'string') throw new Error(`not a verdict: ${JSON.stringify(v)}`)
  return v.$.toLowerCase()
}

// A short readable form of a meaning: "Known[DeleteTree c:/x, Read c:/y]" or "Unknown(why)[...]".
export function showMeaning(m) {
  const showPath = p => (p && p.$ === 'Path' ? `${p.drive}:/${fromList(p.segs).join('/')}` : JSON.stringify(p))
  const showAct = a => {
    const fields = Object.entries(a).filter(([k]) => k !== '$')
    return `${a.$}${fields.length ? ' ' + fields.map(([k, v]) => (v && v.$ === 'Path' ? showPath(v) : k === 'refs' || k === 'pkgs' ? `[${fromList(v).join(',')}]` : `${k}=${typeof v === 'object' ? JSON.stringify(v) : v}`)).join(' ') : ''}`
  }
  if (m.$ === 'Known') return `Known[${fromList(m.actions).map(showAct).join(', ')}]`
  return `Unknown(${m.why})[${fromList(m.known).map(showAct).join(', ')}]`
}
