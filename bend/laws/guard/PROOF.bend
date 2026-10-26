# bend-guard: proofs of laws/guard/LAWS.bend. Built bottom-up from small
# lemmas, one per Guard step (protect, relax, finish, floor, after_clef), each
# a case split; the laws compose them along run.go (bend/NOTES.md section 8):
#   run.go(sh, table, x, m, v) = protect(sh, .., relax(relax.cond(x, m), finish(x, floor(v, m))))

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ../../core/Meaning.bend as Meaning
import ../../core/Call.bend as Call
import ../../core/Guard.bend as Guard
import ../verdict/LAWS.bend as VerdictLaws
import ../verdict/PROOF.bend as VerdictProof
import ./LAWS.bend as Laws

# ---------------------------------------------------------------------------
# Bool and rank facts

def BoolT(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def false_ne_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : BoolT(_)
  Unit{}

def true_ne_false(e: {True{} == False{} : Bool}) -> Empty:
  false_ne_true(Equal.sym(Bool, True{}, False{}, e))

def and_false_r(b: Bool) -> {Bool.and(b, False{}) == False{} : Bool}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def rank_refl(v: T.Verdict) -> {Nat.is_le(Verdict.rank(v), Verdict.rank(v)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      {==}
    case T.Ask{r}:
      {==}
    case T.Deny{r}:
      {==}

def rank_ge_zero(v: T.Verdict) -> {Nat.is_le(0n, Verdict.rank(v)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      {==}
    case T.Ask{r}:
      {==}
    case T.Deny{r}:
      {==}

def rank_le_two(v: T.Verdict) -> {Nat.is_le(Verdict.rank(v), 2n) == True{} : Bool}:
  match v:
    case T.Allow{}:
      {==}
    case T.Ask{r}:
      {==}
    case T.Deny{r}:
      {==}

# ---------------------------------------------------------------------------
# unknown_never_allowed: no step turns a non-Allow into Allow for an Unknown
# meaning when the user did not say yes.

def prot_na(sh: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -m: T.Meaning, -v: T.Verdict, hv: {Verdict.is_allow(v) == False{} : Bool}) -> {Verdict.is_allow(Guard.protect(sh, table, x, m, v)) == False{} : Bool}:
  match sh:
    case True{}:
      {==}
    case False{}:
      hv

def relax_na(c: Bool, -v: T.Verdict, hc: {c == False{} : Bool}, hv: {Verdict.is_allow(v) == False{} : Bool}) -> {Verdict.is_allow(Guard.relax(c, v)) == False{} : Bool}:
  match c:
    case True{}:
      Empty.absurd({Verdict.is_allow(T.Allow{}) == False{} : Bool}, true_ne_false(hc))
    case False{}:
      hv

# log-only never relaxes an Unknown meaning
def rc_false(x: T.Ctx, m: T.Meaning, h1: {Meaning.is_unknown(m) == True{} : Bool}) -> {Guard.relax.cond(x, m) == False{} : Bool}:
  match m:
    case T.Known{xs}:
      Empty.absurd({Guard.relax.cond(x, T.Known{xs}) == False{} : Bool}, false_ne_true(h1))
    case T.Unknown{why, ks}:
      and_false_r(Call.Ctx.log_only(x))

def fin_na.ask(s: T.Stage, ca: Bool, dy: Bool, -r: String, hdy: {dy == False{} : Bool}) -> {Verdict.is_allow(Guard.finish.ask(s, ca, dy, r)) == False{} : Bool}:
  match s:
    case T.AtCheck{}:
      match ca:
        case True{}:
          {==}
        case False{}:
          {==}
    case T.AtCall{asked, consent}:
      match dy:
        case True{}:
          Empty.absurd({Verdict.is_allow(Guard.finish.call(True{}, r)) == False{} : Bool}, true_ne_false(hdy))
        case False{}:
          {==}

def fin_na(s: T.Stage, ca: Bool, dy: Bool, v: T.Verdict, hdy: {dy == False{} : Bool}, hv: {Verdict.is_allow(v) == False{} : Bool}) -> {Verdict.is_allow(Guard.finish.go(s, ca, dy, v)) == False{} : Bool}:
  match v:
    case T.Allow{}:
      Empty.absurd({Verdict.is_allow(Guard.finish.go(s, ca, dy, T.Allow{})) == False{} : Bool}, true_ne_false(hv))
    case T.Ask{r}:
      fin_na.ask(s, ca, dy, r, hdy)
    case T.Deny{r}:
      {==}

def floor_na(v: T.Verdict, m: T.Meaning, h1: {Meaning.is_unknown(m) == True{} : Bool}) -> {Verdict.is_allow(Guard.floor(v, m)) == False{} : Bool}:
  match v:
    case T.Allow{}:
      match m:
        case T.Known{xs}:
          Empty.absurd({Verdict.is_allow(Guard.floor(T.Allow{}, T.Known{xs})) == False{} : Bool}, false_ne_true(h1))
        case T.Unknown{why, ks}:
          {==}
    case T.Ask{r}:
      {==}
    case T.Deny{r}:
      {==}

# run.go never gives Allow, for any self-hit flag sh and any step verdict v
def run_na(sh: Bool, -table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +v: T.Verdict, +h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Call.Ctx.dan_said_yes(x) == False{} : Bool}) -> {Verdict.is_allow(Guard.run.go(sh, table, x, m, v)) == False{} : Bool}:
  prot_na(sh, table, x, m, Guard.relax(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m))),
    relax_na(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m)), rc_false(x, m, h1),
      fin_na(Call.Ctx.stage(x), Guard.can_ask(x), Call.Ctx.dan_said_yes(x), Guard.floor(v, m), h2, floor_na(v, m, h1))))

def Laws.unknown_never_allowed(table, x, m, t, a, h1, h2):
  run_na(Guard.self_hit(table, x, m), table, x, m, Guard.after_clef(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t), a), h1, h2)

# ---------------------------------------------------------------------------
# no_ask_without_person: with nobody to ask, finish turns every Ask into
# Allow or Deny, and relax and protect only give Allow or Deny.

def prot_nk(sh: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -m: T.Meaning, -v: T.Verdict, hv: {Verdict.is_ask(v) == False{} : Bool}) -> {Verdict.is_ask(Guard.protect(sh, table, x, m, v)) == False{} : Bool}:
  match sh:
    case True{}:
      {==}
    case False{}:
      hv

def relax_nk(c: Bool, -v: T.Verdict, hv: {Verdict.is_ask(v) == False{} : Bool}) -> {Verdict.is_ask(Guard.relax(c, v)) == False{} : Bool}:
  match c:
    case True{}:
      {==}
    case False{}:
      hv

def fin_nk.ask(s: T.Stage, ca: Bool, dy: Bool, -r: String, hca: {ca == False{} : Bool}) -> {Verdict.is_ask(Guard.finish.ask(s, ca, dy, r)) == False{} : Bool}:
  match s:
    case T.AtCheck{}:
      match ca:
        case True{}:
          Empty.absurd({Verdict.is_ask(Guard.finish.check(True{}, r)) == False{} : Bool}, true_ne_false(hca))
        case False{}:
          {==}
    case T.AtCall{asked, consent}:
      match dy:
        case True{}:
          {==}
        case False{}:
          {==}

def fin_nk(s: T.Stage, ca: Bool, dy: Bool, v: T.Verdict, hca: {ca == False{} : Bool}) -> {Verdict.is_ask(Guard.finish.go(s, ca, dy, v)) == False{} : Bool}:
  match v:
    case T.Allow{}:
      {==}
    case T.Ask{r}:
      fin_nk.ask(s, ca, dy, r, hca)
    case T.Deny{r}:
      {==}

# run.go never gives Ask, for any self-hit flag sh and any step verdict v
def run_nk(sh: Bool, -table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +v: T.Verdict, h: {Guard.can_ask(x) == False{} : Bool}) -> {Verdict.is_ask(Guard.run.go(sh, table, x, m, v)) == False{} : Bool}:
  prot_nk(sh, table, x, m, Guard.relax(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m))),
    relax_nk(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v, m)),
      fin_nk(Call.Ctx.stage(x), Guard.can_ask(x), Call.Ctx.dan_said_yes(x), Guard.floor(v, m), h)))

def Laws.no_ask_without_person(table, x, m, t, a, h):
  run_nk(Guard.self_hit(table, x, m), table, x, m, Guard.after_clef(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t), a), h)

# ---------------------------------------------------------------------------
# combine_monotone: combine is Verdict.max(base, clef.x(q, a))

def Laws.combine_monotone(base, q, a):
  VerdictLaws.max_ge_left(base, Guard.clef.x(q, a))

# ---------------------------------------------------------------------------
# finish_monotone, over free stage, can_ask and dan_said_yes

# two asks settle the same way (only the reasons differ)
def fin_mono.ask(s: T.Stage, ca: Bool, dy: Bool, -r1: String, -r2: String) -> {Nat.is_le(Verdict.rank(Guard.finish.ask(s, ca, dy, r1)), Verdict.rank(Guard.finish.ask(s, ca, dy, r2))) == True{} : Bool}:
  match s:
    case T.AtCheck{}:
      match ca:
        case True{}:
          {==}
        case False{}:
          {==}
    case T.AtCall{asked, consent}:
      match dy:
        case True{}:
          {==}
        case False{}:
          {==}

def fin_mono(s: T.Stage, ca: Bool, dy: Bool, v1: T.Verdict, v2: T.Verdict, h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}) -> {Nat.is_le(Verdict.rank(Guard.finish.go(s, ca, dy, v1)), Verdict.rank(Guard.finish.go(s, ca, dy, v2))) == True{} : Bool}:
  match v1 v2:
    case T.Allow{} T.Allow{}:
      {==}
    case T.Allow{} T.Ask{r2}:
      rank_ge_zero(Guard.finish.ask(s, ca, dy, r2))
    case T.Allow{} T.Deny{r2}:
      {==}
    case T.Ask{r1} T.Allow{}:
      Empty.absurd({Nat.is_le(Verdict.rank(Guard.finish.ask(s, ca, dy, r1)), 0n) == True{} : Bool}, false_ne_true(h))
    case T.Ask{r1} T.Ask{r2}:
      fin_mono.ask(s, ca, dy, r1, r2)
    case T.Ask{r1} T.Deny{r2}:
      rank_le_two(Guard.finish.ask(s, ca, dy, r1))
    case T.Deny{r1} T.Allow{}:
      Empty.absurd({Nat.is_le(2n, 0n) == True{} : Bool}, false_ne_true(h))
    case T.Deny{r1} T.Ask{r2}:
      Empty.absurd({Nat.is_le(2n, Verdict.rank(Guard.finish.ask(s, ca, dy, r2))) == True{} : Bool}, false_ne_true(h))
    case T.Deny{r1} T.Deny{r2}:
      {==}

def Laws.finish_monotone(x, v1, v2, h):
  fin_mono(Call.Ctx.stage(x), Guard.can_ask(x), Call.Ctx.dan_said_yes(x), v1, v2, h)

# ---------------------------------------------------------------------------
# clef_cannot_loosen: both sides are run.go over the same decide step S;
# (1) the step's base is at most the step after Clef, (2) run.go is monotone.

def floor_mono(v1: T.Verdict, v2: T.Verdict, m: T.Meaning, h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}) -> {Nat.is_le(Verdict.rank(Guard.floor(v1, m)), Verdict.rank(Guard.floor(v2, m))) == True{} : Bool}:
  match v1 v2:
    case T.Allow{} T.Allow{}:
      rank_refl(Guard.floor.allow(m))
    case T.Allow{} T.Ask{r2}:
      match m:
        case T.Known{xs}:
          {==}
        case T.Unknown{why, ks}:
          {==}
    case T.Allow{} T.Deny{r2}:
      rank_le_two(Guard.floor.allow(m))
    case T.Ask{r1} T.Allow{}:
      Empty.absurd({Nat.is_le(1n, Verdict.rank(Guard.floor.allow(m))) == True{} : Bool}, false_ne_true(h))
    case T.Ask{r1} T.Ask{r2}:
      {==}
    case T.Ask{r1} T.Deny{r2}:
      {==}
    case T.Deny{r1} T.Allow{}:
      Empty.absurd({Nat.is_le(2n, Verdict.rank(Guard.floor.allow(m))) == True{} : Bool}, false_ne_true(h))
    case T.Deny{r1} T.Ask{r2}:
      Empty.absurd({Nat.is_le(2n, 1n) == True{} : Bool}, false_ne_true(h))
    case T.Deny{r1} T.Deny{r2}:
      {==}

def relax_mono(c: Bool, -v1: T.Verdict, -v2: T.Verdict, h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}) -> {Nat.is_le(Verdict.rank(Guard.relax(c, v1)), Verdict.rank(Guard.relax(c, v2))) == True{} : Bool}:
  match c:
    case True{}:
      {==}
    case False{}:
      h

def prot_mono(sh: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -m: T.Meaning, -v1: T.Verdict, -v2: T.Verdict, h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}) -> {Nat.is_le(Verdict.rank(Guard.protect(sh, table, x, m, v1)), Verdict.rank(Guard.protect(sh, table, x, m, v2))) == True{} : Bool}:
  match sh:
    case True{}:
      {==}
    case False{}:
      h

def run_mono(sh: Bool, -table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +v1: T.Verdict, +v2: T.Verdict, h: {Nat.is_le(Verdict.rank(v1), Verdict.rank(v2)) == True{} : Bool}) -> {Nat.is_le(Verdict.rank(Guard.run.go(sh, table, x, m, v1)), Verdict.rank(Guard.run.go(sh, table, x, m, v2))) == True{} : Bool}:
  prot_mono(sh, table, x, m, Guard.relax(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v1, m))), Guard.relax(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v2, m))),
    relax_mono(Guard.relax.cond(x, m), Guard.finish(x, Guard.floor(v1, m)), Guard.finish(x, Guard.floor(v2, m)),
      fin_mono(Call.Ctx.stage(x), Guard.can_ask(x), Call.Ctx.dan_said_yes(x), Guard.floor(v1, m), Guard.floor(v2, m),
        floor_mono(v1, v2, m, h))))

def base_le(s: T.Step, a: T.ClefAnswer) -> {Nat.is_le(Verdict.rank(Guard.step_base(s)), Verdict.rank(Guard.after_clef(s, a))) == True{} : Bool}:
  match s:
    case T.Step.Done{v}:
      rank_refl(v)
    case T.Consult{q, b, t}:
      VerdictLaws.max_ge_left(b, Guard.clef.x(q, a))

def Laws.clef_cannot_loosen(table, x, m, t, a):
  run_mono(Guard.self_hit(table, x, m), table, x, m,
    Guard.step_base(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t)),
    Guard.after_clef(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t), a),
    base_le(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t), a))

# ---------------------------------------------------------------------------
# named_noread_unknown_denied: decide gives Done{Deny} at every step it can
# stop (folders, self-protection, a rule Deny, or the no-read check for an
# Unknown meaning), and run.go keeps a Deny for an Unknown meaning.

def nr_mean(m: T.Meaning, -v: T.Verdict, +table: List<&2, T.Project>, +x: T.Ctx, +t: String, -a: T.ClefAnswer, h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Guard.noread.hit(table, x, t) == True{} : Bool}) -> {Verdict.is_deny(Guard.after_clef(Guard.decide.meaning(m, v, table, x, t), a)) == True{} : Bool}:
  match m:
    case T.Known{xs}:
      Empty.absurd({Verdict.is_deny(Guard.after_clef(Guard.decide.meaning(T.Known{xs}, v, table, x, t), a)) == True{} : Bool}, false_ne_true(h1))
    case T.Unknown{why, ks}:
      %Equal.sym(Bool, Guard.noread.hit(table, x, t), True{}, h2) : {Verdict.is_deny(Guard.after_clef(Guard.decide.noread(_, why, v, table, x, t), a)) == True{} : Bool}
      {==}

def nr_rules(v: T.Verdict, +m: T.Meaning, +table: List<&2, T.Project>, +x: T.Ctx, +t: String, -a: T.ClefAnswer, h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Guard.noread.hit(table, x, t) == True{} : Bool}) -> {Verdict.is_deny(Guard.after_clef(Guard.decide.rules(v, m, table, x, t), a)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      nr_mean(m, T.Allow{}, table, x, t, a, h1, h2)
    case T.Ask{r}:
      nr_mean(m, T.Ask{r}, table, x, t, a, h1, h2)
    case T.Deny{r}:
      {==}

def nr_self(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, -a: T.ClefAnswer, h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Guard.noread.hit(table, x, t) == True{} : Bool}) -> {Verdict.is_deny(Guard.after_clef(Guard.decide.self(sh, table, x, m, t), a)) == True{} : Bool}:
  match sh:
    case True{}:
      {==}
    case False{}:
      nr_rules(Guard.rule_verdict(table, x, m), m, table, x, t, a, h1, h2)

def nr_sent(b: Bool, sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, -a: T.ClefAnswer, h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Guard.noread.hit(table, x, t) == True{} : Bool}) -> {Verdict.is_deny(Guard.after_clef(Guard.decide.sent(b, sh, table, x, m, t), a)) == True{} : Bool}:
  match b:
    case True{}:
      {==}
    case False{}:
      nr_self(sh, table, x, m, t, a, h1, h2)

def nr_step(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, -a: T.ClefAnswer, h1: {Meaning.is_unknown(m) == True{} : Bool}, h2: {Guard.noread.hit(table, x, t) == True{} : Bool}) -> {Verdict.is_deny(Guard.after_clef(Guard.decide.go(sh, table, x, m, t), a)) == True{} : Bool}:
  nr_sent(Guard.bad(x), sh, table, x, m, t, a, h1, h2)

# a Deny passes relax (when its condition is False) and protect
def nr_relax(c: Bool, sh: Bool, -table: List<&2, T.Project>, -x: T.Ctx, -m: T.Meaning, -r: String, hc: {c == False{} : Bool}) -> {Verdict.is_deny(Guard.protect(sh, table, x, m, Guard.relax(c, T.Deny{r}))) == True{} : Bool}:
  match c:
    case True{}:
      Empty.absurd({Verdict.is_deny(Guard.protect(sh, table, x, m, Guard.relax(True{}, T.Deny{r}))) == True{} : Bool}, true_ne_false(hc))
    case False{}:
      match sh:
        case True{}:
          {==}
        case False{}:
          {==}

# run.go keeps a Deny for an Unknown meaning, for any self-hit flag sh
def nr_go(sh: Bool, -table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, v: T.Verdict, h1: {Meaning.is_unknown(m) == True{} : Bool}, hv: {Verdict.is_deny(v) == True{} : Bool}) -> {Verdict.is_deny(Guard.run.go(sh, table, x, m, v)) == True{} : Bool}:
  match v:
    case T.Allow{}:
      Empty.absurd({Verdict.is_deny(Guard.run.go(sh, table, x, m, T.Allow{})) == True{} : Bool}, false_ne_true(hv))
    case T.Ask{r}:
      Empty.absurd({Verdict.is_deny(Guard.run.go(sh, table, x, m, T.Ask{r})) == True{} : Bool}, false_ne_true(hv))
    case T.Deny{r}:
      nr_relax(Guard.relax.cond(x, m), sh, table, x, m, r, rc_false(x, m, h1))

def Laws.named_noread_unknown_denied(table, x, m, t, a, h1, h2):
  nr_go(Guard.self_hit(table, x, m), table, x, m, Guard.after_clef(Guard.decide.go(Guard.self_hit(table, x, m), table, x, m, t), a), h1,
    nr_step(Guard.self_hit(table, x, m), table, x, m, t, a, h1, h2))
