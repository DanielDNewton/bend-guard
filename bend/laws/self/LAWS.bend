# bend-guard: self-protection laws (plan Task 2.4). Proven in PROOF.bend
# beside this file. The meaning m is free (Known or Unknown), and there is no
# log-only or "the user said yes" hypothesis: these hold in every mode.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ../../core/Path.bend as Path
import ../../core/Meaning.bend as Meaning
import ../../core/Call.bend as Call
import ../../core/Protect.bend as Protect
import ../../core/Guard.bend as Guard

# A call that changes a protected path counts as a self-protection hit.
law changes_hits:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +p: T.Path
  for h1: {Meaning.changes(m, p) == True{} : Bool}
  for +h2: {Protect.covers(table, x, p) == True{} : Bool}
  {Guard.self_hit(table, x, m) == True{} : Bool}

# A call that reads the OpenRouter key file counts as a self-protection hit.
law key_hits:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for h: {Meaning.reads(m, Protect.key_file(Call.Ctx.home(x))) == True{} : Bool}
  {Guard.self_hit(table, x, m) == True{} : Bool}

# Any call that changes bend-guard's own files, rules, key or Claude Code's settings is denied, even in log-only mode and even if the user said yes.
law self_protection:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for +p: T.Path
  for h1: {Meaning.changes(m, p) == True{} : Bool}
  for +h2: {Protect.covers(table, x, p) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}

# Any call that reads the OpenRouter key file is denied, even in log-only mode and even if the user said yes.
law key_unreadable:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for h: {Meaning.reads(m, Protect.key_file(Call.Ctx.home(x))) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}

# A call that writes a file protected by name (some folder's .claude/settings.json, .claude/settings.local.json, .mcp.json or a hook script in .claude/hooks, or any repository's git hooks or git config) is denied, in any folder, even in log-only mode and even if the user said yes.
law named_settings_denied:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +q: T.Path
  for +as2: List<&2, T.Action>
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Write{q} <> as2) : List<&2, T.Action>}
  for h2: {Protect.named(q) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}

# A call that writes any repository's git hooks or git config (.git/hooks, .git/config, config.worktree, commondir, gitdir, also of submodules, worktrees and bare repositories), any .git file or folder by name, or a HEAD outside a git folder (final review ENV-F2) is denied, in any folder, even in log-only mode and even if the user said yes.
law git_hooks_denied:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +m: T.Meaning
  for +t: String
  for +a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +q: T.Path
  for +as2: List<&2, T.Action>
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Write{q} <> as2) : List<&2, T.Action>}
  for h2: {Protect.named.git(q) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}
