# bend-guard: proofs of laws/path/LAWS.bend. Segment equality (Path.Seg.eq)
# compares Nat codes, so its reflexivity, symmetry and transitivity follow
# from the same facts about Nat.is_eq, by induction; the path laws are built
# from those and from list lemmas about Path.prefix.

import Base
import ../../core/Types.bend as T
import ../../core/Path.bend as Path
import ./LAWS.bend as Laws

# ---------------------------------------------------------------------------
# Bool

def BoolT(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def false_ne_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : BoolT(_)
  Unit{}

def and_intro(a: Bool, -b: Bool) -> {a == True{} : Bool} -> {b == True{} : Bool} -> {Bool.and(a, b) == True{} : Bool}:
  match a:
    case True{}:
      ha => hb => hb
    case False{}:
      ha => hb => ha

def and_l(a: Bool, -b: Bool) -> {Bool.and(a, b) == True{} : Bool} -> {a == True{} : Bool}:
  match a:
    case True{}:
      h => {==}
    case False{}:
      h => h

def and_r(a: Bool, -b: Bool) -> {Bool.and(a, b) == True{} : Bool} -> {b == True{} : Bool}:
  match a:
    case True{}:
      h => h
    case False{}:
      h => Empty.absurd({b == True{} : Bool}, false_ne_true(h))

def or_l(a: Bool, -b: Bool) -> {a == True{} : Bool} -> {Bool.or(a, b) == True{} : Bool}:
  match a:
    case True{}:
      h => {==}
    case False{}:
      h => Empty.absurd({b == True{} : Bool}, false_ne_true(h))

def or_r(a: Bool, -b: Bool) -> {b == True{} : Bool} -> {Bool.or(a, b) == True{} : Bool}:
  match a:
    case True{}:
      h => {==}
    case False{}:
      h => h

def or_comm(a: Bool, b: Bool) -> {Bool.or(a, b) == Bool.or(b, a) : Bool}:
  match a b:
    case True{} True{}:
      {==}
    case True{} False{}:
      {==}
    case False{} True{}:
      {==}
    case False{} False{}:
      {==}

# Both conditions hold and one of the two facts holds.
def or_and2(d1: Bool, -p1: Bool, d2: Bool, -p2: Bool) -> {d1 == True{} : Bool} -> {d2 == True{} : Bool} -> {Bool.or(p1, p2) == True{} : Bool} -> {Bool.or(Bool.and(d1, p1), Bool.and(d2, p2)) == True{} : Bool}:
  match d1 d2:
    case True{} True{}:
      h1 => h2 => h3 => h3
    case True{} False{}:
      h1 => h2 => h3 => Empty.absurd({Bool.or(p1, False{}) == True{} : Bool}, false_ne_true(h2))
    case False{} True{}:
      h1 => h2 => h3 => Empty.absurd({p2 == True{} : Bool}, false_ne_true(h1))
    case False{} False{}:
      h1 => h2 => h3 => h1

# ---------------------------------------------------------------------------
# Nat.is_eq

def nat_refl(n: Nat) -> {Nat.is_eq(n, n) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      nat_refl(p)

def nat_symt(a: Nat, b: Nat) -> {Nat.is_eq(a, b) == True{} : Bool} -> {Nat.is_eq(b, a) == True{} : Bool}:
  match a b:
    case 0n 0n:
      h => {==}
    case 0n 1n+q:
      h => h
    case 1n+p 0n:
      h => h
    case 1n+p 1n+q:
      nat_symt(p, q)

def nat_trans(a: Nat, b: Nat, c: Nat) -> {Nat.is_eq(a, b) == True{} : Bool} -> {Nat.is_eq(b, c) == True{} : Bool} -> {Nat.is_eq(a, c) == True{} : Bool}:
  match a b c:
    case 0n 0n 0n:
      h1 => h2 => {==}
    case 0n 0n 1n+r:
      h1 => h2 => h2
    case 0n 1n+q 0n:
      h1 => h2 => {==}
    case 0n 1n+q 1n+r:
      h1 => h2 => h1
    case 1n+p 0n 0n:
      h1 => h2 => h1
    case 1n+p 0n 1n+r:
      h1 => h2 => Empty.absurd({Nat.is_eq(p, r) == True{} : Bool}, false_ne_true(h1))
    case 1n+p 1n+q 0n:
      h1 => h2 => h2
    case 1n+p 1n+q 1n+r:
      nat_trans(p, q, r)

# ---------------------------------------------------------------------------
# Path.Seg.eq

def seg_refl(s: String) -> {Path.Seg.eq(s, s) == True{} : Bool}:
  match s:
    case SNil{}:
      {==}
    case SCon{+x, +t}:
      and_intro(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(x)), Path.Seg.eq(t, t), nat_refl(Path.Seg.code(x)), seg_refl(t))

def seg_symt(a: String, b: String) -> {Path.Seg.eq(a, b) == True{} : Bool} -> {Path.Seg.eq(b, a) == True{} : Bool}:
  match a b:
    case SNil{} SNil{}:
      h => {==}
    case SNil{} SCon{y, bt}:
      h => h
    case SCon{x, at} SNil{}:
      h => h
    case SCon{+x, +at} SCon{+y, +bt}:
      +h => and_intro(Nat.is_eq(Path.Seg.code(y), Path.Seg.code(x)), Path.Seg.eq(bt, at),
        nat_symt(Path.Seg.code(x), Path.Seg.code(y), and_l(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(y)), Path.Seg.eq(at, bt), h)),
        seg_symt(at, bt, and_r(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(y)), Path.Seg.eq(at, bt), h)))

def seg_trans(a: String, b: String, c: String) -> {Path.Seg.eq(a, b) == True{} : Bool} -> {Path.Seg.eq(b, c) == True{} : Bool} -> {Path.Seg.eq(a, c) == True{} : Bool}:
  match a b c:
    case SNil{} SNil{} SNil{}:
      h1 => h2 => {==}
    case SNil{} SNil{} SCon{z, ct}:
      h1 => h2 => h2
    case SNil{} SCon{y, bt} SNil{}:
      h1 => h2 => {==}
    case SNil{} SCon{y, bt} SCon{z, ct}:
      h1 => h2 => h1
    case SCon{x, at} SNil{} SNil{}:
      h1 => h2 => h1
    case SCon{x, at} SNil{} SCon{z, ct}:
      h1 => h2 => Empty.absurd({Path.Seg.eq(SCon{x, at}, SCon{z, ct}) == True{} : Bool}, false_ne_true(h1))
    case SCon{x, at} SCon{y, bt} SNil{}:
      h1 => h2 => h2
    case SCon{+x, +at} SCon{+y, +bt} SCon{+z, +ct}:
      +h1 => +h2 => and_intro(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(z)), Path.Seg.eq(at, ct),
        nat_trans(Path.Seg.code(x), Path.Seg.code(y), Path.Seg.code(z),
          and_l(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(y)), Path.Seg.eq(at, bt), h1),
          and_l(Nat.is_eq(Path.Seg.code(y), Path.Seg.code(z)), Path.Seg.eq(bt, ct), h2)),
        seg_trans(at, bt, ct,
          and_r(Nat.is_eq(Path.Seg.code(x), Path.Seg.code(y)), Path.Seg.eq(at, bt), h1),
          and_r(Nat.is_eq(Path.Seg.code(y), Path.Seg.code(z)), Path.Seg.eq(bt, ct), h2)))

# ---------------------------------------------------------------------------
# Path.prefix and Path.eq.segs

def prefix_refl(xs: List<&2, String>) -> {Path.prefix(xs, xs) == True{} : Bool}:
  match xs:
    case Nil{}:
      {==}
    case +h <> +t:
      and_intro(Path.Seg.eq(h, h), Path.prefix(t, t), seg_refl(h), prefix_refl(t))

def prefix_app(xs: List<&2, String>, +ys: List<&2, String>) -> {Path.prefix(xs, List.append(&2, String, xs, ys)) == True{} : Bool}:
  match xs:
    case Nil{}:
      {==}
    case +h <> +t:
      and_intro(Path.Seg.eq(h, h), Path.prefix(t, List.append(&2, String, t, ys)), seg_refl(h), prefix_app(t, ys))

def prefix_trans(xs: List<&2, String>, ys: List<&2, String>, zs: List<&2, String>) -> {Path.prefix(xs, ys) == True{} : Bool} -> {Path.prefix(ys, zs) == True{} : Bool} -> {Path.prefix(xs, zs) == True{} : Bool}:
  match xs ys zs:
    case Nil{} _ _:
      h1 => h2 => {==}
    case x <> xt Nil{} Nil{}:
      h1 => h2 => h1
    case x <> xt Nil{} z <> zt:
      h1 => h2 => Empty.absurd({Path.prefix(x <> xt, z <> zt) == True{} : Bool}, false_ne_true(h1))
    case x <> xt y <> yt Nil{}:
      h1 => h2 => h2
    case +x <> +xt +y <> +yt +z <> +zt:
      +h1 => +h2 => and_intro(Path.Seg.eq(x, z), Path.prefix(xt, zt),
        seg_trans(x, y, z, and_l(Path.Seg.eq(x, y), Path.prefix(xt, yt), h1), and_l(Path.Seg.eq(y, z), Path.prefix(yt, zt), h2)),
        prefix_trans(xt, yt, zt, and_r(Path.Seg.eq(x, y), Path.prefix(xt, yt), h1), and_r(Path.Seg.eq(y, z), Path.prefix(yt, zt), h2)))

# Two prefixes of the same list: one is a prefix of the other.
def prefix_comp(xs: List<&2, String>, ys: List<&2, String>, zs: List<&2, String>) -> {Path.prefix(xs, zs) == True{} : Bool} -> {Path.prefix(ys, zs) == True{} : Bool} -> {Bool.or(Path.prefix(ys, xs), Path.prefix(xs, ys)) == True{} : Bool}:
  match xs ys zs:
    case Nil{} +ys2 _:
      h1 => h2 => or_r(Path.prefix(ys2, []), True{}, {==})
    case x <> xt Nil{} _:
      h1 => h2 => {==}
    case x <> xt y <> yt Nil{}:
      h1 => h2 => Empty.absurd({Bool.or(Path.prefix(y <> yt, x <> xt), Path.prefix(x <> xt, y <> yt)) == True{} : Bool}, false_ne_true(h1))
    case +x <> +xt +y <> +yt +z <> +zt:
      +h1 => +h2 => or_and2(Path.Seg.eq(y, x), Path.prefix(yt, xt), Path.Seg.eq(x, y), Path.prefix(xt, yt),
        seg_trans(y, z, x, and_l(Path.Seg.eq(y, z), Path.prefix(yt, zt), h2), seg_symt(x, z, and_l(Path.Seg.eq(x, z), Path.prefix(xt, zt), h1))),
        seg_trans(x, z, y, and_l(Path.Seg.eq(x, z), Path.prefix(xt, zt), h1), seg_symt(y, z, and_l(Path.Seg.eq(y, z), Path.prefix(yt, zt), h2))),
        prefix_comp(xt, yt, zt, and_r(Path.Seg.eq(x, z), Path.prefix(xt, zt), h1), and_r(Path.Seg.eq(y, z), Path.prefix(yt, zt), h2)))

def eqsegs_prefix(xs: List<&2, String>, ys: List<&2, String>) -> {Path.eq.segs(xs, ys) == True{} : Bool} -> {Path.prefix(ys, xs) == True{} : Bool}:
  match xs ys:
    case Nil{} Nil{}:
      h => {==}
    case Nil{} y <> yt:
      h => h
    case x <> xt Nil{}:
      h => {==}
    case +x <> +xt +y <> +yt:
      +h => and_intro(Path.Seg.eq(y, x), Path.prefix(yt, xt),
        seg_symt(x, y, and_l(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h)),
        eqsegs_prefix(xt, yt, and_r(Path.Seg.eq(x, y), Path.eq.segs(xt, yt), h)))

# ---------------------------------------------------------------------------
# The normaliser's last step

def MaybeT(m: Maybe<&2, T.Path>) -> Type:
  match m:
    case None{}:
      Unit
    case Some{q}:
      Empty

def none_ne_some(-p: T.Path, e: {None{} == Some{p} : Maybe<&2, T.Path>}) -> Empty:
  %e : MaybeT(_)
  Unit{}

def unwrap(m: Maybe<&2, T.Path>) -> T.Path:
  match m:
    case None{}:
      T.Path{"?", []}
    case Some{q}:
      q

def fin_if(c: Bool, -xs: List<&2, String>, -p: T.Path) -> {c == Path.clean.segs(xs) : Bool} -> {Path.norm.fin.if(c, xs) == Some{p} : Maybe<&2, T.Path>} -> {Path.clean(p) == True{} : Bool}:
  match c:
    case False{}:
      e => h => Empty.absurd({Path.clean(p) == True{} : Bool}, none_ne_some(p, h))
    case True{}:
      e => h =>
        %h : {Path.clean(unwrap(_)) == True{} : Bool}
        %e : {_ == True{} : Bool}
        {==}

def fin_clean(m: Maybe<&2, List<&2, String>>, -p: T.Path) -> {Path.norm.fin(m) == Some{p} : Maybe<&2, T.Path>} -> {Path.clean(p) == True{} : Bool}:
  match m:
    case None{}:
      h => Empty.absurd({Path.clean(p) == True{} : Bool}, none_ne_some(p, h))
    case Some{+xs}:
      h => fin_if(Path.clean.segs(xs), xs, p, {==}, h)

# ---------------------------------------------------------------------------
# The laws

def Laws.under_refl(p):
  match p:
    case T.Path{+d, +xs}:
      and_intro(Path.Seg.eq(d, d), Path.prefix(xs, xs), seg_refl(d), prefix_refl(xs))

def Laws.under_child(p, x):
  match p:
    case T.Path{+d, +xs}:
      and_intro(Path.Seg.eq(d, d), Path.prefix(xs, List.append(&2, String, xs, Path.child.parts(Path.split(x)))),
        seg_refl(d), prefix_app(xs, Path.child.parts(Path.split(x))))

def Laws.under_trans(a, b, c, h1, h2):
  match a b c:
    case T.Path{+ad, +axs} T.Path{+bd, +bxs} T.Path{+cd, +cxs}:
      and_intro(Path.Seg.eq(cd, ad), Path.prefix(cxs, axs),
        seg_trans(cd, bd, ad, and_l(Path.Seg.eq(cd, bd), Path.prefix(cxs, bxs), h2), and_l(Path.Seg.eq(bd, ad), Path.prefix(bxs, axs), h1)),
        prefix_trans(cxs, bxs, axs, and_r(Path.Seg.eq(cd, bd), Path.prefix(cxs, bxs), h2), and_r(Path.Seg.eq(bd, ad), Path.prefix(bxs, axs), h1)))

def Laws.overlaps_sym(a, b):
  or_comm(Path.under(a, b), Path.under(b, a))

def Laws.under_overlaps(a, b, h):
  or_l(Path.under(a, b), Path.under(b, a), h)

def Laws.eq_under(a, b, h):
  match a b:
    case T.Path{+ad, +axs} T.Path{+bd, +bxs}:
      and_intro(Path.Seg.eq(bd, ad), Path.prefix(bxs, axs),
        seg_symt(ad, bd, and_l(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h)),
        eqsegs_prefix(axs, bxs, and_r(Path.Seg.eq(ad, bd), Path.eq.segs(axs, bxs), h)))

def Laws.ancestors_comparable(p, a, b, h1, h2):
  match p a b:
    case T.Path{+pd, +pxs} T.Path{+ad, +axs} T.Path{+bd, +bxs}:
      or_and2(Path.Seg.eq(bd, ad), Path.prefix(bxs, axs), Path.Seg.eq(ad, bd), Path.prefix(axs, bxs),
        seg_trans(bd, pd, ad, and_l(Path.Seg.eq(bd, pd), Path.prefix(bxs, pxs), h2), seg_symt(ad, pd, and_l(Path.Seg.eq(ad, pd), Path.prefix(axs, pxs), h1))),
        seg_trans(ad, pd, bd, and_l(Path.Seg.eq(ad, pd), Path.prefix(axs, pxs), h1), seg_symt(bd, pd, and_l(Path.Seg.eq(bd, pd), Path.prefix(bxs, pxs), h2))),
        prefix_comp(axs, bxs, pxs, and_r(Path.Seg.eq(ad, pd), Path.prefix(axs, pxs), h1), and_r(Path.Seg.eq(bd, pd), Path.prefix(bxs, pxs), h2)))

def Laws.norm_clean(cwd, home, raw, p, h):
  fin_clean(Path.norm.junc(Path.parse(raw, Path.absolute(cwd), Path.absolute(home))), p, h)
