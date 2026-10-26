// bend-guard tests: run every case in tests/corpus/*.jsonl through the
// compiled policy (tests/.build/policy.mjs; build it with
// node tests/lib/build.mjs).
//
//   node --test tests/corpus.node.test.mjs
//   node --test --test-name-pattern=redteam tests/corpus.node.test.mjs
//
// One JSON object per line:
//   { "name": "...", "tool": "Bash", "args": { "command": "rm -rf specs" },
//     "opts": { "agent": true, "logOnly": true, "cwds": [...], "stage": { "asked": true } },
//     "answer": { "risky": 900, "unsure": 0 },        (optional; default NoAnswer)
//     "expect": "allow" | "ask" | "deny",
//     "meaning": "DeleteTree c:/users/user/bend2_test/specs",   (optional substring)
//     "nextCwds": ["c:/users/user/bend2_test/src", ...],        (optional; the folders after the text, exactly)
//     "reason": "may not be read or changed.",                  (optional substring of the verdict's reason)
//     "why": "the spec line that sets the expectation" }
// Lines starting with // and blank lines are skipped.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { load, call, run, meaning, nextCwds, showMeaning, verdictOf, answer, NO_ANSWER } from './lib/policy.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DIR = path.join(HERE, 'corpus')
const P = await load()

const files = fs.existsSync(DIR) ? fs.readdirSync(DIR).filter(f => f.endsWith('.jsonl')).sort() : []
for (const file of files) {
  const lines = fs.readFileSync(path.join(DIR, file), 'utf8').split(/\r?\n/)
  lines.forEach((line, i) => {
    const t = line.trim()
    if (!t || t.startsWith('//')) return
    let c
    try {
      c = JSON.parse(t)
    } catch (err) {
      test(`${file}:${i + 1} parses`, () => assert.fail(`bad JSON: ${err.message}`))
      return
    }
    test(`${file.replace(/\.jsonl$/, '')}: ${c.name ?? `line ${i + 1}`}`, () => {
      const bc = call(c.tool, c.args ?? {}, c.opts ?? {})
      const a = c.answer ? answer(c.answer.risky ?? 0, c.answer.unsure ?? 0) : NO_ANSWER
      const v = run(P, bc, a)
      const m = showMeaning(meaning(P, bc))
      const got = verdictOf(v)
      assert.equal(got, c.expect, `${c.tool} ${JSON.stringify(c.args)} ${JSON.stringify(c.opts ?? {})}: expected ${c.expect}, got ${got}\n  reason: ${v.reason ?? ''}\n  meaning: ${m}\n  why: ${c.why ?? ''}`)
      if (c.reason) assert.ok(String(v.reason ?? '').includes(c.reason), `reason ${v.reason ?? ''} does not include ${c.reason}`)
      if (c.meaning) assert.ok(m.toLowerCase().includes(String(c.meaning).toLowerCase()), `meaning ${m} does not include ${c.meaning}`)
      if (c.nextCwds) assert.deepEqual(nextCwds(P, bc), c.nextCwds, `next folders of ${JSON.stringify(c.args)}`)
    })
  })
}
