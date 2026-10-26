// bend-guard: the generator. Turns a draft's sort.json and ask.json (data
// only, never Bend text) plus the already-approved projects into the project
// Bend files, filled from bend/templates only.
// Plan: docs/plan.md Task 3.1; brief: docs/build-brief.md; template rules:
// bend/templates/README.md.
//
//   node gen.mjs <draftDir> <outDir> [--projects <liveProjectsDir>]
//
// Reads <draftDir>\sort.json and <draftDir>\ask.json, and
// <liveProjectsDir>\<slug>\sort.json for each approved project. Writes
// <outDir>\project\{Rules,Policy,LAWS,PROOF}.bend, <outDir>\display.json and
// <outDir>\probes.json. Any bad input: exit 1 with the reason.
//
// sort.json: { "root": "c:/users/user/app", "lines": [ entry, ... ] },
// entry = { line, text, kind: "hard"|"ask"|"judgment", reason, rules,
// suggestion? }, rules only on hard lines:
//   {"kind":"NoChange","rel":R} {"kind":"NoReadOrChange","rel":R}
//   {"kind":"TreeDeleteOnlyUnder","rel":R} {"kind":"NoForcePush"}
//   {"kind":"NoPushTo","branch":B} {"kind":"TrustScript","name":N}
// ask.json: { newTopLevelDir, npmInstall, testBeforeDone, lintBeforeDone }.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildProbes } from './probes.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const TEMPLATES = path.join(HERE, '..', 'bend', 'templates')

export class GenError extends Error {}
function fail(msg) {
  throw new GenError(msg)
}

// ---------------------------------------------------------------------------
// Reading and validating

const SEG = /^[a-z0-9_][a-z0-9._ -]*$/ // a root folder name, as Path.norm gives it
const REL_SEG = /^[a-z0-9._][a-z0-9._-]*$/
const NAME = /^[A-Za-z0-9._/][A-Za-z0-9._/-]*$/ // branch or script name
const KINDS = ['hard', 'ask', 'judgment']

// The draft and live folder name of a root: : / . and space become -, so a
// slug is always [a-z0-9_-]+ (draft-check.mjs, Bend dc.slug and stage.sh
// accept nothing else). hooks/glue.ts slugOf must stay the same. Two roots can
// share a slug (a-b and a/b); generate refuses the second one.
export function slugOf(root) {
  return root.replace(/[:/. ]/g, '-')
}

function readJson(file, what) {
  let st
  try {
    st = fs.lstatSync(file)
  } catch {
    fail(`${what}: ${file} is missing`)
  }
  if (!st.isFile()) fail(`${what}: ${file} is not a plain file`)
  if (st.size > 1024 * 1024) fail(`${what}: ${file} is larger than 1 MiB`)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''))
  } catch (err) {
    fail(`${what}: ${file} is not valid JSON (${String(err.message).slice(0, 120)})`)
  }
}

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
}

function exactKeys(o, required, optional, where) {
  if (!isObj(o)) fail(`${where}: expected an object`)
  for (const k of required) if (!(k in o)) fail(`${where}: "${k}" is missing`)
  for (const k of Object.keys(o)) {
    if (!required.includes(k) && !optional.includes(k)) fail(`${where}: unknown key "${k}"`)
  }
}

function plainText(v, where, max = 2000) {
  if (typeof v !== 'string') fail(`${where}: expected a string`)
  if (v.length > max) fail(`${where}: longer than ${max} characters`)
  if (/[\u0000-\u001f\u007f]/.test(v)) fail(`${where}: holds a control character or line break`)
  return v
}

// The normalised project root, lower case c:/... with plain folder names.
export function checkRoot(root, where) {
  if (typeof root !== 'string') fail(`${where}: "root" must be a string`)
  const m = /^c:\/(.+)$/.exec(root)
  if (!m) fail(`${where}: root "${root}" is not a normalised c:/... path (lower case, / separators, at least one folder)`)
  const segs = m[1].split('/')
  for (const s of segs) {
    if (!SEG.test(s) || /[. ]$/.test(s)) {
      fail(`${where}: root "${root}" has the folder name "${s}"; only lower-case a-z 0-9 . _ - and spaces are allowed, not ending in . or space`)
    }
  }
  return { root, drive: 'c', segs, show: root }
}

function checkRel(rel, where) {
  if (typeof rel !== 'string' || rel === '') fail(`${where}: "rel" must be a non-empty string`)
  if (rel.startsWith('/')) fail(`${where}: rel "${rel}" starts with /; it must be relative to the project root`)
  for (const s of rel.split('/')) {
    if (s === '.' || s === '..') fail(`${where}: rel "${rel}" holds "${s}"; only plain folder and file names are allowed`)
    if (!REL_SEG.test(s) || s.endsWith('.')) {
      fail(`${where}: rel "${rel}" is not plain lower-case names (a-z 0-9 . _ -, not starting with - or ending in .) separated by /`)
    }
  }
  return rel
}

function checkName(v, key, where) {
  if (typeof v !== 'string' || !NAME.test(v) || v.length > 200) {
    fail(`${where}: ${key} "${String(v)}" must match [A-Za-z0-9._/-]+ and not start with -`)
  }
  return v
}

function checkRule(r, where) {
  if (!isObj(r)) fail(`${where}: a rule must be an object`)
  switch (r.kind) {
    case 'NoChange':
    case 'NoReadOrChange':
    case 'TreeDeleteOnlyUnder':
      exactKeys(r, ['kind', 'rel'], [], where)
      return { kind: r.kind, rel: checkRel(r.rel, where) }
    case 'NoForcePush':
      exactKeys(r, ['kind'], [], where)
      return { kind: r.kind }
    case 'NoPushTo':
      exactKeys(r, ['kind', 'branch'], [], where)
      return { kind: r.kind, branch: checkName(r.branch, 'branch', where) }
    case 'TrustScript':
      exactKeys(r, ['kind', 'name'], [], where)
      return { kind: r.kind, name: checkName(r.name, 'name', where) }
    default:
      fail(`${where}: unknown rule kind ${JSON.stringify(r.kind)} (known: NoChange, NoReadOrChange, TreeDeleteOnlyUnder, NoForcePush, NoPushTo, TrustScript)`)
  }
}

// -> { root, drive, segs, show, lines: [{line, text, kind, reason, suggestion?, rules}] }
export function checkSort(obj, where) {
  exactKeys(obj, ['root', 'lines'], [], where)
  const r = checkRoot(obj.root, where)
  if (!Array.isArray(obj.lines)) fail(`${where}: "lines" must be an array`)
  const seen = new Set()
  const lines = obj.lines.map((e, i) => {
    const w = `${where}: lines[${i}]`
    exactKeys(e, ['line', 'text', 'kind', 'reason', 'rules'], ['suggestion'], w)
    if (!Number.isInteger(e.line) || e.line < 1 || e.line > 100000) fail(`${w}: "line" must be a positive whole number`)
    if (seen.has(e.line)) fail(`${w}: line ${e.line} appears twice`)
    seen.add(e.line)
    if (!KINDS.includes(e.kind)) fail(`${w}: kind ${JSON.stringify(e.kind)} is not hard, ask or judgment`)
    if (!Array.isArray(e.rules)) fail(`${w}: "rules" must be an array`)
    if (e.kind !== 'hard' && e.rules.length > 0) fail(`${w}: only a hard line may carry rules`)
    const out = {
      line: e.line,
      text: plainText(e.text, `${w}.text`),
      kind: e.kind,
      reason: plainText(e.reason, `${w}.reason`),
      rules: e.rules.map((x, j) => checkRule(x, `${w}.rules[${j}]`)),
    }
    if ('suggestion' in e) out.suggestion = plainText(e.suggestion, `${w}.suggestion`)
    return out
  })
  lines.sort((a, b) => a.line - b.line)
  // Guard.bend applies each rule on its own, so two TreeDeleteOnlyUnder rules
  // would each deny what the other allows, and the table could never pass its
  // probes. One per project.
  const tdo = []
  for (const l of lines) for (const x of l.rules) if (x.kind === 'TreeDeleteOnlyUnder') tdo.push({ line: l.line, rel: x.rel })
  if (tdo.length > 1) {
    const [a, b] = tdo
    const at = a.line === b.line ? `line ${a.line} has two TreeDeleteOnlyUnder rules` : `lines ${a.line} and ${b.line} both have a TreeDeleteOnlyUnder rule`
    const rels = tdo.map(t => t.rel).join(', ')
    fail(`${where}: ${at} (${rels}); bend-guard can allow recursive deletes under one folder per project only. Keep one, or make the line hard with no rules and say why`)
  }
  return { ...r, lines }
}

export function checkAsk(obj, where) {
  exactKeys(obj, ['newTopLevelDir', 'npmInstall', 'testBeforeDone', 'lintBeforeDone'], [], where)
  for (const k of ['newTopLevelDir', 'npmInstall']) {
    if (typeof obj[k] !== 'boolean') fail(`${where}: "${k}" must be true or false`)
  }
  for (const k of ['testBeforeDone', 'lintBeforeDone']) {
    if (obj[k] !== null) {
      plainText(obj[k], `${where}: "${k}"`, 200)
      if (obj[k].trim() === '') fail(`${where}: "${k}" must be a command or null`)
    }
  }
  return obj
}

// The project's rules: hard lines in line order, each line's rules in order.
function tableRules(p) {
  const out = []
  for (const l of p.lines) if (l.kind === 'hard') for (const r of l.rules) out.push({ ...r, line: l.line })
  return out
}

function readLive(dir) {
  let st
  try {
    st = fs.lstatSync(dir)
  } catch {
    fail(`--projects: ${dir} does not exist`)
  }
  if (!st.isDirectory()) fail(`--projects: ${dir} is not a folder`)
  const out = []
  for (const ent of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (!ent.isDirectory()) continue
    const where = `approved project ${ent.name}`
    const p = checkSort(readJson(path.join(dir, ent.name, 'sort.json'), where), where)
    if (slugOf(p.root) !== ent.name) fail(`${where}: its sort.json root ${p.root} does not match the folder name`)
    out.push(p)
  }
  return out
}

// ---------------------------------------------------------------------------
// Rendering (bend/templates/README.md)

function readTemplate(rel) {
  return fs.readFileSync(path.join(TEMPLATES, rel), 'utf8').replace(/\r\n/g, '\n')
}

export function fill(text, vals, what) {
  const out = text.replace(/\{\{([A-Z0-9_]+)\}\}/g, (_, k) => {
    if (typeof vals[k] !== 'string') fail(`template ${what}: no value for {{${k}}}`)
    return vals[k]
  })
  if (out.includes('{{')) fail(`template ${what}: a {{ is left after filling`)
  return out
}

const rootLit = p => `T.Path{"${p.drive}", [${p.segs.map(s => `"${s}"`).join(', ')}]}`
const oneLine = items => (items.length === 0 ? '[]' : `[${items.join(', ')}]`)

function ruleLit(r) {
  switch (r.kind) {
    case 'NoChange':
      return `T.NoChange{"${r.rel}"}`
    case 'NoReadOrChange':
      return `T.NoReadOrChange{"${r.rel}"}`
    case 'TreeDeleteOnlyUnder':
      return `T.TreeDeleteOnlyUnder{"${r.rel}"}`
    case 'NoForcePush':
      return 'T.NoForcePush{}'
    case 'NoPushTo':
      return `T.NoPushTo{"${r.branch}"}`
    case 'TrustScript':
      return `T.TrustScript{"${r.name}"}`
  }
  fail(`unknown rule kind ${r.kind}`)
}

const projLit = p => `T.Project{${rootLit(p)}, ${oneLine(p.rules.map(ruleLit))}}`

function projBlock(p) {
  if (p.rules.length === 0) return `    T.Project{${rootLit(p)}, []}`
  return `    T.Project{${rootLit(p)}, [\n${p.rules.map(r => '      ' + ruleLit(r)).join(',\n')}\n    ]}`
}

// <n>: lower case, runs outside a-z0-9 become one _, _ trimmed; x prefix
// when empty or starting with a digit.
export function lawStem(s) {
  let n = s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')
  if (n === '' || /^[0-9]/.test(n)) n = 'x' + n
  return n
}

// Templates per rule kind, with the law name pattern.
const LAW_KINDS = {
  NoChange: [['NoChange', r => `${lawStem(r.rel)}_protected`]],
  NoReadOrChange: [
    ['NoReadOrChange-change', r => `${lawStem(r.rel)}_protected`],
    ['NoReadOrChange-read', r => `${lawStem(r.rel)}_unreadable`],
  ],
  TreeDeleteOnlyUnder: [['TreeDeleteOnlyUnder', r => `tree_delete_only_${lawStem(r.rel)}`]],
  NoForcePush: [['NoForcePush', () => 'force_push_denied']],
  NoPushTo: [['NoPushTo', r => `push_${lawStem(r.branch)}_denied`]],
  TrustScript: [],
}

// The law text by name, from the generated LAWS.bend: the comment line above
// `law <name>:` (without "# ") and the law block itself.
export function lawTexts(lawsBend) {
  const lines = lawsBend.split('\n')
  const out = new Map()
  lines.forEach((l, i) => {
    const m = /^law ([A-Za-z0-9_]+):$/.exec(l)
    if (!m) return
    const above = i > 0 ? lines[i - 1] : ''
    let end = i
    while (end + 1 < lines.length && lines[end + 1].trim() !== '') end++
    out.set(m[1], { english: above.startsWith('# ') ? above.slice(2) : '', bend: lines.slice(i, end + 1).join('\n') })
  })
  return out
}

// ---------------------------------------------------------------------------
// The generator

export function generate({ draftDir, outDir, projectsDir = null }) {
  const draft = checkSort(readJson(path.join(draftDir, 'sort.json'), 'draft sort.json'), 'draft sort.json')
  checkAsk(readJson(path.join(draftDir, 'ask.json'), 'draft ask.json'), 'draft ask.json')
  draft.rules = tableRules(draft)

  // The table: approved projects (the draft replaces its own root) plus the
  // draft, sorted by root as Path.show prints it.
  const projects = [draft]
  const roots = new Set([draft.root])
  const slug = slugOf(draft.root)
  for (const p of projectsDir ? readLive(projectsDir) : []) {
    if (p.root === draft.root) continue
    if (slugOf(p.root) === slug) {
      fail(`the draft's root ${draft.root} has the same draft name (${slug}) as the approved project ${p.root}; bend-guard cannot keep both`)
    }
    if (roots.has(p.root)) fail(`approved projects: root ${p.root} appears twice`)
    roots.add(p.root)
    p.rules = tableRules(p)
    projects.push(p)
  }
  projects.sort((a, b) => (a.show < b.show ? -1 : a.show > b.show ? 1 : 0))
  const at = projects.indexOf(draft)
  const PRE = oneLine(projects.slice(0, at).map(projLit))
  const POST = oneLine(projects.slice(at + 1).map(projLit))
  const ROOT = rootLit(draft)
  const ROOT_SHOW = draft.show

  // One law (and proof) per template, in rule order, then reads_allowed.
  const taken = new Set(['reads_allowed'])
  const unique = n => {
    let name = n
    for (let k = 2; taken.has(name); k++) name = `${n}_${k}`
    taken.add(name)
    return name
  }
  const lawSnips = []
  const proofSnips = []
  const lawsByLine = new Map()
  draft.rules.forEach((r, i) => {
    for (const [tpl, nameOf] of LAW_KINDS[r.kind]) {
      const LAW = unique(nameOf(r))
      const vals = {
        ROOT,
        ROOT_SHOW,
        LINE: String(r.line),
        LAW,
        PRE,
        POST,
        RS1: oneLine(draft.rules.slice(0, i).map(ruleLit)),
        RS2: oneLine(draft.rules.slice(i + 1).map(ruleLit)),
      }
      if ('rel' in r) vals.REL = r.rel
      if ('branch' in r) vals.BRANCH = r.branch
      lawSnips.push(fill(readTemplate(`law/${tpl}.bend`), vals, `law/${tpl}.bend`).replace(/\n+$/, ''))
      proofSnips.push(fill(readTemplate(`proof/${tpl}.bend`), vals, `proof/${tpl}.bend`).replace(/\n+$/, ''))
      if (!lawsByLine.has(r.line)) lawsByLine.set(r.line, [])
      lawsByLine.get(r.line).push(LAW)
    }
  })
  lawSnips.push(fill(readTemplate('law/reads_allowed.bend'), { ROOT, ROOT_SHOW }, 'law/reads_allowed.bend').replace(/\n+$/, ''))
  proofSnips.push(fill(readTemplate('proof/reads_allowed.bend'), { ROOT, ROOT_SHOW }, 'proof/reads_allowed.bend').replace(/\n+$/, ''))

  const files = {
    'Rules.bend': fill(readTemplate('Rules.bend'), { PROJECTS: projects.map(projBlock).join(',\n') }, 'Rules.bend'),
    'Policy.bend': fill(readTemplate('Policy.bend'), {}, 'Policy.bend'),
    'LAWS.bend': fill(readTemplate('LAWS.bend'), { ROOT_SHOW, LAWS: lawSnips.join('\n\n') }, 'LAWS.bend'),
    'PROOF.bend': fill(readTemplate('PROOF.bend'), { PROOFS: proofSnips.join('\n\n') }, 'PROOF.bend'),
  }

  // display.json: per BEND_RULES.md line, its laws as LAWS.bend states them.
  const texts = lawTexts(files['LAWS.bend'])
  const lawOf = name => {
    const t = texts.get(name)
    if (!t) fail(`generated LAWS.bend has no law ${name}`)
    return { name, english: t.english, bend: t.bend }
  }
  const display = {
    root: draft.root,
    lines: draft.lines.map(l => ({
      line: l.line,
      text: l.text,
      kind: l.kind,
      reason: l.reason,
      ...(l.suggestion !== undefined ? { suggestion: l.suggestion } : {}),
      laws: (lawsByLine.get(l.line) || []).map(lawOf),
    })),
    projectLaws: [lawOf('reads_allowed')],
    note: 'Project rules are not enforced in log-only mode.',
  }
  const probes = buildProbes(draft.root, draft.rules)

  // Write: <outDir>\project holds exactly the four generated .bend files.
  const projDir = path.join(outDir, 'project')
  fs.mkdirSync(projDir, { recursive: true })
  for (const f of fs.readdirSync(projDir)) if (f.endsWith('.bend')) fs.rmSync(path.join(projDir, f))
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(projDir, name), text, 'utf8')
  fs.writeFileSync(path.join(outDir, 'display.json'), JSON.stringify(display, null, 2) + '\n', 'utf8')
  fs.writeFileSync(path.join(outDir, 'probes.json'), JSON.stringify(probes, null, 2) + '\n', 'utf8')

  return { root: draft.root, projects: projects.map(p => p.root), laws: [...texts.keys()], probes: probes.length }
}

// ---------------------------------------------------------------------------
// Command line

function main(argv) {
  const pos = []
  let projectsDir = null
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--projects') {
      if (i + 1 >= argv.length) fail('--projects needs a folder')
      projectsDir = argv[++i]
    } else if (argv[i].startsWith('--')) {
      fail(`unknown option ${argv[i]}`)
    } else {
      pos.push(argv[i])
    }
  }
  if (pos.length !== 2) fail('usage: node gen.mjs <draftDir> <outDir> [--projects <liveProjectsDir>]')
  const r = generate({ draftDir: pos[0], outDir: pos[1], projectsDir })
  console.log(`gen: ${r.root}: ${r.laws.length} laws, ${r.probes} probes, table of ${r.projects.length} project(s); wrote ${path.resolve(pos[1])}`)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2))
  } catch (err) {
    console.error(`gen: ${err instanceof GenError ? err.message : 'failed: ' + String(err && err.message ? err.message : err).slice(0, 300)}`)
    process.exit(1)
  }
}
