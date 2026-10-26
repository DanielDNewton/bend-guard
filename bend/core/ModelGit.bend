# bend-guard: models of git, npm, the PowerShell cmdlets and the draft check
# (plan.md Task 1.8; design.md component 2, layer 4). ModelShell.bend calls
# the four public defs. Imported as ModelGit.
#
#   git(sh, cwds, home, args)     args: the words after "git", either shell
#   npm(sh, cwds, home, args)     args: the words after "npm", either shell
#   node(sh, cwds, home, args)    args: the words after "node"; the one known
#                                 form is the draft check (DraftCheck{slug})
#   cmdlet(cwds, home, name, args)
#                                 PowerShell only: every command name other
#                                 than cd, chdir, sl, Set-Location, git, npm
#                                 and node. name is lower-cased; args as typed.
#   node_exe(cwds, home, name)    name is node's own program (node.exe, or a
#                                 path to C:\Program Files\nodejs\node.exe)
#   approve.unknown(why, home), approve.other(home, words, m)
#                                 the built-in rule that only the user runs
#                                 bend-guard's approve step (section below)
# cwds are the possible current folders ([] = not known); home is the home
# folder. Anything not listed in plan Task 1.8 is Unknown (fail closed).
#
# Stricter than the plan, on purpose:
# - git checkout <ref>, switch, stash and reset --hard rewrite files across the
#   whole repository, which may start above the shell's folder. They are
#   Unknown, keeping WriteTree of each possible folder as their known part, so
#   the rule and self-protection checks still see that write.
# - A ':' in a path (other than "c:" at its start) is Unknown: git pathspec
#   magic (:/x), PowerShell drives (Env:, HKCU:, Function:) and file streams.
#   The one exception (round 3, P1): a plain <rev>:<path> object name given
#   to git show, cat-file, diff (blob against blob), ls-tree or rev-parse,
#   read as a ReadTree of every place the path can name (section below).
# - git push to anything but a plain remote name is Unknown (a path or URL
#   writes somewhere we cannot see); --delete and :dst also set force.
# - git commit (hooks) and git pull (rewrites working files) stay Unknown.
#
# Every def here that walks a whole text or word list is tail-recursive (an
# accumulator, then a reverse): the compiled JavaScript turns tail calls into
# loops, and anything else overflows the stack on a long command (round 2,
# P8 D: approve.fold crashed on texts of about 6,000 characters).

import Base
import ./Types.bend as T
import ./Path.bend as Path
import ./Model.bend as Model

# ---------------------------------------------------------------------------
# Small helpers

def pick.l(b: Bool, x: List<&2, String>, y: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      x
    case False{}:
      y

# s lower-cased (a loop; Base String.to_lower is not tail-recursive)
def low.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{c, t}:
      low.go(t, SCon{Char.to_lower(c), acc})

def low(s: String) -> String:
  low.go(s, "")

# s holds a wildcard (* ? [), as Model.has_glob, but a loop
def glob.has(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      glob.has(t, acc || Model.is_glob_char(c))

# s holds a ':' other than right after a leading c or C
def colon.bad(s: String) -> Bool:
  match s:
    case SCon{Chr{99}, SCon{Chr{58}, t}}:
      Path.has_colon(t)
    case SCon{Chr{67}, SCon{Chr{58}, t}}:
      Path.has_colon(t)
    case other:
      Path.has_colon(other)

def colon.any.go(xs: List<&2, String>, acc: Bool) -> Bool:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      colon.any.go(t, acc || colon.bad(x))

def colon.any(xs: List<&2, String>) -> Bool:
  colon.any.go(xs, False{})

def colon.why() -> String:
  "a ':' in a path (other than after the drive letter c) is not modelled: it can be git pathspec magic, a PowerShell drive such as Env: or HKCU:, or a file stream"

def cc.in(c: Char, lo: U32, hi: U32) -> Bool:
  match c:
    case Chr{+x}:
      Bool.and(Bool.not(U32.is_lt(x, lo)), Bool.not(U32.is_gt(x, hi)))

# c may stand in a name: a-z 0-9 _ - always; with up also A-Z and '.'; with
# sl also '/'
def cc.ok(up: Bool, sl: Bool, c: Char) -> Bool:
  match c:
    case Chr{+x}:
      (cc.in(Chr{x}, 97, 122) || cc.in(Chr{x}, 48, 57) || U32.is_eq(x, 95) || U32.is_eq(x, 45)) || (up && (cc.in(Chr{x}, 65, 90) || U32.is_eq(x, 46))) || (sl && U32.is_eq(x, 47))

def cc.all.go(s: String, +up: Bool, +sl: Bool, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      cc.all.go(t, up, sl, acc && cc.ok(up, sl, c))

def cc.all(s: String, +up: Bool, +sl: Bool) -> Bool:
  cc.all.go(s, up, sl, True{})

# the words around the first "--": is there one, the words before it, the
# words after it ([] when there is none)
def dd.has(ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case w <> t:
      String.eq(w, "--") || dd.has(t)

def dd.pre(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      []
    case +w <> t:
      pick.l(String.eq(w, "--"), [], w <> dd.pre(t))

def dd.post(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      []
    case w <> +t:
      pick.l(String.eq(w, "--"), t, dd.post(t))

# every path in ps resolves (from each possible folder) to exactly q
def at.all(ps: List<&2, T.Path>, +q: T.Path) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case p <> t:
      Path.eq(p, q) && at.all(t, q)

def at.is(m: Maybe<&2, List<&2, T.Path>>, +q: T.Path) -> Bool:
  match m:
    case Some{ps}:
      at.all(ps, q)
    case None{}:
      False{}

# with no known folder only an absolute path can be placed ("" never
# normalises, so a relative path gives None)
def at.cwds(cwds: List<&2, String>) -> List<&2, String>:
  match cwds:
    case Nil{}:
      [""]
    case c <> t:
      c <> t

# raw names the file q from every possible folder, with no wildcard or ':'
def at.file(+cwds: List<&2, String>, +home: String, +raw: String, +q: T.Path) -> Bool:
  Bool.not(glob.has(raw, False{})) && Bool.not(colon.bad(raw)) && at.is(Model.resolve(at.cwds(cwds), home, raw), q)

# ---------------------------------------------------------------------------
# git: paths and whole-folder rewrites

def gpaths.if(bad: Bool, raws: List<&2, String>, +sh: T.Shell, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown(colon.why())
    case False{}:
      Model.rpaths(raws, sh, k, k, cwds, home)

# kind k on each path; a path with a wildcard (git matches it at any depth)
# gets kind k on the folder before the wildcard
def gpaths(+raws: List<&2, String>, +sh: T.Shell, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  gpaths.if(colon.any(raws), raws, sh, k, cwds, home)

def folders(+k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  Model.path(k, cwds, home, ".")

# kind k on each path, or on each possible folder when no path is named
def tree.ps(xs: List<&2, String>, +sh: T.Shell, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match xs:
    case Nil{}:
      folders(k, cwds, home)
    case p <> t:
      gpaths(p <> t, sh, k, cwds, home)

def wide.k(m: T.Meaning, what: String) -> T.Meaning:
  match m:
    case T.Known{xs}:
      T.Unknown{what ++ " can rewrite files anywhere in the repository, also above the current folder", xs}
    case T.Unknown{w, xs}:
      T.Unknown{w, xs}

# a rewrite of the whole working tree: Unknown, with WriteTree of each
# possible folder as the known part
def wide(what: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  wide.k(folders(Model.AKind.WriteTree{}, cwds, home), what)

# ---------------------------------------------------------------------------
# <rev>:<path> object names (round 3, P1). git show, cat-file, diff, ls-tree
# and rev-parse print the content (or the hash) of a file or folder as it is
# stored in a commit, or in the index (:path). REV is empty or a plain
# revision. PATH is a plain relative path, which git reads from the
# repository's top folder (bend-guard cannot see where that is), or a ./ or
# ../ path, which git reads from the current folder; an empty PATH is ".".
# The meaning is a ReadTree of every place PATH can name: a plain PATH from
# each possible current folder and each of its parents (32 levels at most,
# never the bare drive c:/), a ./ or ../ PATH from each current folder. So
# the rules refuse at least what the real call reads. Every other form with
# a ':' (:/text, :N:path, rev@{...}, wildcards, ~ $ % or a backslash) stays
# Unknown.

# Rpm.No: the colon rule; Rpm.Yes: a <rev>:<path> operand is read as above;
# Rpm.NoDots: the same with no '..' in the path (git diff takes an operand
# that leaves the repository for a file outside it)
type Rpm is Data:
  Rpm.No{}
  Rpm.Yes{}
  Rpm.NoDots{}

def rpm.on(m: Rpm) -> Bool:
  match m:
    case Rpm.No{}:
      False{}
    case _:
      True{}

def rpm.nd(m: Rpm) -> Bool:
  match m:
    case Rpm.NoDots{}:
      True{}
    case _:
      False{}

type Rp is Data:
  Rp.Mk{rev: String, path: String}

# the text before the first ':' and the text after it (acc: reversed)
def rp.split(s: String, acc: String) -> Maybe<&2, Rp>:
  match s:
    case SNil{}:
      None{}
    case SCon{Chr{58}, t}:
      Some{Rp.Mk{String.reverse(acc), t}}
    case SCon{c, t}:
      rp.split(t, SCon{c, acc})

# c may stand in a revision: a-z A-Z 0-9 _ - . / ~ ^ @
def rp.revc(c: Char) -> Bool:
  match c:
    case Chr{+x}:
      cc.ok(True{}, True{}, Chr{x}) || U32.is_eq(x, 126) || U32.is_eq(x, 94) || U32.is_eq(x, 64)

def rp.revs(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      rp.revs(t, acc && rp.revc(c))

# empty, or a plain revision with no '{', no ".." and no leading '-'
def rp.rev(+r: String) -> Bool:
  String.is_empty(r) || (Bool.not(String.starts_with(r, "-")) && Bool.not(String.contains(r, "..")) && rp.revs(r, True{}))

# ~ % $ or a backslash
def rp.badc(c: Char) -> Bool:
  match c:
    case Chr{126}:
      True{}
    case Chr{37}:
      True{}
    case Chr{36}:
      True{}
    case Chr{92}:
      True{}
    case _:
      False{}

def rp.bad(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      rp.bad(t, acc || rp.badc(c))

# a ./ or ../ path: git reads it from the current folder
def rp.rel(+p: String) -> Bool:
  String.starts_with(p, "./") || String.starts_with(p, "../")

# "" when the path after ':' can be placed, else the reason (nd: no '..')
def rp.pwhy(+p: String, nd: Bool) -> String:
  Model.pick.s(Path.has_colon(p), "a second ':' (a stage number, as in :1:path) is not modelled", Model.pick.s(String.starts_with(p, "/"), "a path after ':' that starts with / (as in :/text, which searches commit messages) is not modelled", Model.pick.s(glob.has(p, False{}), "wildcards (*, ? or [) in the path after ':' are not modelled", Model.pick.s(rp.bad(p, False{}), "the path after ':' must be a plain relative path (no ~, %, $ or backslash)", Model.pick.s(String.contains(p, "..") && (nd || Bool.not(rp.rel(p))), "'..' in the path after ':' is modelled only at its start (./ or ../), and not at all in git diff", "")))))

def rp.why(+r: String, +p: String, nd: Bool) -> String:
  Model.pick.s(rp.rev(r), rp.pwhy(p, nd), "the revision before ':' must be empty or plain (letters, digits and . _ - / ~ ^ @; no {, no .. and no leading -), so forms such as rev@{...} are not modelled")

# each folder from cwd's first part down to cwd itself (c:/a, c:/a/b, ...),
# as text; None past 32 levels
def anc.go(n: Nat, xs: List<&2, String>, +cur: List<&2, String>, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match n xs:
    case 0n Nil{}:
      Some{acc}
    case 1n+p Nil{}:
      Some{acc}
    case 0n Con{h, t}:
      None{}
    case 1n+p Con{+h, t}:
      anc.go(p, t, h <> cur, Path.show(T.Path{"c", List.reverse(&2, String, h <> cur)}) <> acc)

def anc.of(m: Maybe<&2, T.Path>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{T.Path{d, xs}}:
      anc.go(32n, xs, [], [])
    case None{}:
      None{}

def anc.cat(a: Maybe<&2, List<&2, String>>, b: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match a b:
    case Some{xs} Some{ys}:
      Some{List.append(&2, String, xs, ys)}
    case _ _:
      None{}

# every folder that may be the repository's top: each possible current
# folder and each of its parents (an unknown folder gives None later, when
# a relative path is placed against no folder)
def anc.all(cwds: List<&2, String>, +home: String) -> Maybe<&2, List<&2, String>>:
  match cwds:
    case Nil{}:
      Some{[]}
    case c <> t:
      anc.cat(anc.of(Path.norm(c, home, ".")), anc.all(t, home))

def rp.fin(m: Maybe<&2, List<&2, T.Path>>, +raw: String) -> T.Meaning:
  match m:
    case Some{ps}:
      T.Known{Model.acts(ps, Model.AKind.ReadTree{})}
    case None{}:
      Model.unknown("cannot tell which files the object name " ++ raw ++ " can read (the current folder is not known or is more than 32 levels deep, or the path cannot be placed)")

def rp.top(m: Maybe<&2, List<&2, String>>, +q: String, +raw: String, +home: String) -> T.Meaning:
  match m:
    case Some{fs}:
      rp.fin(Model.resolve(fs, home, q), raw)
    case None{}:
      rp.fin(None{}, raw)

def rp.cands.k(rel: Bool, +q: String, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match rel:
    case True{}:
      rp.fin(Model.resolve(cwds, home, q), raw)
    case False{}:
      rp.top(anc.all(cwds, home), q, raw, home)

def rp.cands(+p: String, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  rp.cands.k(rp.rel(p), Model.pick.s(String.is_empty(p), ".", p), raw, cwds, home)

def rp.chk.k(ok: Bool, why: String, +p: String, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok:
    case True{}:
      rp.cands(p, raw, cwds, home)
    case False{}:
      Model.unknown("the object name " ++ raw ++ " is not modelled: " ++ why)

def rp.chk(+why: String, +p: String, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  rp.chk.k(String.is_empty(why), why, p, raw, cwds, home)

def rp.at(m: Maybe<&2, Rp>, nd: Bool, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match m:
    case Some{Rp.Mk{+r, +p}}:
      rp.chk(rp.why(r, p, nd), p, raw, cwds, home)
    case None{}:
      Model.unknown(colon.why())

# raw holds a ':': ReadTree of each place its <rev>:<path> can name, or
# Unknown naming the form that is not modelled
def rp.read(nd: Bool, +raw: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  rp.at(rp.split(raw, ""), nd, raw, cwds, home)

# ---------------------------------------------------------------------------
# git status, diff, log: GitRead

# The flags of status, log, show, diff, reflog and rev-list. None of them
# writes a file or runs a program of its own choosing: never --output,
# --ext-diff, --textconv, -O<file> (reads an order file), -L (reads line
# ranges), --relative (narrows output to a folder without naming it as a
# path), --no-index, --show-signature (runs gpg) or --open-files-in-pager.
def gread.long() -> List<&2, String>:
  ["--short", "--stat", "--name-only", "--name-status", "--oneline", "--cached", "--staged", "--graph", "--patch", "--no-patch", "--decorate", "--no-decorate", "--all", "--branch", "--porcelain", "--long", "--numstat", "--shortstat", "--summary", "--raw", "--abbrev-commit", "--no-abbrev-commit", "--no-merges", "--merges", "--first-parent", "--reverse", "--follow", "--date-order", "--topo-order", "--author-date-order", "--relative-date", "--color", "--no-color", "--word-diff", "--color-words", "--color-moved", "--ignore-all-space", "--ignore-space-change", "--ignore-blank-lines", "--ignore-cr-at-eol", "--minimal", "--patience", "--histogram", "--find-renames", "--no-renames", "--full-history", "--left-right", "--cherry-pick", "--boundary", "--no-ext-diff", "--no-textconv", "--quiet", "--exit-code", "--check", "--ignored", "--untracked-files", "--show-stash", "--ahead-behind", "--no-ahead-behind", "--text", "--full-index", "--no-prefix", "--tags", "--branches", "--remotes", "--simplify-by-decoration", "--count", "--pretty", "--dirstat", "--compact-summary", "--merge-base", "--no-walk", "--stdin", "--stat=", "--porcelain=", "--untracked-files=", "--ignored=", "--decorate=", "--format=", "--pretty=", "--date=", "--since=", "--until=", "--after=", "--before=", "--author=", "--committer=", "--grep=", "--max-count=", "--skip=", "--abbrev=", "--unified=", "--diff-filter=", "--word-diff=", "--color=", "--color-moved=", "--find-renames=", "--diff-algorithm=", "--dirstat=", "--branches=", "--tags=", "--remotes=", "--glob=", "--ignore-submodules=", "--min-parents=", "--max-parents=", "--stat-width=", "--stat-count="]

# each long flag counts as the char x (no caller reads the flags)
def flags.x(xs: List<&2, String>) -> List<&2, T.Arg>:
  match xs:
    case Nil{}:
      []
    case f <> t:
      T.Arg{f, "x"} <> flags.x(t)

def gread.spec() -> Model.Spec:
  Model.spec("sbpuwzMRaivq", "nUSG", flags.x(gread.long()), True{}, True{})

# Pathspecs (SH-4). status, log and diff print the content or names of the
# paths they are given, so each path is a ReadTree: every word after "--",
# and every operand before it that does not look like a revision. An operand
# that names exactly the current folder ("." from every possible folder)
# adds nothing, the same as no path. GitRead is always there.

# '\' read as '/'
def rev.sl.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{92}, t}:
      rev.sl.go(t, SCon{Chr{47}, acc})
    case SCon{c, t}:
      rev.sl.go(t, SCon{c, acc})

def rev.sl(s: String) -> String:
  rev.sl.go(s, "")

def rev.hexc(c: Char) -> Bool:
  match c:
    case Chr{97}:
      True{}
    case Chr{98}:
      True{}
    case Chr{99}:
      True{}
    case Chr{100}:
      True{}
    case Chr{101}:
      True{}
    case Chr{102}:
      True{}
    case _:
      False{}

def rev.hex.go(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{+c, t}:
      rev.hex.go(t, acc && (Char.is_digit(c) || rev.hexc(Char.to_lower(c))))

def rev.hex(s: String) -> Bool:
  rev.hex.go(s, True{})

def rev.name(s: String) -> Bool:
  match s:
    case "HEAD":
      True{}
    case "FETCH_HEAD":
      True{}
    case "ORIG_HEAD":
      True{}
    case "MERGE_HEAD":
      True{}
    case _:
      False{}

# s ('\' read as '/') looks like a revision: HEAD and friends, a hash of 7 or
# more hex digits, or it holds ~ ^ @ { or a range ".." inside a part
# (main..feature). Never a word that starts with ~ / or . (a path), holds ':'
# (gpaths makes that Unknown), or has a part that starts with '.' (../x).
def rev.like(+s: String) -> Bool:
  +p = String.starts_with(s, "~") || String.starts_with(s, "/") || String.starts_with(s, ".") || String.contains(s, ":") || String.contains(s, "/.")
  +r = rev.name(s) || (Nat.is_le(7n, String.length(s)) && rev.hex(s)) || String.contains(s, "~") || String.contains(s, "^") || String.contains(s, "@") || String.contains(s, "{") || String.contains(s, "..")
  Bool.not(p) && r

def here.all(ps: List<&2, T.Path>, qs: List<&2, T.Path>) -> Bool:
  match ps qs:
    case Nil{} Nil{}:
      True{}
    case Con{p, pt} Con{q, qt}:
      Path.eq(p, q) && here.all(pt, qt)
    case _ _:
      False{}

def here.is(a: Maybe<&2, List<&2, T.Path>>, b: Maybe<&2, List<&2, T.Path>>) -> Bool:
  match a b:
    case Some{ps} Some{qs}:
      here.all(ps, qs)
    case _ _:
      False{}

# raw names exactly the current folder, from every possible folder
def here(+cwds: List<&2, String>, +home: String, +raw: String) -> Bool:
  Bool.not(glob.has(raw, False{})) && Bool.not(colon.bad(raw)) && here.is(Model.resolve(cwds, home, raw), Model.resolve(cwds, home, "."))

def gread.op.k(h: Bool, r: Bool, raw: String, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match h r:
    case True{} _:
      T.Known{[]}
    case False{} True{}:
      T.Known{[]}
    case False{} False{}:
      gpaths([raw], sh, k, cwds, home)

def gread.op.c(c: Bool, nd: Bool, revok: Bool, +raw: String, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match c:
    case True{}:
      rp.read(nd, raw, cwds, home)
    case False{}:
      gread.op.k(here(cwds, home, raw), revok && rev.like(rev.sl(raw)), raw, k, sh, cwds, home)

# rp: whether a <rev>:<path> word is read (Rpm); revok: the word may be a
# revision (it stands before "--"); k: the kind of action on a path
# (ReadTree for content, ListDir for names only)
def gread.op(+rp: Rpm, revok: Bool, +raw: String, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  gread.op.c(rpm.on(rp) && colon.bad(raw), rpm.nd(rp), revok, raw, k, sh, cwds, home)

def gread.list(raws: List<&2, String>, +rp: Rpm, +revok: Bool, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match raws:
    case Nil{}:
      T.Known{[]}
    case r <> t:
      Model.join(gread.op(rp, revok, r, k, sh, cwds, home), gread.list(t, rp, revok, k, sh, cwds, home))

# ops: the operands before "--" (a <rev>:<path> among them read as rp says);
# post: the words after it (the colon rule)
def gread.ops.k(rp: Rpm, ops: List<&2, String>, post: List<&2, String>, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  Model.join(T.Known{[T.GitRead{}]}, Model.join(gread.list(ops, rp, True{}, k, sh, cwds, home), gread.list(post, Rpm.No{}, False{}, k, sh, cwds, home)))

def gread.ops(ops: List<&2, String>, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  gread.ops.k(Rpm.No{}, ops, post, Model.AKind.ReadTree{}, sh, cwds, home)

def gread.o(o: Model.Opts, post: List<&2, String>, rp: Rpm, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      gread.ops.k(rp, ops, post, k, sh, cwds, home)

# a read-only git command read with spec sp; kind k on each path it names;
# rp: whether a <rev>:<path> operand is read
def gread.with.rp(rp: Rpm, sp: Model.Spec, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  gread.o(Model.parse(sp, dd.pre(args)), dd.post(args), rp, k, sh, cwds, home)

def gread.with(sp: Model.Spec, +k: Model.AKind, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  gread.with.rp(Rpm.No{}, sp, k, sh, cwds, home, args)

# git status, log, show, rev-list with its words args
def gread.run(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  gread.with(gread.spec(), Model.AKind.ReadTree{}, sh, cwds, home, args)

# git diff with exactly two arguments compares two files when one is outside
# the repository (an implied --no-index), so both are read
def diff.ops(ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Con{a, Con{b, Nil{}}}:
      Model.why_prefix("with two arguments diff may compare files outside the repository: ", gpaths([a, b], sh, Model.AKind.ReadTree{}, cwds, home))
    case _:
      T.Known{[]}

# exactly two operands, each a <rev>:<path> (blob against blob)
def diff.blobs(ops: List<&2, String>) -> Bool:
  match ops:
    case Con{a, Con{b, Nil{}}}:
      colon.bad(a) && colon.bad(b)
    case _:
      False{}

# blob against blob: no file outside the repository is read (the paths
# hold no '..'), so only the two object names are; otherwise as before
def diff.k(blobs: Bool, +ops: List<&2, String>, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match blobs:
    case True{}:
      gread.ops.k(Rpm.NoDots{}, ops, post, Model.AKind.ReadTree{}, sh, cwds, home)
    case False{}:
      Model.join(gread.ops(ops, post, sh, cwds, home), diff.ops(ops, sh, cwds, home))

def diff.o(o: Model.Opts, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      diff.k(diff.blobs(ops), ops, post, sh, cwds, home)

def diff.run(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  diff.o(Model.parse(gread.spec(), dd.pre(args)), dd.post(args), sh, cwds, home)

# ---------------------------------------------------------------------------
# git push: GitPush{dir, force, all, refs, unsure}

# the refspec without a leading +
def refspec.body(+r: String) -> String:
  Model.pick.s(String.starts_with(r, "+"), String.drop(r, 1n), r)

# the text after the first ':'
def refspec.after(s: String) -> Maybe<&2, String>:
  match s:
    case SNil{}:
      None{}
    case SCon{Chr{58}, t}:
      Some{t}
    case SCon{c, t}:
      refspec.after(t)

def refspec.dest(m: Maybe<&2, String>, body: String) -> String:
  match m:
    case Some{d}:
      d
    case None{}:
      body

# the destination: dst of src:dst, or the name itself for a plain name
def refspec.target(+r: String) -> String:
  refspec.dest(refspec.after(refspec.body(r)), refspec.body(r))

# a destination we can name: a plain ref name, not HEAD or @, no wildcard,
# none of the spellings git would read another way
def refspec.ok(+d: String) -> Bool:
  cc.all(d, True{}, True{}) && Bool.not(String.is_empty(d)) && Bool.not(String.eq(low(d), "head")) && Bool.not(String.starts_with(d, ".")) && Bool.not(String.starts_with(d, "/")) && Bool.not(String.starts_with(d, "-")) && Bool.not(String.ends_with(d, "/")) && Bool.not(String.ends_with(d, ".")) && Bool.not(String.ends_with(d, ".lock")) && Bool.not(String.contains(d, "//")) && Bool.not(String.contains(d, "..")) && Bool.not(String.contains(d, "/."))

def refspec.strip.if(a: Bool, b: Bool, d: String) -> String:
  match a b:
    case True{} _:
      String.drop(d, 11n)
    case False{} True{}:
      String.drop(d, 6n)
    case False{} False{}:
      d

# refs/heads/x and heads/x (which git resolves to refs/heads/x) give x
def refspec.strip(+d: String) -> String:
  refspec.strip.if(String.starts_with(low(d), "refs/heads/"), String.starts_with(low(d), "heads/"), d)

def refspec.name.if(ok: Bool, n: String) -> List<&2, String>:
  match ok:
    case True{}:
      [n]
    case False{}:
      []

def refspec.name(+d: String) -> List<&2, String>:
  refspec.name.if(refspec.ok(d), refspec.strip(d))

def refspec.refs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case r <> t:
      List.append(&2, String, refspec.name(refspec.target(r)), refspec.refs(t))

def refspec.unsure(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case r <> t:
      Bool.not(refspec.ok(refspec.target(r))) || refspec.unsure(t)

# +ref forces; :dst (no source) deletes the remote branch, counted as force
def refspec.force(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +r <> t:
      (String.starts_with(r, "+") || String.starts_with(refspec.body(r), ":")) || refspec.force(t)

def remote.ok(+r: String) -> Bool:
  cc.all(r, True{}, False{}) && Bool.not(String.is_empty(r)) && Bool.not(String.starts_with(r, "."))

def push.spec() -> Model.Spec:
  Model.spec("fun", "", [T.Arg{"--force", "f"}, T.Arg{"--force-with-lease", "f"}, T.Arg{"--force-if-includes", "f"}, T.Arg{"--set-upstream", "u"}, T.Arg{"--all", "a"}, T.Arg{"--mirror", "m"}, T.Arg{"--tags", "t"}, T.Arg{"--delete", "d"}, T.Arg{"--dry-run", "n"}], False{}, False{})

def push.remote(ok: Bool, rem: String, d: T.Path, fo: Bool, al: Bool, +xs: List<&2, String>) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitPush{d, fo || refspec.force(xs), al, refspec.refs(xs), List.is_empty(&2, String, xs) || refspec.unsure(xs)}]}
    case False{}:
      Model.unknown("the push target " ++ rem ++ " is not a plain remote name, so where it writes is not known")

# no remote, or a remote and no refspec: refs [] and unsure
def push.ops(ops: List<&2, String>, d: T.Path, fo: Bool, al: Bool) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitPush{d, fo, al, [], True{}}]}
    case +r <> xs:
      push.remote(remote.ok(r), r, d, fo, al, xs)

# dir is the only possible folder; more than one, or none known, is Unknown
def push.at(m: Maybe<&2, List<&2, T.Path>>, +fl: String, ops: List<&2, String>) -> T.Meaning:
  match m:
    case Some{Con{d, Nil{}}}:
      push.ops(ops, d, Model.has_char(fl, 'f') || Model.has_char(fl, 'm') || Model.has_char(fl, 'd'), Model.has_char(fl, 'a') || Model.has_char(fl, 'm'))
    case Some{_}:
      Model.unknown("the shell may be in more than one folder, so the repository it pushes from is not known")
    case None{}:
      Model.unknown("the shell's current folder is not known, so the repository it pushes from is not known")

def push.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      push.at(Model.resolve(cwds, home, "."), fl, ops)

# ---------------------------------------------------------------------------
# git checkout, switch, restore, stash, reset --hard, apply, clean

# a new branch from HEAD (no start point) changes no file: GitRef
def newref(ops: List<&2, String>, what: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRef{}]}
    case Con{s, Nil{}}:
      wide(what ++ " with a start point", cwds, home)
    case _:
      Model.unknown(what ++ " takes one start point at most")

# checkout <commit> -- [paths]
def co.tree(post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match post:
    case Nil{}:
      wide("checkout of another commit", cwds, home)
    case p <> t:
      gpaths(p <> t, sh, Model.AKind.WriteTree{}, cwds, home)

# checkout with --: before it at most one commit, after it the paths
def co.dd(ops: List<&2, String>, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      tree.ps(post, sh, Model.AKind.WriteTree{}, cwds, home)
    case Con{c, Nil{}}:
      co.tree(post, sh, cwds, home)
    case _:
      Model.unknown("more than one commit before -- is not modelled")

# a ref name never starts with '.', so then every argument is a path;
# otherwise the first may be a branch (a whole-tree rewrite) or a path
def co.plain.k(isp: Bool, ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match isp:
    case True{}:
      gpaths(ops, sh, Model.AKind.WriteTree{}, cwds, home)
    case False{}:
      Model.join(wide("checkout of a branch or commit", cwds, home), gpaths(ops, sh, Model.AKind.WriteTree{}, cwds, home))

def co.plain(ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      folders(Model.AKind.WriteTree{}, cwds, home)
    case +o <> t:
      co.plain.k(String.starts_with(o, "."), o <> t, sh, cwds, home)

def co.k(b: Bool, has: Bool, ops: List<&2, String>, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match b has:
    case True{} True{}:
      Model.unknown("checkout -b with paths is not modelled")
    case True{} False{}:
      newref(ops, "checkout -b", cwds, home)
    case False{} True{}:
      co.dd(ops, post, sh, cwds, home)
    case False{} False{}:
      co.plain(ops, sh, cwds, home)

def co.o(o: Model.Opts, has: Bool, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      co.k(Model.has_char(fl, 'b'), has, ops, post, sh, cwds, home)

def git.checkout(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  co.o(Model.parse(Model.spec("", "b", [], False{}, False{}), dd.pre(args)), dd.has(args), dd.post(args), sh, cwds, home)

# restore [--staged] [--worktree] [--] <paths>: WriteTree of each path
def rst.o(o: Model.Opts, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      tree.ps(List.append(&2, String, ops, post), sh, Model.AKind.WriteTree{}, cwds, home)

def git.restore(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  rst.o(Model.parse(Model.spec("", "", [T.Arg{"--staged", "s"}, T.Arg{"--worktree", "w"}], False{}, False{}), dd.pre(args)), dd.post(args), sh, cwds, home)

def sw.to(ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Con{r, Nil{}}:
      wide("switch to another branch", cwds, home)
    case _:
      Model.unknown("switch takes one branch name")

def sw.k(c: Bool, ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match c:
    case True{}:
      newref(ops, "switch -c", cwds, home)
    case False{}:
      sw.to(ops, cwds, home)

def sw.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      sw.k(Model.has_char(fl, 'c'), ops, cwds, home)

def git.switch(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  sw.o(Model.parse(Model.spec("", "c", [], False{}, False{}), args), cwds, home)

# stash in any form, with only these flags (show and list take diff and log
# options such as --output=<file>, which writes a file)
def gstash.flag(+w: String) -> Bool:
  Model.elem(w, ["--", "-q", "--quiet", "-k", "--keep-index", "--no-keep-index", "-u", "--include-untracked", "-a", "--all", "-S", "--staged", "--index", "-m", "--message", "-p", "--patch"])

def gstash.bad(ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      (String.starts_with(w, "-") && Bool.not(gstash.flag(w))) || gstash.bad(t)

def gstash.k(bad: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown("stash flags other than -q -k -u -a -S -m -p --index (and their long names) are not modelled")
    case False{}:
      wide("stash", cwds, home)

def git.stash.any(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  gstash.k(gstash.bad(args), cwds, home)

# stash list (no options: it takes log options such as --output=<file>)
def gstash.list(ws: List<&2, String>) -> T.Meaning:
  match ws:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case _:
      Model.unknown("stash list with options is not modelled")

# N or stash@{N}
def sref.go(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{125}, SNil{}}:
      acc
    case SCon{c, t}:
      sref.go(t, acc && Char.is_digit(c))

def sref(+s: String) -> Bool:
  (Bool.not(String.is_empty(s)) && Model.all_digits(s)) || (String.starts_with(s, "stash@{") && Nat.is_le(9n, String.length(s)) && sref.go(String.drop(s, 7n), True{}))

def gstash.show.r(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitRead{}]}
    case False{}:
      Model.unknown("stash show takes a stash as N or stash@{N}")

def gstash.show.k(ops: List<&2, String>) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case Con{+r, Nil{}}:
      gstash.show.r(sref(r))
    case _:
      Model.unknown("stash show takes one stash at most")

def gstash.show.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      gstash.show.k(ops)

# stash show [-p | --patch | --stat] [N | stash@{N}]: GitRead
def gstash.show(ws: List<&2, String>) -> T.Meaning:
  gstash.show.o(Model.parse(Model.spec("p", "", [T.Arg{"--patch", "p"}, T.Arg{"--stat", "t"}], False{}, False{}), ws))

# gstash.sub: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitGstashSub is Data:
  KGitGstashSub.List{}
  KGitGstashSub.Show{}
  KGitGstashSub.Rest{}

type KGitGstashSubE is Data:
  KGitGstashSubE.Mk{name: String, k: KGitGstashSub}

def gstash.sub.tab() -> List<&2, KGitGstashSubE>:
  [KGitGstashSubE.Mk{"list", KGitGstashSub.List{}}, KGitGstashSubE.Mk{"show", KGitGstashSub.Show{}}]

def gstash.sub.go(xs: List<&2, KGitGstashSubE>, hit: Bool, k: KGitGstashSub, +w: String) -> KGitGstashSub:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitGstashSub.Rest{}
    case KGitGstashSubE.Mk{n, k2} <> t False{}:
      gstash.sub.go(t, String.eq(n, w), k2, w)

def gstash.sub.find(xs: List<&2, KGitGstashSubE>, +w: String) -> KGitGstashSub:
  gstash.sub.go(xs, False{}, KGitGstashSub.Rest{}, w)

def gstash.sub.k(key: KGitGstashSub, +a: String, t: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KGitGstashSub.List{}:
      gstash.list(t)
    case KGitGstashSub.Show{}:
      gstash.show(t)
    case KGitGstashSub.Rest{}:
      git.stash.any(cwds, home, a <> t)

def gstash.sub(+a: String, t: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  gstash.sub.k(gstash.sub.find(gstash.sub.tab(), a), a, t, cwds, home)

def git.stash(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      git.stash.any(cwds, home, [])
    case a <> t:
      gstash.sub(a, t, cwds, home)

def greset.k(h: Bool, ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match h ops:
    case True{} Nil{}:
      wide("reset --hard", cwds, home)
    case True{} Con{c, Nil{}}:
      wide("reset --hard", cwds, home)
    case True{} _:
      Model.unknown("reset --hard takes one commit at most")
    case False{} _:
      Model.unknown("only git reset --hard is modelled")

def greset.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      greset.k(Model.has_char(fl, 'h'), ops, cwds, home)

def git.reset(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  greset.o(Model.parse(Model.spec("", "", [T.Arg{"--hard", "h"}], False{}, False{}), args), cwds, home)

# apply <patch>...: reads each patch, rewrites files below the current folder
# (git ignores patched paths outside it when run in a subfolder)
def gapply.k(g: Bool, ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case True{}:
      Model.unknown("wildcards (*, ? or [) in patch names are not modelled")
    case False{}:
      Model.join(gpaths(ops, sh, Model.AKind.Read{}, cwds, home), folders(Model.AKind.WriteTree{}, cwds, home))

def gapply.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      gapply.k(Model.any_glob(ops), ops, sh, cwds, home)

def git.apply(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  gapply.o(Model.parse(Model.spec("", "", [], False{}, False{}), args), sh, cwds, home)

# clean -f -d -x -X -n [--] [paths]: DeleteTree of each path, or of each
# possible folder (git clean works below the current folder)
def gclean.o(o: Model.Opts, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      tree.ps(List.append(&2, String, ops, post), sh, Model.AKind.DeleteTree{}, cwds, home)

def git.clean(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  gclean.o(Model.parse(Model.spec("fdxXn", "", [], False{}, False{}), dd.pre(args)), dd.post(args), sh, cwds, home)

# ---------------------------------------------------------------------------
# git

# ---------------------------------------------------------------------------
# More read-only git commands (round 2, P8): GitRead, with a read of each
# path they name (ReadTree for content, ListDir for names only)

def shortlog.spec() -> Model.Spec:
  Model.spec("sne", "", flags.x(["--summary", "--numbered", "--email", "--all", "--no-merges", "--merges", "--since=", "--until=", "--after=", "--before=", "--author=", "--committer=", "--grep=", "--format=", "--group=", "--max-count="]), False{}, True{})

# never -S <file> or --ignore-revs-file (read a file of revisions)
def blame.spec() -> Model.Spec:
  Model.spec("wMCesltfnpc", "L", flags.x(["--porcelain", "--line-porcelain", "--show-email", "--show-name", "--show-number", "--root", "--first-parent", "--incremental", "--date=", "--abbrev=", "--color-lines", "--color-by-age"]), False{}, True{})

def lsfiles.spec() -> Model.Spec:
  Model.spec("cdmoiskutvz", "", flags.x(["--cached", "--deleted", "--modified", "--others", "--ignored", "--stage", "--unmerged", "--killed", "--exclude-standard", "--directory", "--no-empty-directory", "--full-name", "--error-unmatch", "--abbrev", "--abbrev=", "--exclude=", "--eol", "--deduplicate", "--format="]), False{}, True{})

def lstree.spec() -> Model.Spec:
  Model.spec("rdtlz", "", flags.x(["--name-only", "--name-status", "--object-only", "--full-name", "--full-tree", "--long", "--abbrev", "--abbrev=", "--format="]), False{}, True{})

def checkignore.spec() -> Model.Spec:
  Model.spec("vnqz", "", flags.x(["--verbose", "--non-matching", "--quiet", "--no-index"]), False{}, True{})

# git grep: never -f <file> (reads patterns from a file), -O or
# --open-files-in-pager (runs a program) or --textconv
def ggrep.spec() -> Model.Spec:
  Model.spec("nilLcwvEFPhHIoqzaprW", "eABCm", flags.x(["--cached", "--untracked", "--no-index", "--ignore-case", "--line-number", "--count", "--files-with-matches", "--files-without-match", "--name-only", "--word-regexp", "--invert-match", "--extended-regexp", "--fixed-strings", "--perl-regexp", "--basic-regexp", "--full-name", "--heading", "--break", "--all-match", "--and", "--or", "--not", "--exclude-standard", "--null", "--only-matching", "--show-function", "--function-context", "--column", "--quiet", "--text", "--no-textconv", "--color", "--no-color", "--max-depth=", "--threads=", "--context=", "--after-context=", "--before-context=", "--color="]), True{}, True{})

def gwords.add(r: Bool, w: String, acc: List<&2, String>) -> List<&2, String>:
  match r:
    case True{}:
      acc
    case False{}:
      w <> acc

# the operands that are paths: each word that does not look like a revision
def gwords.go(ws: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +w <> t:
      gwords.go(t, gwords.add(rev.like(rev.sl(w)), w, acc))

# GitRead, a ReadTree of each path (of each possible folder when none is
# named: git grep searches below the current folder), and the folder that a
# bash wildcard in the pattern can reach
def ggrep.fin(pat: List<&2, String>, ps: List<&2, String>, post: List<&2, String>, lo: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  Model.join(T.Known{[T.GitRead{}]}, Model.join(tree.ps(List.append(&2, String, ps, post), sh, Model.AKind.ReadTree{}, cwds, home), Model.wglobs(List.append(&2, String, pat, lo), sh, cwds, home)))

# the first operand is the pattern unless -e is given
def ggrep.k(hase: Bool, ops: List<&2, String>, post: List<&2, String>, lo: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match hase ops:
    case False{} Nil{}:
      Model.unknown("no pattern is given")
    case False{} Con{p, t}:
      ggrep.fin([p], gwords.go(t, []), post, lo, sh, cwds, home)
    case True{} xs:
      ggrep.fin([], gwords.go(xs, []), post, lo, sh, cwds, home)

def ggrep.o(o: Model.Opts, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      ggrep.k(Model.has_char(fl, 'e'), ops, post, lo, sh, cwds, home)

def git.grep(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  ggrep.o(Model.parse(ggrep.spec(), dd.pre(args)), dd.post(args), sh, cwds, home)

# commands whose operands are revisions or ref patterns only: GitRead
def grevs.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      T.Known{[T.GitRead{}]}

def grevs(sp: Model.Spec, args: List<&2, String>) -> T.Meaning:
  grevs.o(Model.parse(sp, args))

def describe.spec() -> Model.Spec:
  Model.spec("", "", flags.x(["--tags", "--all", "--always", "--long", "--abbrev=", "--dirty", "--dirty=", "--broken", "--exact-match", "--contains", "--first-parent", "--match=", "--exclude=", "--candidates="]), False{}, False{})

def mergebase.spec() -> Model.Spec:
  Model.spec("a", "", flags.x(["--is-ancestor", "--all", "--octopus", "--independent", "--fork-point"]), False{}, False{})

def namerev.spec() -> Model.Spec:
  Model.spec("", "", flags.x(["--name-only", "--tags", "--always", "--all", "--no-undefined", "--refs=", "--exclude="]), False{}, False{})

def foreachref.spec() -> Model.Spec:
  Model.spec("", "", flags.x(["--format=", "--sort=", "--count=", "--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at=", "--shell", "--perl", "--python", "--tcl", "--ignore-case", "--omit-empty"]), False{}, False{})

def showref.spec() -> Model.Spec:
  Model.spec("sdq", "", flags.x(["--heads", "--tags", "--branches", "--hash", "--hash=", "--verify", "--dereference", "--abbrev", "--abbrev=", "--quiet", "--head", "--exists"]), False{}, True{})

def revparse.spec() -> Model.Spec:
  Model.spec("q", "", flags.x(["--show-toplevel", "--abbrev-ref", "--abbrev-ref=", "--short", "--short=", "--git-dir", "--absolute-git-dir", "--git-common-dir", "--is-inside-work-tree", "--is-inside-git-dir", "--is-bare-repository", "--is-shallow-repository", "--show-prefix", "--show-cdup", "--verify", "--quiet", "--symbolic", "--symbolic-full-name", "--show-superproject-working-tree", "--all", "--branches", "--tags", "--remotes", "--show-object-format", "--show-ref-format"]), False{}, True{})

# rev-parse: GitRead, and each <rev>:<path> operand read as above (git
# prints the object's hash, which can give away a short file's content)
def rps.one(c: Bool, +o: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match c:
    case True{}:
      rp.read(False{}, o, cwds, home)
    case False{}:
      T.Known{[]}

def rps.list(ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[]}
    case +o <> t:
      Model.join(rps.one(colon.bad(o), o, cwds, home), rps.list(t, cwds, home))

def revparse.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      Model.join(T.Known{[T.GitRead{}]}, rps.list(ops, cwds, home))

# cat-file -t -s -p -e <object>: GitRead, and a ReadTree of each place a
# <rev>:<path> object can name; cat-file <type> <object>: GitRead, with no
# ':' in either word
def catfile.one(col: Bool, fl: Bool, +o: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match col fl:
    case False{} _:
      T.Known{[T.GitRead{}]}
    case True{} True{}:
      Model.join(T.Known{[T.GitRead{}]}, rp.read(False{}, o, cwds, home))
    case True{} False{}:
      Model.unknown("a ':' in an object name (<rev>:<path>) is modelled only with cat-file -p, -t, -s or -e")

def catfile.two(col: Bool) -> T.Meaning:
  match col:
    case True{}:
      Model.unknown("a ':' in an object name (<rev>:<path>) after a type is not modelled; cat-file -p <rev>:<path> is")
    case False{}:
      T.Known{[T.GitRead{}]}

def catfile.k(fl: Bool, ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Con{+o, Nil{}}:
      catfile.one(Path.has_colon(o), fl, o, cwds, home)
    case Con{+k, Con{+o, Nil{}}}:
      catfile.two(Path.has_colon(k) || Path.has_colon(o))
    case _:
      Model.unknown("cat-file takes one object, or a type and an object")

def catfile.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      catfile.k(Bool.not(String.is_empty(fl)), ops, cwds, home)

# branch: the listing forms only (no name; or a pattern with --list, -v,
# --contains, --merged and the like, which all list)
def branch.spec() -> Model.Spec:
  Model.spec("arvli", "", [T.Arg{"--all", "a"}, T.Arg{"--remotes", "r"}, T.Arg{"--verbose", "v"}, T.Arg{"--list", "l"}, T.Arg{"--show-current", "c"}, T.Arg{"--contains", "l"}, T.Arg{"--no-contains", "l"}, T.Arg{"--merged", "l"}, T.Arg{"--no-merged", "l"}, T.Arg{"--contains=", "l"}, T.Arg{"--no-contains=", "l"}, T.Arg{"--merged=", "l"}, T.Arg{"--no-merged=", "l"}, T.Arg{"--points-at=", "l"}, T.Arg{"--sort=", "o"}, T.Arg{"--format=", "o"}, T.Arg{"--color", "o"}, T.Arg{"--no-color", "o"}, T.Arg{"--ignore-case", "i"}, T.Arg{"--column", "o"}, T.Arg{"--no-column", "o"}, T.Arg{"--abbrev=", "o"}, T.Arg{"--no-abbrev", "o"}], False{}, False{})

def branch.k(ops: List<&2, String>, lst: Bool) -> T.Meaning:
  match ops lst:
    case Nil{} _:
      T.Known{[T.GitRead{}]}
    case _ True{}:
      T.Known{[T.GitRead{}]}
    case _ False{}:
      Model.unknown("git branch with a name makes, renames or deletes a branch, which is not modelled")

def branch.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      branch.k(ops, Model.has_char(fl, 'l') || Model.has_char(fl, 'v'))

# remote, remote -v, remote get-url <name>, remote show <name>: GitRead
def remote.unk() -> T.Meaning:
  Model.unknown("only git remote, remote -v, remote get-url <name> and remote show <name> are modelled")

def remote.pick(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitRead{}]}
    case False{}:
      remote.unk()

def git.remote(args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case Con{+a, Nil{}}:
      remote.pick(String.eq(a, "-v") || String.eq(a, "--verbose"))
    case Con{+a, Con{+b, Nil{}}}:
      remote.pick((String.eq(a, "get-url") || String.eq(a, "show")) && remote.ok(b))
    case _:
      remote.unk()

# add [-A | -u | -v] [--] <paths>: GitRef, and a ReadTree of each path (git
# copies its content), so git add .env is refused and git add . at the
# project root asks (D4). -A or -u with no path adds across the whole
# repository: Unknown, with a ReadTree of each possible folder.
def add.spec() -> Model.Spec:
  Model.spec("Auv", "", [T.Arg{"--all", "A"}, T.Arg{"--update", "u"}, T.Arg{"--verbose", "v"}], False{}, True{})

def add.wide(m: T.Meaning) -> T.Meaning:
  match m:
    case T.Known{xs}:
      T.Unknown{"add -A or -u with no path adds files anywhere in the repository, also above the current folder", T.GitRef{} <> xs}
    case T.Unknown{w, xs}:
      T.Unknown{w, xs}

def add.k(ps: List<&2, String>, all: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ps all:
    case Nil{} False{}:
      T.Known{[T.GitRef{}]}
    case Nil{} True{}:
      add.wide(folders(Model.AKind.ReadTree{}, cwds, home))
    case Con{p, t} _:
      Model.join(T.Known{[T.GitRef{}]}, gpaths(p <> t, sh, Model.AKind.ReadTree{}, cwds, home))

def add.o(o: Model.Opts, post: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      add.k(List.append(&2, String, ops, post), Model.has_char(fl, 'A') || Model.has_char(fl, 'u'), sh, cwds, home)

def git.add(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  add.o(Model.parse(add.spec(), dd.pre(args)), dd.post(args), sh, cwds, home)

# fetch [--all --prune -p --tags -q -v] [<remote>]: GitRef (refs and objects
# only, no working file)
def fetch.spec() -> Model.Spec:
  Model.spec("pqv", "", [T.Arg{"--all", "a"}, T.Arg{"--prune", "p"}, T.Arg{"--tags", "t"}, T.Arg{"--quiet", "q"}, T.Arg{"--verbose", "v"}], False{}, False{})

def fetch.r(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitRef{}]}
    case False{}:
      Model.unknown("the fetch source is not a plain remote name")

def fetch.ops(ops: List<&2, String>) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRef{}]}
    case Con{+r, Nil{}}:
      fetch.r(remote.ok(r))
    case _:
      Model.unknown("fetch takes one plain remote name at most (refspecs are not modelled)")

def fetch.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      fetch.ops(ops)

# config --get / --get-all / --get-regexp NAME [PATTERN], config --list,
# config NAME, config list, config get NAME: GitRead. Every other form may write git's settings (round 2, ADJ-1): it
# stays Unknown with a WriteTree of .git/config in each possible folder (the
# -C folders under git -C) and of ~/.gitconfig as its known part, so
# self-protection refuses it, also after the user's yes and in log-only mode
# (design.md: bend-guard never lets Claude change git config).
def config.spec() -> Model.Spec:
  Model.spec("lz", "", [T.Arg{"--get", "g"}, T.Arg{"--get-all", "g"}, T.Arg{"--get-regexp", "g"}, T.Arg{"--list", "l"}, T.Arg{"--global", "o"}, T.Arg{"--local", "o"}, T.Arg{"--system", "o"}, T.Arg{"--show-origin", "o"}, T.Arg{"--show-scope", "o"}, T.Arg{"--name-only", "o"}, T.Arg{"--null", "z"}, T.Arg{"--includes", "o"}, T.Arg{"--no-includes", "o"}], False{}, False{})

def config.why() -> String:
  "git config changes git's settings, which bend-guard protects (a setting such as core.hooksPath or an alias runs code later); the user runs it themselves"

def config.w(+cwds: List<&2, String>, +home: String) -> T.Meaning:
  T.Unknown{config.why(), List.append(&2, T.Action, Model.acts.of(Model.path(Model.AKind.WriteTree{}, cwds, home, ".git/config")), Model.acts.of(Model.path(Model.AKind.WriteTree{}, cwds, home, "~/.gitconfig")))}

def config.r(read: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match read:
    case True{}:
      T.Known{[T.GitRead{}]}
    case False{}:
      config.w(cwds, home)

# with no option: config NAME (a dotted key, so not the "edit" subcommand of
# newer git), config list and config get NAME read too
# config.one: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitConfigOne is Data:
  KGitConfigOne.List{}
  KGitConfigOne.Rest{}

type KGitConfigOneE is Data:
  KGitConfigOneE.Mk{name: String, k: KGitConfigOne}

def config.one.tab() -> List<&2, KGitConfigOneE>:
  [KGitConfigOneE.Mk{"list", KGitConfigOne.List{}}]

def config.one.go(xs: List<&2, KGitConfigOneE>, hit: Bool, k: KGitConfigOne, +w: String) -> KGitConfigOne:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitConfigOne.Rest{}
    case KGitConfigOneE.Mk{n, k2} <> t False{}:
      config.one.go(t, String.eq(n, w), k2, w)

def config.one.find(xs: List<&2, KGitConfigOneE>, +w: String) -> KGitConfigOne:
  config.one.go(xs, False{}, KGitConfigOne.Rest{}, w)

def config.one.k(key: KGitConfigOne, +a: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KGitConfigOne.List{}:
      T.Known{[T.GitRead{}]}
    case KGitConfigOne.Rest{}:
      config.r(String.contains(a, ".") && Bool.not(String.starts_with(a, "-")), cwds, home)

def config.one(+a: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  config.one.k(config.one.find(config.one.tab(), a), a, cwds, home)

def config.two(a: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match a:
    case "get":
      T.Known{[T.GitRead{}]}
    case _:
      config.w(cwds, home)

def config.k(get: Bool, lst: Bool, ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match get lst ops:
    case True{} False{} Con{a, Nil{}}:
      T.Known{[T.GitRead{}]}
    case True{} False{} Con{a, Con{b, Nil{}}}:
      T.Known{[T.GitRead{}]}
    case False{} True{} Nil{}:
      T.Known{[T.GitRead{}]}
    case False{} False{} Con{a, Nil{}}:
      config.one(a, cwds, home)
    case False{} False{} Con{a, Con{b, Nil{}}}:
      config.two(a, cwds, home)
    case _ _ _:
      config.w(cwds, home)

def config.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      config.w(cwds, home)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      config.k(Model.has_char(fl, 'g'), Model.has_char(fl, 'l'), ops, cwds, home)

def reflog.w(+a: String) -> T.Meaning:
  Model.unknown("reflog " ++ a ++ " changes the reflog, which is not modelled")

# reflog.k: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitReflogK is Data:
  KGitReflogK.Show{}
  KGitReflogK.Expire{}
  KGitReflogK.Rest{}

type KGitReflogKE is Data:
  KGitReflogKE.Mk{name: String, k: KGitReflogK}

def reflog.k.tab() -> List<&2, KGitReflogKE>:
  [KGitReflogKE.Mk{"show", KGitReflogK.Show{}}, KGitReflogKE.Mk{"expire", KGitReflogK.Expire{}}, KGitReflogKE.Mk{"delete", KGitReflogK.Expire{}}, KGitReflogKE.Mk{"drop", KGitReflogK.Expire{}}]

def reflog.k.go(xs: List<&2, KGitReflogKE>, hit: Bool, k: KGitReflogK, +w: String) -> KGitReflogK:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitReflogK.Rest{}
    case KGitReflogKE.Mk{n, k2} <> t False{}:
      reflog.k.go(t, String.eq(n, w), k2, w)

def reflog.k.find(xs: List<&2, KGitReflogKE>, +w: String) -> KGitReflogK:
  reflog.k.go(xs, False{}, KGitReflogK.Rest{}, w)

def reflog.k.k(key: KGitReflogK, +a: String, t: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KGitReflogK.Show{}:
      gread.run(sh, cwds, home, t)
    case KGitReflogK.Expire{}:
      reflog.w(a)
    case KGitReflogK.Rest{}:
      gread.run(sh, cwds, home, a <> t)

def reflog.k(+a: String, t: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  reflog.k.k(reflog.k.find(reflog.k.tab(), a), a, t, sh, cwds, home)

# reflog [show] with log's options: GitRead
def git.reflog(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      gread.run(sh, cwds, home, [])
    case a <> t:
      reflog.k(a, t, sh, cwds, home)

# ---------------------------------------------------------------------------
# Listings that read refs and objects only (round 3, P8): GitRead

# tag: the listing forms only. With no operand, or with -l/--list, -n[N],
# --contains X or --points-at X (git lists then, and their value is read as
# one more pattern), every operand is a pattern; --sort=X orders the list.
# A name without them makes a tag; -a, -d, -f, -s and the rest are not known.
def tag.spec() -> Model.Spec:
  Model.spec("ln", "", [T.Arg{"--list", "l"}, T.Arg{"--contains", "l"}, T.Arg{"--contains=", "l"}, T.Arg{"--points-at", "l"}, T.Arg{"--points-at=", "l"}, T.Arg{"--sort=", "o"}], False{}, False{})

# -n<digits> read as -n
def tag.nw(+w: String) -> String:
  Model.pick.s(String.starts_with(w, "-n") && Model.all_digits(String.drop(w, 2n)), "-n", w)

def tag.ws(ws: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      List.reverse(&2, String, acc)
    case w <> t:
      tag.ws(t, tag.nw(w) <> acc)

def tag.k(ops: List<&2, String>, lst: Bool) -> T.Meaning:
  match ops lst:
    case Nil{} _:
      T.Known{[T.GitRead{}]}
    case _ True{}:
      T.Known{[T.GitRead{}]}
    case _ False{}:
      Model.unknown("git tag with a name makes a tag, which is not modelled (only the listing forms are: no name, -l, -n, --contains, --points-at)")

def tag.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      tag.k(ops, Model.has_char(fl, 'l') || Model.has_char(fl, 'n'))

def git.tag(args: List<&2, String>) -> T.Meaning:
  tag.o(Model.parse(tag.spec(), tag.ws(args, [])))

# worktree list [--porcelain]
def wt.pick(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitRead{}]}
    case False{}:
      Model.unknown("only git worktree list [--porcelain] is modelled")

def git.worktree(args: List<&2, String>) -> T.Meaning:
  match args:
    case Con{+a, Nil{}}:
      wt.pick(String.eq(a, "list"))
    case Con{+a, Con{+b, Nil{}}}:
      wt.pick(String.eq(a, "list") && String.eq(b, "--porcelain"))
    case _:
      wt.pick(False{})

# cherry [-v] [<upstream> [<head>]]
def cherry.k(ops: List<&2, String>) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case Con{a, Nil{}}:
      T.Known{[T.GitRead{}]}
    case Con{a, Con{b, Nil{}}}:
      T.Known{[T.GitRead{}]}
    case _:
      Model.unknown("cherry takes two revisions at most")

def cherry.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      cherry.k(ops)

# count-objects [-v] [-H]
def count.k(ops: List<&2, String>) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case _:
      Model.unknown("count-objects takes no operand")

def count.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      count.k(ops)

# ls-remote [--heads] [--tags] [--refs] [<remote>]: the remote is a plain
# remote name or an https:// URL; a path, ext:: or any other scheme (which
# can run a program or read another repository) is not modelled
def lsr.spec() -> Model.Spec:
  Model.spec("", "", [T.Arg{"--heads", "h"}, T.Arg{"--tags", "t"}, T.Arg{"--refs", "r"}], False{}, False{})

# c may stand in an https URL after https://: a-z A-Z 0-9 _ - . / : @
def url.c(c: Char) -> Bool:
  match c:
    case Chr{+x}:
      cc.ok(True{}, True{}, Chr{x}) || U32.is_eq(x, 58) || U32.is_eq(x, 64)

def url.cs(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      url.cs(t, acc && url.c(c))

def url.ok(+r: String) -> Bool:
  String.starts_with(r, "https://") && Bool.not(String.is_empty(String.drop(r, 8n))) && url.cs(String.drop(r, 8n), True{})

def lsr.r(ok: Bool, r: String) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.GitRead{}]}
    case False{}:
      Model.unknown("the ls-remote source " ++ r ++ " is not a plain remote name or an https:// URL (a path, ext:: or another scheme is not modelled)")

def lsr.k(ops: List<&2, String>) -> T.Meaning:
  match ops:
    case Nil{}:
      T.Known{[T.GitRead{}]}
    case Con{+r, Nil{}}:
      lsr.r(remote.ok(r) || url.ok(r), r)
    case _:
      Model.unknown("ls-remote takes one remote at most (patterns are not modelled)")

def lsr.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      lsr.k(ops)

# ---------------------------------------------------------------------------
# git

def git.other(+sub: String) -> T.Meaning:
  Model.unknown(Model.pick.s(String.starts_with(sub, "-"), "options before the subcommand (such as -c, --git-dir or --work-tree) are not modelled", "the subcommand " ++ sub ++ " is not modelled"))

# The subcommands, looked up by name in a table and then matched as a
# constructor: a match on many string literals makes bend's checker use
# several GB of memory (round 2: the whole build ran out of memory).
type Gs is Data:
  Gs.Read{}
  Gs.Show{}
  Gs.Tag{}
  Gs.Worktree{}
  Gs.Cherry{}
  Gs.CountObjects{}
  Gs.LsRemote{}
  Gs.Reflog{}
  Gs.Shortlog{}
  Gs.Blame{}
  Gs.LsFiles{}
  Gs.LsTree{}
  Gs.CheckIgnore{}
  Gs.Grep{}
  Gs.CatFile{}
  Gs.Describe{}
  Gs.MergeBase{}
  Gs.NameRev{}
  Gs.ForEachRef{}
  Gs.ShowRef{}
  Gs.RevParse{}
  Gs.Branch{}
  Gs.Remote{}
  Gs.Add{}
  Gs.Fetch{}
  Gs.Config{}
  Gs.Commit{}
  Gs.Pull{}
  Gs.Diff{}
  Gs.Push{}
  Gs.Checkout{}
  Gs.Restore{}
  Gs.Switch{}
  Gs.Stash{}
  Gs.Reset{}
  Gs.Apply{}
  Gs.Clean{}
  Gs.Other{}

type GsE is Data:
  GsE.Mk{name: String, gs: Gs}

def gs.table() -> List<&2, GsE>:
  [GsE.Mk{"status", Gs.Read{}}, GsE.Mk{"log", Gs.Read{}}, GsE.Mk{"show", Gs.Show{}}, GsE.Mk{"rev-list", Gs.Read{}}, GsE.Mk{"reflog", Gs.Reflog{}}, GsE.Mk{"shortlog", Gs.Shortlog{}}, GsE.Mk{"blame", Gs.Blame{}}, GsE.Mk{"ls-files", Gs.LsFiles{}}, GsE.Mk{"ls-tree", Gs.LsTree{}}, GsE.Mk{"check-ignore", Gs.CheckIgnore{}}, GsE.Mk{"grep", Gs.Grep{}}, GsE.Mk{"cat-file", Gs.CatFile{}}, GsE.Mk{"describe", Gs.Describe{}}, GsE.Mk{"merge-base", Gs.MergeBase{}}, GsE.Mk{"name-rev", Gs.NameRev{}}, GsE.Mk{"for-each-ref", Gs.ForEachRef{}}, GsE.Mk{"show-ref", Gs.ShowRef{}}, GsE.Mk{"rev-parse", Gs.RevParse{}}, GsE.Mk{"branch", Gs.Branch{}}, GsE.Mk{"remote", Gs.Remote{}}, GsE.Mk{"add", Gs.Add{}}, GsE.Mk{"fetch", Gs.Fetch{}}, GsE.Mk{"config", Gs.Config{}}, GsE.Mk{"commit", Gs.Commit{}}, GsE.Mk{"pull", Gs.Pull{}}, GsE.Mk{"diff", Gs.Diff{}}, GsE.Mk{"push", Gs.Push{}}, GsE.Mk{"checkout", Gs.Checkout{}}, GsE.Mk{"restore", Gs.Restore{}}, GsE.Mk{"switch", Gs.Switch{}}, GsE.Mk{"stash", Gs.Stash{}}, GsE.Mk{"reset", Gs.Reset{}}, GsE.Mk{"apply", Gs.Apply{}}, GsE.Mk{"clean", Gs.Clean{}}, GsE.Mk{"tag", Gs.Tag{}}, GsE.Mk{"worktree", Gs.Worktree{}}, GsE.Mk{"cherry", Gs.Cherry{}}, GsE.Mk{"count-objects", Gs.CountObjects{}}, GsE.Mk{"ls-remote", Gs.LsRemote{}}]

def gs.hit(b: Bool, g: Gs, rest: Gs) -> Gs:
  match b:
    case True{}:
      g
    case False{}:
      rest

def gs.find(xs: List<&2, GsE>, +w: String) -> Gs:
  match xs:
    case Nil{}:
      Gs.Other{}
    case GsE.Mk{k, g} <> t:
      gs.hit(String.eq(k, w), g, gs.find(t, w))

def git.sub.k(g: Gs, +sub: String, +sh: T.Shell, +cwds: List<&2, String>, +home: String, rest: List<&2, String>) -> T.Meaning:
  match g:
    case Gs.Read{}:
      gread.run(sh, cwds, home, rest)
    case Gs.Show{}:
      gread.with.rp(Rpm.Yes{}, gread.spec(), Model.AKind.ReadTree{}, sh, cwds, home, rest)
    case Gs.Tag{}:
      git.tag(rest)
    case Gs.Worktree{}:
      git.worktree(rest)
    case Gs.Cherry{}:
      cherry.o(Model.parse(Model.spec("v", "", [], False{}, False{}), rest))
    case Gs.CountObjects{}:
      count.o(Model.parse(Model.spec("vH", "", [T.Arg{"--verbose", "v"}, T.Arg{"--human-readable", "H"}], False{}, False{}), rest))
    case Gs.LsRemote{}:
      lsr.o(Model.parse(lsr.spec(), rest))
    case Gs.Reflog{}:
      git.reflog(sh, cwds, home, rest)
    case Gs.Shortlog{}:
      gread.with(shortlog.spec(), Model.AKind.ReadTree{}, sh, cwds, home, rest)
    case Gs.Blame{}:
      gread.with(blame.spec(), Model.AKind.ReadTree{}, sh, cwds, home, rest)
    case Gs.LsFiles{}:
      gread.with(lsfiles.spec(), Model.AKind.ListDir{}, sh, cwds, home, rest)
    case Gs.LsTree{}:
      gread.with.rp(Rpm.Yes{}, lstree.spec(), Model.AKind.ListDir{}, sh, cwds, home, rest)
    case Gs.CheckIgnore{}:
      gread.with(checkignore.spec(), Model.AKind.ListDir{}, sh, cwds, home, rest)
    case Gs.Grep{}:
      git.grep(sh, cwds, home, rest)
    case Gs.CatFile{}:
      catfile.o(Model.parse(Model.spec("tspe", "", [], False{}, False{}), rest), cwds, home)
    case Gs.Describe{}:
      grevs(describe.spec(), rest)
    case Gs.MergeBase{}:
      grevs(mergebase.spec(), rest)
    case Gs.NameRev{}:
      grevs(namerev.spec(), rest)
    case Gs.ForEachRef{}:
      grevs(foreachref.spec(), rest)
    case Gs.ShowRef{}:
      grevs(showref.spec(), rest)
    case Gs.RevParse{}:
      revparse.o(Model.parse(revparse.spec(), rest), cwds, home)
    case Gs.Branch{}:
      branch.o(Model.parse(branch.spec(), rest))
    case Gs.Remote{}:
      git.remote(rest)
    case Gs.Add{}:
      git.add(sh, cwds, home, rest)
    case Gs.Fetch{}:
      fetch.o(Model.parse(fetch.spec(), rest))
    case Gs.Config{}:
      config.o(Model.parse(config.spec(), rest), cwds, home)
    case Gs.Commit{}:
      Model.unknown("commit runs the repository's commit hooks, which may be files Claude can change")
    case Gs.Pull{}:
      Model.unknown("pull rewrites working files")
    case Gs.Diff{}:
      diff.run(sh, cwds, home, rest)
    case Gs.Push{}:
      push.o(Model.parse(push.spec(), rest), cwds, home)
    case Gs.Checkout{}:
      git.checkout(sh, cwds, home, rest)
    case Gs.Restore{}:
      git.restore(sh, cwds, home, rest)
    case Gs.Switch{}:
      git.switch(cwds, home, rest)
    case Gs.Stash{}:
      git.stash(cwds, home, rest)
    case Gs.Reset{}:
      git.reset(cwds, home, rest)
    case Gs.Apply{}:
      git.apply(sh, cwds, home, rest)
    case Gs.Clean{}:
      git.clean(sh, cwds, home, rest)
    case Gs.Other{}:
      git.other(sub)

def git.sub(+sub: String, +sh: T.Shell, +cwds: List<&2, String>, +home: String, rest: List<&2, String>) -> T.Meaning:
  git.sub.k(gs.find(gs.table(), sub), sub, sh, cwds, home, rest)

def git.args(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      Model.unknown("git with no subcommand is not modelled")
    case sub <> rest:
      git.sub(sub, sh, cwds, home, rest)

# The words before the subcommand. --no-pager, -P and --no-optional-locks
# change nothing that is modelled and are dropped. -C <folder> (once) runs
# git from that folder: it is resolved against every possible current folder
# as cd does, and the subcommand is modelled from there (so push rules and
# tree-delete rules see that folder). Any other word starting with '-' (-c,
# --git-dir, --work-tree, --exec-path, -p) stays Unknown (git.other).

# "d" dropped, "c" -C, "s" the subcommand or an option that is not modelled
def gtop.cls(w: String) -> String:
  match w:
    case "--no-pager":
      "d"
    case "-P":
      "d"
    case "--no-optional-locks":
      "d"
    case "-C":
      "c"
    case _:
      "s"

# done: the subcommand has been seen; want: -C waits for its folder; nc: -C
# was given; twice: -C was given more than once; rest: the subcommand and
# its words, reversed
type GTop is Data:
  GTop.Mk{done: Bool, want: Bool, nc: Bool, twice: Bool, dir: String, rest: List<&2, String>}

def gtop.c(cls: String, nc: Bool, twice: Bool, dir: String, rest: List<&2, String>, w: String) -> GTop:
  match cls:
    case "d":
      GTop.Mk{False{}, False{}, nc, twice, dir, rest}
    case "c":
      GTop.Mk{False{}, True{}, True{}, twice || nc, dir, rest}
    case _:
      GTop.Mk{True{}, False{}, nc, twice, dir, w <> rest}

def gtop.k(done: Bool, want: Bool, nc: Bool, twice: Bool, dir: String, rest: List<&2, String>, +w: String) -> GTop:
  match done want:
    case True{} _:
      GTop.Mk{True{}, False{}, nc, twice, dir, w <> rest}
    case False{} True{}:
      GTop.Mk{False{}, False{}, nc, twice, w, rest}
    case False{} False{}:
      gtop.c(gtop.cls(w), nc, twice, dir, rest, w)

def gtop.step(st: GTop, +w: String) -> GTop:
  match st:
    case GTop.Mk{done, want, nc, twice, dir, rest}:
      gtop.k(done, want, nc, twice, dir, rest, w)

def gtop.go(ws: List<&2, String>, st: GTop) -> GTop:
  match ws:
    case Nil{}:
      st
    case w <> t:
      gtop.go(t, gtop.step(st, w))

def gc.show(ps: List<&2, T.Path>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      Path.show(p) <> gc.show(t)

def gc.at(m: Maybe<&2, List<&2, T.Path>>, d: String, +sh: T.Shell, +home: String, args: List<&2, String>) -> T.Meaning:
  match m:
    case Some{ps}:
      git.args(sh, gc.show(ps), home, args)
    case None{}:
      Model.unknown("cannot tell where the folder " ++ d ++ " after -C points")

def gc.ok(+d: String) -> Bool:
  Bool.not(String.is_empty(d)) && Bool.not(String.starts_with(d, "-")) && Bool.not(glob.has(d, False{})) && Bool.not(colon.bad(d))

def gc.go(ok: Bool, +d: String, +sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match ok:
    case True{}:
      gc.at(Model.resolve(cwds, home, d), d, sh, home, args)
    case False{}:
      Model.unknown("the folder after -C must be a plain path (no wildcard, ':' or leading -)")

def gtop.fin.k(twice: Bool, want: Bool, nc: Bool, +dir: String, args: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match twice want nc:
    case True{} _ _:
      Model.unknown("-C given more than once is not modelled")
    case False{} True{} _:
      Model.unknown("-C needs a folder")
    case False{} False{} False{}:
      git.args(sh, cwds, home, args)
    case False{} False{} True{}:
      gc.go(gc.ok(dir), dir, sh, cwds, home, args)

def gtop.fin(st: GTop, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match st:
    case GTop.Mk{done, want, nc, twice, dir, rest}:
      gtop.fin.k(twice, want, nc, dir, List.reverse(&2, String, rest), sh, cwds, home)

def git(sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("git: ", gtop.fin(gtop.go(args, GTop.Mk{False{}, False{}, False{}, False{}, "", []}), sh, cwds, home))

# ---------------------------------------------------------------------------
# npm: test / t, run / run-script <name> (then nothing or -- and the
# script's arguments) give RunScript; install / i / add / ci give NpmInstall

def npm.tail(ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case w <> t:
      String.eq(w, "--")

def npm.script.k(ok: Bool, name: String) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.RunScript{name}]}
    case False{}:
      Model.unknown("only -- and the script's own arguments may follow the script name")

def npm.script(name: String, rest: List<&2, String>) -> T.Meaning:
  npm.script.k(npm.tail(rest), name)

def npm.run.k(dash: Bool, n: String, rest: List<&2, String>) -> T.Meaning:
  match dash:
    case True{}:
      Model.unknown("flags before the script name are not modelled")
    case False{}:
      npm.script(n, rest)

def npm.run(rest: List<&2, String>) -> T.Meaning:
  match rest:
    case Nil{}:
      Model.unknown("npm run with no script name is not modelled")
    case +n <> t:
      npm.run.k(String.starts_with(n, "-"), n, t)

def npm.ispec() -> Model.Spec:
  Model.spec("DEg", "", [T.Arg{"--save-dev", "D"}, T.Arg{"--save-exact", "E"}], False{}, False{})

def npm.inst.k(g: Bool, pkgs: List<&2, String>) -> T.Meaning:
  match g:
    case True{}:
      Model.unknown("-g installs into the global npm folder, which is not modelled")
    case False{}:
      T.Known{[T.NpmInstall{pkgs}]}

def npm.inst(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      npm.inst.k(Model.has_char(fl, 'g'), ops)

def npm.other(+sub: String) -> T.Meaning:
  Model.unknown(Model.pick.s(String.starts_with(sub, "-"), "npm options before the command are not modelled", "the npm command " ++ sub ++ " is not modelled"))

# npm.sub: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitNpmSub is Data:
  KGitNpmSub.Test{}
  KGitNpmSub.Run{}
  KGitNpmSub.Install{}
  KGitNpmSub.Rest{}

type KGitNpmSubE is Data:
  KGitNpmSubE.Mk{name: String, k: KGitNpmSub}

def npm.sub.tab() -> List<&2, KGitNpmSubE>:
  [KGitNpmSubE.Mk{"test", KGitNpmSub.Test{}}, KGitNpmSubE.Mk{"t", KGitNpmSub.Test{}}, KGitNpmSubE.Mk{"run", KGitNpmSub.Run{}}, KGitNpmSubE.Mk{"run-script", KGitNpmSub.Run{}}, KGitNpmSubE.Mk{"install", KGitNpmSub.Install{}}, KGitNpmSubE.Mk{"i", KGitNpmSub.Install{}}, KGitNpmSubE.Mk{"add", KGitNpmSub.Install{}}, KGitNpmSubE.Mk{"ci", KGitNpmSub.Install{}}]

def npm.sub.go(xs: List<&2, KGitNpmSubE>, hit: Bool, k: KGitNpmSub, +w: String) -> KGitNpmSub:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitNpmSub.Rest{}
    case KGitNpmSubE.Mk{n, k2} <> t False{}:
      npm.sub.go(t, String.eq(n, w), k2, w)

def npm.sub.find(xs: List<&2, KGitNpmSubE>, +w: String) -> KGitNpmSub:
  npm.sub.go(xs, False{}, KGitNpmSub.Rest{}, w)

def npm.sub.k(key: KGitNpmSub, +sub: String, rest: List<&2, String>) -> T.Meaning:
  match key:
    case KGitNpmSub.Test{}:
      npm.script("test", rest)
    case KGitNpmSub.Run{}:
      npm.run(rest)
    case KGitNpmSub.Install{}:
      npm.inst(Model.parse(npm.ispec(), rest))
    case KGitNpmSub.Rest{}:
      npm.other(sub)

def npm.sub(+sub: String, rest: List<&2, String>) -> T.Meaning:
  npm.sub.k(npm.sub.find(npm.sub.tab(), sub), sub, rest)

def npm.args(args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      Model.unknown("npm with no command is not modelled")
    case sub <> rest:
      npm.sub(sub, rest)

def npm(sh: T.Shell, cwds: List<&2, String>, home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("npm: ", npm.args(args))

# ---------------------------------------------------------------------------
# bend-guard's approve step is the user's alone: they run tools/approve.mjs in their
# own terminal, or types /bend-guard approve and /bend-guard confirm. A call
# that would run it is Unknown with a write of bend-guard's state folder
# home/.claude/bend-guard (where approve.mjs writes approved.json and live\)
# as a known part. That folder is in Protect.covers, so the proven
# self_protection law denies the call, in log-only mode and in agents too.

# the home folder as a path; when home cannot be read, the sentinel ?:/,
# which equals no real path (bend-guard then refuses every call anyway)
def hpath.or(m: Maybe<&2, T.Path>) -> T.Path:
  match m:
    case Some{p}:
      p
    case None{}:
      T.Path{"?", []}

def hpath(+home: String) -> T.Path:
  hpath.or(Path.norm(home, home, "~"))

# bend-guard's own tools, below the call's home folder (round 3, P5: no
# fixed user folder)
def approve.target(+home: String) -> T.Path:
  Path.child(hpath(home), ".claude/local-plugins/bend-guard/tools/approve.mjs")

def approve.or_drive(m: Maybe<&2, T.Path>) -> T.Path:
  match m:
    case Some{p}:
      p
    case None{}:
      T.Path{"c", []}

# a write of the state folder; of the whole drive c:/ when home cannot be
# read (which overlaps the state folder too)
def approve.write(+home: String) -> T.Action:
  T.WriteTree{approve.or_drive(Path.norm(home, home, "~/.claude/bend-guard"))}

# the meaning of a call that runs the approve step
def approve.unknown(why: String, home: String) -> T.Meaning:
  T.Unknown{why, [approve.write(home)]}

# s lower-cased, with '\' read as '/' (a loop with an accumulator: the old
# SCon{c, fold(t)} form overflowed the stack on long texts)
def approve.fold.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{92}, t}:
      approve.fold.go(t, SCon{Chr{47}, acc})
    case SCon{c, t}:
      approve.fold.go(t, SCon{Char.to_lower(c), acc})

def approve.fold(s: String) -> String:
  approve.fold.go(s, "")

def approve.text(+s: String) -> Bool:
  String.contains(s, "approve.mjs") || String.contains(s, "bend-guard/tools/approve")

# w names the approve tool: lower-cased, with '\' read as '/', it holds
# approve.mjs or bend-guard/tools/approve
def approve.word(w: String) -> Bool:
  approve.text(approve.fold(w))

# after "bend-guard": the end, or a character that cannot go on a name or a
# path (so .../bend-guard/tools and bend-guard-drafts do not count)
def slash.end(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{47}, t}:
      False{}
    case SCon{Chr{45}, t}:
      False{}
    case SCon{Chr{95}, t}:
      False{}
    case SCon{Chr{46}, t}:
      False{}
    case SCon{+c, t}:
      Bool.not(Char.is_alpha(c) || Char.is_digit(c))

def slash.at(+s: String) -> Bool:
  String.starts_with(s, "bend-guard") && slash.end(String.drop(s, 10n))

# c can stand just before the '/' of a slash command: not a letter, digit or
# one of . - _ ~ : / (so .../local-plugins/bend-guard is a path, not the
# command)
def slash.sep(+c: Char) -> Bool:
  match c:
    case Chr{46}:
      False{}
    case Chr{45}:
      False{}
    case Chr{95}:
      False{}
    case Chr{126}:
      False{}
    case Chr{58}:
      False{}
    case Chr{47}:
      False{}
    case _:
      Bool.not(Char.is_alpha(c) || Char.is_digit(c))

# ok: the text so far is empty or ends in a separator; acc: found so far
def slash.go(s: String, ok: Bool, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{47}, +t}:
      slash.go(t, False{}, acc || (ok && slash.at(t)))
    case SCon{+c, t}:
      slash.go(t, slash.sep(c), acc)

# w (lower-cased, '\' read as '/') holds the /bend-guard command: "/bend-guard"
# at the start or after a space, quote or the like, and followed by the end
# or a character such as a space or a quote. Used only for commands that are
# not modelled (approve.other), never for node's draft check.
def approve.slash(w: String) -> Bool:
  slash.go(approve.fold(w), True{}, False{})

def approve.any.go(ws: List<&2, String>, acc: Bool) -> Bool:
  match ws:
    case Nil{}:
      acc
    case +w <> t:
      approve.any.go(t, acc || (approve.word(w) || approve.slash(w)))

def approve.any(ws: List<&2, String>) -> Bool:
  approve.any.go(ws, False{})

def approve.add(hit: Bool, home: String, m: T.Meaning) -> T.Meaning:
  match hit:
    case True{}:
      Model.join(m, T.Known{[approve.write(home)]})
    case False{}:
      m

# ---------------------------------------------------------------------------
# A nested Claude Code session (the claude program, or the
# @anthropic-ai/claude-code package run through npx, npm and the like) can
# type /bend-guard as its prompt, or start with plugins or permission checks
# turned off, so bend-guard denies it: the user runs it themselves.

def claude.why() -> String:
  "claude: starting another Claude Code session can run /bend-guard or turn off bend-guard; the user runs it themselves"

# the text after the last '/'
def claude.base(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{47}, t}:
      claude.base(t, "")
    case SCon{c, t}:
      claude.base(t, SCon{c, acc})

def claude.exe(s: String) -> Bool:
  match s:
    case "claude":
      True{}
    case "claude.exe":
      True{}
    case "claude.cmd":
      True{}
    case "claude.ps1":
      True{}
    case "claude.bat":
      True{}
    case _:
      False{}

# a command name that is the claude program (any folder, any case)
def claude.name(name: String) -> Bool:
  claude.exe(claude.base(approve.fold(name), ""))

# a word that names the package, or a command text that starts the claude
# program (bash -c 'claude -p ...', cmd /c "claude ...")
def claude.word(w: String) -> Bool:
  +f = approve.fold(w)
  String.contains(f, "@anthropic-ai/claude-code") || String.starts_with(f, "claude ") || String.starts_with(f, "claude.exe ")

def claude.any.go(ws: List<&2, String>, acc: Bool) -> Bool:
  match ws:
    case Nil{}:
      acc
    case w <> t:
      claude.any.go(t, acc || claude.word(w))

def claude.any(ws: List<&2, String>) -> Bool:
  claude.any.go(ws, False{})

def claude.pick(hit: Bool, home: String, m: T.Meaning) -> T.Meaning:
  match hit:
    case True{}:
      approve.unknown(claude.why(), home)
    case False{}:
      m

# m, the meaning of a command that is not modelled, with the state-folder
# write added when one of its words ws (its name too) names the approve tool
# or the /bend-guard command; a self-protection meaning when a word starts
# a nested Claude Code session
def approve.other(+home: String, +ws: List<&2, String>, m: T.Meaning) -> T.Meaning:
  claude.pick(claude.any(ws), home, approve.add(approve.any(ws), home, m))

# Final review (2026-10-26, ENV-F5): reg add, delete, import, restore,
# load, unload and copy change the registry, which holds the user's lasting
# environment (PATH, GIT_CONFIG_GLOBAL, NODE_OPTIONS: every later program
# reads it). Like a git config write (ADJ-1) the command stays not
# understood, with a write of ~/NTUSER.DAT (the user registry, in
# Protect.bend) as its known part, so self-protection refuses it in every
# mode. reg query and reg export stay only not understood. setx is found
# by name in the call's text (Model.bend nm.table), since Bash drops the
# backslash in an unquoted HKCU\Environment.
def env.verbs() -> List<&2, String>:
  ["add", "delete", "import", "restore", "load", "unload", "copy"]

def env.why() -> String:
  "reg: changes the registry, which holds the user's lasting environment (PATH, GIT_CONFIG_GLOBAL, NODE_OPTIONS) and programs that start later; the user runs it themselves"

def env.first(args: List<&2, String>) -> String:
  match args:
    case Nil{}:
      ""
    case a <> t:
      low(a)

def env.w.k(hit: Bool, +home: String, m: T.Meaning) -> T.Meaning:
  match hit:
    case True{}:
      T.Unknown{env.why(), List.append(&2, T.Action, Model.acts.of(m), Model.acts.of(Model.path(Model.AKind.WriteTree{}, [home], home, "~/ntuser.dat")))}
    case False{}:
      m

def env.w(+home: String, +name: String, args: List<&2, String>, m: T.Meaning) -> T.Meaning:
  env.w.k(Model.elem(low(name), ["reg", "reg.exe"]) && Model.elem(env.first(args), env.verbs()), home, m)

# approve.other for a command name and its words; the name may be the claude
# program itself
def approve.cmd(+home: String, +name: String, +args: List<&2, String>, m: T.Meaning) -> T.Meaning:
  claude.pick(claude.name(name), home, approve.other(home, name <> args, env.w(home, name, args, m)))

# npm, except that a word naming the @anthropic-ai/claude-code package (npm
# exec, npm install -g) is the nested-session meaning above
def npm.claude(sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  claude.pick(claude.any(args), home, npm(sh, cwds, home, args))

# some word names the approve tool: it resolves to tools/approve.mjs from
# every possible folder (or as an absolute path), or its text names it
def approve.at.go(ws: List<&2, String>, +cwds: List<&2, String>, +home: String, acc: Bool) -> Bool:
  match ws:
    case Nil{}:
      acc
    case +w <> t:
      approve.at.go(t, cwds, home, acc || (at.file(cwds, home, w, approve.target(home)) || approve.word(w)))

def approve.at(+cwds: List<&2, String>, +home: String, ws: List<&2, String>) -> Bool:
  approve.at.go(ws, cwds, home, False{})

# ---------------------------------------------------------------------------
# node: only the draft check, node <plugin>/tools/draft-check.mjs <slug>;
# any argument that names the approve tool makes it the approve step

def dc.target(+home: String) -> T.Path:
  Path.child(hpath(home), ".claude/local-plugins/bend-guard/tools/draft-check.mjs")

# [a-z0-9_-]+
def dc.slug(+s: String) -> Bool:
  Bool.not(String.is_empty(s)) && cc.all(s, False{}, False{})

def node_exe(+cwds: List<&2, String>, +home: String, +name: String) -> Bool:
  String.eq(low(name), "node.exe") || at.file(cwds, home, name, T.Path{"c", ["program files", "nodejs", "node.exe"]})

def node.why() -> String:
  "node runs other code; only the draft check (node <plugin>/tools/draft-check.mjs <name>) is modelled"

def node.k(ok: Bool, slug: String) -> T.Meaning:
  match ok:
    case True{}:
      T.Known{[T.DraftCheck{slug}]}
    case False{}:
      Model.unknown(node.why())

def node.args(args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match args:
    case Con{script, Con{+slug, Nil{}}}:
      node.k(at.file(cwds, home, script, dc.target(home)) && dc.slug(slug), slug)
    case _:
      Model.unknown(node.why())

def node.go(hit: Bool, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match hit:
    case True{}:
      approve.unknown("approve.mjs: only the user approves bend-guard rules (they type /bend-guard approve themselves)", home)
    case False{}:
      Model.why_prefix("node: ", node.args(args, cwds, home))

def node(sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  node.go(approve.at(cwds, home, args), cwds, home, args)

# ---------------------------------------------------------------------------
# PowerShell parameters. A word starting with '-' is a parameter name,
# matched in lower case against the full names listed per cmdlet (no
# abbreviations, no -Name:value except a listed exact word such as
# -confirm:$false). Each name maps to one char; a char in vals takes the next
# word as its value, and 'P' marks a path value. Every modelled cmdlet also
# takes the common parameters -ErrorAction (-EA) and -WarningAction (-WA),
# chars E and W, with the values SilentlyContinue, Stop, Ignore or Continue
# only; the other common parameters (-OutVariable, -PipelineVariable, ...)
# are not known.

# ---------------------------------------------------------------------------
# PowerShell comma lists (round 3, P9). Lex.pwsh writes an unquoted list a,b
# as one word with char 1 between the elements. Only -Path, -LiteralPath and
# the positional path of the file cmdlets (Cm below, lst.cm) take a list:
# each element is a path of its own, with the same wildcard and colon rules
# as a single path, so the meaning is the union of the single meanings. A
# list anywhere else, or of more than 64 elements, is Unknown.

def lst.why() -> String:
  "a comma list is modelled only as -Path, -LiteralPath or the positional path of a file cmdlet"

def lst.big_why() -> String:
  "a comma list of more than 64 elements is not modelled"

# the word is a list
def lst.has(w: String) -> Bool:
  match w:
    case SNil{}:
      False{}
    case SCon{Chr{1}, t}:
      True{}
    case SCon{c, t}:
      lst.has(t)

def lst.any.go(xs: List<&2, String>, acc: Bool) -> Bool:
  match xs:
    case Nil{}:
      acc
    case w <> t:
      lst.any.go(t, acc || lst.has(w))

def lst.any(xs: List<&2, String>) -> Bool:
  lst.any.go(xs, False{})

# the word has more than n + 1 elements
def lst.over(w: String, n: Nat) -> Bool:
  match w:
    case SNil{}:
      False{}
    case SCon{Chr{1}, t}:
      match n:
        case 0n:
          True{}
        case 1n+k:
          lst.over(t, k)
    case SCon{c, t}:
      lst.over(t, n)

def lst.big.go(xs: List<&2, String>, acc: Bool) -> Bool:
  match xs:
    case Nil{}:
      acc
    case w <> t:
      lst.big.go(t, acc || lst.over(w, 63n))

# some word is a list of more than 64 elements
def lst.big(xs: List<&2, String>) -> Bool:
  lst.big.go(xs, False{})

# the elements of a word, reversed onto acc (a plain word is one element)
def lst.flat.go(s: String, cur: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      String.reverse(cur) <> acc
    case SCon{Chr{1}, t}:
      lst.flat.go(t, "", String.reverse(cur) <> acc)
    case SCon{c, t}:
      lst.flat.go(t, SCon{c, cur}, acc)

def lst.flat.ws(xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, acc)
    case w <> t:
      lst.flat.ws(t, lst.flat.go(w, "", acc))

# every element of the words, in order
def lst.flat(xs: List<&2, String>) -> List<&2, String>:
  lst.flat.ws(xs, [])

# m, or Unknown when bad
def lst.gate(bad: Bool, m: T.Meaning) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown(lst.why())
    case False{}:
      m

# want: the char of a parameter waiting for its value ("" if none); sw: one
# char per parameter seen; named: path values; pos: positional words; vs:
# every value with its parameter's char (all three reversed)
type PsSt is Data:
  PsSt.Mk{ok: Bool, why: String, want: String, sw: String, named: List<&2, String>, pos: List<&2, String>, vs: List<&2, T.Arg>}

type PsOpts is Data:
  PsOpts.Ok{sw: String, named: List<&2, String>, pos: List<&2, String>, vs: List<&2, T.Arg>}
  PsOpts.Bad{why: String}

def ps.hit(b: Bool, c: String, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match b:
    case True{}:
      Some{c}
    case False{}:
      rest

def ps.find(xs: List<&2, T.Arg>, +w: String) -> Maybe<&2, String>:
  match xs:
    case Nil{}:
      None{}
    case T.Arg{k, c} <> t:
      ps.hit(String.eq(k, w), c, ps.find(t, w))

def ps.bad(+w: String) -> String:
  Model.pick.s(Model.has_char(w, ':'), "the form " ++ w ++ " (a parameter joined to a value by :) is not modelled", "the parameter " ++ w ++ " is not known (only full names are modelled, not abbreviations)")

def ps.keep(isp: Bool, w: String, named: List<&2, String>) -> List<&2, String>:
  match isp:
    case True{}:
      w <> named
    case False{}:
      named

def ps.param(m: Maybe<&2, String>, +ok: Bool, why: String, sw: String, named: List<&2, String>, pos: List<&2, String>, vs: List<&2, T.Arg>, +vals: String, +w: String) -> PsSt:
  match m:
    case Some{+c}:
      PsSt.Mk{ok, why, Model.pick.s(String.contains(vals, c), c, ""), c ++ sw, named, pos, vs}
    case None{}:
      PsSt.Mk{False{}, Model.pick.s(ok, ps.bad(w), why), "", sw, named, pos, vs}

def ps.step.k(free: Bool, dash: Bool, +ok: Bool, why: String, +want: String, sw: String, named: List<&2, String>, pos: List<&2, String>, vs: List<&2, T.Arg>, +names: List<&2, T.Arg>, +vals: String, +w: String) -> PsSt:
  match free dash:
    case False{} True{}:
      PsSt.Mk{False{}, Model.pick.s(ok, "the parameter before " ++ w ++ " needs a value", why), "", sw, named, pos, vs}
    case False{} False{}:
      +isp = String.eq(want, "P")
      +bad = Bool.not(isp) && lst.has(w)
      PsSt.Mk{ok && Bool.not(bad), Model.pick.s(ok && bad, lst.why(), why), "", sw, ps.keep(isp, w, named), pos, T.Arg{want, w} <> vs}
    case True{} True{}:
      ps.param(ps.find(names, low(w)), ok, why, sw, named, pos, vs, vals, w)
    case True{} False{}:
      PsSt.Mk{ok, why, "", sw, named, w <> pos, vs}

def ps.step(+names: List<&2, T.Arg>, +vals: String, st: PsSt, +w: String) -> PsSt:
  match st:
    case PsSt.Mk{ok, why, +want, sw, named, pos, vs}:
      ps.step.k(String.is_empty(want), String.starts_with(w, "-"), ok, why, want, sw, named, pos, vs, names, vals, w)

def ps.go(ws: List<&2, String>, +names: List<&2, T.Arg>, +vals: String, st: PsSt) -> PsSt:
  match ws:
    case Nil{}:
      st
    case w <> t:
      ps.go(t, names, vals, ps.step(names, vals, st, w))

# a value of -ErrorAction or -WarningAction that changes nothing modelled
# (Inquire would prompt; Suspend and Break are not for plain cmdlets)
def ps.act(v: String) -> Bool:
  Model.elem(low(v), ["silentlycontinue", "stop", "ignore", "continue"])

def ps.cv(vs: List<&2, T.Arg>, acc: Bool) -> Bool:
  match vs:
    case Nil{}:
      acc
    case T.Arg{+k, v} <> t:
      ps.cv(t, acc && (Bool.not(String.eq(k, "E") || String.eq(k, "W")) || ps.act(v)))

def ps.fin.k(ok: Bool, free: Bool, cv: Bool, why: String, sw: String, named: List<&2, String>, pos: List<&2, String>, vs: List<&2, T.Arg>) -> PsOpts:
  match ok free cv:
    case False{} _ _:
      PsOpts.Bad{why}
    case True{} False{} _:
      PsOpts.Bad{"the last parameter needs a value"}
    case True{} True{} False{}:
      PsOpts.Bad{"-ErrorAction and -WarningAction are modelled only with SilentlyContinue, Stop, Ignore or Continue"}
    case True{} True{} True{}:
      PsOpts.Ok{sw, List.reverse(&2, String, named), List.reverse(&2, String, pos), List.reverse(&2, T.Arg, vs)}

def ps.fin(st: PsSt) -> PsOpts:
  match st:
    case PsSt.Mk{ok, why, +want, sw, named, pos, +vs}:
      ps.fin.k(ok, String.is_empty(want), ps.cv(vs, True{}), why, sw, named, pos, vs)

def ps.common() -> List<&2, T.Arg>:
  [T.Arg{"-erroraction", "E"}, T.Arg{"-ea", "E"}, T.Arg{"-warningaction", "W"}, T.Arg{"-wa", "W"}]

def ps.parse(names: List<&2, T.Arg>, vals: String, ws: List<&2, String>) -> PsOpts:
  ps.fin(ps.go(ws, List.append(&2, T.Arg, names, ps.common()), vals ++ "EW", PsSt.Mk{True{}, "", "", "", [], [], []}))

# the value given to the parameter with char c, if any
def ps.val(vs: List<&2, T.Arg>, +c: String) -> Maybe<&2, String>:
  match vs:
    case Nil{}:
      None{}
    case T.Arg{k, v} <> t:
      ps.hit(String.eq(k, c), v, ps.val(t, c))

def ps.or(m: Maybe<&2, String>, d: String) -> String:
  match m:
    case Some{v}:
      v
    case None{}:
      d

# kind k on each path; nothing named, a wildcard or a ':' is Unknown
def each.k(none: Bool, g: Bool, col: Bool, xs: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match none g col:
    case True{} _ _:
      Model.unknown("nothing is named")
    case False{} True{} _:
      Model.glob.with(Model.unknown("wildcards (*, ? or [) are not modelled here"), T.Pwsh{}, k, cwds, home, xs)
    case False{} False{} True{}:
      Model.unknown(colon.why())
    case False{} False{} False{}:
      Model.paths(xs, k, cwds, home)

def each.ps.l(big: Bool, +xs: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match big:
    case True{}:
      Model.unknown(lst.big_why())
    case False{}:
      each.k(List.is_empty(&2, String, xs), Model.any_glob(xs), colon.any(xs), xs, k, cwds, home)

# each word may be a comma list: kind k on each element
def each.ps(+xs: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  each.ps.l(lst.big(xs), lst.flat(xs), k, cwds, home)

# kind k on each path; a wildcard gives kind g on its folder
def look.k(none: Bool, col: Bool, xs: List<&2, String>, +k: Model.AKind, +g: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match none col:
    case True{} _:
      Model.unknown("nothing is named")
    case False{} True{}:
      Model.unknown(colon.why())
    case False{} False{}:
      Model.rpaths(xs, T.Pwsh{}, k, g, cwds, home)

def look.ps.l(big: Bool, +xs: List<&2, String>, +k: Model.AKind, +g: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match big:
    case True{}:
      Model.unknown(lst.big_why())
    case False{}:
      look.k(List.is_empty(&2, String, xs), colon.any(xs), xs, k, g, cwds, home)

# each word may be a comma list: kind k on each element
def look.ps(+xs: List<&2, String>, +k: Model.AKind, +g: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  look.ps.l(lst.big(xs), lst.flat(xs), k, g, cwds, home)

# New-Item -ItemType HardLink, mklink /H, fsutil hardlink (also inside cmd)
def hl.word(+w: String) -> Bool:
  String.contains(low(w), "hardlink") || String.eq(low(w), "/h")

def hl.any.go(ws: List<&2, String>, acc: Bool) -> Bool:
  match ws:
    case Nil{}:
      acc
    case w <> t:
      hl.any.go(t, acc || hl.word(w))

def hl.any(ws: List<&2, String>) -> Bool:
  hl.any.go(ws, False{})

def hl.why(link: Bool, why: String) -> T.Meaning:
  match link:
    case True{}:
      Model.unknown(Model.hard_link_why())
    case False{}:
      Model.unknown(why)

# Remove-Item (rm del ri rd rmdir erase): -Path -LiteralPath -Recurse -Force
# -Confirm:$false; Delete each path, DeleteTree with -Recurse
def remove_item.kind(rec: Bool) -> Model.AKind:
  match rec:
    case True{}:
      Model.AKind.DeleteTree{}
    case False{}:
      Model.AKind.Delete{}

def remove_item.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      each.ps(List.append(&2, String, named, pos), remove_item.kind(String.contains(sw, "r")), cwds, home)

def remove_item(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Remove-Item: ", remove_item.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-recurse", "r"}, T.Arg{"-force", "f"}, T.Arg{"-confirm:$false", "c"}], "P", args), cwds, home))

# Get-Content (gc cat type): -Path -LiteralPath -TotalCount N -Head N -Tail N
# -Raw; Read each path (a wildcard reads its folder)
def get_content.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      look.ps(List.append(&2, String, named, pos), Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home)

def get_content(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Get-Content: ", get_content.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-totalcount", "n"}, T.Arg{"-head", "n"}, T.Arg{"-tail", "n"}, T.Arg{"-raw", "w"}], "Pn", args), cwds, home))

# Set-Content (sc) and Add-Content (ac): -Path -LiteralPath -Value V
# -NoNewline -Encoding E; Write each path. Positional words bind to -Path
# (position 0), then -Value (position 1), skipping the ones given by name.
def set_content.w(+xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  each.ps(xs, Model.AKind.Write{}, cwds, home)

def set_content.first(pos: List<&2, String>, extra: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pos extra:
    case Nil{} _:
      Model.unknown("nothing is named")
    case Con{p, Nil{}} _:
      set_content.w([p], cwds, home)
    case Con{p, Con{+v, Nil{}}} True{}:
      lst.gate(lst.has(v), set_content.w([p], cwds, home))
    case _ _:
      Model.unknown("more positional arguments than -Path and -Value are not modelled")

def set_content.rest(named: List<&2, String>, pos: List<&2, String>, extra: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pos extra:
    case Nil{} _:
      set_content.w(named, cwds, home)
    case Con{+v, Nil{}} True{}:
      lst.gate(lst.has(v), set_content.w(named, cwds, home))
    case _ _:
      Model.unknown("more positional arguments than -Path and -Value are not modelled")

def set_content.k(nonamed: Bool, extra: Bool, named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match nonamed:
    case True{}:
      set_content.first(pos, extra, cwds, home)
    case False{}:
      set_content.rest(named, pos, extra, cwds, home)

def set_content.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, +named, pos, vs}:
      set_content.k(List.is_empty(&2, String, named), Bool.not(String.contains(sw, "v")), named, pos, cwds, home)

def set_content.names() -> List<&2, T.Arg>:
  [T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-value", "v"}, T.Arg{"-nonewline", "x"}, T.Arg{"-encoding", "e"}]

def set_content(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Set-Content: ", set_content.o(ps.parse(set_content.names(), "Pve", args), cwds, home))

def add_content(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Add-Content: ", set_content.o(ps.parse(set_content.names(), "Pve", args), cwds, home))

# Get-ChildItem (ls dir gci): -Path -LiteralPath -Recurse -Force -Name -File
# -Directory -Hidden, -Filter F -Include I -Exclude X (name patterns), -Depth
# N; ListDir of each path, or of the current folder. Positional words bind
# to -Path (position 0), then -Filter (position 1, a name pattern), skipping
# -Path when it is given by name.
def get_childitem.l(+xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  look.ps(xs, Model.AKind.ListDir{}, Model.AKind.ListDir{}, cwds, home)

def get_childitem.first(pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pos:
    case Nil{}:
      get_childitem.l(["."], cwds, home)
    case Con{p, Nil{}}:
      get_childitem.l([p], cwds, home)
    case Con{p, Con{+f, Nil{}}}:
      lst.gate(lst.has(f), get_childitem.l([p], cwds, home))
    case _:
      Model.unknown("more positional arguments than -Path and -Filter are not modelled")

def get_childitem.rest(named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pos:
    case Nil{}:
      get_childitem.l(named, cwds, home)
    case Con{+f, Nil{}}:
      lst.gate(lst.has(f), get_childitem.l(named, cwds, home))
    case _:
      Model.unknown("more positional arguments than -Path and -Filter are not modelled")

def get_childitem.k(nonamed: Bool, named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match nonamed:
    case True{}:
      get_childitem.first(pos, cwds, home)
    case False{}:
      get_childitem.rest(named, pos, cwds, home)

def get_childitem.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, +named, pos, vs}:
      get_childitem.k(List.is_empty(&2, String, named), named, pos, cwds, home)

def get_childitem(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Get-ChildItem: ", get_childitem.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-recurse", "r"}, T.Arg{"-force", "f"}, T.Arg{"-name", "n"}, T.Arg{"-file", "i"}, T.Arg{"-directory", "d"}, T.Arg{"-hidden", "h"}, T.Arg{"-filter", "F"}, T.Arg{"-include", "I"}, T.Arg{"-exclude", "X"}, T.Arg{"-depth", "D"}], "PFIXD", args), cwds, home))

# ---------------------------------------------------------------------------
# PowerShell, round 2 (P11): common cmdlets and formatter pipelines

# Get-Item (gi), Test-Path, Resolve-Path (rvpa) look at a path's properties
# and read no content: ListDir of each path (a wildcard: of its folder)
def stat.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      look.ps(List.append(&2, String, named, pos), Model.AKind.ListDir{}, Model.AKind.ListDir{}, cwds, home)

def stat(pre: String, names: List<&2, T.Arg>, vals: String, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(pre, stat.o(ps.parse(names, vals, args), cwds, home))

def inert.k(bad: Bool) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown("positional arguments are not modelled here")
    case False{}:
      Model.inert()

# a cmdlet that only prints, or passes objects along a pipeline: Inert.
# nopos: it takes no positional argument. Its values are literal words (the
# lexer refuses script blocks, $variables, (...) and @(...)).
def inert.o(o: PsOpts, nopos: Bool) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      inert.k(nopos && Bool.not(List.is_empty(&2, String, pos)))

def inert.ps(pre: String, names: List<&2, T.Arg>, vals: String, nopos: Bool, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(pre, inert.o(ps.parse(names, vals, args), nopos))

# Where-Object in the simple form <property> <operator> <value>: Inert
def where.op(o: String) -> Bool:
  Model.elem(low(o), ["-eq", "-ne", "-like", "-notlike", "-match", "-notmatch", "-gt", "-lt", "-ge", "-le"])

def where.k(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      Model.inert()
    case False{}:
      Model.unknown("Where-Object: only the form Where-Object <property> <operator> <value> is modelled (no script block)")

def where_object(args: List<&2, String>) -> T.Meaning:
  match args:
    case Con{p, Con{o, Con{v, Nil{}}}}:
      where.k(Bool.not(String.starts_with(p, "-")) && where.op(o) && Bool.not(String.starts_with(v, "-")))
    case _:
      where.k(False{})

# Get-CimInstance (gcim), Get-WmiObject (gwmi): one literal class name
# (-ClassName, -Class or positional) and an optional -Filter: Inert (a local
# query; -ComputerName, -Query and the rest are not known)
def cim.k(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      Model.inert()
    case False{}:
      Model.unknown("the class name must be a plain name")

def cim.cls(m: Maybe<&2, String>, pos: List<&2, String>) -> T.Meaning:
  match m pos:
    case Some{+c} Nil{}:
      cim.k(Bool.not(String.is_empty(c)) && cc.all(c, True{}, False{}))
    case None{} Con{+c, Nil{}}:
      cim.k(Bool.not(String.is_empty(c)) && cc.all(c, True{}, False{}))
    case _ _:
      Model.unknown("one class name is needed")

def cim.o(o: PsOpts) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      cim.cls(ps.val(vs, "c"), pos)

def get_cim(pre: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(pre, cim.o(ps.parse([T.Arg{"-classname", "c"}, T.Arg{"-class", "c"}, T.Arg{"-filter", "f"}], "cf", args)))

# Select-String (sls): -Path -LiteralPath (Read each path, a wildcard reads
# its folder), -Pattern P, -SimpleMatch -CaseSensitive -Context N -NotMatch
# -List -AllMatches -Quiet. Positional words bind to -Pattern (position 0),
# then -Path. No path: it reads the pipeline (Inert).
def sls.f(none: Bool, xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match none:
    case True{}:
      Model.inert()
    case False{}:
      look.ps(xs, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home)

def sls.files(+xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  sls.f(List.is_empty(&2, String, xs), xs, cwds, home)

def sls.pos(named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pos:
    case Nil{}:
      Model.unknown("no pattern is given")
    case Con{+p, t}:
      lst.gate(lst.has(p), sls.files(List.append(&2, String, named, t), cwds, home))

def sls.k(hasp: Bool, named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match hasp:
    case True{}:
      sls.files(List.append(&2, String, named, pos), cwds, home)
    case False{}:
      sls.pos(named, pos, cwds, home)

def sls.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      sls.k(String.contains(sw, "p"), named, pos, cwds, home)

def select_string(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Select-String: ", sls.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-pattern", "p"}, T.Arg{"-simplematch", "s"}, T.Arg{"-casesensitive", "c"}, T.Arg{"-context", "x"}, T.Arg{"-notmatch", "n"}, T.Arg{"-list", "l"}, T.Arg{"-allmatches", "a"}, T.Arg{"-quiet", "q"}], "Ppx", args), cwds, home))

# Copy-Item (cp copy cpi) and Move-Item (mv move mi): -Path -LiteralPath
# -Destination D -Recurse -Force -Confirm:$false, read as cp and mv are
# (Model.move): each source Read (ReadTree with -Recurse) or MoveFrom; the
# target Write, and WriteTree of target/<last part of the source>. Positional
# words bind to -Path, then -Destination. No wildcards, no ':' and no source
# ending in . or .. (a folder's contents).
def cpmv.kind(mv: Bool, rec: Bool) -> Model.AKind:
  match mv rec:
    case True{} _:
      Model.AKind.MoveFrom{}
    case False{} True{}:
      Model.AKind.ReadTree{}
    case False{} False{}:
      Model.AKind.Read{}

def cpmv.k(g: Bool, col: Bool, dots: Bool, srcs: List<&2, String>, dst: String, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g col dots:
    case True{} _ _:
      Model.glob.with(Model.glob.with(Model.unknown("wildcards (*, ? or [) are not modelled here"), T.Pwsh{}, k, cwds, home, srcs), T.Pwsh{}, Model.AKind.WriteTree{}, cwds, home, [dst])
    case False{} True{} _:
      Model.unknown(colon.why())
    case False{} False{} True{}:
      Model.unknown("a source ending in . or .. (a folder's contents) is not modelled")
    case False{} False{} False{}:
      Model.move(srcs, dst, k, cwds, home)

def cpmv.go.f(+srcs: List<&2, String>, +dst: String, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  cpmv.k(Model.any_glob(dst <> srcs), colon.any(dst <> srcs), Model.any_dotted_end(srcs), srcs, dst, k, cwds, home)

def cpmv.go.l(dl: Bool, big: Bool, +srcs: List<&2, String>, +dst: String, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match dl big:
    case True{} _:
      Model.unknown(lst.why())
    case False{} True{}:
      Model.unknown(lst.big_why())
    case False{} False{}:
      cpmv.go.f(lst.flat(srcs), dst, k, cwds, home)

# each source may be a comma list; the destination (one string) may not
def cpmv.go(+srcs: List<&2, String>, +dst: String, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  cpmv.go.l(lst.has(dst), lst.big(srcs), srcs, dst, k, cwds, home)

def cpmv.named(named: List<&2, String>, pos: List<&2, String>, +d: String, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match named pos:
    case Nil{} Con{s, Nil{}}:
      cpmv.go([s], d, k, cwds, home)
    case Con{a, b} Nil{}:
      cpmv.go(a <> b, d, k, cwds, home)
    case _ _:
      Model.unknown("the sources and the destination are not clear")

def cpmv.unnamed(named: List<&2, String>, pos: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match named pos:
    case Nil{} Con{s, Con{d, Nil{}}}:
      cpmv.go([s], d, k, cwds, home)
    case Con{a, b} Con{d, Nil{}}:
      cpmv.go(a <> b, d, k, cwds, home)
    case _ _:
      Model.unknown("a source and a destination are needed")

def cpmv.dst(m: Maybe<&2, String>, named: List<&2, String>, pos: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match m:
    case Some{d}:
      cpmv.named(named, pos, d, k, cwds, home)
    case None{}:
      cpmv.unnamed(named, pos, k, cwds, home)

def cpmv.o(o: PsOpts, mv: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, named, pos, vs}:
      cpmv.dst(ps.val(vs, "d"), named, pos, cpmv.kind(mv, String.contains(sw, "r")), cwds, home)

def cpmv(pre: String, mv: Bool, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(pre, cpmv.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-destination", "d"}, T.Arg{"-recurse", "r"}, T.Arg{"-force", "f"}, T.Arg{"-confirm:$false", "c"}], "Pd", args), mv, cwds, home))

# New-Item (ni), and mkdir and md (functions that call New-Item -ItemType
# Directory): -Path (or positional), -ItemType (-Type) Directory gives
# MakeDir, File (the default for ni) gives Write; -Value (-Target), -Force.
# Other item types (SymbolicLink, HardLink, Junction) and -Name are Unknown.
# ni.type: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitNiType is Data:
  KGitNiType.Directory{}
  KGitNiType.File{}
  KGitNiType.Rest{}

type KGitNiTypeE is Data:
  KGitNiTypeE.Mk{name: String, k: KGitNiType}

def ni.type.tab() -> List<&2, KGitNiTypeE>:
  [KGitNiTypeE.Mk{"directory", KGitNiType.Directory{}}, KGitNiTypeE.Mk{"file", KGitNiType.File{}}]

def ni.type.go(xs: List<&2, KGitNiTypeE>, hit: Bool, k: KGitNiType, +w: String) -> KGitNiType:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitNiType.Rest{}
    case KGitNiTypeE.Mk{n, k2} <> t False{}:
      ni.type.go(t, String.eq(n, w), k2, w)

def ni.type.find(xs: List<&2, KGitNiTypeE>, +w: String) -> KGitNiType:
  ni.type.go(xs, False{}, KGitNiType.Rest{}, w)

def ni.type.k(key: KGitNiType, +t: String, xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KGitNiType.Directory{}:
      each.ps(xs, Model.AKind.MakeDir{}, cwds, home)
    case KGitNiType.File{}:
      each.ps(xs, Model.AKind.Write{}, cwds, home)
    case KGitNiType.Rest{}:
      hl.why(String.contains(t, "hardlink"), "the item type " ++ t ++ " (a link or another kind of item) is not modelled")

def ni.type(+t: String, xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  ni.type.k(ni.type.find(ni.type.tab(), t), t, xs, cwds, home)

def ni.k(hasname: Bool, t: String, xs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match hasname:
    case True{}:
      Model.unknown("-Name (a name joined to the path) is not modelled")
    case False{}:
      ni.type(t, xs, cwds, home)

def ni.o(o: PsOpts, dflt: String, args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      hl.why(hl.any(args), why)
    case PsOpts.Ok{sw, named, pos, vs}:
      ni.k(String.contains(sw, "n"), low(ps.or(ps.val(vs, "t"), dflt)), List.append(&2, String, named, pos), cwds, home)

def new_item(pre: String, dflt: String, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(pre, ni.o(ps.parse([T.Arg{"-path", "P"}, T.Arg{"-itemtype", "t"}, T.Arg{"-type", "t"}, T.Arg{"-value", "v"}, T.Arg{"-target", "v"}, T.Arg{"-force", "f"}, T.Arg{"-name", "n"}], "Ptvn", args), dflt, args, cwds, home))

# Out-File: -FilePath (-Path) or -LiteralPath or one positional path,
# -Append -Encoding E -NoNewline -Force -Width N -NoClobber -InputObject V:
# Write of the path
def outf.k(named: List<&2, String>, pos: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match named pos:
    case Nil{} Nil{}:
      Model.unknown("nothing is named")
    case Nil{} Con{p, Nil{}}:
      each.ps([p], Model.AKind.Write{}, cwds, home)
    case Con{a, b} Nil{}:
      each.ps(a <> b, Model.AKind.Write{}, cwds, home)
    case _ _:
      Model.unknown("more positional arguments than -FilePath are not modelled")

def outf.o(o: PsOpts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case PsOpts.Bad{why}:
      Model.unknown(why)
    case PsOpts.Ok{sw, +named, +pos, vs}:
      lst.gate(lst.any(named) || lst.any(pos), outf.k(named, pos, cwds, home))

def out_file(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("Out-File: ", outf.o(ps.parse([T.Arg{"-filepath", "P"}, T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}, T.Arg{"-append", "a"}, T.Arg{"-encoding", "e"}, T.Arg{"-nonewline", "x"}, T.Arg{"-force", "f"}, T.Arg{"-width", "w"}, T.Arg{"-noclobber", "n"}, T.Arg{"-inputobject", "i"}], "Pewi", args), cwds, home))

# ---------------------------------------------------------------------------
# PowerShell command names

def cmdlet.code(+name: String) -> T.Meaning:
  Model.unknown(name ++ ": runs other code, which is not modelled")

def cmdlet.loc(+name: String) -> T.Meaning:
  Model.unknown(name ++ ": changes the folder through the location stack, which is not modelled")

# the PowerShell commands that are not modelled, each with its reason
# cmdlet.why: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KGitCmdletWhy is Data:
  KGitCmdletWhy.Mklink{}
  KGitCmdletWhy.Fsutil{}
  KGitCmdletWhy.Cmd{}
  KGitCmdletWhy.Iex{}
  KGitCmdletWhy.PushLocation{}
  KGitCmdletWhy.Rest{}

type KGitCmdletWhyE is Data:
  KGitCmdletWhyE.Mk{name: String, k: KGitCmdletWhy}

def cmdlet.why.tab() -> List<&2, KGitCmdletWhyE>:
  [KGitCmdletWhyE.Mk{"mklink", KGitCmdletWhy.Mklink{}}, KGitCmdletWhyE.Mk{"fsutil", KGitCmdletWhy.Fsutil{}}, KGitCmdletWhyE.Mk{"cmd", KGitCmdletWhy.Cmd{}}, KGitCmdletWhyE.Mk{"cmd.exe", KGitCmdletWhy.Cmd{}}, KGitCmdletWhyE.Mk{"iex", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"invoke-expression", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"start-process", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"saps", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"start", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"invoke-command", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"icm", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"powershell", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"powershell.exe", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"pwsh", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"pwsh.exe", KGitCmdletWhy.Iex{}}, KGitCmdletWhyE.Mk{"push-location", KGitCmdletWhy.PushLocation{}}, KGitCmdletWhyE.Mk{"pushd", KGitCmdletWhy.PushLocation{}}, KGitCmdletWhyE.Mk{"pop-location", KGitCmdletWhy.PushLocation{}}, KGitCmdletWhyE.Mk{"popd", KGitCmdletWhy.PushLocation{}}]

def cmdlet.why.go(xs: List<&2, KGitCmdletWhyE>, hit: Bool, k: KGitCmdletWhy, +w: String) -> KGitCmdletWhy:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KGitCmdletWhy.Rest{}
    case KGitCmdletWhyE.Mk{n, k2} <> t False{}:
      cmdlet.why.go(t, String.eq(n, w), k2, w)

def cmdlet.why.find(xs: List<&2, KGitCmdletWhyE>, +w: String) -> KGitCmdletWhy:
  cmdlet.why.go(xs, False{}, KGitCmdletWhy.Rest{}, w)

def cmdlet.why.k(key: KGitCmdletWhy, +name: String, args: List<&2, String>) -> T.Meaning:
  match key:
    case KGitCmdletWhy.Mklink{}:
      hl.why(hl.any(args), "mklink: making links is not modelled")
    case KGitCmdletWhy.Fsutil{}:
      hl.why(hl.any(args), "fsutil is not modelled")
    case KGitCmdletWhy.Cmd{}:
      hl.why(hl.any(args), "cmd: runs other code, which is not modelled")
    case KGitCmdletWhy.Iex{}:
      cmdlet.code(name)
    case KGitCmdletWhy.PushLocation{}:
      cmdlet.loc(name)
    case KGitCmdletWhy.Rest{}:
      Model.unknown("the PowerShell command " ++ name ++ " is not modelled")

def cmdlet.why(+name: String, args: List<&2, String>) -> T.Meaning:
  cmdlet.why.k(cmdlet.why.find(cmdlet.why.tab(), name), name, args)

# The modelled cmdlets and their aliases, looked up by name in a table and
# then matched as a constructor (a match on many string literals makes bend's
# checker use several GB of memory)
type Cm is Data:
  Cm.Remove{}
  Cm.GetContent{}
  Cm.SetContent{}
  Cm.AddContent{}
  Cm.Gci{}
  Cm.GetItem{}
  Cm.TestPath{}
  Cm.ResolvePath{}
  Cm.Sls{}
  Cm.Copy{}
  Cm.Move{}
  Cm.NewItem{}
  Cm.Mkdir{}
  Cm.OutFile{}
  Cm.GetLocation{}
  Cm.WriteOutput{}
  Cm.GetCommand{}
  Cm.GetProcess{}
  Cm.GetDate{}
  Cm.GetPSDrive{}
  Cm.Select{}
  Cm.Sort{}
  Cm.Measure{}
  Cm.Group{}
  Cm.FormatTable{}
  Cm.FormatList{}
  Cm.OutString{}
  Cm.Where{}
  Cm.Cim{}
  Cm.Wmi{}
  Cm.Node{}
  Cm.Other{}

type CmE is Data:
  CmE.Mk{name: String, cm: Cm}

def cm.table() -> List<&2, CmE>:
  [CmE.Mk{"remove-item", Cm.Remove{}}, CmE.Mk{"rm", Cm.Remove{}}, CmE.Mk{"del", Cm.Remove{}}, CmE.Mk{"ri", Cm.Remove{}}, CmE.Mk{"rd", Cm.Remove{}}, CmE.Mk{"rmdir", Cm.Remove{}}, CmE.Mk{"erase", Cm.Remove{}}, CmE.Mk{"get-content", Cm.GetContent{}}, CmE.Mk{"gc", Cm.GetContent{}}, CmE.Mk{"cat", Cm.GetContent{}}, CmE.Mk{"type", Cm.GetContent{}}, CmE.Mk{"set-content", Cm.SetContent{}}, CmE.Mk{"sc", Cm.SetContent{}}, CmE.Mk{"add-content", Cm.AddContent{}}, CmE.Mk{"ac", Cm.AddContent{}}, CmE.Mk{"get-childitem", Cm.Gci{}}, CmE.Mk{"ls", Cm.Gci{}}, CmE.Mk{"dir", Cm.Gci{}}, CmE.Mk{"gci", Cm.Gci{}}, CmE.Mk{"get-item", Cm.GetItem{}}, CmE.Mk{"gi", Cm.GetItem{}}, CmE.Mk{"test-path", Cm.TestPath{}}, CmE.Mk{"resolve-path", Cm.ResolvePath{}}, CmE.Mk{"rvpa", Cm.ResolvePath{}}, CmE.Mk{"select-string", Cm.Sls{}}, CmE.Mk{"sls", Cm.Sls{}}, CmE.Mk{"copy-item", Cm.Copy{}}, CmE.Mk{"copy", Cm.Copy{}}, CmE.Mk{"cp", Cm.Copy{}}, CmE.Mk{"cpi", Cm.Copy{}}, CmE.Mk{"move-item", Cm.Move{}}, CmE.Mk{"move", Cm.Move{}}, CmE.Mk{"mv", Cm.Move{}}, CmE.Mk{"mi", Cm.Move{}}, CmE.Mk{"new-item", Cm.NewItem{}}, CmE.Mk{"ni", Cm.NewItem{}}, CmE.Mk{"mkdir", Cm.Mkdir{}}, CmE.Mk{"md", Cm.Mkdir{}}, CmE.Mk{"out-file", Cm.OutFile{}}, CmE.Mk{"get-location", Cm.GetLocation{}}, CmE.Mk{"gl", Cm.GetLocation{}}, CmE.Mk{"pwd", Cm.GetLocation{}}, CmE.Mk{"write-output", Cm.WriteOutput{}}, CmE.Mk{"echo", Cm.WriteOutput{}}, CmE.Mk{"write", Cm.WriteOutput{}}, CmE.Mk{"get-command", Cm.GetCommand{}}, CmE.Mk{"gcm", Cm.GetCommand{}}, CmE.Mk{"get-process", Cm.GetProcess{}}, CmE.Mk{"ps", Cm.GetProcess{}}, CmE.Mk{"gps", Cm.GetProcess{}}, CmE.Mk{"get-date", Cm.GetDate{}}, CmE.Mk{"get-psdrive", Cm.GetPSDrive{}}, CmE.Mk{"gdr", Cm.GetPSDrive{}}, CmE.Mk{"select-object", Cm.Select{}}, CmE.Mk{"select", Cm.Select{}}, CmE.Mk{"sort-object", Cm.Sort{}}, CmE.Mk{"sort", Cm.Sort{}}, CmE.Mk{"measure-object", Cm.Measure{}}, CmE.Mk{"measure", Cm.Measure{}}, CmE.Mk{"group-object", Cm.Group{}}, CmE.Mk{"group", Cm.Group{}}, CmE.Mk{"format-table", Cm.FormatTable{}}, CmE.Mk{"ft", Cm.FormatTable{}}, CmE.Mk{"format-list", Cm.FormatList{}}, CmE.Mk{"fl", Cm.FormatList{}}, CmE.Mk{"out-string", Cm.OutString{}}, CmE.Mk{"where-object", Cm.Where{}}, CmE.Mk{"where", Cm.Where{}}, CmE.Mk{"get-ciminstance", Cm.Cim{}}, CmE.Mk{"gcim", Cm.Cim{}}, CmE.Mk{"get-wmiobject", Cm.Wmi{}}, CmE.Mk{"gwmi", Cm.Wmi{}}, CmE.Mk{"node.exe", Cm.Node{}}]

def cm.hit(b: Bool, c: Cm, rest: Cm) -> Cm:
  match b:
    case True{}:
      c
    case False{}:
      rest

def cm.find(xs: List<&2, CmE>, +w: String) -> Cm:
  match xs:
    case Nil{}:
      Cm.Other{}
    case CmE.Mk{k, c} <> t:
      cm.hit(String.eq(k, w), c, cm.find(t, w))

def cm.statn() -> List<&2, T.Arg>:
  [T.Arg{"-path", "P"}, T.Arg{"-literalpath", "P"}]

def cmdlet.k(c: Cm, +cwds: List<&2, String>, +home: String, +name: String, +args: List<&2, String>) -> T.Meaning:
  match c:
    case Cm.Remove{}:
      remove_item(cwds, home, args)
    case Cm.GetContent{}:
      get_content(cwds, home, args)
    case Cm.SetContent{}:
      set_content(cwds, home, args)
    case Cm.AddContent{}:
      add_content(cwds, home, args)
    case Cm.Gci{}:
      get_childitem(cwds, home, args)
    case Cm.GetItem{}:
      stat("Get-Item: ", T.Arg{"-force", "f"} <> cm.statn(), "P", cwds, home, args)
    case Cm.TestPath{}:
      stat("Test-Path: ", T.Arg{"-pathtype", "t"} <> T.Arg{"-isvalid", "v"} <> cm.statn(), "Pt", cwds, home, args)
    case Cm.ResolvePath{}:
      stat("Resolve-Path: ", T.Arg{"-relative", "r"} <> cm.statn(), "P", cwds, home, args)
    case Cm.Sls{}:
      select_string(cwds, home, args)
    case Cm.Copy{}:
      cpmv("Copy-Item: ", False{}, cwds, home, args)
    case Cm.Move{}:
      cpmv("Move-Item: ", True{}, cwds, home, args)
    case Cm.NewItem{}:
      new_item("New-Item: ", "file", cwds, home, args)
    case Cm.Mkdir{}:
      new_item("mkdir: ", "directory", cwds, home, args)
    case Cm.OutFile{}:
      out_file(cwds, home, args)
    case Cm.GetLocation{}:
      inert.ps("Get-Location: ", [], "", True{}, args)
    case Cm.WriteOutput{}:
      inert.ps("Write-Output: ", [T.Arg{"-noenumerate", "n"}], "", False{}, args)
    case Cm.GetCommand{}:
      inert.ps("Get-Command: ", [T.Arg{"-name", "n"}, T.Arg{"-commandtype", "t"}, T.Arg{"-all", "a"}, T.Arg{"-module", "m"}, T.Arg{"-syntax", "s"}], "ntm", False{}, args)
    case Cm.GetProcess{}:
      inert.ps("Get-Process: ", [T.Arg{"-name", "n"}, T.Arg{"-id", "i"}], "ni", False{}, args)
    case Cm.GetDate{}:
      inert.ps("Get-Date: ", [T.Arg{"-format", "f"}, T.Arg{"-uformat", "u"}, T.Arg{"-date", "d"}], "fud", False{}, args)
    case Cm.GetPSDrive{}:
      inert.ps("Get-PSDrive: ", [T.Arg{"-name", "n"}, T.Arg{"-psprovider", "p"}], "np", False{}, args)
    case Cm.Select{}:
      inert.ps("Select-Object: ", [T.Arg{"-first", "f"}, T.Arg{"-last", "l"}, T.Arg{"-skip", "s"}, T.Arg{"-unique", "u"}, T.Arg{"-property", "p"}, T.Arg{"-expandproperty", "e"}], "flspe", False{}, args)
    case Cm.Sort{}:
      inert.ps("Sort-Object: ", [T.Arg{"-property", "p"}, T.Arg{"-descending", "d"}, T.Arg{"-unique", "u"}], "p", False{}, args)
    case Cm.Measure{}:
      inert.ps("Measure-Object: ", [T.Arg{"-line", "l"}, T.Arg{"-word", "w"}, T.Arg{"-character", "c"}, T.Arg{"-property", "p"}, T.Arg{"-sum", "s"}, T.Arg{"-average", "a"}, T.Arg{"-maximum", "x"}, T.Arg{"-minimum", "m"}], "p", False{}, args)
    case Cm.Group{}:
      inert.ps("Group-Object: ", [T.Arg{"-property", "p"}, T.Arg{"-noelement", "n"}], "p", False{}, args)
    case Cm.FormatTable{}:
      inert.ps("Format-Table: ", [T.Arg{"-autosize", "a"}, T.Arg{"-wrap", "w"}, T.Arg{"-property", "p"}], "p", False{}, args)
    case Cm.FormatList{}:
      inert.ps("Format-List: ", [T.Arg{"-property", "p"}], "p", False{}, args)
    case Cm.OutString{}:
      inert.ps("Out-String: ", [T.Arg{"-stream", "s"}, T.Arg{"-width", "w"}], "w", False{}, args)
    case Cm.Where{}:
      where_object(args)
    case Cm.Cim{}:
      get_cim("Get-CimInstance: ", args)
    case Cm.Wmi{}:
      get_cim("Get-WmiObject: ", args)
    case Cm.Node{}:
      node(T.Pwsh{}, cwds, home, args)
    case Cm.Other{}:
      approve.cmd(home, name, args, cmdlet.why(name, args))

# the cmdlets whose -Path, -LiteralPath or positional path takes a comma
# list (a string[] parameter; Out-File's -FilePath is one string)
def lst.cm(c: Cm) -> Bool:
  match c:
    case Cm.Remove{}:
      True{}
    case Cm.GetContent{}:
      True{}
    case Cm.SetContent{}:
      True{}
    case Cm.AddContent{}:
      True{}
    case Cm.Gci{}:
      True{}
    case Cm.GetItem{}:
      True{}
    case Cm.TestPath{}:
      True{}
    case Cm.ResolvePath{}:
      True{}
    case Cm.Sls{}:
      True{}
    case Cm.Copy{}:
      True{}
    case Cm.Move{}:
      True{}
    case Cm.NewItem{}:
      True{}
    case Cm.Mkdir{}:
      True{}
    case _:
      False{}

def cmdlet.l(bad: Bool, c: Cm, +cwds: List<&2, String>, +home: String, +name: String, +args: List<&2, String>) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown(lst.why())
    case False{}:
      cmdlet.k(c, cwds, home, name, args)

# the modelled cmdlets; any other command is not modelled, and is the
# approve step when one of its words names the approve tool. A comma list
# reaches only the cmdlets of lst.cm.
def cmdlet(+cwds: List<&2, String>, +home: String, +name: String, +args: List<&2, String>) -> T.Meaning:
  +c = cm.find(cm.table(), name)
  cmdlet.l(Bool.not(lst.cm(c)) && lst.any(name <> args), c, cwds, home, name, args)
