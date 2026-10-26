// bend-guard: the mod's own Clef client (hooks/clef.ts) for the terminal
// tools (doctor.mjs --clef, clef-bench.mjs). It is imported, not copied, so a
// tool asks Clef with the very same questions, request body, timeout, status
// handling and answer parsing as the mod.
//
// The key is read here, in this process, from <home>\.claude\bend-guard\
// openrouter.key. It only ever goes into the Authorization header of the
// request; it is never printed, logged, returned in a result or put on a
// command line.

import fs from 'node:fs'
import path from 'node:path'
import { registerHooks } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { PLUGIN_DIR, keyFile } from './home.mjs'

const CLEF_TS = path.join(PLUGIN_DIR, 'hooks', 'clef.ts')

// hooks/*.ts import each other without a file extension ("./glue"), as the
// mod's bundler allows. Node needs the ".ts": this resolve hook adds it for a
// relative import from a .ts file under hooks\ only.
let hooked = false
function allowHookImports() {
  if (hooked) return
  if (typeof registerHooks !== 'function') throw new Error('this needs Node 22.15 or newer (module.registerHooks)')
  const hooksDir = path.join(PLUGIN_DIR, 'hooks').toLowerCase()
  registerHooks({
    resolve(spec, ctx, next) {
      const parent = ctx.parentURL
      if (parent && parent.startsWith('file:') && /^\.\.?\//.test(spec) && !/\.[cm]?[jt]sx?$/.test(spec)) {
        const parentFile = fileURLToPath(parent)
        if (/\.ts$/.test(parentFile) && path.dirname(parentFile).toLowerCase() === hooksDir) {
          const u = new URL(spec + '.ts', parent)
          if (fs.existsSync(fileURLToPath(u))) return next(u.href, ctx)
        }
      }
      return next(spec, ctx)
    },
  })
  hooked = true
}

// The hooks/clef.ts module: { CLEF_URL, CLEF_MODEL, CLEF_TIMEOUT_MS,
// QUESTIONS_VERSION, questionsV2, clefRequest, toClefAnswer, askClef, ... }.
export async function loadClef() {
  allowHookImports()
  return import(pathToFileURL(CLEF_TS).href)
}

// The key, trimmed, or null when the file is missing, empty or not a plain
// small file. Never throws, never prints.
export function readKey(file = keyFile()) {
  try {
    const st = fs.lstatSync(file)
    if (!st.isFile() || st.size === 0 || st.size > 4096) return null
    const k = fs.readFileSync(file, 'utf8').trim()
    return k ? k : null
  } catch {
    return null
  }
}

// The `$` askClef needs, over node's fetch: $.http.fetch(url, init) resolves
// { status, text }, $.clock.after(ms, f) returns { cancel }. onBody(text) sees
// each response body (for usage.cost). hardLimitMs aborts a request that
// outlives askClef's own timeout, so a run never hangs.
export function nodeDollar({ fetchImpl = globalThis.fetch, onBody, hardLimitMs = 15000 } = {}) {
  return {
    http: {
      async fetch(url, init) {
        const ac = new AbortController()
        const t = setTimeout(() => ac.abort(), hardLimitMs)
        try {
          const res = await fetchImpl(url, { ...init, signal: ac.signal })
          const text = await res.text()
          if (onBody) onBody(text)
          return { status: res.status, text }
        } finally {
          clearTimeout(t)
        }
      },
    },
    clock: {
      after(ms, f) {
        const t = setTimeout(f, ms)
        return { cancel: () => clearTimeout(t) }
      },
    },
  }
}

// usage.cost of a Decisions API reply (dollars), or null.
export function costOf(text) {
  try {
    const c = JSON.parse(text)?.usage?.cost
    return typeof c === 'number' && Number.isFinite(c) && c >= 0 ? c : null
  } catch {
    return null
  }
}
