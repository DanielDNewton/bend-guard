# bend-guard: generic laws for project rules (plan Task 2.5, design.md
# component 4). Each law holds for every rule table: a rule of one kind, in
# any project, anywhere in the table (pre ++ [Project{root, rs1 ++ [rule] ++
# rs2}] ++ post), refuses the calls it is about. Project laws (templates/,
# made per project by tools/gen.mjs) are one-line instances of these.
# Proven in PROOF.bend.
#
# Rules are not enforced in log-only mode (D8), so every Deny law assumes
# Call.Ctx.log_only(x) is False. The meaning m is free: the laws hold for
# whatever the translator says the call does (for Unknown meanings, for the
# parts that were understood). An action "in m" is stated as
# Meaning.actions(m) == as1 ++ [action] ++ as2.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ../../core/Path.bend as Path
import ../../core/Meaning.bend as Meaning
import ../../core/Call.bend as Call
import ../../core/Protect.bend as Protect
import ../../core/Guard.bend as Guard

# NoChange{rel}: outside log-only mode, a call that changes anything under root/rel is denied.
law rule_nochange_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +rel: String
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +p: T.Path
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.changes(m, p) == True{} : Bool}
  for h2: {Path.under(p, Path.child(root, rel)) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.NoChange{rel} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# NoReadOrChange{rel}: outside log-only mode, a call that changes anything under root/rel is denied.
law rule_noread_change_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +rel: String
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +p: T.Path
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.changes(m, p) == True{} : Bool}
  for h2: {Path.under(p, Path.child(root, rel)) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.NoReadOrChange{rel} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# NoReadOrChange{rel}: outside log-only mode, a call that reads a file under root/rel (a Read action) is denied.
law rule_noread_read_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +rel: String
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +q: T.Path
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Read{q} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(q, Path.child(root, rel)) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.NoReadOrChange{rel} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# TreeDeleteOnlyUnder{rel}: outside log-only mode, a recursive delete of a folder inside the project (or containing it) that is not under root/rel is denied.
law rule_tree_delete_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +rel: String
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +q: T.Path
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.DeleteTree{q} <> as2) : List<&2, T.Action>}
  for h2: {Path.overlaps(q, root) == True{} : Bool}
  for h3: {Path.under(q, Path.child(root, rel)) == False{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.TreeDeleteOnlyUnder{rel} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# NoForcePush: outside log-only mode, a forced git push run in a folder inside the project is denied.
law rule_force_push_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +dir: T.Path
  for +all: Bool
  for +refs: List<&2, String>
  for +unsure: Bool
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, True{}, all, refs, unsure} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(dir, root) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.NoForcePush{} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# NoPushTo{b}: outside log-only mode, a git push that names branch b, run in a folder inside the project, is denied.
law rule_push_to_denies:
  for pre: List<&2, T.Project>
  for post: List<&2, T.Project>
  for +root: T.Path
  for rs1: List<&2, T.Rule>
  for rs2: List<&2, T.Rule>
  for +b: String
  for +x: T.Ctx
  for +m: T.Meaning
  for t: String
  for a: T.ClefAnswer
  for +as1: List<&2, T.Action>
  for +dir: T.Path
  for +force: Bool
  for +all: Bool
  for +r1: List<&2, String>
  for +r2: List<&2, String>
  for +unsure: Bool
  for +as2: List<&2, T.Action>
  for h0: {Call.Ctx.log_only(x) == False{} : Bool}
  for h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2) : List<&2, T.Action>}
  for h2: {Path.under(dir, root) == True{} : Bool}
  {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, T.NoPushTo{b} <> rs2)} <> post), x, m, t, a)) == True{} : Bool}

# Any table: a plain read of a path that no rule names, that is not the key file, not behind a link and in no double-check zone, is allowed whatever Clef says (when both folders were read).
law read_allowed:
  for +table: List<&2, T.Project>
  for +x: T.Ctx
  for +t: String
  for +a: T.ClefAnswer
  for +p: T.Path
  for h0: {Path.is_sentinel(Call.Ctx.root(x)) == False{} : Bool}
  for h0b: {Path.is_sentinel(Call.Ctx.home(x)) == False{} : Bool}
  for h2: {Guard.in_rule_zone(table, p) == False{} : Bool}
  for h4: {Path.overlaps(p, Protect.key_file(Call.Ctx.home(x))) == False{} : Bool}
  for h6: {Guard.no_rule_names(table, p) == True{} : Bool}
  for h7: {Guard.no_link(x, p) == True{} : Bool}
  {Verdict.is_allow(Guard.run_m(table, x, T.Known{[T.Read{p}]}, t, a)) == True{} : Bool}
