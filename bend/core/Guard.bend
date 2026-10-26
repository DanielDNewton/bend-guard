# bend-guard: the generic policy (design.md components 3 and 4, plan Task 2.1).
# Guard.decide_m picks the step for a call (Done, or Consult Clef), and
# Guard.run_m gives the final verdict for a meaning m and Clef's answer.
# Guard never imports a Model file: every law is stated with the meaning m
# free (plan Phase 2). The shape is chosen so the laws are short case splits;
# bend/NOTES.md "Guard proof map" says which function each law unfolds.
#
#   run_m = protect(self_hit, relax(relax.cond, finish(x, floor(after_clef(decide.go(self_hit, ...), a), m))))
#
# Every reason starts with "bend-guard" and says what to do next.

import Base
import ./Types.bend as T
import ./Verdict.bend as Verdict
import ./Path.bend as Path
import ./Meaning.bend as Meaning
import ./Call.bend as Call
import ./Protect.bend as Protect

# ---------------------------------------------------------------------------
# Clef thresholds, per thousand (build brief Q6; starting values, not tuned)

def T_TRIAGE() -> U32:
  800

def T_VETO() -> U32:
  500

def T_UNSURE() -> U32:
  300

# ---------------------------------------------------------------------------
# Small builders

def deny_if(b: Bool, r: String) -> T.Verdict:
  match b:
    case True{}:
      T.Deny{r}
    case False{}:
      T.Allow{}

def ask_if(b: Bool, r: String) -> T.Verdict:
  match b:
    case True{}:
      T.Ask{r}
    case False{}:
      T.Allow{}

def ask_unless(b: Bool, r: String) -> T.Verdict:
  match b:
    case True{}:
      T.Allow{}
    case False{}:
      T.Ask{r}

def pick(c: Bool, s: String, rest: String) -> String:
  match c:
    case True{}:
      s
    case False{}:
      rest

# Who can be asked: Call.Ctx.can_ask (build brief Q9).
def can_ask(x: T.Ctx) -> Bool:
  Call.Ctx.can_ask(x)

# The project or home folder could not be read.
def bad(+x: T.Ctx) -> Bool:
  Bool.or(Path.is_sentinel(Call.Ctx.root(x)), Path.is_sentinel(Call.Ctx.home(x)))

# The path an action names, if any.
def act.path(a: T.Action) -> Maybe<&2, T.Path>:
  match a:
    case T.Read{q}:
      Some{q}
    case T.ReadTree{q}:
      Some{q}
    case T.ListDir{q}:
      Some{q}
    case T.Write{q}:
      Some{q}
    case T.WriteTree{q}:
      Some{q}
    case T.Delete{q}:
      Some{q}
    case T.DeleteTree{q}:
      Some{q}
    case T.MoveFrom{q}:
      Some{q}
    case T.MakeDir{q}:
      Some{q}
    case T.ChangeDir{q}:
      Some{q}
    case T.GitPush{q, force, all, refs, unsure}:
      Some{q}
    case _:
      None{}

def act.show.m(m: Maybe<&2, T.Path>) -> String:
  match m:
    case Some{q}:
      Path.show(q)
    case None{}:
      "a protected file"

def act.show(a: T.Action) -> String:
  act.show.m(act.path(a))

# The path a change action changes, if a is a change.
def change.path(a: T.Action) -> Maybe<&2, T.Path>:
  match a:
    case T.Write{q}:
      Some{q}
    case T.Delete{q}:
      Some{q}
    case T.MakeDir{q}:
      Some{q}
    case T.WriteTree{q}:
      Some{q}
    case T.DeleteTree{q}:
      Some{q}
    case T.MoveFrom{q}:
      Some{q}
    case _:
      None{}

# ---------------------------------------------------------------------------
# Zone hits. An action changes zone z when it changes exactly a path under z
# (Write, Delete, MakeDir), or changes a tree that overlaps z (WriteTree,
# DeleteTree, MoveFrom). Meaning.changes(m, p) with p under z implies a hit.

def hit.one(a: T.Action, +z: T.Path) -> Bool:
  match a:
    case T.Write{q}:
      Path.under(q, z)
    case T.Delete{q}:
      Path.under(q, z)
    case T.MakeDir{q}:
      Path.under(q, z)
    case T.WriteTree{q}:
      Path.overlaps(q, z)
    case T.DeleteTree{q}:
      Path.overlaps(q, z)
    case T.MoveFrom{q}:
      Path.overlaps(q, z)
    case _:
      False{}

def hit.list(xs: List<&2, T.Action>, +z: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(hit.one(a, z), hit.list(t, z))

def hit.zones(+a: T.Action, zs: List<&2, T.Path>) -> Bool:
  match zs:
    case Nil{}:
      False{}
    case z <> t:
      Bool.or(hit.one(a, z), hit.zones(a, t))

# ---------------------------------------------------------------------------
# Self-protection: a change that touches Protect.covers or a file protected
# by name in any folder (Protect.named: Claude Code settings, .claude/hooks,
# git hooks and git config; a .claude folder as a whole too, except for
# MakeDir), or a read that overlaps the key file.

def self.one(a: T.Action, table: List<&2, T.Project>, +x: T.Ctx) -> Bool:
  match a:
    case T.Write{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named_or_dir(q))
    case T.Delete{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named_or_dir(q))
    case T.MakeDir{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named(q))
    case T.WriteTree{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named_or_dir(q))
    case T.DeleteTree{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named_or_dir(q))
    case T.MoveFrom{+q}:
      Bool.or(Protect.covers(table, x, q), Protect.named_or_dir(q))
    case T.Read{q}:
      Path.overlaps(q, Protect.key_file(Call.Ctx.home(x)))
    case T.ReadTree{q}:
      Path.overlaps(q, Protect.key_file(Call.Ctx.home(x)))
    case _:
      False{}

def self.list(xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(self.one(a, table, x), self.list(t, table, x))

def self_hit(+table: List<&2, T.Project>, +x: T.Ctx, m: T.Meaning) -> Bool:
  self.list(Meaning.actions(m), table, x)

# The first action that hits, for the message.
def self.path(xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx) -> String:
  match xs:
    case Nil{}:
      "a protected file"
    case +a <> t:
      pick(self.one(a, table, x), act.show(a), self.path(t, table, x))

# A call that is not fully understood but names or can reach a protected
# path (round 2, P2: a wildcard that can match a protected name, or a
# protected path named in its text) gets its own wording: it may only read
# the file, and the Read tool does that.
def self_msg(+table: List<&2, T.Project>, +x: T.Ctx, m: T.Meaning) -> String:
  match m:
    case T.Known{xs}:
      "bend-guard self-protection: " ++ self.path(xs, table, x) ++ " is bend-guard's own rules, code, key, Claude Code settings, git hooks or git config, or another file that decides what runs later. The user changes these themselves; leave it alone."
    case T.Unknown{why, xs}:
      "bend-guard self-protection: this call names or can reach " ++ self.path(xs, table, x) ++ ", which bend-guard protects (its own rules, code or key, Claude Code settings, git hooks or config, or another file that decides what runs later), and it is not fully understood (" ++ why ++ "). To read the file, use the Read tool; the user changes it themselves."

# ---------------------------------------------------------------------------
# Project rules (plan Task 2.1 rule table). Each check is a Bool fold over
# the actions; the rule turns it into a verdict once.

# NoReadOrChange: a Read or ReadTree of a path under z.
def read.one(a: T.Action, +z: T.Path) -> Bool:
  match a:
    case T.Read{q}:
      Path.under(q, z)
    case T.ReadTree{q}:
      Path.under(q, z)
    case _:
      False{}

def read.list(xs: List<&2, T.Action>, +z: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(read.one(a, z), read.list(t, z))

# NoReadOrChange: a ReadTree whose path strictly contains z (D4: ask).
def above.one(a: T.Action, +z: T.Path) -> Bool:
  match a:
    case T.ReadTree{+q}:
      Bool.and(Path.under(z, q), Bool.not(Path.under(q, z)))
    case _:
      False{}

def above.list(xs: List<&2, T.Action>, +z: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(above.one(a, z), above.list(t, z))

# TreeDeleteOnlyUnder: a DeleteTree is in scope when its path overlaps the
# project root, or the call's folder is in the project or unknown.
def tdo.scope(+q: T.Path, +root: T.Path, +x: T.Ctx) -> Bool:
  Bool.or(Path.overlaps(q, root), Bool.or(Path.under(Call.Ctx.cwd(x), root), Path.is_sentinel(Call.Ctx.cwd(x))))

def tdo.one(a: T.Action, +root: T.Path, +z: T.Path, +x: T.Ctx) -> Bool:
  match a:
    case T.DeleteTree{+q}:
      Bool.and(tdo.scope(q, root, x), Bool.not(Path.under(q, z)))
    case _:
      False{}

def tdo.list(xs: List<&2, T.Action>, +root: T.Path, +z: T.Path, +x: T.Ctx) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(tdo.one(a, root, z, x), tdo.list(t, root, z, x))

# Pushes: a GitPush is in scope when its folder is in the project (or unknown).
def push.scope(+dir: T.Path, +root: T.Path) -> Bool:
  Bool.or(Path.under(dir, root), Path.is_sentinel(dir))

def force.one(a: T.Action, +root: T.Path) -> Bool:
  match a:
    case T.GitPush{dir, force, all, refs, unsure}:
      Bool.and(push.scope(dir, root), force)
    case _:
      False{}

def force.list(xs: List<&2, T.Action>, +root: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(force.one(a, root), force.list(t, root))

def elem(+s: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(Path.Seg.eq(h, s), elem(s, t))

def pushto.one(a: T.Action, +root: T.Path, +b: String) -> Bool:
  match a:
    case T.GitPush{dir, force, all, refs, unsure}:
      Bool.and(push.scope(dir, root), elem(b, refs))
    case _:
      False{}

def pushto.list(xs: List<&2, T.Action>, +root: T.Path, +b: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(pushto.one(a, root, b), pushto.list(t, root, b))

def unsure.one(a: T.Action, +root: T.Path) -> Bool:
  match a:
    case T.GitPush{dir, force, all, refs, unsure}:
      Bool.and(push.scope(dir, root), Bool.or(unsure, all))
    case _:
      False{}

def unsure.list(xs: List<&2, T.Action>, +root: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(unsure.one(a, root), unsure.list(t, root))

def rule.nochange(+z: T.Path, xs: List<&2, T.Action>) -> T.Verdict:
  deny_if(hit.list(xs, z), "bend-guard rule (BEND_RULES.md): " ++ Path.show(z) ++ " may not be changed. Leave it as it is, or ask the user to change BEND_RULES.md.")

def rule.noread(+z: T.Path, +xs: List<&2, T.Action>) -> T.Verdict:
  Verdict.max(deny_if(Bool.or(hit.list(xs, z), read.list(xs, z)), "bend-guard rule (BEND_RULES.md): " ++ Path.show(z) ++ " may not be read or changed. Leave it alone, or ask the user to change BEND_RULES.md."), ask_if(above.list(xs, z), "bend-guard rule (BEND_RULES.md): this reads a whole folder that contains " ++ Path.show(z) ++ ", which may not be read. Narrow the search so it skips that path, or the user can approve."))

def rule.tdo(+root: T.Path, +z: T.Path, +x: T.Ctx, xs: List<&2, T.Action>) -> T.Verdict:
  deny_if(tdo.list(xs, root, z, x), "bend-guard rule (BEND_RULES.md): recursive deletes for " ++ Path.show(root) ++ " are allowed only under " ++ Path.show(z) ++ ". Delete single files instead, or ask the user.")

def rule.force(+root: T.Path, xs: List<&2, T.Action>) -> T.Verdict:
  deny_if(force.list(xs, root), "bend-guard rule (BEND_RULES.md): force pushes are not allowed in " ++ Path.show(root) ++ ". Push without --force (or -f, +ref, --mirror), or ask the user.")

def rule.pushto(+b: String, +root: T.Path, +xs: List<&2, T.Action>) -> T.Verdict:
  Verdict.max(deny_if(pushto.list(xs, root, b), "bend-guard rule (BEND_RULES.md): pushing to '" ++ b ++ "' is not allowed in " ++ Path.show(root) ++ ". Push to another branch and open a pull request, or ask the user."), ask_if(unsure.list(xs, root), "bend-guard rule (BEND_RULES.md): this push may update '" ++ b ++ "', which may not be pushed to, and the command does not show the destination. Name the branch (git push origin <branch>), or the user can approve."))

def rule.v(r: T.Rule, +root: T.Path, +x: T.Ctx, +xs: List<&2, T.Action>) -> T.Verdict:
  match r:
    case T.NoChange{rel}:
      rule.nochange(Path.child(root, rel), xs)
    case T.NoReadOrChange{rel}:
      rule.noread(Path.child(root, rel), xs)
    case T.TreeDeleteOnlyUnder{rel}:
      rule.tdo(root, Path.child(root, rel), x, xs)
    case T.NoForcePush{}:
      rule.force(root, xs)
    case T.NoPushTo{b}:
      rule.pushto(b, root, xs)
    case T.TrustScript{n}:
      T.Allow{}

def rules.v(rs: List<&2, T.Rule>, +root: T.Path, +x: T.Ctx, +xs: List<&2, T.Action>) -> T.Verdict:
  match rs:
    case Nil{}:
      T.Allow{}
    case r <> t:
      Verdict.max(rule.v(r, root, x, xs), rules.v(t, root, x, xs))

def table.v(table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>) -> T.Verdict:
  match table:
    case Nil{}:
      T.Allow{}
    case T.Project{root, rules} <> t:
      Verdict.max(rules.v(rules, root, x, xs), table.v(t, x, xs))

# ---------------------------------------------------------------------------
# Built-in rows (D3, D5)

def attr.zones.projects(table: List<&2, T.Project>) -> List<&2, T.Path>:
  match table:
    case Nil{}:
      []
    case T.Project{root, rules} <> t:
      Path.child(root, ".gitattributes") <> attr.zones.projects(t)

def attr.zones(table: List<&2, T.Project>, +x: T.Ctx) -> List<&2, T.Path>:
  Path.child(Call.Ctx.root(x), ".gitattributes") <> attr.zones.projects(table)

def segs.attr.name2(h: String) -> Bool:
  match h:
    case "attributes":
      True{}
    case _:
      False{}

# .git/info/attributes does the same job as .gitattributes.
def segs.attr.info2(t: List<&2, String>) -> Bool:
  match t:
    case Nil{}:
      False{}
    case h <> r:
      segs.attr.name2(h)

def segs.attr.info.at(h: String, r: List<&2, String>) -> Bool:
  match h:
    case "info":
      segs.attr.info2(r)
    case _:
      False{}

def segs.attr.info(t: List<&2, String>) -> Bool:
  match t:
    case Nil{}:
      False{}
    case h <> r:
      segs.attr.info.at(h, r)

def segs.attr.at(h: String, t: List<&2, String>) -> Bool:
  match h:
    case ".gitattributes":
      True{}
    case ".git":
      segs.attr.info(t)
    case _:
      False{}

def segs.attr(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> +t:
      Bool.or(segs.attr.at(h, t), segs.attr(t))

def change.attr(m: Maybe<&2, T.Path>) -> Bool:
  match m:
    case Some{T.Path{d, xs}}:
      segs.attr(xs)
    case None{}:
      False{}

def has_trust(rs: List<&2, T.Rule>, +n: String) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case T.TrustScript{s} <> t:
      Bool.or(Path.Seg.eq(s, n), has_trust(t, n))
    case r <> t:
      has_trust(t, n)

# Some project that contains the call's folder trusts script n.
def trusted(table: List<&2, T.Project>, +cwd: T.Path, +n: String) -> Bool:
  match table:
    case Nil{}:
      False{}
    case T.Project{root, rules} <> t:
      Bool.or(Bool.and(Path.under(cwd, root), has_trust(rules, n)), trusted(t, cwd, n))

def builtin.script(a: T.Action, table: List<&2, T.Project>, +x: T.Ctx) -> T.Verdict:
  match a:
    case T.RunScript{+n}:
      ask_unless(trusted(table, Call.Ctx.cwd(x), n), "bend-guard: this runs the package.json script '" ++ n ++ "', which no TrustScript rule in BEND_RULES.md trusts. The user can approve, or add a TrustScript rule for it.")
    case T.NpmInstall{pkgs}:
      T.Ask{"bend-guard: npm install runs package.json install scripts. The user can approve; or skip the install."}
    case _:
      T.Allow{}

# Hook managers' files, by name in any folder: .husky and .githooks (folders
# that core.hooksPath often points at), pre-commit's and lefthook's config.
# They decide what runs at the next commit, so a change asks, like
# .gitattributes (log-only relaxes it). Git's own hooks and config are in
# Protect (self-protection, never relaxed).
def segs.hookcfg.name(h: String) -> Bool:
  match h:
    case ".husky":
      True{}
    case ".githooks":
      True{}
    case ".pre-commit-config.yaml":
      True{}
    case "lefthook.yml":
      True{}
    case "lefthook.yaml":
      True{}
    case ".lefthook.yml":
      True{}
    case ".lefthook.yaml":
      True{}
    case "lefthook-local.yml":
      True{}
    case "lefthook-local.yaml":
      True{}
    case ".lefthook-local.yml":
      True{}
    case ".lefthook-local.yaml":
      True{}
    case _:
      False{}

def segs.hookcfg(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(segs.hookcfg.name(h), segs.hookcfg(t))

def change.hookcfg(m: Maybe<&2, T.Path>) -> Bool:
  match m:
    case Some{T.Path{d, xs}}:
      segs.hookcfg(xs)
    case None{}:
      False{}

def builtin.one(+a: T.Action, +table: List<&2, T.Project>, +x: T.Ctx) -> T.Verdict:
  Verdict.max(ask_if(Bool.or(hit.zones(a, attr.zones(table, x)), change.attr(change.path(a))), "bend-guard: .gitattributes (and .git/info/attributes) can make git run filters later. The user can approve; otherwise leave it as it is."), Verdict.max(ask_if(change.hookcfg(change.path(a)), "bend-guard: this changes a git hook manager's files (.husky, .githooks, .pre-commit-config.yaml or lefthook.yml), which decide what runs at the next commit. The user can approve; otherwise leave them as they are."), builtin.script(a, table, x)))

def builtin.list(xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx) -> T.Verdict:
  match xs:
    case Nil{}:
      T.Allow{}
    case a <> t:
      Verdict.max(builtin.one(a, table, x), builtin.list(t, table, x))

# ---------------------------------------------------------------------------
# Link facts (x.links; always [] in this version, build brief Q11)

def no_link.list(ls: List<&2, T.Path>, +p: T.Path) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case l <> t:
      Bool.and(Bool.not(Path.under(p, l)), no_link.list(t, p))

# p is not under any path in x.links.
def no_link(x: T.Ctx, +p: T.Path) -> Bool:
  no_link.list(Call.Ctx.links(x), p)

def link.m(m: Maybe<&2, T.Path>, +x: T.Ctx) -> T.Verdict:
  match m:
    case None{}:
      T.Allow{}
    case Some{+q}:
      ask_unless(no_link(x, q), "bend-guard: " ++ Path.show(q) ++ " goes through a link (symlink, junction or hard link), so where it really points cannot be checked. Use the real path, or the user can approve.")

def link.list(xs: List<&2, T.Action>, +x: T.Ctx) -> T.Verdict:
  match xs:
    case Nil{}:
      T.Allow{}
    case a <> t:
      Verdict.max(link.m(act.path(a), x), link.list(t, x))

# ---------------------------------------------------------------------------
# rule_verdict: the strictest of every (rule, action) pair, every built-in
# row and every link fact.

def rv.go(+table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>) -> T.Verdict:
  Verdict.max(table.v(table, x, xs), Verdict.max(builtin.list(xs, table, x), link.list(xs, x)))

def rule_verdict(+table: List<&2, T.Project>, +x: T.Ctx, m: T.Meaning) -> T.Verdict:
  rv.go(table, x, Meaning.actions(m))

# ---------------------------------------------------------------------------
# Double-check zones (NoChange and NoReadOrChange paths), and rule names

def zone.rule(r: T.Rule, +root: T.Path, +p: T.Path) -> Bool:
  match r:
    case T.NoChange{rel}:
      Path.under(p, Path.child(root, rel))
    case T.NoReadOrChange{rel}:
      Path.under(p, Path.child(root, rel))
    case _:
      False{}

def zone.rules(rs: List<&2, T.Rule>, +root: T.Path, +p: T.Path) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case r <> t:
      Bool.or(zone.rule(r, root, p), zone.rules(t, root, p))

# p is under a NoChange or NoReadOrChange path of some project.
def in_rule_zone(table: List<&2, T.Project>, +p: T.Path) -> Bool:
  match table:
    case Nil{}:
      False{}
    case T.Project{root, rules} <> t:
      Bool.or(zone.rules(rules, root, p), in_rule_zone(t, p))

def zone.act(a: T.Action, +table: List<&2, T.Project>) -> Bool:
  match a:
    case T.Read{q}:
      in_rule_zone(table, q)
    case T.ReadTree{q}:
      in_rule_zone(table, q)
    case _:
      False{}

def zone.acts(xs: List<&2, T.Action>, +table: List<&2, T.Project>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(zone.act(a, table), zone.acts(t, table))

def names.rule(r: T.Rule, +root: T.Path, +p: T.Path) -> Bool:
  match r:
    case T.NoChange{rel}:
      Bool.not(Path.overlaps(p, Path.child(root, rel)))
    case T.NoReadOrChange{rel}:
      Bool.not(Path.overlaps(p, Path.child(root, rel)))
    case T.TreeDeleteOnlyUnder{rel}:
      Bool.not(Path.overlaps(p, Path.child(root, rel)))
    case _:
      True{}

def names.rules(rs: List<&2, T.Rule>, +root: T.Path, +p: T.Path) -> Bool:
  match rs:
    case Nil{}:
      True{}
    case r <> t:
      Bool.and(names.rule(r, root, p), names.rules(t, root, p))

# No rule path of any project overlaps p (it neither contains nor is under p).
def no_rule_names(table: List<&2, T.Project>, +p: T.Path) -> Bool:
  match table:
    case Nil{}:
      True{}
    case T.Project{root, rules} <> t:
      Bool.and(names.rules(rules, root, p), no_rule_names(t, p))

# ---------------------------------------------------------------------------
# Clef (combine can only tighten: always Verdict.max(base, clef.x(q, a)))

def clef.triage(risky: U32) -> T.Verdict:
  deny_if(U32.is_ge(risky, T_TRIAGE()), "bend-guard: Clef (the second opinion) rates this command as risky. Rewrite it with known commands, or ask the user to run it.")

def clef.veto(risky: U32, unsure: U32) -> T.Verdict:
  ask_if(Bool.or(U32.is_ge(risky, T_VETO()), U32.is_ge(unsure, T_UNSURE())), "bend-guard: Clef (the second opinion) is not sure this command only reads inside a protected folder. The user can approve; or use the Read tool.")

def clef.x(q: T.ClefQ, a: T.ClefAnswer) -> T.Verdict:
  match q a:
    case T.Triage{} T.Answer{risky, unsure}:
      clef.triage(risky)
    case T.Veto{} T.Answer{risky, unsure}:
      clef.veto(risky, unsure)
    case T.Triage{} T.NoAnswer{}:
      T.Ask{"bend-guard: Clef (the second opinion) did not answer, so the user must approve. The user can approve; or try again."}
    case T.Veto{} T.NoAnswer{}:
      T.Ask{"bend-guard: Clef (the second opinion) did not answer, so the user must approve. The user can approve; or try again."}

def combine(base: T.Verdict, q: T.ClefQ, a: T.ClefAnswer) -> T.Verdict:
  Verdict.max(base, clef.x(q, a))

# ---------------------------------------------------------------------------
# The text Clef is sent (a Consult's text): t cut to its first 1500 and last
# 500 characters when it is 2001 to 4000 characters long. c: at most 2000
# characters; l: more than 4000 (left whole; short(t) is False then and
# decide never sends it to Clef).

def text.cap.if(c: Bool, l: Bool, +s: String) -> String:
  match c l:
    case True{} _:
      s
    case False{} True{}:
      s
    case False{} False{}:
      String.take(s, 1500n) ++ "\n[...]\n" ++ String.drop(s, Nat.sub(String.length(s), 500n))

def text.cap(+s: String) -> String:
  text.cap.if(Nat.is_le(String.length(s), 2000n), Bool.not(Nat.is_le(String.length(s), 4000n)), s)

# ---------------------------------------------------------------------------
# No-read zones named by a shell command that is not understood (round 3,
# P3). The command part of the call's text t (after "\nCommand: ") is
# lower-cased, '\' is read as '/' and a run of '/' as one. Each
# NoReadOrChange zone of every project is looked for in two spellings: its
# path from its project folder, and its path from the call's folder (from
# where the two first differ; "" when the folder is inside the zone, which
# is never looked for). A spelling counts only at path boundaries: after the
# start, a space, a quote, '=', '(', '/', or one of ; , | & < > @ : { [ ;
# and before the end, a space, a quote, '/', ')', or one of ; , | & < > ] }
# : * ?, after any dots (Windows drops them at the end of a name). So '/'
# before also covers ./x, ../x and absolute spellings (c:/..., /c/...), and
# .env.example, dotenv, my-secrets.txt and secretsx do not count. decide
# refuses such a call before Clef (law named_noread_unknown_denied).
# Scanners are loops (NOTES.md section 8: a command can be 40,000
# characters).

# the text after the first "\nCommand: " in s ("" when there is none)
def nr.cmd(s: String, hit: Bool) -> String:
  match s hit:
    case _ True{}:
      String.drop(s, 9n)
    case SNil{} False{}:
      ""
    case SCon{Chr{10}, +r} False{}:
      nr.cmd(r, String.starts_with(r, "Command: "))
    case SCon{c, r} False{}:
      nr.cmd(r, False{})

# lower case, '\' as '/', a run of '/' as one; acc reversed, sl: last was '/'
def nr.fold(s: String, sl: Bool, acc: String) -> String:
  match s sl:
    case SNil{} _:
      String.reverse(acc)
    case SCon{Chr{47}, t} True{}:
      nr.fold(t, True{}, acc)
    case SCon{Chr{92}, t} True{}:
      nr.fold(t, True{}, acc)
    case SCon{Chr{47}, t} False{}:
      nr.fold(t, True{}, SCon{'/', acc})
    case SCon{Chr{92}, t} False{}:
      nr.fold(t, True{}, SCon{'/', acc})
    case SCon{c, t} _:
      nr.fold(t, False{}, SCon{Char.to_lower(c), acc})

# a spelling may start after c
def nr.before(c: Char) -> Bool:
  match c:
    case Chr{32}:
      True{}
    case Chr{9}:
      True{}
    case Chr{10}:
      True{}
    case Chr{13}:
      True{}
    case Chr{34}:
      True{}
    case Chr{39}:
      True{}
    case Chr{96}:
      True{}
    case Chr{61}:
      True{}
    case Chr{40}:
      True{}
    case Chr{47}:
      True{}
    case Chr{59}:
      True{}
    case Chr{44}:
      True{}
    case Chr{124}:
      True{}
    case Chr{38}:
      True{}
    case Chr{60}:
      True{}
    case Chr{62}:
      True{}
    case Chr{64}:
      True{}
    case Chr{58}:
      True{}
    case Chr{123}:
      True{}
    case Chr{91}:
      True{}
    case _:
      False{}

# a spelling may end before c
def nr.endc(c: Char) -> Bool:
  match c:
    case Chr{32}:
      True{}
    case Chr{9}:
      True{}
    case Chr{10}:
      True{}
    case Chr{13}:
      True{}
    case Chr{34}:
      True{}
    case Chr{39}:
      True{}
    case Chr{96}:
      True{}
    case Chr{47}:
      True{}
    case Chr{41}:
      True{}
    case Chr{59}:
      True{}
    case Chr{44}:
      True{}
    case Chr{124}:
      True{}
    case Chr{38}:
      True{}
    case Chr{60}:
      True{}
    case Chr{62}:
      True{}
    case Chr{93}:
      True{}
    case Chr{125}:
      True{}
    case Chr{58}:
      True{}
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case _:
      False{}

# the text after a spelling: dots, then the end or a boundary
def nr.after(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{46}, t}:
      nr.after(t)
    case SCon{c, t}:
      nr.endc(c)

def nr.pick.l(b: Bool, x: List<&2, String>, y: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      x
    case False{}:
      y

# zs after the longest common start with cs
def nr.rest(zs: List<&2, String>, cs: List<&2, String>) -> List<&2, String>:
  match zs cs:
    case Nil{} _:
      []
    case Con{h, t} Nil{}:
      h <> t
    case Con{+h, +t} Con{h2, t2}:
      nr.pick.l(Path.Seg.eq(h, h2), nr.rest(t, t2), h <> t)

def nr.sep(acc: String) -> String:
  match acc:
    case SNil{}:
      ""
    case SCon{c, r}:
      SCon{c, r} ++ "/"

# the parts joined with '/'
def nr.join(xs: List<&2, String>, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      nr.join(t, nr.sep(acc) ++ h)

def nr.spell.k(same: Bool, zs: List<&2, String>, bs: List<&2, String>) -> String:
  match same:
    case True{}:
      nr.join(nr.rest(zs, bs), "")
    case False{}:
      ""

# zone z as written from folder b ("" on another drive)
def nr.spell(b: T.Path, z: T.Path) -> String:
  match b z:
    case T.Path{bd, bs} T.Path{zd, zs}:
      nr.spell.k(Path.Seg.eq(bd, zd), zs, bs)

# a zone and its spellings
type NrZ is Data:
  NrZ.Mk{zone: T.Path, sps: List<&2, String>}

def nr.mk(+root: T.Path, +cwd: T.Path, +z: T.Path) -> NrZ:
  NrZ.Mk{z, [nr.spell(root, z), nr.spell(cwd, z)]}

def nr.rules(rs: List<&2, T.Rule>, +root: T.Path, +cwd: T.Path) -> List<&2, NrZ>:
  match rs:
    case Nil{}:
      []
    case T.NoReadOrChange{rel} <> t:
      nr.mk(root, cwd, Path.child(root, rel)) <> nr.rules(t, root, cwd)
    case r <> t:
      nr.rules(t, root, cwd)

# every NoReadOrChange zone of every project, with its spellings
def nr.zones(table: List<&2, T.Project>, +cwd: T.Path) -> List<&2, NrZ>:
  match table:
    case Nil{}:
      []
    case T.Project{root, rules} <> t:
      List.append(&2, NrZ, nr.rules(rules, root, cwd), nr.zones(t, cwd))

def nr.one.k(hit: Bool, +sp: String, +s: String) -> Bool:
  match hit:
    case True{}:
      nr.after(String.drop(s, String.length(sp)))
    case False{}:
      False{}

# s starts with the spelling sp, which ends at a boundary
def nr.one(+sp: String, +s: String) -> Bool:
  nr.one.k(Bool.and(Bool.not(String.is_empty(sp)), String.starts_with(s, sp)), sp, s)

def nr.any(sps: List<&2, String>, +s: String) -> Bool:
  match sps:
    case Nil{}:
      False{}
    case sp <> t:
      Bool.or(nr.one(sp, s), nr.any(t, s))

def nr.at(ok: Bool, +s: String, +sps: List<&2, String>) -> Bool:
  match ok:
    case True{}:
      nr.any(sps, s)
    case False{}:
      False{}

# some spelling starts at a boundary in s; ok: a spelling may start here
def nr.scan(s: String, ok: Bool, +sps: List<&2, String>, acc: Bool) -> Bool:
  match s acc:
    case _ True{}:
      True{}
    case SNil{} False{}:
      False{}
    case SCon{+c, +t} False{}:
      nr.scan(t, nr.before(c), sps, nr.at(ok, SCon{c, t}, sps))

def nr.find.k(hit: Bool, z: T.Path, rest: Maybe<&2, T.Path>) -> Maybe<&2, T.Path>:
  match hit:
    case True{}:
      Some{z}
    case False{}:
      rest

def nr.find.go(zs: List<&2, NrZ>, +s: String) -> Maybe<&2, T.Path>:
  match zs:
    case Nil{}:
      None{}
    case NrZ.Mk{z, sps} <> t:
      nr.find.k(nr.scan(s, True{}, sps, False{}), z, nr.find.go(t, s))

# the first no-read zone the command in t names
def nr.find(+table: List<&2, T.Project>, +x: T.Ctx, t: String) -> Maybe<&2, T.Path>:
  nr.find.go(nr.zones(table, Call.Ctx.cwd(x)), nr.fold(nr.cmd(t, False{}), False{}, ""))

def nr.some(m: Maybe<&2, T.Path>) -> Bool:
  match m:
    case Some{z}:
      True{}
    case None{}:
      False{}

# a shell call whose command names a no-read zone (decide applies it only to
# an Unknown meaning)
def noread.hit(+table: List<&2, T.Project>, +x: T.Ctx, t: String) -> Bool:
  Bool.and(Call.Ctx.shell_tool(x), nr.some(nr.find(table, x, t)))

def noread_msg.m(m: Maybe<&2, T.Path>) -> String:
  match m:
    case Some{+z}:
      "bend-guard rule (BEND_RULES.md): " ++ Path.show(z) ++ " may not be read or changed. This command names it, and bend-guard does not fully understand the command, so it cannot tell what the command does with it. Leave that path out, use commands bend-guard understands, or ask the user."
    case None{}:
      "bend-guard rule (BEND_RULES.md): this command names a path that may not be read, and bend-guard does not fully understand it. Leave that path out, use commands bend-guard understands, or ask the user."

def noread_msg(+table: List<&2, T.Project>, +x: T.Ctx, t: String) -> String:
  noread_msg.m(nr.find(table, x, t))

# ---------------------------------------------------------------------------
# decide_m, steps 1-7 of plan Task 2.1. decide.go takes self_hit as an
# argument so run_m computes it once and the laws can split on it.

def unknown_msg(why: String) -> String:
  "bend-guard: not understood (" ++ why ++ "). The user can approve; or use a known command."

# t is at most 4000 characters (longer text is never sent to Clef).
def short(t: String) -> Bool:
  Nat.is_le(String.length(t), 4000n)

def decide.triage(c: Bool, v: T.Verdict, t: String) -> T.Step:
  match c:
    case True{}:
      T.Consult{T.Triage{}, v, text.cap(t)}
    case False{}:
      T.Step.Done{v}

# step 4: the meaning is Unknown
def decide.unknown(ca: Bool, why: String, v: T.Verdict, +x: T.Ctx, +t: String) -> T.Step:
  match ca:
    case False{}:
      T.Step.Done{T.Deny{"bend-guard: not understood (" ++ why ++ "), and no person can be asked here. Ask the user in the main session, or use a known command."}}
    case True{}:
      decide.triage(Bool.and(Call.Ctx.shell_tool(x), short(t)), Verdict.max(v, T.Ask{unknown_msg(why)}), t)

# step 4a (round 3, P3): an Unknown shell call whose command names a no-read
# zone is refused, before Clef and whoever could be asked
def decide.noread(nh: Bool, why: String, v: T.Verdict, +table: List<&2, T.Project>, +x: T.Ctx, +t: String) -> T.Step:
  match nh:
    case True{}:
      T.Step.Done{T.Deny{noread_msg(table, x, t)}}
    case False{}:
      decide.unknown(can_ask(x), why, v, x, t)

# step 6, a text too long for Clef (short(t) is False): the user must approve,
# as when Clef does not answer
def decide.veto.clef(c: Bool, t: String) -> T.Step:
  match c:
    case True{}:
      T.Consult{T.Veto{}, T.Allow{}, text.cap(t)}
    case False{}:
      T.Step.Done{T.Ask{"bend-guard: this command is too long for the second opinion (Clef), so the user must approve. The user can approve; or use a shorter command."}}

# step 6: a shell read inside a double-check zone gets a Clef veto, in the main
# session only: an agent is never sent to Clef (the rules already allow the read)
def decide.veto(z: Bool, st: Bool, +t: String) -> T.Step:
  match z st:
    case False{} _:
      T.Step.Done{T.Allow{}}
    case True{} True{}:
      decide.veto.clef(short(t), t)
    case True{} False{}:
      T.Step.Done{T.Allow{}}

# steps 5-7: the meaning is Known
def decide.known(v: T.Verdict, xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx, t: String) -> T.Step:
  match v:
    case T.Allow{}:
      decide.veto(zone.acts(xs, table), Bool.and(Call.Ctx.shell_tool(x), Bool.not(Call.Ctx.agent(x))), t)
    case T.Ask{r}:
      T.Step.Done{T.Ask{r}}
    case T.Deny{r}:
      T.Step.Done{T.Deny{r}}

def decide.meaning(m: T.Meaning, v: T.Verdict, +table: List<&2, T.Project>, +x: T.Ctx, +t: String) -> T.Step:
  match m:
    case T.Known{xs}:
      decide.known(v, xs, table, x, t)
    case T.Unknown{why, xs}:
      decide.noread(noread.hit(table, x, t), why, v, table, x, t)

# step 3: a Deny from the rules ends here
def decide.rules(v: T.Verdict, m: T.Meaning, +table: List<&2, T.Project>, +x: T.Ctx, +t: String) -> T.Step:
  match v:
    case T.Deny{r}:
      T.Step.Done{T.Deny{r}}
    case T.Ask{r}:
      decide.meaning(m, T.Ask{r}, table, x, t)
    case T.Allow{}:
      decide.meaning(m, T.Allow{}, table, x, t)

# step 2: self-protection
def decide.self(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String) -> T.Step:
  match sh:
    case True{}:
      T.Step.Done{T.Deny{self_msg(table, x, m)}}
    case False{}:
      decide.rules(rule_verdict(table, x, m), m, table, x, t)

# step 1: the project or home folder could not be read
def decide.sent(b: Bool, sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String) -> T.Step:
  match b:
    case True{}:
      T.Step.Done{T.Deny{"bend-guard: cannot read the project folder or the home folder, so every call is refused. Start Claude Code from a normal folder on drive C."}}
    case False{}:
      decide.self(sh, table, x, m, t)

def decide.go(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String) -> T.Step:
  decide.sent(bad(x), sh, table, x, m, t)

def decide_m(+table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String) -> T.Step:
  decide.go(self_hit(table, x, m), table, x, m, t)

# ---------------------------------------------------------------------------
# From a step to the final verdict

# the step's verdict, combined with Clef's answer if it is a Consult
def after_clef(s: T.Step, a: T.ClefAnswer) -> T.Verdict:
  match s:
    case T.Step.Done{v}:
      v
    case T.Consult{q, b, t}:
      combine(b, q, a)

# the step's verdict with the Consult's base used as is
def step_base(s: T.Step) -> T.Verdict:
  match s:
    case T.Step.Done{v}:
      v
    case T.Consult{q, b, t}:
      b

# An Unknown meaning is never Allow before finish (decide already makes it
# at least Ask; this keeps unknown_never_allowed independent of decide).
def floor.allow(m: T.Meaning) -> T.Verdict:
  match m:
    case T.Known{xs}:
      T.Allow{}
    case T.Unknown{why, xs}:
      T.Ask{unknown_msg(why)}

def floor(v: T.Verdict, m: T.Meaning) -> T.Verdict:
  match v:
    case T.Allow{}:
      floor.allow(m)
    case T.Ask{r}:
      T.Ask{r}
    case T.Deny{r}:
      T.Deny{r}

def finish.check(ca: Bool, r: String) -> T.Verdict:
  match ca:
    case True{}:
      T.Ask{r}
    case False{}:
      T.Deny{"bend-guard: no person can answer an ask here, so this is refused. Ask the user in the main session. (" ++ r ++ ")"}

def finish.call(dy: Bool, r: String) -> T.Verdict:
  match dy:
    case True{}:
      T.Allow{}
    case False{}:
      T.Deny{"bend-guard: this call needed the user's approval and did not get it. Ask the user in the main session. (" ++ r ++ ")"}

def finish.ask(s: T.Stage, ca: Bool, dy: Bool, r: String) -> T.Verdict:
  match s:
    case T.AtCheck{}:
      finish.check(ca, r)
    case T.AtCall{asked, consent}:
      finish.call(dy, r)

# ca = can_ask(x), dy = Ctx.dan_said_yes(x); only an Ask changes.
def finish.go(s: T.Stage, ca: Bool, dy: Bool, v: T.Verdict) -> T.Verdict:
  match v:
    case T.Allow{}:
      T.Allow{}
    case T.Ask{r}:
      finish.ask(s, ca, dy, r)
    case T.Deny{r}:
      T.Deny{r}

def finish(+x: T.Ctx, v: T.Verdict) -> T.Verdict:
  finish.go(Call.Ctx.stage(x), can_ask(x), Call.Ctx.dan_said_yes(x), v)

# Log-only relaxes a Known meaning when both folders were read (D8).
# Self-protection is applied after this, so it is never relaxed.
def relax.cond(+x: T.Ctx, m: T.Meaning) -> Bool:
  Bool.and(Call.Ctx.log_only(x), Bool.and(Bool.not(Meaning.is_unknown(m)), Bool.not(bad(x))))

def relax(c: Bool, v: T.Verdict) -> T.Verdict:
  match c:
    case True{}:
      T.Allow{}
    case False{}:
      v

def protect(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, m: T.Meaning, v: T.Verdict) -> T.Verdict:
  match sh:
    case True{}:
      T.Deny{self_msg(table, x, m)}
    case False{}:
      v

# v: the verdict of the step (after Clef, or the base without Clef)
def run.go(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, v: T.Verdict) -> T.Verdict:
  protect(sh, table, x, m, relax(relax.cond(x, m), finish(x, floor(v, m))))

def run.with(+sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, t: String, a: T.ClefAnswer) -> T.Verdict:
  run.go(sh, table, x, m, after_clef(decide.go(sh, table, x, m, t), a))

def run.nc(+sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, t: String) -> T.Verdict:
  run.go(sh, table, x, m, step_base(decide.go(sh, table, x, m, t)))

def run_m(+table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, t: String, a: T.ClefAnswer) -> T.Verdict:
  run.with(self_hit(table, x, m), table, x, m, t, a)

def run_m_without_clef(+table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, t: String) -> T.Verdict:
  run.nc(self_hit(table, x, m), table, x, m, t)

# ---------------------------------------------------------------------------
# The call's text: "Shell: <tool>\nFolder: <first cwd>\nCommand: <command>".
# Clef sees it capped (text.cap, above decide): the first 1500 and the last
# 500 characters when it is 2001 to 4000 characters long. A longer text is
# never sent: short(t) is then False and the call asks.

def text.first(cwds: List<&2, String>) -> String:
  match cwds:
    case Nil{}:
      "(unknown)"
    case h <> t:
      h

def text.arg(args: List<&2, T.Arg>, +key: String) -> String:
  match args:
    case Nil{}:
      ""
    case T.Arg{+k, v} <> t:
      pick(String.eq(k, key), v, text.arg(t, key))

# The whole text: decide reads all of it for no-read zones (round 3, P3),
# and cuts it (text.cap) only where it hands it to Clef in a Consult.
def clef_text(c: T.Call) -> String:
  match c:
    case T.Call{tool, args, cwds, root, home, links, agent, approver, interactive, mode, stage, log_only}:
      "Shell: " ++ tool ++ "\nFolder: " ++ text.first(cwds) ++ "\nCommand: " ++ text.arg(args, "command")
