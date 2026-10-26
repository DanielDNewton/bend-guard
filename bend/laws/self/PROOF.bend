# bend-guard: proofs of laws/self/LAWS.bend. run_m puts protect(self_hit, ..)
# outermost, so both laws come down to "self_hit is True" (run_deny). That is
# a list induction over Meaning.actions(m) (the same term in Meaning.changes,
# Meaning.reads and Guard.self_hit). One change action: its path q contains
# p (an exact action: eq(p, q) gives under(p, q)), and every protected path
# that overlaps p also overlaps q (ovl_up, from ancestors_comparable and
# under_trans). One read action: the key file is under q, so q overlaps it.

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
# Bool and Path lemmas

# Case analysis on Bool.or: each side alone gives g.
def or_case(c: Bool, -r: Bool, -g: Bool) -> ({c == True{} : Bool} -> {g == True{} : Bool}) -> ({r == True{} : Bool} -> {g == True{} : Bool}) -> {Bool.or(c, r) == True{} : Bool} -> {g == True{} : Bool}:
  match c:
    case True{}:
      f1 => f2 => h => f1({==})
    case False{}:
      f1 => f2 => h => f2(h)

# Path.eq.segs and Path.eq are symmetric.
def eqsegs_symt(xs: List<&2, String>, ys: List<&2, String>) -> {Path.eq.segs(xs, ys) == True{} : Bool} -> {Path.eq.segs(ys, xs) == True{} : Bool}:
  match xs ys:
    case Nil{} Nil{}:
      h => {==}
    case Nil{} y <> yt:
      h => h
    case x <> xt Nil{}:
      h => h
    case +x <> +xt +y <> +yt:
      +h => PathProof.and_intro(Path.Seg.eq(y, x), Path.eq.segs(yt, xt),
        PathProof.seg_symt(x, y, PathProof.and_l(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h)),
        eqsegs_symt(xt, yt, PathProof.and_r(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h)))

def eq_symt(a: T.Path, b: T.Path) -> {Path.eq(a, b) == True{} : Bool} -> {Path.eq(b, a) == True{} : Bool}:
  match a b:
    case T.Path{+ad, +axs} T.Path{+bd, +bxs}:
      +h => PathProof.and_intro(Path.Seg.eq(bd, ad), Path.eq.segs(bxs, axs),
        PathProof.seg_symt(ad, bd, PathProof.and_l(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h)),
        eqsegs_symt(axs, bxs, PathProof.and_r(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h)))

# p is under q and overlaps z, so q overlaps z.
def ovl_up(+p: T.Path, +q: T.Path, +z: T.Path) -> {Path.under(p, q) == True{} : Bool} -> {Path.overlaps(p, z) == True{} : Bool} -> {Path.overlaps(q, z) == True{} : Bool}:
  +hu => or_case(Path.under(p, z), Path.under(z, p), Path.overlaps(q, z),
    h => PathLaws.ancestors_comparable(p, q, z, hu, h),
    h => PathProof.or_r(Path.under(q, z), Path.under(z, q), PathLaws.under_trans(z, p, q, h, hu)))

# p is under q and some path of ps overlaps p, so that path overlaps q.
def covers_up(ps: List<&2, T.Path>, +p: T.Path, +q: T.Path) -> {Path.under(p, q) == True{} : Bool} -> {Protect.covers.list(ps, p) == True{} : Bool} -> {Protect.covers.list(ps, q) == True{} : Bool}:
  match ps:
    case Nil{}:
      hu => h => h
    case +z <> +t:
      +hu => or_case(Path.overlaps(p, z), Protect.covers.list(t, p), Bool.or(Path.overlaps(q, z), Protect.covers.list(t, q)),
        h => PathProof.or_l(Path.overlaps(q, z), Protect.covers.list(t, q), ovl_up(p, q, z, hu, h)),
        h => PathProof.or_r(Path.overlaps(q, z), Protect.covers.list(t, q), covers_up(t, p, q, hu, h)))

# ---------------------------------------------------------------------------
# Changes of a protected path hit self-protection

# One action that changes p, with p protected, is a self hit.
def change_one_hits(a: T.Action, +table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> {Meaning.changes.one(a, p) == True{} : Bool} -> {Protect.covers(table, x, p) == True{} : Bool} -> {Guard.self.one(a, table, x) == True{} : Bool}:
  match a:
    case T.Read{+q}:
      h1 => h2 => Empty.absurd({Guard.self.one(T.Read{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h1))
    case T.ReadTree{+q}:
      h1 => h2 => Empty.absurd({Guard.self.one(T.ReadTree{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h1))
    case T.ListDir{q}:
      h1 => h2 => h1
    case T.Write{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named_or_dir(q), covers_up(Protect.set(table, x), p, q, PathLaws.eq_under(p, q, h1), h2))
    case T.WriteTree{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named_or_dir(q), covers_up(Protect.set(table, x), p, q, h1, h2))
    case T.Delete{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named_or_dir(q), covers_up(Protect.set(table, x), p, q, PathLaws.eq_under(p, q, h1), h2))
    case T.DeleteTree{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named_or_dir(q), covers_up(Protect.set(table, x), p, q, h1, h2))
    case T.MoveFrom{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named_or_dir(q), covers_up(Protect.set(table, x), p, q, h1, h2))
    case T.MakeDir{+q}:
      h1 => h2 => PathProof.or_l(Protect.covers(table, x, q), Protect.named(q), covers_up(Protect.set(table, x), p, q, PathLaws.eq_under(p, q, h1), h2))
    case T.ChangeDir{q}:
      h1 => h2 => h1
    case T.GitRead{}:
      h1 => h2 => h1
    case T.GitRef{}:
      h1 => h2 => h1
    case T.GitPush{dir, force, all, refs, unsure}:
      h1 => h2 => h1
    case T.NpmInstall{pkgs}:
      h1 => h2 => h1
    case T.RunScript{name}:
      h1 => h2 => h1
    case T.DraftCheck{slug}:
      h1 => h2 => h1
    case T.Inert{}:
      h1 => h2 => h1

def changes_hits.go(xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> {Meaning.changes.list(xs, p) == True{} : Bool} -> {Protect.covers(table, x, p) == True{} : Bool} -> {Guard.self.list(xs, table, x) == True{} : Bool}:
  match xs:
    case Nil{}:
      h1 => h2 => h1
    case +a <> +t:
      h1 => +h2 => or_case(Meaning.changes.one(a, p), Meaning.changes.list(t, p), Bool.or(Guard.self.one(a, table, x), Guard.self.list(t, table, x)),
        h => PathProof.or_l(Guard.self.one(a, table, x), Guard.self.list(t, table, x), change_one_hits(a, table, x, p, h, h2)),
        h => PathProof.or_r(Guard.self.one(a, table, x), Guard.self.list(t, table, x), changes_hits.go(t, table, x, p, h, h2)),
        h1)

# ---------------------------------------------------------------------------
# Reads of the key file hit self-protection

# One action that reads the key file is a self hit.
def key_one_hits(a: T.Action, +table: List<&2, T.Project>, +x: T.Ctx) -> {Meaning.reads.one(a, Protect.key_file(Call.Ctx.home(x))) == True{} : Bool} -> {Guard.self.one(a, table, x) == True{} : Bool}:
  match a:
    case T.Read{+q}:
      h => PathProof.or_r(Path.under(q, Protect.key_file(Call.Ctx.home(x))), Path.under(Protect.key_file(Call.Ctx.home(x)), q),
        PathLaws.eq_under(Protect.key_file(Call.Ctx.home(x)), q, h))
    case T.ReadTree{+q}:
      h => PathProof.or_r(Path.under(q, Protect.key_file(Call.Ctx.home(x))), Path.under(Protect.key_file(Call.Ctx.home(x)), q), h)
    case T.ListDir{q}:
      h => h
    case T.Write{+q}:
      h => Empty.absurd({Guard.self.one(T.Write{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.WriteTree{+q}:
      h => Empty.absurd({Guard.self.one(T.WriteTree{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.Delete{+q}:
      h => Empty.absurd({Guard.self.one(T.Delete{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.DeleteTree{+q}:
      h => Empty.absurd({Guard.self.one(T.DeleteTree{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.MoveFrom{+q}:
      h => Empty.absurd({Guard.self.one(T.MoveFrom{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.MakeDir{+q}:
      h => Empty.absurd({Guard.self.one(T.MakeDir{q}, table, x) == True{} : Bool}, PathProof.false_ne_true(h))
    case T.ChangeDir{q}:
      h => h
    case T.GitRead{}:
      h => h
    case T.GitRef{}:
      h => h
    case T.GitPush{dir, force, all, refs, unsure}:
      h => h
    case T.NpmInstall{pkgs}:
      h => h
    case T.RunScript{name}:
      h => h
    case T.DraftCheck{slug}:
      h => h
    case T.Inert{}:
      h => h

def key_hits.go(xs: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx) -> {Meaning.reads.list(xs, Protect.key_file(Call.Ctx.home(x))) == True{} : Bool} -> {Guard.self.list(xs, table, x) == True{} : Bool}:
  match xs:
    case Nil{}:
      h => h
    case +a <> +t:
      h => or_case(Meaning.reads.one(a, Protect.key_file(Call.Ctx.home(x))), Meaning.reads.list(t, Protect.key_file(Call.Ctx.home(x))), Bool.or(Guard.self.one(a, table, x), Guard.self.list(t, table, x)),
        e => PathProof.or_l(Guard.self.one(a, table, x), Guard.self.list(t, table, x), key_one_hits(a, table, x, e)),
        e => PathProof.or_r(Guard.self.one(a, table, x), Guard.self.list(t, table, x), key_hits.go(t, table, x, e)),
        h)

# ---------------------------------------------------------------------------
# A write of a file protected by name hits self-protection

# One action that is a self hit, anywhere in the list, makes the list a hit.
def self_app(as1: List<&2, T.Action>, +a: T.Action, +as2: List<&2, T.Action>, +table: List<&2, T.Project>, +x: T.Ctx) -> {Guard.self.one(a, table, x) == True{} : Bool} -> {Guard.self.list(List.append(&2, T.Action, as1, a <> as2), table, x) == True{} : Bool}:
  match as1:
    case Nil{}:
      h => PathProof.or_l(Guard.self.one(a, table, x), Guard.self.list(as2, table, x), h)
    case +b <> +t:
      h => PathProof.or_r(Guard.self.one(b, table, x), Guard.self.list(List.append(&2, T.Action, t, a <> as2), table, x), self_app(t, a, as2, table, x, h))

def named_hit(+table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +as1: List<&2, T.Action>, +q: T.Path, +as2: List<&2, T.Action>, h1: {Meaning.actions(m) == List.append(&2, T.Action, as1, T.Write{q} <> as2) : List<&2, T.Action>}, h2: {Protect.named(q) == True{} : Bool}) -> {Guard.self.list(Meaning.actions(m), table, x) == True{} : Bool}:
  %Equal.sym(List<&2, T.Action>, Meaning.actions(m), List.append(&2, T.Action, as1, T.Write{q} <> as2), h1) : {Guard.self.list(_, table, x) == True{} : Bool}
  self_app(as1, T.Write{q}, as2, table, x, PathProof.or_r(Protect.covers(table, x, q), Protect.named_or_dir(q), PathProof.or_l(Protect.named(q), Protect.named_dir(q), h2)))

# ---------------------------------------------------------------------------
# A self hit makes run_m Deny: protect(True, ..) is outermost in run.go.

def run_deny(sh: Bool, +table: List<&2, T.Project>, +x: T.Ctx, +m: T.Meaning, +t: String, +a: T.ClefAnswer) -> {sh == True{} : Bool} -> {Verdict.is_deny(Guard.run.with(sh, table, x, m, t, a)) == True{} : Bool}:
  match sh:
    case True{}:
      h => {==}
    case False{}:
      h => Empty.absurd({Verdict.is_deny(Guard.run.with(False{}, table, x, m, t, a)) == True{} : Bool}, PathProof.false_ne_true(h))

# ---------------------------------------------------------------------------
# The laws

def Laws.changes_hits(table, x, m, p, h1, h2):
  changes_hits.go(Meaning.actions(m), table, x, p, h1, h2)

def Laws.key_hits(table, x, m, h):
  key_hits.go(Meaning.actions(m), table, x, h)

def Laws.self_protection(table, x, m, t, a, p, h1, h2):
  run_deny(Guard.self_hit(table, x, m), table, x, m, t, a, changes_hits.go(Meaning.actions(m), table, x, p, h1, h2))

def Laws.key_unreadable(table, x, m, t, a, h):
  run_deny(Guard.self_hit(table, x, m), table, x, m, t, a, key_hits.go(Meaning.actions(m), table, x, h))

def Laws.named_settings_denied(table, x, m, t, a, as1, q, as2, h1, h2):
  run_deny(Guard.self_hit(table, x, m), table, x, m, t, a, named_hit(table, x, m, as1, q, as2, h1, h2))

def Laws.git_hooks_denied(table, x, m, t, a, as1, q, as2, h1, h2):
  run_deny(Guard.self_hit(table, x, m), table, x, m, t, a, named_hit(table, x, m, as1, q, as2, h1, PathProof.or_r(Protect.named.claude(q), Protect.named.git(q), h2)))
