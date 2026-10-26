# bend-guard: proofs of laws/rules/LAWS.bend. Built bottom-up (bend/NOTES.md
# section 8, "Guard proof map"):
#   1. Deny path: a rule whose verdict is Deny makes rule_verdict Deny (the
#      table and rule lists are Verdict.max folds), decide stops at step 3,
#      and floor, finish, relax (log_only False) and protect keep a Deny.
#   2. Per rule kind: the rule's Bool fold is True for the action, so its
#      deny_if gives Deny.
#   3. read_allowed: every step computes to Allow for Known{[Read{p}]} once the
#      hypotheses rewrite the few Bools that depend on p and x.
# Lemmas over free Bools are instantiated with Guard's terms, so no proof
# needs to split on a computed value.
#
# The msg.* defs copy Guard's reason texts. A deny_if or ask_if lemma must
# name the reason it is applied to, and Bend has no inference, so the text is
# repeated here. If a reason in core/Guard.bend changes, this file stops
# checking (it never passes wrongly); copy the new text into msg.*.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ../../core/Path.bend as Path
import ../../core/Meaning.bend as Meaning
import ../../core/Call.bend as Call
import ../../core/Protect.bend as Protect
import ../../core/Guard.bend as Guard
import ../path/LAWS.bend as PathLaws
import ../path/PROOF.bend as PathProof
import ./LAWS.bend as Laws

# ---------------------------------------------------------------------------
# Guard's reason texts (see the header)

def msg.nochange(+z: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): " ++ Path.show(z) ++ " may not be changed. Leave it as it is, or ask the user to change BEND_RULES.md."

def msg.noread(+z: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): " ++ Path.show(z) ++ " may not be read or changed. Leave it alone, or ask the user to change BEND_RULES.md."

def msg.above(+z: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): this reads a whole folder that contains " ++ Path.show(z) ++ ", which may not be read. Narrow the search so it skips that path, or the user can approve."

def msg.tdo(+root: T.Path, +z: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): recursive deletes for " ++ Path.show(root) ++ " are allowed only under " ++ Path.show(z) ++ ". Delete single files instead, or ask the user."

def msg.force(+root: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): force pushes are not allowed in " ++ Path.show(root) ++ ". Push without --force (or -f, +ref, --mirror), or ask the user."

def msg.pushto(+b: String, +root: T.Path) -> String:
  "bend-guard rule (BEND_RULES.md): pushing to '" ++ b ++ "' is not allowed in " ++ Path.show(root) ++ ". Push to another branch and open a pull request, or ask the user."

def msg.unsure(+b: String) -> String:
  "bend-guard rule (BEND_RULES.md): this push may update '" ++ b ++ "', which may not be pushed to, and the command does not show the destination. Name the branch (git push origin <branch>), or the user can approve."

def msg.link(+q: T.Path) -> String:
  "bend-guard: " ++ Path.show(q) ++ " goes through a link (symlink, junction or hard link), so where it really points cannot be checked. Use the real path, or the user can approve."


def msg.attr() -> String:
  "bend-guard: .gitattributes (and .git/info/attributes) can make git run filters later. The user can approve; otherwise leave it as it is."

def msg.hookcfg() -> String:
  "bend-guard: this changes a git hook manager's files (.husky, .githooks, .pre-commit-config.yaml or lefthook.yml), which decide what runs at the next commit. The user can approve; otherwise leave them as they are."

# ---------------------------------------------------------------------------
# Bool

def true_ne_false(e: {True{} == False{} : Bool}) -> Empty:
  PathProof.false_ne_true(Equal.sym(Bool, True{}, False{}, e))

def not_false(b: Bool) -> {b == False{} : Bool} -> {Bool.not(b) == True{} : Bool}:
  match b:
    case True{}:
      h => Empty.absurd({False{} == True{} : Bool}, true_ne_false(h))
    case False{}:
      h => {==}

def or_false(a: Bool, -b: Bool) -> {a == False{} : Bool} -> {b == False{} : Bool} -> {Bool.or(a, b) == False{} : Bool}:
  match a:
    case True{}:
      ha => hb => Empty.absurd({True{} == False{} : Bool}, true_ne_false(ha))
    case False{}:
      ha => hb => hb

def or_false_r(a: Bool) -> {a == False{} : Bool} -> {Bool.or(a, False{}) == False{} : Bool}:
  match a:
    case True{}:
      h => Empty.absurd({True{} == False{} : Bool}, true_ne_false(h))
    case False{}:
      h => {==}

def and_false_l(a: Bool, -b: Bool) -> {a == False{} : Bool} -> {Bool.and(a, b) == False{} : Bool}:
  match a:
    case True{}:
      h => Empty.absurd({b == False{} : Bool}, true_ne_false(h))
    case False{}:
      h => {==}

# not (u or v) gives not u
def not_or_l(u: Bool, -v: Bool) -> {Bool.not(Bool.or(u, v)) == True{} : Bool} -> {u == False{} : Bool}:
  match u:
    case True{}:
      h => Empty.absurd({True{} == False{} : Bool}, PathProof.false_ne_true(h))
    case False{}:
      h => {==}

# Bool.or is monotone in both arguments.
def or_mono(c: Bool, -rc: Bool, d: Bool, -rd: Bool) -> ({c == True{} : Bool} -> {d == True{} : Bool}) -> ({rc == True{} : Bool} -> {rd == True{} : Bool}) -> {Bool.or(c, rc) == True{} : Bool} -> {Bool.or(d, rd) == True{} : Bool}:
  match c:
    case True{}:
      f => g => h => PathProof.or_l(d, rd, f({==}))
    case False{}:
      f => g => h => PathProof.or_r(d, rd, g(h))

# ---------------------------------------------------------------------------
# Verdicts

def max_deny_left(v: T.Verdict, -w: T.Verdict) -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Verdict.max(v, w)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      h => Empty.absurd({Verdict.is_deny(w) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Ask{r}:
      h => Empty.absurd({Verdict.is_deny(Verdict.max(T.Ask{r}, w)) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Deny{r}:
      h => {==}

def max_deny_right(v: T.Verdict, w: T.Verdict) -> {Verdict.is_deny(w) == True{} : Bool} -> {Verdict.is_deny(Verdict.max(v, w)) == True{} : Bool}:
  match v w:
    case T.Allow{} T.Allow{}:
      h => h
    case T.Allow{} T.Ask{s}:
      h => h
    case T.Allow{} T.Deny{s}:
      h => h
    case T.Ask{r} T.Allow{}:
      h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Ask{r} T.Ask{s}:
      h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Ask{r} T.Deny{s}:
      h => {==}
    case T.Deny{r} T.Allow{}:
      h => {==}
    case T.Deny{r} T.Ask{s}:
      h => {==}
    case T.Deny{r} T.Deny{s}:
      h => {==}

def max_allow(v: T.Verdict, -w: T.Verdict) -> {Verdict.is_allow(v) == True{} : Bool} -> {Verdict.is_allow(w) == True{} : Bool} -> {Verdict.is_allow(Verdict.max(v, w)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      hv => hw => hw
    case T.Ask{r}:
      hv => hw => Empty.absurd({Verdict.is_allow(Verdict.max(T.Ask{r}, w)) == True{} : Bool}, PathProof.false_ne_true(hv))
    case T.Deny{r}:
      hv => hw => Empty.absurd({Verdict.is_allow(Verdict.max(T.Deny{r}, w)) == True{} : Bool}, PathProof.false_ne_true(hv))

def deny_if_true(b: Bool, -r: String) -> {b == True{} : Bool} -> {Verdict.is_deny(Guard.deny_if(b, r)) == True{} : Bool}:
  match b:
    case True{}:
      h => {==}
    case False{}:
      h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))

# ---------------------------------------------------------------------------
# 1. A Deny from rule_verdict survives run_m (outside log-only mode)

def finish_floor_deny(-x: T.Ctx, v: T.Verdict, -m: T.Meaning) -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Guard.finish(x, Guard.floor(v, m))) == True{} : Bool}:
  match v:
    case T.Allow{}:
      h => Empty.absurd({Verdict.is_deny(Guard.finish(x, Guard.floor(T.Allow{}, m))) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Ask{r}:
      h => Empty.absurd({Verdict.is_deny(Guard.finish(x, Guard.floor(T.Ask{r}, m))) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Deny{r}:
      h => {==}

def relax_deny(c: Bool, -v: T.Verdict) -> {c == False{} : Bool} -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Guard.relax(c, v)) == True{} : Bool}:
  match c:
    case True{}:
      hc => hv => Empty.absurd({Verdict.is_deny(T.Allow{}) == True{} : Bool}, true_ne_false(hc))
    case False{}:
      hc => hv => hv

def protect_deny(sh: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -m: T.Meaning, -v: T.Verdict) -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Guard.protect(sh, table, x, m, v)) == True{} : Bool}:
  match sh:
    case True{}:
      h => {==}
    case False{}:
      h => h

def relax_cond_false(+x: T.Ctx, -m: T.Meaning) -> {Call.Ctx.log_only(x) == False{} : Bool} -> {Guard.relax.cond(x, m) == False{} : Bool}:
  h0 => and_false_l(Call.Ctx.log_only(x), Bool.and(Bool.not(Meaning.is_unknown(m)), Bool.not(Guard.bad(x))), h0)

def run_go_deny(sh: Bool, -table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +v: T.Verdict) -> {Call.Ctx.log_only(x) == False{} : Bool} -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Guard.run.go(sh, table, x, m, v)) == True{} : Bool}:
  h0 => hv => protect_deny(sh, table, x, m, Guard.relax(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m))),
    relax_deny(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m)), relax_cond_false(x, m, h0), finish_floor_deny(x, v, m, hv)))

def decide_rules_deny(v: T.Verdict, -m: T.Meaning, -table: List<&2, T.Project>, -x: T.Ctx, -t: String, -a: T.ClefAnswer) -> {Verdict.is_deny(v) == True{} : Bool} -> {Verdict.is_deny(Guard.after_clef(Guard.decide.rules(v, m, table, x, t), a)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      h => Empty.absurd({Verdict.is_deny(Guard.after_clef(Guard.decide.rules(T.Allow{}, m, table, x, t), a)) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Ask{r}:
      h => Empty.absurd({Verdict.is_deny(Guard.after_clef(Guard.decide.rules(T.Ask{r}, m, table, x, t), a)) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Deny{r}:
      h => {==}

def decide_sent_deny(b: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, -t: String, -a: T.ClefAnswer) -> {Verdict.is_deny(Guard.rule_verdict(table, x, m)) == True{} : Bool} -> {Verdict.is_deny(Guard.after_clef(Guard.decide.sent(b, False{}, table, x, m, t), a)) == True{} : Bool}:
  match b:
    case True{}:
      h => {==}
    case False{}:
      h => decide_rules_deny(Guard.rule_verdict(table, x, m), m, table, x, t, a, h)

def run_with_deny(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, +a: T.ClefAnswer) -> {Call.Ctx.log_only(x) == False{} : Bool} -> {Verdict.is_deny(Guard.rule_verdict(table, x, m)) == True{} : Bool} -> {Verdict.is_deny(Guard.run.with(sh, table, x, m, t, a)) == True{} : Bool}:
  match sh:
    case True{}:
      h0 => hr => {==}
    case False{}:
      h0 => hr => run_go_deny(False{}, table, x, m, Guard.after_clef(Guard.decide.go(False{}, table, x, m, t), a), h0,
        decide_sent_deny(Guard.bad(x), table, x, m, t, a, hr))

def run_m_deny(+table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, +a: T.ClefAnswer) -> {Call.Ctx.log_only(x) == False{} : Bool} -> {Verdict.is_deny(Guard.rule_verdict(table, x, m)) == True{} : Bool} -> {Verdict.is_deny(Guard.run_m(table, x, m, t, a)) == True{} : Bool}:
  h0 => hr => run_with_deny(Guard.self_hit(table, x, m), table, x, m, t, a, h0, hr)

# A rule that gives Deny, anywhere in a rule list, makes the list's verdict Deny.
def rules_deny(rs1: List<&2, T.Rule>, +r: T.Rule, +rs2: List<&2, T.Rule>, +root: T.Path, +x: T.Ctx, +xs: List<&2, T.Action>) -> {Verdict.is_deny(Guard.rule.v(r, root, x, xs)) == True{} : Bool} -> {Verdict.is_deny(Guard.rules.v(List.append(&2, T.Rule, rs1, r <> rs2), root, x, xs)) == True{} : Bool}:
  match rs1:
    case Nil{}:
      h => max_deny_left(Guard.rule.v(r, root, x, xs), Guard.rules.v(rs2, root, x, xs), h)
    case +q <> +t:
      h => max_deny_right(Guard.rule.v(q, root, x, xs), Guard.rules.v(List.append(&2, T.Rule, t, r <> rs2), root, x, xs), rules_deny(t, r, rs2, root, x, xs, h))

# A project whose rules give Deny, anywhere in the table, makes the table's verdict Deny.
def table_deny(pre: List<&2, T.Project>, +root: T.Path, +rs: List<&2, T.Rule>, +post: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>) -> {Verdict.is_deny(Guard.rules.v(rs, root, x, xs)) == True{} : Bool} -> {Verdict.is_deny(Guard.table.v(List.append(&2, T.Project, pre, T.Project{root, rs} <> post), x, xs)) == True{} : Bool}:
  match pre:
    case Nil{}:
      h => max_deny_left(Guard.rules.v(rs, root, x, xs), Guard.table.v(post, x, xs), h)
    case T.Project{+r0, +rs0} <> +t:
      h => max_deny_right(Guard.rules.v(rs0, r0, x, xs), Guard.table.v(List.append(&2, T.Project, t, T.Project{root, rs} <> post), x, xs), table_deny(t, root, rs, post, x, xs, h))

def rv_deny(+table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>) -> {Verdict.is_deny(Guard.table.v(table, x, xs)) == True{} : Bool} -> {Verdict.is_deny(Guard.rv.go(table, x, xs)) == True{} : Bool}:
  h => max_deny_left(Guard.table.v(table, x, xs), Verdict.max(Guard.builtin.list(xs, table, x), Guard.link.list(xs, x)), h)

# The generic step: a rule r of a project, anywhere in the table, whose verdict
# for m's actions is Deny, makes run_m Deny outside log-only mode.
def in_table(+pre: List<&2, T.Project>, +post: List<&2, T.Project>, +root: T.Path, +rs1: List<&2, T.Rule>, +r: T.Rule, +rs2: List<&2, T.Rule>, +x: T.Ctx, +m: T.Meaning, +t: String, +a: T.ClefAnswer) -> {Call.Ctx.log_only(x) == False{} : Bool} -> {Verdict.is_deny(Guard.rule.v(r, root, x, Meaning.actions(m))) == True{} : Bool} -> {Verdict.is_deny(Guard.run_m(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, r <> rs2)} <> post), x, m, t, a)) == True{} : Bool}:
  h0 => hr => run_m_deny(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, r <> rs2)} <> post), x, m, t, a, h0,
    rv_deny(List.append(&2, T.Project, pre, T.Project{root, List.append(&2, T.Rule, rs1, r <> rs2)} <> post), x, Meaning.actions(m),
      table_deny(pre, root, List.append(&2, T.Rule, rs1, r <> rs2), post, x, Meaning.actions(m),
        rules_deny(rs1, r, rs2, root, x, Meaning.actions(m), hr))))

# ---------------------------------------------------------------------------
# 2. Per rule kind

# Path.eq(a, b) gives under(b, a) (eq_under gives under(a, b)).
def eqsegs_prefix_l(xs: List<&2, String>, ys: List<&2, String>) -> {Path.eq.segs(xs, ys) == True{} : Bool} -> {Path.prefix(xs, ys) == True{} : Bool}:
  match xs ys:
    case Nil{} Nil{}:
      h => {==}
    case Nil{} y <> yt:
      h => {==}
    case x <> xt Nil{}:
      h => h
    case +x <> +xt +y <> +yt:
      +h => PathProof.and_intro(Path.Seg.eq(x, y), Path.prefix(xt, yt),
        PathProof.and_l(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h),
        eqsegs_prefix_l(xt, yt, PathProof.and_r(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h)))

def eq_under_r(a: T.Path, b: T.Path) -> {Path.eq(a, b) == True{} : Bool} -> {Path.under(b, a) == True{} : Bool}:
  match a b:
    case T.Path{+ad, +axs} T.Path{+bd, +bxs}:
      +h => PathProof.and_intro(Path.Seg.eq(ad, bd), Path.prefix(axs, bxs),
        PathProof.and_l(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h),
        eqsegs_prefix_l(axs, bxs, PathProof.and_r(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h)))

# An action that changes p, with p under z, hits zone z.
def one_hit(a: T.Action, +p: T.Path, +z: T.Path) -> {Path.under(p, z) == True{} : Bool} -> {Meaning.changes.one(a, p) == True{} : Bool} -> {Guard.hit.one(a, z) == True{} : Bool}:
  match a:
    case T.Write{+q}:
      hz => h => PathLaws.under_trans(q, p, z, eq_under_r(p, q, h), hz)
    case T.Delete{+q}:
      hz => h => PathLaws.under_trans(q, p, z, eq_under_r(p, q, h), hz)
    case T.MakeDir{+q}:
      hz => h => PathLaws.under_trans(q, p, z, eq_under_r(p, q, h), hz)
    case T.WriteTree{+q}:
      hz => h => PathLaws.ancestors_comparable(p, q, z, h, hz)
    case T.DeleteTree{+q}:
      hz => h => PathLaws.ancestors_comparable(p, q, z, h, hz)
    case T.MoveFrom{+q}:
      hz => h => PathLaws.ancestors_comparable(p, q, z, h, hz)
    case T.Read{q}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.ReadTree{q}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.ListDir{q}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.ChangeDir{q}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.GitRead{}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.GitRef{}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.GitPush{d, f, al, rf, un}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.NpmInstall{ps}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.RunScript{n}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.DraftCheck{sl}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Inert{}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))

def changes_hit(xs: List<&2, T.Action>, +p: T.Path, +z: T.Path) -> {Path.under(p, z) == True{} : Bool} -> {Meaning.changes.list(xs, p) == True{} : Bool} -> {Guard.hit.list(xs, z) == True{} : Bool}:
  match xs:
    case Nil{}:
      hz => h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))
    case +a <> +t:
      +hz => h => or_mono(Meaning.changes.one(a, p), Meaning.changes.list(t, p), Guard.hit.one(a, z), Guard.hit.list(t, z),
        one_hit(a, p, z, hz), changes_hit(t, p, z, hz), h)

# Each fold is True when the list holds an action for which the fold's one-step test is True.
def read_mem(as1: List<&2, T.Action>, +b: T.Action, +as2: List<&2, T.Action>, +z: T.Path) -> {Guard.read.one(b, z) == True{} : Bool} -> {Guard.read.list(List.append(&2, T.Action, as1, b <> as2), z) == True{} : Bool}:
  match as1:
    case Nil{}:
      h => PathProof.or_l(Guard.read.one(b, z), Guard.read.list(as2, z), h)
    case +c <> +t:
      h => PathProof.or_r(Guard.read.one(c, z), Guard.read.list(List.append(&2, T.Action, t, b <> as2), z), read_mem(t, b, as2, z, h))

def tdo_mem(as1: List<&2, T.Action>, +b: T.Action, +as2: List<&2, T.Action>, +root: T.Path, +z: T.Path, +x: T.Ctx) -> {Guard.tdo.one(b, root, z, x) == True{} : Bool} -> {Guard.tdo.list(List.append(&2, T.Action, as1, b <> as2), root, z, x) == True{} : Bool}:
  match as1:
    case Nil{}:
      h => PathProof.or_l(Guard.tdo.one(b, root, z, x), Guard.tdo.list(as2, root, z, x), h)
    case +c <> +t:
      h => PathProof.or_r(Guard.tdo.one(c, root, z, x), Guard.tdo.list(List.append(&2, T.Action, t, b <> as2), root, z, x), tdo_mem(t, b, as2, root, z, x, h))

def force_mem(as1: List<&2, T.Action>, +b: T.Action, +as2: List<&2, T.Action>, +root: T.Path) -> {Guard.force.one(b, root) == True{} : Bool} -> {Guard.force.list(List.append(&2, T.Action, as1, b <> as2), root) == True{} : Bool}:
  match as1:
    case Nil{}:
      h => PathProof.or_l(Guard.force.one(b, root), Guard.force.list(as2, root), h)
    case +c <> +t:
      h => PathProof.or_r(Guard.force.one(c, root), Guard.force.list(List.append(&2, T.Action, t, b <> as2), root), force_mem(t, b, as2, root, h))

def pushto_mem(as1: List<&2, T.Action>, +b: T.Action, +as2: List<&2, T.Action>, +root: T.Path, +br: String) -> {Guard.pushto.one(b, root, br) == True{} : Bool} -> {Guard.pushto.list(List.append(&2, T.Action, as1, b <> as2), root, br) == True{} : Bool}:
  match as1:
    case Nil{}:
      h => PathProof.or_l(Guard.pushto.one(b, root, br), Guard.pushto.list(as2, root, br), h)
    case +c <> +t:
      h => PathProof.or_r(Guard.pushto.one(c, root, br), Guard.pushto.list(List.append(&2, T.Action, t, b <> as2), root, br), pushto_mem(t, b, as2, root, br, h))

def elem_mem(r1: List<&2, String>, +b: String, +r2: List<&2, String>) -> {Guard.elem(b, List.append(&2, String, r1, b <> r2)) == True{} : Bool}:
  match r1:
    case Nil{}:
      PathProof.or_l(Path.Seg.eq(b, b), Guard.elem(b, r2), PathProof.seg_refl(b))
    case +h <> +t:
      PathProof.or_r(Path.Seg.eq(h, b), Guard.elem(b, List.append(&2, String, t, b <> r2)), elem_mem(t, b, r2))

# The rule verdicts
def nochange_v(+root: T.Path, +rel: String, -x: T.Ctx, +xs: List<&2, T.Action>, +p: T.Path) -> {Meaning.changes.list(xs, p) == True{} : Bool} -> {Path.under(p, Path.child(root, rel)) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.NoChange{rel}, root, x, xs)) == True{} : Bool}:
  h1 => h2 => deny_if_true(Guard.hit.list(xs, Path.child(root, rel)), msg.nochange(Path.child(root, rel)),
    changes_hit(xs, p, Path.child(root, rel), h2, h1))

def noread_v(+z: T.Path, +xs: List<&2, T.Action>) -> {Bool.or(Guard.hit.list(xs, z), Guard.read.list(xs, z)) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.noread(z, xs)) == True{} : Bool}:
  h => max_deny_left(Guard.deny_if(Bool.or(Guard.hit.list(xs, z), Guard.read.list(xs, z)), msg.noread(z)), Guard.ask_if(Guard.above.list(xs, z), msg.above(z)),
    deny_if_true(Bool.or(Guard.hit.list(xs, z), Guard.read.list(xs, z)), msg.noread(z), h))

def noread_change_v(+root: T.Path, +rel: String, -x: T.Ctx, +xs: List<&2, T.Action>, +p: T.Path) -> {Meaning.changes.list(xs, p) == True{} : Bool} -> {Path.under(p, Path.child(root, rel)) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.NoReadOrChange{rel}, root, x, xs)) == True{} : Bool}:
  h1 => h2 => noread_v(Path.child(root, rel), xs,
    PathProof.or_l(Guard.hit.list(xs, Path.child(root, rel)), Guard.read.list(xs, Path.child(root, rel)), changes_hit(xs, p, Path.child(root, rel), h2, h1)))

def noread_read_v(+root: T.Path, +rel: String, +x: T.Ctx, +m: T.Meaning, +as1: List<&2, T.Action>, +q: T.Path, +as2: List<&2, T.Action>) -> {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Read{q} <> as2) : List<&2, T.Action>} -> {Path.under(q, Path.child(root, rel)) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.NoReadOrChange{rel}, root, x, Meaning.actions(m))) == True{} : Bool}:
  h1 => h2 =>
    %Equal.sym(List<&2, T.Action>, Meaning.actions(m), List.append(&2, T.Action, as1, T.Read{q} <> as2), h1) : {Verdict.is_deny(Guard.rule.v(T.NoReadOrChange{rel}, root, x, _)) == True{} : Bool}
    noread_v(Path.child(root, rel), List.append(&2, T.Action, as1, T.Read{q} <> as2),
      PathProof.or_r(Guard.hit.list(List.append(&2, T.Action, as1, T.Read{q} <> as2), Path.child(root, rel)), Guard.read.list(List.append(&2, T.Action, as1, T.Read{q} <> as2), Path.child(root, rel)),
        read_mem(as1, T.Read{q}, as2, Path.child(root, rel), h2)))

def tdo_one(+q: T.Path, +root: T.Path, +z: T.Path, +x: T.Ctx) -> {Path.overlaps(q, root) == True{} : Bool} -> {Path.under(q, z) == False{} : Bool} -> {Guard.tdo.one(T.DeleteTree{q}, root, z, x) == True{} : Bool}:
  h1 => h2 => PathProof.and_intro(Guard.tdo.scope(q, root, x), Bool.not(Path.under(q, z)),
    PathProof.or_l(Path.overlaps(q, root), Bool.or(Path.under(Call.Ctx.cwd(x), root), Path.is_sentinel(Call.Ctx.cwd(x))), h1),
    not_false(Path.under(q, z), h2))

def tdo_v(+root: T.Path, +rel: String, +x: T.Ctx, +m: T.Meaning, +as1: List<&2, T.Action>, +q: T.Path, +as2: List<&2, T.Action>) -> {Meaning.actions(m) == List.append(&2, T.Action, as1, T.DeleteTree{q} <> as2) : List<&2, T.Action>} -> {Path.overlaps(q, root) == True{} : Bool} -> {Path.under(q, Path.child(root, rel)) == False{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.TreeDeleteOnlyUnder{rel}, root, x, Meaning.actions(m))) == True{} : Bool}:
  h1 => h2 => h3 =>
    %Equal.sym(List<&2, T.Action>, Meaning.actions(m), List.append(&2, T.Action, as1, T.DeleteTree{q} <> as2), h1) : {Verdict.is_deny(Guard.rule.v(T.TreeDeleteOnlyUnder{rel}, root, x, _)) == True{} : Bool}
    deny_if_true(Guard.tdo.list(List.append(&2, T.Action, as1, T.DeleteTree{q} <> as2), root, Path.child(root, rel), x), msg.tdo(root, Path.child(root, rel)),
      tdo_mem(as1, T.DeleteTree{q}, as2, root, Path.child(root, rel), x, tdo_one(q, root, Path.child(root, rel), x, h2, h3)))

def force_one(+dir: T.Path, -all: Bool, -refs: List<&2, String>, -unsure: Bool, +root: T.Path) -> {Path.under(dir, root) == True{} : Bool} -> {Guard.force.one(T.GitPush{dir, True{}, all, refs, unsure}, root) == True{} : Bool}:
  h => PathProof.and_intro(Guard.push.scope(dir, root), True{}, PathProof.or_l(Path.under(dir, root), Path.is_sentinel(dir), h), {==})

def force_v(+root: T.Path, -x: T.Ctx, +m: T.Meaning, +as1: List<&2, T.Action>, +dir: T.Path, +all: Bool, +refs: List<&2, String>, +unsure: Bool, +as2: List<&2, T.Action>) -> {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, True{}, all, refs, unsure} <> as2) : List<&2, T.Action>} -> {Path.under(dir, root) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.NoForcePush{}, root, x, Meaning.actions(m))) == True{} : Bool}:
  h1 => h2 =>
    %Equal.sym(List<&2, T.Action>, Meaning.actions(m), List.append(&2, T.Action, as1, T.GitPush{dir, True{}, all, refs, unsure} <> as2), h1) : {Verdict.is_deny(Guard.rule.v(T.NoForcePush{}, root, x, _)) == True{} : Bool}
    deny_if_true(Guard.force.list(List.append(&2, T.Action, as1, T.GitPush{dir, True{}, all, refs, unsure} <> as2), root), msg.force(root),
      force_mem(as1, T.GitPush{dir, True{}, all, refs, unsure}, as2, root, force_one(dir, all, refs, unsure, root, h2)))

def pushto_one(+dir: T.Path, -force: Bool, -all: Bool, +r1: List<&2, String>, +b: String, +r2: List<&2, String>, -unsure: Bool, +root: T.Path) -> {Path.under(dir, root) == True{} : Bool} -> {Guard.pushto.one(T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure}, root, b) == True{} : Bool}:
  h => PathProof.and_intro(Guard.push.scope(dir, root), Guard.elem(b, List.append(&2, String, r1, b <> r2)),
    PathProof.or_l(Path.under(dir, root), Path.is_sentinel(dir), h), elem_mem(r1, b, r2))

def pushto_v(+root: T.Path, +b: String, -x: T.Ctx, +m: T.Meaning, +as1: List<&2, T.Action>, +dir: T.Path, +force: Bool, +all: Bool, +r1: List<&2, String>, +r2: List<&2, String>, +unsure: Bool, +as2: List<&2, T.Action>) -> {Meaning.actions(m) == List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2) : List<&2, T.Action>} -> {Path.under(dir, root) == True{} : Bool} -> {Verdict.is_deny(Guard.rule.v(T.NoPushTo{b}, root, x, Meaning.actions(m))) == True{} : Bool}:
  h1 => h2 =>
    %Equal.sym(List<&2, T.Action>, Meaning.actions(m), List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2), h1) : {Verdict.is_deny(Guard.rule.v(T.NoPushTo{b}, root, x, _)) == True{} : Bool}
    max_deny_left(Guard.deny_if(Guard.pushto.list(List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2), root, b), msg.pushto(b, root)),
      Guard.ask_if(Guard.unsure.list(List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2), root), msg.unsure(b)),
      deny_if_true(Guard.pushto.list(List.append(&2, T.Action, as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure} <> as2), root, b), msg.pushto(b, root),
        pushto_mem(as1, T.GitPush{dir, force, all, List.append(&2, String, r1, b <> r2), unsure}, as2, root, b, pushto_one(dir, force, all, r1, b, r2, unsure, root, h2))))

# ---------------------------------------------------------------------------
# 3. read_allowed: Known{[Read{p}]} computes to Allow step by step

def read_allow.fin(c: Bool, -r: String) -> {c == False{} : Bool} -> {Verdict.is_allow(Verdict.max(Guard.deny_if(Bool.or(c, False{}), r), T.Allow{})) == True{} : Bool}:
  match c:
    case True{}:
      h => Empty.absurd({Verdict.is_allow(Verdict.max(Guard.deny_if(Bool.or(True{}, False{}), r), T.Allow{})) == True{} : Bool}, true_ne_false(h))
    case False{}:
      h => {==}

# The rule verdicts for a plain read: only NoReadOrChange depends on p.
def noread_read_allow(+z: T.Path, +p: T.Path) -> {Path.under(p, z) == False{} : Bool} -> {Verdict.is_allow(Guard.rule.noread(z, [T.Read{p}])) == True{} : Bool}:
  h => read_allow.fin(Path.under(p, z), msg.noread(z), h)

def rule_read_allow(r: T.Rule, +root: T.Path, -x: T.Ctx, +p: T.Path) -> {Guard.names.rule(r, root, p) == True{} : Bool} -> {Verdict.is_allow(Guard.rule.v(r, root, x, [T.Read{p}])) == True{} : Bool}:
  match r:
    case T.NoChange{rel}:
      h => {==}
    case T.NoReadOrChange{+rel}:
      h => noread_read_allow(Path.child(root, rel), p, not_or_l(Path.under(p, Path.child(root, rel)), Path.under(Path.child(root, rel), p), h))
    case T.TreeDeleteOnlyUnder{rel}:
      h => {==}
    case T.NoForcePush{}:
      h => {==}
    case T.NoPushTo{b}:
      h => {==}
    case T.TrustScript{n}:
      h => {==}

def rules_read_allow(rs: List<&2, T.Rule>, +root: T.Path, +x: T.Ctx, +p: T.Path) -> {Guard.names.rules(rs, root, p) == True{} : Bool} -> {Verdict.is_allow(Guard.rules.v(rs, root, x, [T.Read{p}])) == True{} : Bool}:
  match rs:
    case Nil{}:
      h => {==}
    case +r <> +t:
      +h => max_allow(Guard.rule.v(r, root, x, [T.Read{p}]), Guard.rules.v(t, root, x, [T.Read{p}]),
        rule_read_allow(r, root, x, p, PathProof.and_l(Guard.names.rule(r, root, p), Guard.names.rules(t, root, p), h)),
        rules_read_allow(t, root, x, p, PathProof.and_r(Guard.names.rule(r, root, p), Guard.names.rules(t, root, p), h)))

def table_read_allow(table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> {Guard.no_rule_names(table, p) == True{} : Bool} -> {Verdict.is_allow(Guard.table.v(table, x, [T.Read{p}])) == True{} : Bool}:
  match table:
    case Nil{}:
      h => {==}
    case T.Project{+root, +rs} <> +t:
      +h => max_allow(Guard.rules.v(rs, root, x, [T.Read{p}]), Guard.table.v(t, x, [T.Read{p}]),
        rules_read_allow(rs, root, x, p, PathProof.and_l(Guard.names.rules(rs, root, p), Guard.no_rule_names(t, p), h)),
        table_read_allow(t, x, p, PathProof.and_r(Guard.names.rules(rs, root, p), Guard.no_rule_names(t, p), h)))

# A Read is in no zone, whatever the zones are.
def zones_read(+p: T.Path, zs: List<&2, T.Path>) -> {Guard.hit.zones(T.Read{p}, zs) == False{} : Bool}:
  match zs:
    case Nil{}:
      {==}
    case z <> t:
      zones_read(p, t)

# The built-in rows: a Read is in no attr zone and changes no file by name
# (change.attr and change.hookcfg compute to False for a Read).
def builtin_read.fin(c2: Bool) -> {c2 == False{} : Bool} -> {Verdict.is_allow(Verdict.max(Verdict.max(Guard.ask_if(Bool.or(c2, False{}), msg.attr()), Verdict.max(Guard.ask_if(False{}, msg.hookcfg()), T.Allow{})), T.Allow{})) == True{} : Bool}:
  match c2:
    case False{}:
      h2 => {==}
    case True{}:
      h2 => Empty.absurd({Verdict.is_allow(Verdict.max(Verdict.max(Guard.ask_if(Bool.or(True{}, False{}), msg.attr()), Verdict.max(Guard.ask_if(False{}, msg.hookcfg()), T.Allow{})), T.Allow{})) == True{} : Bool}, true_ne_false(h2))

def builtin_read(+table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> {Verdict.is_allow(Guard.builtin.list([T.Read{p}], table, x)) == True{} : Bool}:
  builtin_read.fin(Guard.hit.zones(T.Read{p}, Guard.attr.zones(table, x)), zones_read(p, Guard.attr.zones(table, x)))

# The link row: p is behind no link.
def link_read.fin(c: Bool, -r: String) -> {c == True{} : Bool} -> {Verdict.is_allow(Verdict.max(Guard.ask_unless(c, r), T.Allow{})) == True{} : Bool}:
  match c:
    case True{}:
      h => {==}
    case False{}:
      h => Empty.absurd({False{} == True{} : Bool}, PathProof.false_ne_true(h))

def rv_read_allow(+table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> {Guard.no_rule_names(table, p) == True{} : Bool} -> {Guard.no_link(x, p) == True{} : Bool} -> {Verdict.is_allow(Guard.rule_verdict(table, x, T.Known{[T.Read{p}]})) == True{} : Bool}:
  h6 => h7 => max_allow(Guard.table.v(table, x, [T.Read{p}]), Verdict.max(Guard.builtin.list([T.Read{p}], table, x), Guard.link.list([T.Read{p}], x)),
    table_read_allow(table, x, p, h6),
    max_allow(Guard.builtin.list([T.Read{p}], table, x), Guard.link.list([T.Read{p}], x),
      builtin_read(table, x, p),
      link_read.fin(Guard.no_link(x, p), msg.link(p), h7)))

# decide: no self hit, both folders read, rules Allow, no double-check zone.
def veto_read.fin(z: Bool, -st: Bool, -t: String, -a: T.ClefAnswer) -> {z == False{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.veto(Bool.or(z, False{}), st, t), a)) == True{} : Bool}:
  match z:
    case True{}:
      h => Empty.absurd({Verdict.is_allow(Guard.after_clef(Guard.decide.veto(Bool.or(True{}, False{}), st, t), a)) == True{} : Bool}, true_ne_false(h))
    case False{}:
      h => {==}

def rules_read.fin(v: T.Verdict, +table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>, +t: String, -a: T.ClefAnswer) -> {Verdict.is_allow(v) == True{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.veto(Guard.zone.acts(xs, table), Bool.and(Call.Ctx.shell_tool(x), Bool.not(Call.Ctx.agent(x))), t), a)) == True{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.rules(v, T.Known{xs}, table, x, t), a)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      hv => hz => hz
    case T.Ask{r}:
      hv => hz => Empty.absurd({Verdict.is_allow(Guard.after_clef(Guard.decide.rules(T.Ask{r}, T.Known{xs}, table, x, t), a)) == True{} : Bool}, PathProof.false_ne_true(hv))
    case T.Deny{r}:
      hv => hz => Empty.absurd({Verdict.is_allow(Guard.after_clef(Guard.decide.rules(T.Deny{r}, T.Known{xs}, table, x, t), a)) == True{} : Bool}, PathProof.false_ne_true(hv))

def sent_read.fin(b: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -xs: List<&2, T.Action>, -t: String, -a: T.ClefAnswer) -> {b == False{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.rules(Guard.rule_verdict(table, x, T.Known{xs}), T.Known{xs}, table, x, t), a)) == True{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.sent(b, False{}, table, x, T.Known{xs}, t), a)) == True{} : Bool}:
  match b:
    case True{}:
      hb => hr => Empty.absurd({Verdict.is_allow(Guard.after_clef(Guard.decide.sent(True{}, False{}, table, x, T.Known{xs}, t), a)) == True{} : Bool}, true_ne_false(hb))
    case False{}:
      hb => hr => hr

def relax_allow(c: Bool) -> {Verdict.is_allow(Guard.relax(c, T.Allow{})) == True{} : Bool}:
  match c:
    case True{}:
      {==}
    case False{}:
      {==}

def go_read.fin(v: T.Verdict, -table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>) -> {Verdict.is_allow(v) == True{} : Bool} -> {Verdict.is_allow(Guard.run.go(False{}, table, x, T.Known{xs}, v)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      h => relax_allow(Guard.relax.cond(x, T.Known{xs}))
    case T.Ask{r}:
      h => Empty.absurd({Verdict.is_allow(Guard.run.go(False{}, table, x, T.Known{xs}, T.Ask{r})) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Deny{r}:
      h => Empty.absurd({Verdict.is_allow(Guard.run.go(False{}, table, x, T.Known{xs}, T.Deny{r})) == True{} : Bool}, PathProof.false_ne_true(h))

def with_read.fin(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +xs: List<&2, T.Action>, +t: String, +a: T.ClefAnswer) -> {sh == False{} : Bool} -> {Verdict.is_allow(Guard.after_clef(Guard.decide.go(False{}, table, x, T.Known{xs}, t), a)) == True{} : Bool} -> {Verdict.is_allow(Guard.run.with(sh, table, x, T.Known{xs}, t, a)) == True{} : Bool}:
  match sh:
    case True{}:
      hs => hd => Empty.absurd({Verdict.is_allow(Guard.run.with(True{}, table, x, T.Known{xs}, t, a)) == True{} : Bool}, true_ne_false(hs))
    case False{}:
      hs => hd => go_read.fin(Guard.after_clef(Guard.decide.go(False{}, table, x, T.Known{xs}, t), a), table, x, xs, hd)

# ---------------------------------------------------------------------------
# The laws

def Laws.rule_nochange_denies(pre, post, root, rs1, rs2, rel, x, m, t, a, p, h0, h1, h2):
  in_table(pre, post, root, rs1, T.NoChange{rel}, rs2, x, m, t, a, h0,
    nochange_v(root, rel, x, Meaning.actions(m), p, h1, h2))

def Laws.rule_noread_change_denies(pre, post, root, rs1, rs2, rel, x, m, t, a, p, h0, h1, h2):
  in_table(pre, post, root, rs1, T.NoReadOrChange{rel}, rs2, x, m, t, a, h0,
    noread_change_v(root, rel, x, Meaning.actions(m), p, h1, h2))

def Laws.rule_noread_read_denies(pre, post, root, rs1, rs2, rel, x, m, t, a, as1, q, as2, h0, h1, h2):
  in_table(pre, post, root, rs1, T.NoReadOrChange{rel}, rs2, x, m, t, a, h0,
    noread_read_v(root, rel, x, m, as1, q, as2, h1, h2))

def Laws.rule_tree_delete_denies(pre, post, root, rs1, rs2, rel, x, m, t, a, as1, q, as2, h0, h1, h2, h3):
  in_table(pre, post, root, rs1, T.TreeDeleteOnlyUnder{rel}, rs2, x, m, t, a, h0,
    tdo_v(root, rel, x, m, as1, q, as2, h1, h2, h3))

def Laws.rule_force_push_denies(pre, post, root, rs1, rs2, x, m, t, a, as1, dir, all, refs, unsure, as2, h0, h1, h2):
  in_table(pre, post, root, rs1, T.NoForcePush{}, rs2, x, m, t, a, h0,
    force_v(root, x, m, as1, dir, all, refs, unsure, as2, h1, h2))

def Laws.rule_push_to_denies(pre, post, root, rs1, rs2, b, x, m, t, a, as1, dir, force, all, r1, r2, unsure, as2, h0, h1, h2):
  in_table(pre, post, root, rs1, T.NoPushTo{b}, rs2, x, m, t, a, h0,
    pushto_v(root, b, x, m, as1, dir, force, all, r1, r2, unsure, as2, h1, h2))

def Laws.read_allowed(table, x, t, a, p, h0, h0b, h2, h4, h6, h7):
  with_read.fin(Guard.self_hit(table, x, T.Known{[T.Read{p}]}), table, x, [T.Read{p}], t, a,
    or_false_r(Path.overlaps(p, Protect.key_file(Call.Ctx.home(x))), h4),
    sent_read.fin(Guard.bad(x), table, x, [T.Read{p}], t, a,
      or_false(Path.is_sentinel(Call.Ctx.root(x)), Path.is_sentinel(Call.Ctx.home(x)), h0, h0b),
      rules_read.fin(Guard.rule_verdict(table, x, T.Known{[T.Read{p}]}), table, x, [T.Read{p}], t, a,
        rv_read_allow(table, x, p, h6, h7),
        veto_read.fin(Guard.in_rule_zone(table, p), Bool.and(Call.Ctx.shell_tool(x), Bool.not(Call.Ctx.agent(x))), t, a, h2))))
