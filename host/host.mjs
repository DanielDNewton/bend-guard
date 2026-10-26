// bend-guard: the checker host. Runs as a child of the hooks module, once per
// check. hooks/checker.ts holds a byte-for-byte copy of this file (HOST_SOURCE)
// and runs it with $.process.run(['node.exe', '--input-type=module', '-e',
// HOST_SOURCE], { stdin }), so no file is read at check time. Change this file,
// then copy it into HOST_SOURCE; a tools test compares the two.
//
// stdin:  { "policy": "<policy.mjs text>", "ops": [ { "op", "call", "answer"? }, ... ] }
// stdout: one JSON line, { "ok": true, "results": [...] } or { "ok": false, "error": "..." }
//
// The policy is imported from a data: URL made from the text the glue hashed
// and checked, so this file never reads a path and never uses the network.
// It converts nothing beyond what Bend returns. Always exits 0.
//
// Brief: docs\build-brief.md of the bend2_test project, "Checker host protocol".

// The entry's export keys. If Bend spells them differently, the foundation
// agent records the real keys in bend\NOTES.md: change them here.
const KEYS = {
  decide: 'Policy.decide',
  run: 'Policy.run',
  meaning: 'Policy.meaning',
  next_cwds: 'Policy.next_cwds',
  paths: 'Policy.paths',
}

let answered = false
function reply(obj) {
  if (answered) return
  answered = true
  let line
  try {
    line = JSON.stringify(obj)
  } catch (err) {
    line = JSON.stringify({ ok: false, error: 'result is not JSON: ' + short(err) })
  }
  process.stdout.write(line + '\n')
  process.exitCode = 0
}

function short(err) {
  const s = err && typeof err === 'object' && 'message' in err ? String(err.message) : String(err)
  return s.length > 300 ? s.slice(0, 300) + '...' : s
}

function fail(msg) {
  reply({ ok: false, error: msg })
}

process.on('uncaughtException', err => fail('uncaught: ' + short(err)))
process.on('unhandledRejection', err => fail('unhandled: ' + short(err)))

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : chunk)
  return Buffer.concat(chunks).toString('utf8')
}

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
}

async function main() {
  let req
  try {
    req = JSON.parse(await readStdin())
  } catch (err) {
    return fail('bad request: ' + short(err))
  }
  if (!isObject(req) || typeof req.policy !== 'string' || !Array.isArray(req.ops)) {
    return fail('bad request: want { policy: string, ops: [] }')
  }

  let mod
  try {
    const url = 'data:text/javascript;base64,' + Buffer.from(req.policy, 'utf8').toString('base64')
    mod = await import(url)
  } catch (err) {
    return fail('policy did not load: ' + short(err))
  }
  const api = mod && mod.default
  if (!isObject(api)) return fail('policy has no default export object')
  for (const k of Object.values(KEYS)) {
    if (typeof api[k] !== 'function') return fail('policy lacks export ' + k)
  }

  const results = []
  for (let i = 0; i < req.ops.length; i++) {
    const o = req.ops[i]
    if (!isObject(o) || typeof o.op !== 'string' || !Object.prototype.hasOwnProperty.call(KEYS, o.op)) {
      return fail('op ' + i + ': unknown op')
    }
    if (!isObject(o.call)) return fail('op ' + i + ': call is not an object')
    const f = api[KEYS[o.op]]
    try {
      if (o.op === 'run') {
        if (!isObject(o.answer)) return fail('op ' + i + ': run needs an answer')
        results.push(f(o.call, o.answer))
      } else {
        results.push(f(o.call))
      }
    } catch (err) {
      return fail('op ' + i + ' (' + o.op + ') threw: ' + short(err))
    }
  }
  reply({ ok: true, results })
}

main().catch(err => fail('host: ' + short(err)))
