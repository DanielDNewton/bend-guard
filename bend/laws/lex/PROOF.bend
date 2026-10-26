# bend-guard: proofs of laws/lex/LAWS.bend. The table laws use segment
# equality's reflexivity (laws/path seg_refl) and splits on the compared
# names; the sample-text law computes (the home folder stays free, so it
# holds for every home).

import Base
import ../../core/Types.bend as T
import ../../core/Path.bend as Path
import ../../core/Lex.bend as Lex
import ../path/PROOF.bend as PathProof
import ./LAWS.bend as Laws

def Laws.var_set_get(e, n, v):
  %Equal.sym(Bool, Path.Seg.eq(n, n), True{}, PathProof.seg_refl(n)) : {Lex.var.get.k(_, v, Lex.var.get(Lex.var.del(e, n), n)) == Some{v} : Maybe<&2, String>}
  {==}

def del_get.no(-k: String, -v: String, -t: List<&2, T.Arg>, -n: String, ih: {Lex.var.get(Lex.var.del(t, n), n) == None{} : Maybe<&2, String>}, e: {Path.Seg.eq(k, n) == False{} : Bool}) -> {Lex.var.get.k(Path.Seg.eq(k, n), v, Lex.var.get(Lex.var.del(t, n), n)) == None{} : Maybe<&2, String>}:
  %Equal.sym(Bool, Path.Seg.eq(k, n), False{}, e) : {Lex.var.get.k(_, v, Lex.var.get(Lex.var.del(t, n), n)) == None{} : Maybe<&2, String>}
  ih

# one entry k of the table: whether it is dropped (c) decides the step
def del_get.fin(c: Bool, -k: String, -v: String, -t: List<&2, T.Arg>, -n: String, ih: {Lex.var.get(Lex.var.del(t, n), n) == None{} : Maybe<&2, String>}) -> {Path.Seg.eq(k, n) == c : Bool} -> {Lex.var.get(Lex.var.del.k(c, T.Arg{k, v}, Lex.var.del(t, n)), n) == None{} : Maybe<&2, String>}:
  match c:
    case True{}:
      e => ih
    case False{}:
      e => del_get.no(k, v, t, n, ih, e)

def Laws.var_del_get(e, n):
  match e:
    case Nil{}:
      {==}
    case Con{T.Arg{+k, v}, +t}:
      del_get.fin(Path.Seg.eq(k, n), k, v, t, n, Laws.var_del_get(t, n))({==})

# ---- deleting another name keeps a missing name missing ----------------------------

def MaybeT(x: Maybe<&2, String>) -> Type:
  match x:
    case Some{s}:
      Unit
    case None{}:
      Empty

def some_ne_none(-v: String, e: {Some{v} == None{} : Maybe<&2, String>}) -> Empty:
  %e : MaybeT(_)
  Unit{}

def keep.no(-k: String, -v: String, -t: List<&2, T.Arg>, -m: String, -n: String, en: {Path.Seg.eq(k, n) == False{} : Bool}, h2: {Lex.var.get(Lex.var.del(t, m), n) == None{} : Maybe<&2, String>}) -> {Lex.var.get.k(Path.Seg.eq(k, n), v, Lex.var.get(Lex.var.del(t, m), n)) == None{} : Maybe<&2, String>}:
  %Equal.sym(Bool, Path.Seg.eq(k, n), False{}, en) : {Lex.var.get.k(_, v, Lex.var.get(Lex.var.del(t, m), n)) == None{} : Maybe<&2, String>}
  h2

def keep.cons(cn: Bool, cm: Bool, -k: String, -v: String, -t: List<&2, T.Arg>, -m: String, -n: String, ih: {Lex.var.get(t, n) == None{} : Maybe<&2, String>} -> {Lex.var.get(Lex.var.del(t, m), n) == None{} : Maybe<&2, String>}) -> {Path.Seg.eq(k, n) == cn : Bool} -> {Lex.var.get.k(cn, v, Lex.var.get(t, n)) == None{} : Maybe<&2, String>} -> {Lex.var.get(Lex.var.del.k(cm, T.Arg{k, v}, Lex.var.del(t, m)), n) == None{} : Maybe<&2, String>}:
  match cn cm:
    case True{} _:
      en => h => Empty.absurd({Lex.var.get(Lex.var.del.k(cm, T.Arg{k, v}, Lex.var.del(t, m)), n) == None{} : Maybe<&2, String>}, some_ne_none(v, h))
    case False{} True{}:
      en => h => ih(h)
    case False{} False{}:
      en => h => keep.no(k, v, t, m, n, en, ih(h))

def keep_none(e: List<&2, T.Arg>, +m: String, +n: String) -> {Lex.var.get(e, n) == None{} : Maybe<&2, String>} -> {Lex.var.get(Lex.var.del(e, m), n) == None{} : Maybe<&2, String>}:
  match e:
    case Nil{}:
      h => {==}
    case Con{T.Arg{+k, +v}, +t}:
      h => keep.cons(Path.Seg.eq(k, n), Path.Seg.eq(k, m), k, v, t, m, n, keep_none(t, m, n))({==})(h)

def all_keep(ns: List<&2, String>, +e: List<&2, T.Arg>, +n: String) -> {Lex.var.get(e, n) == None{} : Maybe<&2, String>} -> {Lex.var.get(Lex.var.del_all(ns, e), n) == None{} : Maybe<&2, String>}:
  match ns:
    case Nil{}:
      h => h
    case +m <> t:
      h => all_keep(t, Lex.var.del(e, m), n)(keep_none(e, m, n)(h))

def Laws.var_del_all_get(ns, e, n):
  all_keep(ns, Lex.var.del(e, n), n)(Laws.var_del_get(e, n))

def Laws.var_ins_value(v, cur):
  {==}

def Laws.subst_quoted(h):
  {==}
