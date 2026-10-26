// bend-guard: the ask and reminder hooks for rules 4, 8, 9 and 10. Plain
// TypeScript, not proven. They read the actions the Bend translator found
// (Policy.meaning), so they understand commands the same way the policy does.
// They can only add asks or reminders: a Deny from the policy always wins.
//
// Design: bend2_test\docs\design.md, component 10.
// Plan: bend2_test\docs\plan.md, Task 4.4; the brief
// (bend2_test\docs\build-brief.md, Q7) makes rules 9 and 10 a
// reminder added to the turn's text, since turn.complete cannot block.

import { type AskConfig, type BendAction, type BendMeaning, type TurnLedger, normPath } from './glue'

// Copied from darwin-guards (~\.claude\local-plugins\darwin-guards\
// hooks\rules.ts, askOutcome): a plugin cannot import another plugin's files.
// An ask reaches a person only on the main loop with a person as approver.
export function askOutcome(agentId: string | undefined, approver: string | undefined): 'ask' | 'deny' {
  return agentId === undefined && approver === 'person' ? 'ask' : 'deny'
}

export function newLedger(): TurnLedger {
  return { tick: 0, changedAt: null, passedAt: new Map() }
}

// ---------------------------------------------------------------------------
// Reading Bend values (walks only; checker.ts has already validated shapes).

function listOf<T>(l: unknown): T[] {
  const out: T[] = []
  let cur: any = l
  for (let n = 0; cur && cur.$ === 'Con' && n < 100000; n++) {
    out.push(cur.head as T)
    cur = cur.tail
  }
  return out
}

function actionsOf(m: BendMeaning): BendAction[] {
  if (!m || typeof m !== 'object') return []
  if (m.$ === 'Known') return listOf<BendAction>(m.actions)
  if (m.$ === 'Unknown') return listOf<BendAction>(m.known)
  return []
}

// A path segment is a String, or (brief Q5) a list of character codes.
function segText(s: unknown): string {
  if (typeof s === 'string') return s
  if (typeof s === 'number') return String(s)
  return listOf<number>(s)
    .map(c => String.fromCharCode(Number(c)))
    .join('')
}

// Path{drive, segs} as "c:/a/b" (the comparison form of glue.normPath).
function pathText(p: any): { drive: string; segs: string[] } | null {
  if (!p || p.$ !== 'Path' || typeof p.drive !== 'string' || p.drive === '?') return null
  return { drive: p.drive.toLowerCase(), segs: listOf<unknown>(p.segs).map(segText) }
}

// ---------------------------------------------------------------------------
// Rule 4: ask before a new top-level folder in the project root.

const MAKES = new Set(['MakeDir', 'Write', 'WriteTree'])

// A MakeDir, Write or WriteTree that creates a folder directly in `root`
// (normalised, as askEntry gives it) which does not exist yet gives the ask
// reason; otherwise null. `exists` takes a Windows path; a failing check
// counts as "missing", which asks (the stricter answer).
export async function askForRules(
  meaning: BendMeaning,
  root: string,
  exists: (p: string) => Promise<boolean>,
  cfg: AskConfig,
): Promise<string | null> {
  if (!cfg || cfg.newTopLevelDir !== true) return null
  const r = normPath(root)
  const rootSegs = r.replace(/^[a-z]:\/?/, '').split('/').filter(s => s.length > 0)
  const rootDrive = (r.match(/^([a-z]):/) ?? [])[1]
  if (!rootDrive) return null
  const seen = new Set<string>()
  for (const a of actionsOf(meaning)) {
    if (!MAKES.has(a.$)) continue
    const p = pathText((a as any).path)
    if (!p || p.drive !== rootDrive || p.segs.length <= rootSegs.length) continue
    if (!rootSegs.every((s, i) => p.segs[i]!.toLowerCase() === s)) continue
    const below = p.segs.length - rootSegs.length
    // A Write of a file straight in the root makes no folder.
    if (below === 1 && a.$ === 'Write') continue
    const first = p.segs[rootSegs.length]!
    if (seen.has(first)) continue
    seen.add(first)
    const win = `${rootDrive.toUpperCase()}:\\${[...rootSegs, first].join('\\')}`
    let there = false
    try {
      there = (await exists(win)) === true
    } catch {
      there = false
    }
    if (!there)
      return `bend-guard (rule 4): this makes a new top-level folder "${first}/" in ${r}, and BEND_RULES.md asks first. Approve if you want the folder.`
  }
  return null
}

// ---------------------------------------------------------------------------
// Rule 8: name the packages in the policy's npm install Ask.

export function npmInstallNote(meaning: BendMeaning): string | null {
  const installs = actionsOf(meaning).filter(a => a.$ === 'NpmInstall')
  if (installs.length === 0) return null
  const pkgs = [...new Set(installs.flatMap(a => listOf<unknown>((a as any).pkgs).map(String)))]
  return pkgs.length
    ? `Rule 8: installs ${pkgs.join(', ')}; also runs package.json install scripts.`
    : 'Rule 8: installs the packages in package.json and runs their install scripts.'
}

// ---------------------------------------------------------------------------
// Rules 9 and 10: the turn ledger.

const CHANGES = new Set(['Write', 'WriteTree', 'Delete', 'DeleteTree', 'MoveFrom', 'MakeDir'])

function normCommand(c: string): string {
  return String(c ?? '').trim().replace(/\s+/g, ' ')
}

// Notes one call that ran. A call whose meaning changes a file moves
// `changedAt`. A shell command that exits 0 records each of its `&&` parts
// as passed at this tick; a failing one clears them (a pass must be the
// latest run). `exitCode` undefined means the tool reported no outcome.
export function recordCall(l: TurnLedger, meaning: BendMeaning, command: string | undefined, exitCode: number | undefined): void {
  l.tick += 1
  if (actionsOf(meaning).some(a => CHANGES.has(a.$))) l.changedAt = l.tick
  if (typeof command !== 'string' || !command.trim() || exitCode === undefined) return
  const parts = command.split('&&').map(normCommand).filter(p => p.length > 0)
  for (const p of parts) {
    if (exitCode === 0) l.passedAt.set(p, l.tick)
    else l.passedAt.delete(p)
  }
}

// The reminder to add at the end of a main-loop turn, or null.
export function stopReason(l: TurnLedger, cfg: AskConfig): string | null {
  if (!l || l.changedAt === null || !cfg) return null
  const changedAt = l.changedAt
  const needed = [cfg.testBeforeDone, cfg.lintBeforeDone].filter((c): c is string => typeof c === 'string' && c.trim().length > 0)
  const missing = needed.filter(c => (l.passedAt.get(normCommand(c)) ?? -1) <= changedAt)
  if (missing.length === 0) return null
  const list = missing.map(c => '`' + normCommand(c) + '`').join(' and ')
  return `bend-guard (rules 9 and 10): files changed in this turn, and ${list} ${missing.length > 1 ? 'have' : 'has'} not passed since the last change. Run ${missing.length > 1 ? 'them' : 'it'} and show that ${missing.length > 1 ? 'they' : 'it'} passed before calling the work done.`
}
