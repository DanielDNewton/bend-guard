// bend-guard: the Clef client. Builds the typed questions, sends one POST to
// OpenRouter's Decisions API through $.http.fetch, turns the probabilities
// into per-thousand numbers for Bend, and caches answers for the session.
// It never throws: every failure is NoAnswer{} plus a status for the log.
// The key is only put in the Authorization header; it is never logged,
// returned or passed to the host.
//
// Design: bend2_test\docs\design.md, component 9.
// Brief: bend2_test\docs\build-brief.md, Q3 and Q6.

import { type BendClefAnswer, NO_ANSWER, cacheKey, redact } from './glue'
import { sha256Hex } from './sha256'

export const CLEF_URL = 'https://openrouter.ai/api/alpha/decisions'
export const CLEF_MODEL = 'cloudflare/clef-flash'
export const CLEF_TIMEOUT_MS = 3000
// v2: the danger question also names Claude Code's and bend-guard's own
// settings, shell profiles, startup files and git hooks.
export const QUESTIONS_VERSION = 'v2'
// Clef calls sent per session at most; past it every Consult is NoAnswer.
export const CLEF_SESSION_CAP = 200

export type ClefQuestion = { type: 'noul'; instructions: string } | { type: 'choice'; instructions: string; criteria: Record<string, string> }
export type ClefStatus = 'cache' | 'nokey' | 'capped' | 'ok' | 'timeout' | `http-${number}` | 'badshape' | 'error'

// "a", "a or b", "a, b or c"
function orList(xs: readonly string[]): string {
  if (xs.length <= 1) return xs.join('')
  return xs.slice(0, -1).join(', ') + ' or ' + xs[xs.length - 1]
}

// The questions (version QUESTIONS_VERSION). `zones` are the project's protected names as the rules
// give them (for example "specs/", "secrets/", ".env"), so the wording
// follows each project's rules.
export function questionsV2(zones: readonly string[]): Record<string, ClefQuestion> {
  const names = [...new Set(zones.map(z => String(z).trim()).filter(z => z.length > 0))]
  const files = names.length ? `any file under ${orList(names)}` : 'any protected or secret file'
  const where = `${files}, Claude Code's or bend-guard's own settings (anything under .claude), a shell profile or startup file (.bashrc, .profile, a PowerShell profile), or git hooks or git config`
  return {
    danger: {
      type: 'noul',
      instructions: `Would running this command change, delete, move or reveal ${where}, or push to main or with force?`,
    },
    kind: {
      type: 'choice',
      instructions: 'What does this command do?',
      criteria: {
        readonly: 'Only reads or lists files, or prints information; changes nothing.',
        changes_project: 'Creates, edits, moves or deletes ordinary project files only.',
        changes_protected: `Creates, edits, moves, deletes or reveals ${where}, or pushes to main or with force.`,
        runs_other_code: 'Runs a script, package, installer or other program whose effects are not visible in the command.',
        unclear: 'Cannot tell from the command what it does.',
      },
    },
  }
}

// The cache's question version: the wording depends on the zones too.
function questionsKey(zones: readonly string[]): string {
  return QUESTIONS_VERSION + '|' + zones.join('|')
}

export function clefRequest(step: { text: string }, model: string, zones: readonly string[]): { model: string; state: string; questions: Record<string, ClefQuestion> } {
  return { model, state: redact(String(step?.text ?? '')), questions: questionsV2(zones) }
}

function prob(x: unknown): number | null {
  return typeof x === 'number' && Number.isFinite(x) && x >= 0 && x <= 1 ? x : null
}

// risky = round(1000 * P(danger yes)), unsure = round(1000 * P(kind unclear));
// anything missing, NaN or outside 0..1 gives NoAnswer.
export function toClefAnswer(resp: unknown): BendClefAnswer {
  try {
    let r: any = resp
    if (typeof r === 'string') r = JSON.parse(r)
    const a = r?.answers
    const danger = prob(a?.danger?.noul)
    const unclear = prob(a?.kind?.probabilities?.unclear)
    if (danger === null || unclear === null) return NO_ANSWER
    return { $: 'Answer', risky: Math.round(1000 * danger), unsure: Math.round(1000 * unclear) }
  } catch {
    return NO_ANSWER
  }
}

// `budget`: the session's count of Clef calls sent and its cap. A cached answer
// costs nothing; past the cap nothing is sent and the answer is NoAnswer.
export type ClefBudget = { sent: number; cap: number }
export type ClefOpts = { key: string | undefined; model: string; timeoutMs: number; zones: readonly string[]; budget?: ClefBudget }

// One try, no retry. Only 'ok' answers are cached.
export async function askClef(
  $: any,
  step: { text: string },
  opts: ClefOpts,
  cache: Map<string, BendClefAnswer>,
): Promise<{ answer: BendClefAnswer; status: ClefStatus }> {
  let timer: { cancel(): void } | undefined
  try {
    const zones = Array.isArray(opts?.zones) ? opts.zones : []
    const model = typeof opts?.model === 'string' && opts.model ? opts.model : CLEF_MODEL
    const body = clefRequest(step, model, zones)
    // Keyed by the unmasked text (its hash, so no secret is kept as a key):
    // two commands that differ only in a masked part never share an answer
    // (review R1-07). Clef is still sent only the masked text.
    const ck = cacheKey(model, questionsKey(zones), 'sha256:' + (await sha256Hex(String(step?.text ?? ''))))
    const hit = cache.get(ck)
    if (hit) return { answer: hit, status: 'cache' }
    const key = typeof opts?.key === 'string' ? opts.key.trim() : ''
    if (!key) return { answer: NO_ANSWER, status: 'nokey' }
    const budget = opts.budget
    if (budget) {
      if (!(budget.sent < budget.cap)) return { answer: NO_ANSWER, status: 'capped' }
      budget.sent += 1
    }

    const ms = typeof opts.timeoutMs === 'number' && opts.timeoutMs > 0 ? opts.timeoutMs : CLEF_TIMEOUT_MS
    const timedOut = new Promise<'timeout'>(resolve => {
      timer = $.clock.after(ms, () => resolve('timeout'))
    })
    const request: Promise<any> = $.http.fetch(CLEF_URL, {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    request.catch(() => {}) // a late rejection after the timeout is not an error
    const res = await Promise.race([request, timedOut])
    if (res === 'timeout') return { answer: NO_ANSWER, status: 'timeout' }
    const status = Number(res?.status)
    if (status !== 200) return { answer: NO_ANSWER, status: `http-${Number.isFinite(status) ? status : 0}` }
    const answer = toClefAnswer(String(res?.text ?? ''))
    if (answer.$ !== 'Answer') return { answer: NO_ANSWER, status: 'badshape' }
    cache.set(ck, answer)
    return { answer, status: 'ok' }
  } catch {
    return { answer: NO_ANSWER, status: 'error' }
  } finally {
    try {
      timer?.cancel()
    } catch {
      // nothing to do
    }
  }
}
