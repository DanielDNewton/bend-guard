# bend-guard: questions about a meaning (the list of actions a tool call
# does). Plan "Shared interfaces", design.md component 4. Only the understood
# actions count: Known's actions, or the parts of an Unknown that were
# understood.

import Base
import ./Types.bend as T
import ./Path.bend as Path

def is_unknown(m: T.Meaning) -> Bool:
  match m:
    case T.Known{xs}:
      False{}
    case T.Unknown{why, xs}:
      True{}

def actions(m: T.Meaning) -> List<&2, T.Action>:
  match m:
    case T.Known{xs}:
      xs
    case T.Unknown{why, xs}:
      xs

# a changes p: it writes, deletes or makes exactly p, or writes, deletes or
# moves a tree that contains p. ChangeDir, ListDir and reads change nothing.
def changes.one(a: T.Action, p: T.Path) -> Bool:
  match a:
    case T.Write{q}:
      Path.eq(p, q)
    case T.Delete{q}:
      Path.eq(p, q)
    case T.MakeDir{q}:
      Path.eq(p, q)
    case T.WriteTree{q}:
      Path.under(p, q)
    case T.DeleteTree{q}:
      Path.under(p, q)
    case T.MoveFrom{q}:
      Path.under(p, q)
    case _:
      False{}

def changes.list(xs: List<&2, T.Action>, +p: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(changes.one(a, p), changes.list(t, p))

def changes(m: T.Meaning, +p: T.Path) -> Bool:
  changes.list(actions(m), p)

# a reads p's contents: Read of exactly p, or ReadTree of a tree that contains
# p. ListDir reads names only and is not a read.
def reads.one(a: T.Action, p: T.Path) -> Bool:
  match a:
    case T.Read{q}:
      Path.eq(p, q)
    case T.ReadTree{q}:
      Path.under(p, q)
    case _:
      False{}

def reads.list(xs: List<&2, T.Action>, +p: T.Path) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case a <> t:
      Bool.or(reads.one(a, p), reads.list(t, p))

def reads(m: T.Meaning, +p: T.Path) -> Bool:
  reads.list(actions(m), p)

# Path.show of the path an action names, if any (GitPush's folder included).
def paths.one(a: T.Action) -> List<&2, String>:
  match a:
    case T.Read{q}:
      [Path.show(q)]
    case T.ReadTree{q}:
      [Path.show(q)]
    case T.ListDir{q}:
      [Path.show(q)]
    case T.Write{q}:
      [Path.show(q)]
    case T.WriteTree{q}:
      [Path.show(q)]
    case T.Delete{q}:
      [Path.show(q)]
    case T.DeleteTree{q}:
      [Path.show(q)]
    case T.MoveFrom{q}:
      [Path.show(q)]
    case T.MakeDir{q}:
      [Path.show(q)]
    case T.ChangeDir{q}:
      [Path.show(q)]
    case T.GitPush{q, force, all, refs, unsure}:
      [Path.show(q)]
    case _:
      []

def paths.list(xs: List<&2, T.Action>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case a <> t:
      List.append(&2, String, paths.one(a), paths.list(t))

def paths(m: T.Meaning) -> List<&2, String>:
  paths.list(actions(m))
