// bend-guard: run the WSL build scripts (stage.sh, prove.sh, check.sh, compile.sh) from
// Windows node, always as argv arrays, never as a shell string.
// Facts: docs/build-brief.md "Toolchain"; Bend notes: bend/NOTES.md.
//
// wsl.exe runs the words after `--` through the distro's default shell, which
// expands `$x` and drops backslashes. `--exec` runs the program directly, so
// every argument arrives as given.

import path from 'node:path'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'

export const DISTRO = 'Ubuntu-24.04'

// <Windows folder>\System32\wsl.exe, from %SystemRoot% (or %windir%), never a
// PATH lookup. Without either it is null, and every WSL step fails (execFile
// refuses a null program) instead of running some other wsl.exe.
export function wslExe(env = process.env) {
  const win = env.SystemRoot || env.SYSTEMROOT || env.windir || env.WINDIR
  return typeof win === 'string' && /^[A-Za-z]:[\\/]/.test(win) ? path.win32.join(win, 'System32', 'wsl.exe') : null
}
export const WSL_EXE = wslExe()

// C:\x\y -> /mnt/c/x/y. A path that is already POSIX is returned unchanged.
export function toWslPath(winPath) {
  const p = String(winPath)
  const m = /^([A-Za-z]):[\\/]?(.*)$/.exec(p)
  if (!m) return p.replace(/\\/g, '/')
  const rest = m[2].replace(/\\/g, '/').replace(/\/+$/, '')
  return `/mnt/${m[1].toLowerCase()}${rest ? '/' + rest : ''}`
}

function run(argv, timeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(
      WSL_EXE,
      argv,
      { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, encoding: 'utf8', windowsHide: true },
      (err, stdout, stderr) => {
        if (err && typeof err.code === 'string') return reject(err) // could not start
        const timedOut = Boolean(err && err.killed)
        const code = err ? (typeof err.code === 'number' ? err.code : -1) : 0
        resolve({ code, stdout: String(stdout), stderr: String(stderr), timedOut })
      },
    )
  })
}

// Runs `bash -l <script> ...args` as root in DISTRO. Resolves
// { code, stdout, stderr, timedOut }; code is -1 when killed at timeoutMs.
// Rejects only when wsl.exe cannot start.
export function runWsl(scriptWinPath, args = [], { timeoutMs = 600000 } = {}) {
  const argv = ['-d', DISTRO, '-u', 'root', '--exec', 'bash', '-l', toWslPath(scriptWinPath), ...args.map(String)]
  return run(argv, timeoutMs)
}

// The "sha256 <hex>" line compile.sh prints right after bend writes the
// policy, or null.
export function compiledSha(stdout) {
  const m = /^sha256 ([0-9a-f]{64})\r?$/m.exec(String(stdout))
  return m ? m[1] : null
}

// The compiled bytes about to be probed and fingerprinted must be the ones
// bend wrote (said = compiledSha of compile.sh's output).
export function compiledMatches(buf, said) {
  if (!Buffer.isBuffer(buf) || buf.length === 0) return { ok: false, why: 'the compiled policy.mjs is empty' }
  if (typeof said !== 'string' || !/^[0-9a-f]{64}$/.test(said)) return { ok: false, why: 'compile.sh did not report the sha256 of the compiled policy' }
  const got = createHash('sha256').update(buf).digest('hex')
  if (got !== said) return { ok: false, why: `the compiled policy.mjs changed after bend wrote it (sha256 ${got}, but compile.sh reported ${said}), so it is not approved` }
  return { ok: true }
}

// sha256 (lower-case hex) of the `bend` binary on the login PATH inside WSL.
export async function bendSha256({ timeoutMs = 60000 } = {}) {
  const r = await run(['-d', DISTRO, '-u', 'root', '--exec', 'bash', '-lc', 'sha256sum "$(command -v bend)"'], timeoutMs)
  const m = /^([0-9a-f]{64})\s/.exec(r.stdout)
  if (r.code !== 0 || !m) throw new Error(`bendSha256: could not hash bend (${(r.stderr || r.stdout).trim().slice(0, 200)})`)
  return m[1]
}
