// bend-guard: where things live on this PC. Every path comes from the home
// folder (os.homedir(), which on Windows is %USERPROFILE%) or from this
// plugin's own location, so the tools work for any user. The mod
// (hooks/register.tsx) uses the same layout:
//
//   <home>\.claude\bend-guard                  the state folder (S)
//   <home>\.claude\bend-guard-drafts           the drafts folder (D)
//   <home>\.claude\local-plugins\bend-guard    the plugin itself
//
// Supported: Windows, home folder on drive C:, the plugin at the place above.

import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// This plugin's folder (the parent of tools\).
export const PLUGIN_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

export const homeDir = () => os.homedir()
export const stateDir = (home = homeDir()) => path.join(home, '.claude', 'bend-guard')
export const draftsDir = (home = homeDir()) => path.join(home, '.claude', 'bend-guard-drafts')
export const expectedPluginDir = (home = homeDir()) => path.join(home, '.claude', 'local-plugins', 'bend-guard')
export const keyFile = (home = homeDir()) => path.join(stateDir(home), 'openrouter.key')

// C:\Users\a\b -> C:/Users/a/b
export const fwd = p => String(p).replace(/\\/g, '/')

const same = (a, b) => path.resolve(a).replace(/[\\/]+$/, '').toLowerCase() === path.resolve(b).replace(/[\\/]+$/, '').toLowerCase()

// Plain-English problems with the layout, [] when it is the supported one.
export function layoutProblems({ home = homeDir(), plugin = PLUGIN_DIR } = {}) {
  const out = []
  if (!home || !/^[A-Za-z]:[\\/]/.test(home)) out.push(`the home folder "${home}" is not a full Windows path`)
  else if (!/^[Cc]:/.test(home)) out.push(`the home folder ${home} is not on drive C:, which bend-guard needs`)
  if (!same(plugin, expectedPluginDir(home))) out.push(`the plugin is at ${plugin}, but bend-guard needs it at ${expectedPluginDir(home)}`)
  return out
}
