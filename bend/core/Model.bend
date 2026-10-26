# bend-guard: shared helpers for the command models (plan.md Task 1.7;
# design.md component 2, layer 4). Building and joining meanings, resolving a
# raw path against every possible current folder (one action per folder),
# reading flags (joined short flags too), and the folder a wildcard can reach.
# Imported as Model:  import ./Model.bend as Model
# (ModelShell.bend defines Model.command and friends itself, so it imports
# this file as MH.)

import Base
import ./Types.bend as T
import ./Path.bend as Path

# ---------------------------------------------------------------------------
# Meanings

def nothing() -> T.Meaning:
  T.Known{[]}

def inert() -> T.Meaning:
  T.Known{[T.Inert{}]}

def unknown(why: String) -> T.Meaning:
  T.Unknown{why, []}

# both parts happen; an unknown part makes the whole unknown (the first
# reason is kept) and the actions of every part are kept
def join(a: T.Meaning, b: T.Meaning) -> T.Meaning:
  match a b:
    case T.Known{x} T.Known{y}:
      T.Known{List.append(&2, T.Action, x, y)}
    case T.Known{x} T.Unknown{w, y}:
      T.Unknown{w, List.append(&2, T.Action, x, y)}
    case T.Unknown{w, x} T.Known{y}:
      T.Unknown{w, List.append(&2, T.Action, x, y)}
    case T.Unknown{w, x} T.Unknown{v, y}:
      T.Unknown{w, List.append(&2, T.Action, x, y)}

def join_all(ms: List<&2, T.Meaning>) -> T.Meaning:
  match ms:
    case Nil{}:
      T.Known{[]}
    case m <> t:
      join(m, join_all(t))

# puts pre (such as "rm: ") in front of an Unknown's reason
def why_prefix(pre: String, m: T.Meaning) -> T.Meaning:
  match m:
    case T.Known{x}:
      T.Known{x}
    case T.Unknown{w, x}:
      T.Unknown{pre ++ w, x}

# the reason for every command that makes a hard link (plan Task 1.7)
def hard_link_why() -> String:
  "makes a hard link that can get round path protection"

# ---------------------------------------------------------------------------
# Small helpers

def pick.s(b: Bool, x: String, y: String) -> String:
  match b:
    case True{}:
      x
    case False{}:
      y

def is_pwsh(sh: T.Shell) -> Bool:
  match sh:
    case T.Bash{}:
      False{}
    case T.Pwsh{}:
      True{}

def has_char(s: String, +c: Char) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{x, t}:
      Char.is_eq(x, c) || has_char(t, c)

def elem(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      String.eq(x, h) || elem(x, t)

def all_digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_digit(c) && all_digits(t)

# some word is a short-flag group (-x..., not --x) holding c, or equals long
def short_or_long(ws: List<&2, String>, +c: Char, +long: String) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      (String.eq(w, long) || (String.starts_with(w, "-") && Bool.not(String.starts_with(w, "--")) && has_char(w, c))) || short_or_long(t, c, long)

# ---------------------------------------------------------------------------
# Actions from paths

type AKind is Data:
  AKind.Read{}
  AKind.ReadTree{}
  AKind.ListDir{}
  AKind.Write{}
  AKind.WriteTree{}
  AKind.Delete{}
  AKind.DeleteTree{}
  AKind.MoveFrom{}
  AKind.MakeDir{}
  AKind.ChangeDir{}

def act(k: AKind, p: T.Path) -> T.Action:
  match k:
    case AKind.Read{}:
      T.Read{p}
    case AKind.ReadTree{}:
      T.ReadTree{p}
    case AKind.ListDir{}:
      T.ListDir{p}
    case AKind.Write{}:
      T.Write{p}
    case AKind.WriteTree{}:
      T.WriteTree{p}
    case AKind.Delete{}:
      T.Delete{p}
    case AKind.DeleteTree{}:
      T.DeleteTree{p}
    case AKind.MoveFrom{}:
      T.MoveFrom{p}
    case AKind.MakeDir{}:
      T.MakeDir{p}
    case AKind.ChangeDir{}:
      T.ChangeDir{p}

def acts(ps: List<&2, T.Path>, +k: AKind) -> List<&2, T.Action>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      act(k, p) <> acts(t, k)

# ---------------------------------------------------------------------------
# Resolving raw paths against the possible current folders

def resolve.cons(m: Maybe<&2, T.Path>, r: Maybe<&2, List<&2, T.Path>>) -> Maybe<&2, List<&2, T.Path>>:
  match m r:
    case Some{p} Some{ps}:
      Some{p <> ps}
    case _ _:
      None{}

def resolve.go(cwds: List<&2, String>, +home: String, +raw: String) -> Maybe<&2, List<&2, T.Path>>:
  match cwds:
    case Nil{}:
      Some{[]}
    case c <> t:
      resolve.cons(Path.norm(c, home, raw), resolve.go(t, home, raw))

# raw read from each possible folder, in the order of cwds; None when any
# folder gives no safe path. When cwds is empty (the folder is not known),
# raw is read against "", which places only paths that do not need the
# folder (c:/..., /c/..., /mnt/c/..., ~/...); a relative path gives None
# (design.md Failure behaviour: relative paths in that shell are unknown)
def resolve(cwds: List<&2, String>, +home: String, +raw: String) -> Maybe<&2, List<&2, T.Path>>:
  match cwds:
    case Nil{}:
      resolve.go([""], home, raw)
    case c <> t:
      resolve.go(c <> t, home, raw)

def path.why(cwds: List<&2, String>, raw: String) -> String:
  match cwds:
    case Nil{}:
      "the shell's current folder is not known, so the path " ++ raw ++ " cannot be placed"
    case _:
      "cannot tell where the path " ++ raw ++ " points"

def path.if(m: Maybe<&2, List<&2, T.Path>>, k: AKind, cwds: List<&2, String>, raw: String) -> T.Meaning:
  match m:
    case Some{ps}:
      T.Known{acts(ps, k)}
    case None{}:
      T.Unknown{path.why(cwds, raw), []}

# one action of kind k on raw, per possible folder
def path(+k: AKind, +cwds: List<&2, String>, +home: String, +raw: String) -> T.Meaning:
  path.if(resolve(cwds, home, raw), k, cwds, raw)

def paths(raws: List<&2, String>, +k: AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match raws:
    case Nil{}:
      T.Known{[]}
    case r <> t:
      join(path(k, cwds, home, r), paths(t, k, cwds, home))

# ---------------------------------------------------------------------------
# Wildcards (* ? [). The lexer keeps them in words whether or not they were
# quoted, so a word holding one is treated as if the shell expanded it.

def is_glob_char(c: Char) -> Bool:
  match c:
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case _:
      False{}

# (a loop: since round 2, R2M-3, every word of a command that is not
# understood is tested, and one word can be 20,000 characters long)
def has_glob.go(s: String, acc: Bool) -> Bool:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      has_glob.go(t, acc || is_glob_char(c))

def has_glob(s: String) -> Bool:
  has_glob.go(s, False{})

def any_glob(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      has_glob(x) || any_glob(t)

def glob.keep(stop: Bool, c: Char, acc: String) -> String:
  match stop:
    case True{}:
      acc
    case False{}:
      SCon{c, acc}

# the text before the first wildcard, reversed
def glob.pre(s: String, +stop: Bool, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+c, t}:
      glob.pre(t, stop || is_glob_char(c), glob.keep(stop || is_glob_char(c), c, acc))

# a folder separator where the shell expands wildcards: bash splits a pattern
# on / only (a backslash there is an escape); PowerShell on / and \
def glob.sep(+sh: T.Shell, c: Char) -> Bool:
  match c:
    case Chr{47}:
      True{}
    case Chr{92}:
      is_pwsh(sh)
    case _:
      False{}

# s up to and including its last separator; dir and cur are reversed
def glob.dir(s: String, +sh: T.Shell, +dir: String, +cur: String) -> String:
  match s:
    case SNil{}:
      String.reverse(dir)
    case SCon{+c, t}:
      glob.dir(t, sh, pick.s(glob.sep(sh, c), SCon{c, cur ++ dir}, dir), pick.s(glob.sep(sh, c), "", SCon{c, cur}))

def glob.has_sep(s: String, bs: Bool) -> Bool:
  match s bs:
    case SNil{} _:
      False{}
    case SCon{Chr{47}, t} _:
      True{}
    case SCon{Chr{92}, t} True{}:
      True{}
    case SCon{Chr{92}, t} False{}:
      glob.has_sep(t, False{})
    case SCon{c, t} b:
      glob.has_sep(t, b)

# s holds a character other than * ? .
def glob.lit(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{42}, t}:
      glob.lit(t)
    case SCon{Chr{63}, t}:
      glob.lit(t)
    case SCon{Chr{46}, t}:
      glob.lit(t)
    case SCon{c, t}:
      True{}

# a last part starting with '.' must not be able to match . or ..
def glob.dot_ok(s: String) -> Bool:
  match s:
    case SCon{Chr{46}, +t}:
      Bool.not(String.contains(t, "[")) && glob.lit(t)
    case _:
      True{}

def glob.fin(ok: Bool, dir: String) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{dir}
    case False{}:
      None{}

def glob.rest(+dir: String, +rest: String, bs: Bool) -> Maybe<&2, String>:
  glob.fin(Bool.not(glob.has_sep(rest, bs)) && glob.dot_ok(rest), pick.s(String.is_empty(dir), ".", dir))

def glob.split(+dir: String, raw: String, bs: Bool) -> Maybe<&2, String>:
  glob.rest(dir, String.drop(raw, String.length(dir)), bs)

# raw holds a wildcard. Some{dir}: every file name it can expand to is
# directly inside dir (raw text; "." is the current folder). None when it may
# reach further: a wildcard before the last part, or a last part that can
# match . or .. (.* and the like). path: raw is a path argument, so a
# backslash after the folder is refused too (Windows reads it as a separator
# when the wildcard matches nothing and the text is passed on as it is).
def glob_dir(+sh: T.Shell, path: Bool, +raw: String) -> Maybe<&2, String>:
  glob.split(glob.dir(String.reverse(glob.pre(raw, False{}, "")), sh, "", ""), raw, path || is_pwsh(sh))

# a path argument of a command that reads: a plain path gets kind k; one with
# a wildcard gets kind g on the folder it can reach
def rpath.glob(m: Maybe<&2, String>, g: AKind, +cwds: List<&2, String>, +home: String, raw: String) -> T.Meaning:
  match m:
    case Some{dir}:
      path(g, cwds, home, dir)
    case None{}:
      T.Unknown{"the wildcard in " ++ raw ++ " can reach outside one folder, which is not modelled", []}

def rpath.if(isg: Bool, +sh: T.Shell, k: AKind, g: AKind, +cwds: List<&2, String>, +home: String, +raw: String) -> T.Meaning:
  match isg:
    case False{}:
      path(k, cwds, home, raw)
    case True{}:
      rpath.glob(glob_dir(sh, True{}, raw), g, cwds, home, raw)

def rpath(+sh: T.Shell, k: AKind, g: AKind, +cwds: List<&2, String>, +home: String, +raw: String) -> T.Meaning:
  rpath.if(has_glob(raw), sh, k, g, cwds, home, raw)

def rpaths(raws: List<&2, String>, +sh: T.Shell, +k: AKind, +g: AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match raws:
    case Nil{}:
      T.Known{[]}
    case r <> t:
      join(rpath(sh, k, g, cwds, home, r), rpaths(t, sh, k, g, cwds, home))

# a word that is not a path (a grep pattern, a flag value in its own word):
# under bash a wildcard in it may expand into file names that become
# arguments, so it reads the folder it can reach. PowerShell does not expand
# wildcards in arguments.
def wglob.dir(m: Maybe<&2, String>, +cwds: List<&2, String>, +home: String, w: String) -> T.Meaning:
  match m:
    case Some{dir}:
      path(AKind.ReadTree{}, cwds, home, dir)
    case None{}:
      T.Unknown{"the wildcard in " ++ w ++ " may name files outside one folder, which is not modelled", []}

def wglob.if(isg: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +w: String) -> T.Meaning:
  match isg:
    case False{}:
      T.Known{[]}
    case True{}:
      wglob.dir(glob_dir(sh, False{}, w), cwds, home, w)

def wglob(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +w: String) -> T.Meaning:
  wglob.if(has_glob(w) && Bool.not(is_pwsh(sh)), sh, cwds, home, w)

def wglobs(ws: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ws:
    case Nil{}:
      T.Known{[]}
    case w <> t:
      join(wglob(sh, cwds, home, w), wglobs(t, sh, cwds, home))

# the words not in lit: lit holds words whose wildcards were all quoted
# (Lex.LexOut), which bash passes on as they are (round 2, P10)
def unlit.k(seen: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match seen:
    case True{}:
      rest
    case False{}:
      w <> rest

def unlit(ws: List<&2, String>, +lit: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      []
    case +w <> t:
      unlit.k(elem(w, lit), w, unlit(t, lit))

# ---------------------------------------------------------------------------
# Wildcards that can reach a protected file (round 2, P2). A command that
# deletes, moves, copies or writes through a wildcard stays not modelled, but
# every protected name its last part can match is added to the Unknown as a
# known action (Delete, DeleteTree, MoveFrom, Write, or Read for a copy's
# source), so self-protection and the rules see it. Known actions only make
# a verdict stricter, so no law changes.

# Names bend-guard protects, or folders on the way to a protected file
# (lower case). The home folder's and each possible folder's own last part
# are added at the call (glob.names.all).
def guard_names() -> List<&2, String>:
  ["bend_rules.md", "settings.json", "settings.local.json", ".mcp.json", ".claude.json", ".claude", ".git", "hooks", "config", "config.worktree", ".gitconfig", "gitconfig", ".gitattributes", ".config", "git", "gh", "local-plugins", "plugins", "bend-guard", "powershell", "windowspowershell", "documents", "onedrive", ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".inputrc", ".ssh", ".npmrc", ".curlrc", "_curlrc", ".wgetrc", "github cli", "pip", "shell-snapshots", "session-env", "dev-mods", "claudecode", "openrouter.key", "appdata", "roaming", "microsoft", "windows", "start menu", "programs", "startup", "programdata", "program files", "users", "bin", ".local", ".cargo", "npm", "etc", "npmrc", "local", "windowsapps", "winget", "links", "python", "packages", "commondir", "gitdir", "ntuser.dat"]

# Matching a name against a wildcard pattern (* any run, ? one char, [...]
# any one char, which over-reads a class and so only adds matches). The
# pattern suffixes still possible are kept in a list while the name is read
# char by char (no backtracking, so the time is bounded).

# p, and while p starts with *, the pattern after that * too
def gm.close(p: String) -> List<&2, String>:
  match p:
    case SCon{Chr{42}, +t}:
      SCon{Chr{42}, t} <> gm.close(t)
    case other:
      [other]

# the text after each ']' in s: a bracket class may end at any of them
def gm.ends(s: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{93}, +t}:
      gm.ends(t, t <> acc)
    case SCon{c, t}:
      gm.ends(t, acc)

def gm.lit(hit: Bool, t: String) -> List<&2, String>:
  match hit:
    case True{}:
      [t]
    case False{}:
      []

# the pattern suffixes left once p has read the char c
def gm.step1(+c: Char, p: String) -> List<&2, String>:
  match p:
    case SNil{}:
      []
    case SCon{Chr{42}, t}:
      [SCon{Chr{42}, t}]
    case SCon{Chr{63}, t}:
      [t]
    case SCon{Chr{91}, +t}:
      List.append(&2, String, gm.lit(Char.is_eq(c, '['), t), gm.ends(t, []))
    case SCon{x, t}:
      gm.lit(Char.is_eq(x, c), t)

def gm.closeall(ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      List.append(&2, String, gm.close(p), gm.closeall(t))

def gm.stepall(+c: Char, ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      List.append(&2, String, gm.step1(c, p), gm.stepall(c, t))

def gm.add(seen: Bool, p: String, acc: List<&2, String>) -> List<&2, String>:
  match seen:
    case True{}:
      acc
    case False{}:
      p <> acc

def gm.dedupe(ps: List<&2, String>, +acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      acc
    case +p <> t:
      gm.dedupe(t, gm.add(elem(p, acc), p, acc))

def gm.done(ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      String.is_empty(p) || gm.done(t)

def gm.run(s: String, ps: List<&2, String>) -> Bool:
  match s:
    case SNil{}:
      gm.done(ps)
    case SCon{c, t}:
      gm.run(t, gm.dedupe(gm.closeall(gm.stepall(c, ps)), []))

def glob.match.k(long: Bool, pat: String, name: String) -> Bool:
  match long:
    case True{}:
      True{}
    case False{}:
      gm.run(name, gm.close(pat))

# the wildcard pattern pat (lower case) matches the whole of name; a pattern
# longer than 128 characters is taken to match every name (stricter)
def glob.match(+pat: String, name: String) -> Bool:
  glob.match.k(Nat.is_lt(128n, String.length(pat)), pat, name)

# under bash a name starting with '.' is matched only by a pattern that
# starts with '.' (dotglob is off); PowerShell matches it with * too
def glob.dot(+sh: T.Shell, +pat: String, +name: String) -> Bool:
  Bool.not(Bool.not(is_pwsh(sh)) && String.starts_with(name, ".") && Bool.not(String.starts_with(pat, ".")))

def glob.names.k(hit: Bool, n: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      n <> rest
    case False{}:
      rest

# the names of ns that pat matches
def glob.names(ns: List<&2, String>, +sh: T.Shell, +pat: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      glob.names.k(Bool.not(String.is_empty(n)) && glob.match(pat, n) && glob.dot(sh, pat, n), n, glob.names(t, sh, pat))

# the last part of a folder's text (after the last / or \), lower case
def glob.base.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{47}, t}:
      glob.base.go(t, "")
    case SCon{Chr{92}, t}:
      glob.base.go(t, "")
    case SCon{c, t}:
      glob.base.go(t, SCon{Char.to_lower(c), acc})

def glob.bases(cwds: List<&2, String>) -> List<&2, String>:
  match cwds:
    case Nil{}:
      []
    case c <> t:
      glob.base.go(c, "") <> glob.bases(t)

def glob.names.all(+cwds: List<&2, String>, +home: String) -> List<&2, String>:
  List.append(&2, String, guard_names(), glob.base.go(home, "") <> glob.bases(cwds))

# raw up to and including its last separator (/ or \, in both shells, which
# only adds matches) before the first wildcard
def glob.hdir(+raw: String) -> String:
  glob.dir(String.reverse(glob.pre(raw, False{}, "")), T.Pwsh{}, "", "")

# s lower-cased (a loop: Base String.to_lower is not, and a word can be
# 20,000 characters long)
def glob.lower(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{c, t}:
      glob.lower(t, SCon{Char.to_lower(c), acc})

def glob.hn.if(ok: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +pat: String) -> List<&2, String>:
  match ok:
    case True{}:
      glob.names(glob.names.all(cwds, home), sh, glob.lower(pat, ""))
    case False{}:
      []

def glob.hn.at(+pat: String, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +raw: String) -> List<&2, String>:
  glob.hn.if(has_glob(raw) && Bool.not(glob.has_sep(pat, True{})), sh, cwds, home, pat)

# the protected names the wildcard in raw can match, when it is in raw's
# last part only ([] for a raw with no wildcard)
def glob.hnames(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +raw: String) -> List<&2, String>:
  glob.hn.at(String.drop(raw, String.length(glob.hdir(raw))), sh, cwds, home, raw)

def glob.join(+dir: String, +n: String) -> String:
  pick.s(String.is_empty(dir), n, dir ++ n)

def acts.of(m: T.Meaning) -> List<&2, T.Action>:
  match m:
    case T.Known{xs}:
      xs
    case T.Unknown{w, xs}:
      xs

def glob.acts(ns: List<&2, String>, +dir: String, +k: AKind, +cwds: List<&2, String>, +home: String) -> List<&2, T.Action>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      List.append(&2, T.Action, acts.of(path(k, cwds, home, glob.join(dir, n))), glob.acts(t, dir, k, cwds, home))

# kind k on dir/N for every protected name N the wildcard in raw can match
def glob.hits(+sh: T.Shell, +k: AKind, +cwds: List<&2, String>, +home: String, +raw: String) -> List<&2, T.Action>:
  glob.acts(glob.hnames(sh, cwds, home, raw), glob.hdir(raw), k, cwds, home)

# (loops with acc, so a long list of words cannot overflow the stack)
def glob.hits.all(raws: List<&2, String>, +sh: T.Shell, +k: AKind, +cwds: List<&2, String>, +home: String, acc: List<&2, T.Action>) -> List<&2, T.Action>:
  match raws:
    case Nil{}:
      acc
    case r <> t:
      glob.hits.all(t, sh, k, cwds, home, List.append(&2, T.Action, glob.hits(sh, k, cwds, home, r), acc))

def glob.note.k(ns: List<&2, String>, raw: String) -> String:
  match ns:
    case Nil{}:
      ""
    case n <> t:
      "; the wildcard in " ++ raw ++ " can match the name " ++ n ++ ", which bend-guard protects in some folders"

def glob.note.pick(+found: String, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +r: String) -> String:
  pick.s(String.is_empty(found), glob.note.k(glob.hnames(sh, cwds, home, r), r), found)

# the reason's addition for the first raw whose wildcard can match a
# protected name ("" when none can)
def glob.note(raws: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String, found: String) -> String:
  match raws:
    case Nil{}:
      found
    case r <> t:
      glob.note(t, sh, cwds, home, glob.note.pick(found, sh, cwds, home, r))

def why.of(m: T.Meaning) -> String:
  match m:
    case T.Known{xs}:
      "a wildcard can match a protected name"
    case T.Unknown{w, xs}:
      w

def glob.add(+m: T.Meaning, hits: List<&2, T.Action>, note: String) -> T.Meaning:
  match hits:
    case Nil{}:
      m
    case h <> t:
      T.Unknown{why.of(m) ++ note, List.append(&2, T.Action, acts.of(m), h <> t)}

# m (the meaning of a command whose words raws may hold a wildcard), with
# kind k on every protected name a wildcard can match added as known
# actions; m itself when none can
def glob.with(+m: T.Meaning, +sh: T.Shell, +k: AKind, +cwds: List<&2, String>, +home: String, +raws: List<&2, String>) -> T.Meaning:
  glob.add(m, glob.hits.all(raws, sh, k, cwds, home, []), glob.note(raws, sh, cwds, home, ""))

# ---------------------------------------------------------------------------
# mv and cp: sources and target

# raw's last part (ignoring separators at the end) is only dots and spaces:
# . and .. (copy or move a folder's contents), and what Windows reads as them
def dend.skip(s: String) -> String:
  match s:
    case SCon{Chr{47}, t}:
      dend.skip(t)
    case SCon{Chr{92}, t}:
      dend.skip(t)
    case other:
      other

def dend.dots(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{47}, t}:
      True{}
    case SCon{Chr{92}, t}:
      True{}
    case SCon{Chr{46}, t}:
      dend.dots(t)
    case SCon{Chr{32}, t}:
      dend.dots(t)
    case SCon{c, t}:
      False{}

def dotted_end(raw: String) -> Bool:
  dend.dots(dend.skip(String.reverse(raw)))

def any_dotted_end(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      dotted_end(x) || any_dotted_end(t)

def last.go(t: List<&2, String>, h: String) -> Maybe<&2, String>:
  match t:
    case Nil{}:
      Some{h}
    case x <> r:
      last.go(r, x)

def into.mk(b: Maybe<&2, String>, dd: String, ds: List<&2, String>) -> Maybe<&2, T.Action>:
  match b:
    case Some{x}:
      Some{T.WriteTree{T.Path{dd, List.append(&2, String, ds, [x])}}}
    case None{}:
      None{}

# the source s moved or copied into the folder d: d/<last part of s>
def into.one(s: T.Path, d: T.Path) -> Maybe<&2, T.Action>:
  match s d:
    case T.Path{sd, Nil{}} T.Path{dd, ds}:
      None{}
    case T.Path{sd, h <> t} T.Path{dd, ds}:
      into.mk(last.go(t, h), dd, ds)

def into.cons(m: Maybe<&2, T.Action>, r: Maybe<&2, List<&2, T.Action>>) -> Maybe<&2, List<&2, T.Action>>:
  match m r:
    case Some{a} Some{xs}:
      Some{a <> xs}
    case _ _:
      None{}

# pairs each source with the target from the same possible folder
def into(ss: List<&2, T.Path>, ds: List<&2, T.Path>) -> Maybe<&2, List<&2, T.Action>>:
  match ss ds:
    case s <> st d <> dt:
      into.cons(into.one(s, d), into(st, dt))
    case _ _:
      Some{[]}

def mv.into(m: Maybe<&2, List<&2, T.Action>>, raw: String) -> T.Meaning:
  match m:
    case Some{xs}:
      T.Known{xs}
    case None{}:
      T.Unknown{"cannot tell the name " ++ raw ++ " gets inside the target folder", []}

def mv.pair(ms: Maybe<&2, List<&2, T.Path>>, md: Maybe<&2, List<&2, T.Path>>, raw: String) -> T.Meaning:
  match ms md:
    case Some{ps} Some{ds}:
      mv.into(into(ps, ds), raw)
    case _ _:
      T.Known{[]}

# one source of mv or cp: kind k on the source, and the copy of it inside
# the target (the path meanings say why when a path cannot be placed)
def mv.src(+k: AKind, +cwds: List<&2, String>, +home: String, md: Maybe<&2, List<&2, T.Path>>, +raw: String) -> T.Meaning:
  join(path(k, cwds, home, raw), mv.pair(resolve(cwds, home, raw), md, raw))

def mv.srcs(srcs: List<&2, String>, +k: AKind, +cwds: List<&2, String>, +home: String, +md: Maybe<&2, List<&2, T.Path>>) -> T.Meaning:
  match srcs:
    case Nil{}:
      T.Known{[]}
    case s <> t:
      join(mv.src(k, cwds, home, md, s), mv.srcs(t, k, cwds, home, md))

# A target that surely names a folder that already exists: ~, or a last part
# of . or .. (., ./, .., ../, ../.., src/..), after one separator at the end.
# raw is read reversed: drop one separator, then take the last part.
def sdir.drop1(s: String) -> String:
  match s:
    case SCon{Chr{47}, t}:
      t
    case SCon{Chr{92}, t}:
      t
    case other:
      other

def sdir.part(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{47}, t}:
      acc
    case SCon{Chr{92}, t}:
      acc
    case SCon{c, t}:
      sdir.part(t, SCon{c, acc})

def sdir.name(p: String) -> Bool:
  match p:
    case ".":
      True{}
    case "..":
      True{}
    case _:
      False{}

def sdir.go(+s: String) -> Bool:
  sdir.name(sdir.part(s, "")) || String.eq(s, "~")

def surely_dir(raw: String) -> Bool:
  sdir.go(sdir.drop1(String.reverse(raw)))

# the target's own path meaning with its actions dropped: only its reason
# survives when the target cannot be placed
def dst.why(m: T.Meaning) -> T.Meaning:
  match m:
    case T.Known{xs}:
      T.Known{[]}
    case T.Unknown{w, xs}:
      T.Unknown{w, []}

def move.if(sd: Bool, srcs: List<&2, String>, +dst: String, +k: AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match sd:
    case True{}:
      join(mv.srcs(srcs, k, cwds, home, resolve(cwds, home, dst)), dst.why(path(AKind.Write{}, cwds, home, dst)))
    case False{}:
      join(mv.srcs(srcs, k, cwds, home, resolve(cwds, home, dst)), path(AKind.Write{}, cwds, home, dst))

# srcs and the target dst (already checked: no wildcards, no source ending in
# . or ..): each source gets kind k and WriteTree{dst/<last part of the
# source>}; the target itself gets Write{dst} unless it is ., .. or ~ (or
# ends in . or ..), which always names a folder that exists, so the command
# can never replace it (plan Task 1.7; SH-3)
def move(srcs: List<&2, String>, +dst: String, +k: AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  move.if(surely_dir(dst), srcs, dst, k, cwds, home)

# ---------------------------------------------------------------------------
# Flags

# How a command's flags are read:
#   bool  short flags without a value, which may be joined (-rf)
#   val   short flags that take a value (-n 5, -n5, -rn5)
#   long  long flags: key the whole flag, or a prefix ending in '=' for a
#         long flag with a value (--include=G); value the one-char name it
#         counts as
#   num   -N (only digits) is allowed (head, tail)
#   dd    -- ends the flags
# Long flags are matched in full only (GNU would take abbreviations).
type Spec is Data:
  Spec.Mk{bool: String, val: String, long: List<&2, T.Arg>, num: Bool, dd: Bool}

# A command line read with a Spec:
#   flags  one char per flag seen (value flags too)
#   vals   values given to flags (key: the flag's char)
#   ops    operands, in order
#   loose  values that stood in a word of their own (-e PAT): under bash a
#          wildcard in one may expand into several words
type Opts is Data:
  Opts.Ok{flags: String, vals: List<&2, T.Arg>, ops: List<&2, String>, loose: List<&2, String>}
  Opts.Bad{why: String}

# a short-flag group being read: vc is the value flag met in it ("" if
# none), vb the text after it (reversed), which is that flag's value
type Grp is Data:
  Grp.Mk{ok: Bool, bad: String, flags: String, vc: String, vb: String}

def grp.char.if(free: Bool, isb: Bool, isv: Bool, +c: Char, ok: Bool, bad: String, fl: String, vc: String, vb: String) -> Grp:
  match free isb isv:
    case False{} _ _:
      Grp.Mk{ok, bad, fl, vc, SCon{c, vb}}
    case True{} True{} _:
      Grp.Mk{ok, bad, SCon{c, fl}, vc, vb}
    case True{} False{} True{}:
      Grp.Mk{ok, bad, SCon{c, fl}, SCon{c, ""}, vb}
    case True{} False{} False{}:
      Grp.Mk{False{}, pick.s(ok, SCon{c, ""}, bad), fl, vc, vb}

def grp.char(+b: String, +v: String, +c: Char, g: Grp) -> Grp:
  match g:
    case Grp.Mk{ok, bad, fl, +vc, vb}:
      grp.char.if(String.is_empty(vc), has_char(b, c), has_char(v, c), c, ok, bad, fl, vc, vb)

def grp.go(cs: String, +b: String, +v: String, g: Grp) -> Grp:
  match cs:
    case SNil{}:
      g
    case SCon{c, t}:
      grp.go(t, b, v, grp.char(b, v, c, g))

# how one word reads (it is not a pending value, and flags have not ended)
type Cls is Data:
  Cls.Op{}
  Cls.DD{}
  Cls.Num{}
  Cls.Flag{c: String, v: String}
  Cls.Grp{g: Grp}
  Cls.Bad{why: String}

def long.hit(hit: Bool, c: String, v: String, rest: Maybe<&2, T.Arg>) -> Maybe<&2, T.Arg>:
  match hit:
    case True{}:
      Some{T.Arg{c, v}}
    case False{}:
      rest

def long.one(pre: Bool, +k: String, c: String, +w: String, rest: Maybe<&2, T.Arg>) -> Maybe<&2, T.Arg>:
  match pre:
    case True{}:
      long.hit(String.starts_with(w, k), c, String.drop(w, String.length(k)), rest)
    case False{}:
      long.hit(String.eq(w, k), c, "", rest)

# the long flag w in the table: Arg{its char, its value}
def long.find(xs: List<&2, T.Arg>, +w: String) -> Maybe<&2, T.Arg>:
  match xs:
    case Nil{}:
      None{}
    case T.Arg{+k, c} <> t:
      long.one(String.ends_with(k, "="), k, c, w, long.find(t, w))

def word.dd(dd: Bool) -> Cls:
  match dd:
    case True{}:
      Cls.DD{}
    case False{}:
      Cls.Bad{"the flag -- is not known"}

def word.long(m: Maybe<&2, T.Arg>, w: String) -> Cls:
  match m:
    case Some{T.Arg{c, v}}:
      Cls.Flag{c, v}
    case None{}:
      Cls.Bad{"the flag " ++ w ++ " is not known"}

def word.short(isnum: Bool, b: String, v: String, cs: String) -> Cls:
  match isnum:
    case True{}:
      Cls.Num{}
    case False{}:
      Cls.Grp{grp.go(cs, b, v, Grp.Mk{True{}, "", "", "", ""})}

def word.k(isdd: Bool, islong: Bool, isdash: Bool, isone: Bool, b: String, v: String, l: List<&2, T.Arg>, num: Bool, dd: Bool, +w: String) -> Cls:
  match isdd islong isdash isone:
    case True{} _ _ _:
      word.dd(dd)
    case False{} True{} _ _:
      word.long(long.find(l, w), w)
    case False{} False{} True{} True{}:
      Cls.Bad{"the argument - (standard input) is not modelled"}
    case False{} False{} True{} False{}:
      word.short(num && all_digits(String.drop(w, 1n)), b, v, String.drop(w, 1n))
    case False{} False{} False{} _:
      Cls.Op{}

def word(sp: Spec, +w: String) -> Cls:
  match sp:
    case Spec.Mk{b, v, l, num, dd}:
      word.k(String.eq(w, "--"), String.starts_with(w, "--"), String.starts_with(w, "-"), String.eq(w, "-"), b, v, l, num, dd, w)

# the reading state: ok and why (the first problem), want (a value flag
# waiting for its value in the next word, "" if none), dd (flags ended),
# then the parts of Opts, reversed
type OSt is Data:
  OSt.Mk{ok: Bool, why: String, want: String, dd: Bool, flags: String, vals: List<&2, T.Arg>, ops: List<&2, String>, loose: List<&2, String>}

def apply.grp.k(gok: Bool, novc: Bool, novb: Bool, bad: String, gfl: String, vc: String, vb: String, +ok: Bool, why: String, fl: String, vs: List<&2, T.Arg>, ops: List<&2, String>, lo: List<&2, String>) -> OSt:
  match gok novc novb:
    case False{} _ _:
      OSt.Mk{False{}, pick.s(ok, "the flag -" ++ bad ++ " is not known", why), "", False{}, fl, vs, ops, lo}
    case True{} True{} _:
      OSt.Mk{ok, why, "", False{}, gfl ++ fl, vs, ops, lo}
    case True{} False{} True{}:
      OSt.Mk{ok, why, vc, False{}, gfl ++ fl, vs, ops, lo}
    case True{} False{} False{}:
      OSt.Mk{ok, why, "", False{}, gfl ++ fl, T.Arg{vc, String.reverse(vb)} <> vs, ops, lo}

def apply.grp(g: Grp, +ok: Bool, why: String, fl: String, vs: List<&2, T.Arg>, ops: List<&2, String>, lo: List<&2, String>) -> OSt:
  match g:
    case Grp.Mk{gok, bad, gfl, +vc, +vb}:
      apply.grp.k(gok, String.is_empty(vc), String.is_empty(vb), bad, gfl, vc, vb, ok, why, fl, vs, ops, lo)

def apply(k: Cls, +ok: Bool, why: String, fl: String, vs: List<&2, T.Arg>, ops: List<&2, String>, lo: List<&2, String>, w: String) -> OSt:
  match k:
    case Cls.Op{}:
      OSt.Mk{ok, why, "", False{}, fl, vs, w <> ops, lo}
    case Cls.DD{}:
      OSt.Mk{ok, why, "", True{}, fl, vs, ops, lo}
    case Cls.Num{}:
      OSt.Mk{ok, why, "", False{}, fl, vs, ops, lo}
    case Cls.Flag{+c, v}:
      OSt.Mk{ok, why, "", False{}, c ++ fl, T.Arg{c, v} <> vs, ops, lo}
    case Cls.Grp{g}:
      apply.grp(g, ok, why, fl, vs, ops, lo)
    case Cls.Bad{msg}:
      OSt.Mk{False{}, pick.s(ok, msg, why), "", False{}, fl, vs, ops, lo}

def step.k(free: Bool, +dd: Bool, ok: Bool, why: String, want: String, fl: String, vs: List<&2, T.Arg>, ops: List<&2, String>, lo: List<&2, String>, +sp: Spec, +w: String) -> OSt:
  match free dd:
    case False{} _:
      OSt.Mk{ok, why, "", dd, fl, T.Arg{want, w} <> vs, ops, w <> lo}
    case True{} True{}:
      OSt.Mk{ok, why, "", dd, fl, vs, w <> ops, lo}
    case True{} False{}:
      apply(word(sp, w), ok, why, fl, vs, ops, lo, w)

def step(+sp: Spec, st: OSt, +w: String) -> OSt:
  match st:
    case OSt.Mk{ok, why, +want, dd, fl, vs, ops, lo}:
      step.k(String.is_empty(want), dd, ok, why, want, fl, vs, ops, lo, sp, w)

def opts.go(ws: List<&2, String>, +sp: Spec, st: OSt) -> OSt:
  match ws:
    case Nil{}:
      st
    case w <> t:
      opts.go(t, sp, step(sp, st, w))

def opts.fin.k(ok: Bool, free: Bool, why: String, want: String, fl: String, vs: List<&2, T.Arg>, ops: List<&2, String>, lo: List<&2, String>) -> Opts:
  match ok free:
    case False{} _:
      Opts.Bad{why}
    case True{} False{}:
      Opts.Bad{"the flag -" ++ want ++ " needs a value"}
    case True{} True{}:
      Opts.Ok{fl, List.reverse(&2, T.Arg, vs), List.reverse(&2, String, ops), List.reverse(&2, String, lo)}

def opts.fin(st: OSt) -> Opts:
  match st:
    case OSt.Mk{ok, why, +want, dd, fl, vs, ops, lo}:
      opts.fin.k(ok, String.is_empty(want), why, want, fl, vs, ops, lo)

def spec(bool: String, val: String, long: List<&2, T.Arg>, num: Bool, dd: Bool) -> Spec:
  Spec.Mk{bool, val, long, num, dd}

# Model.parse(spec, args): the flags and operands of args (argv without the
# command name), or Bad with the first problem
def parse(sp: Spec, ws: List<&2, String>) -> Opts:
  opts.fin(opts.go(ws, sp, OSt.Mk{True{}, "", "", False{}, "", [], [], []}))

# the values of every flag, in order
def vals(xs: List<&2, T.Arg>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case T.Arg{k, v} <> t:
      v <> vals(t)

def vals_for.k(hit: Bool, v: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      v <> rest
    case False{}:
      rest

# the values given to the flag whose char is c ("e" for -e PAT, -ePAT and a
# long flag listed with "e"), in order
def vals_for(xs: List<&2, T.Arg>, +c: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case T.Arg{k, v} <> t:
      vals_for.k(String.eq(k, c), v, vals_for(t, c))

# every value of a flag whose char is in cs is a number (one or more digits)
def nums_ok(xs: List<&2, T.Arg>, +cs: String) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case T.Arg{k, +v} <> t:
      (Bool.not(String.contains(cs, k)) || (Bool.not(String.is_empty(v)) && all_digits(v))) && nums_ok(t, cs)

def ident.first() -> String:
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"

def ident.rest(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      (has_char(ident.first(), c) || Char.is_digit(c)) && ident.rest(t)

# a name: a letter or _ first, then letters, digits and _
def is_ident(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+c, t}:
      has_char(ident.first(), c) && ident.rest(t)

def before_eq.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{61}, t}:
      String.reverse(acc)
    case SCon{c, t}:
      before_eq.go(t, SCon{c, acc})

# the text before the first =, or all of it
def before_eq(s: String) -> String:
  before_eq.go(s, "")

# Long flags whose value may stand in the next word (round 3: gh, curl, rg,
# ps, pip). parse reads a long flag's value only after =, so longv first
# joins "--k" and the word after it into "--k=VALUE" for each --k in ks, as
# the program itself does (it takes the next word whatever it is). A --k
# with no word after it is left alone (and is then not a known flag).
def longv.acc(pend: Bool, w: String, acc: List<&2, String>) -> List<&2, String>:
  match pend acc:
    case True{} Con{h, t}:
      (h ++ "=" ++ w) <> t
    case _ a:
      w <> a

def longv.want(pend: Bool, +w: String, +ks: List<&2, String>) -> Bool:
  match pend:
    case True{}:
      False{}
    case False{}:
      elem(w, ks)

def longv.go(ws: List<&2, String>, +ks: List<&2, String>, +pend: Bool, acc: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +w <> t:
      longv.go(t, ks, longv.want(pend, w, ks), longv.acc(pend, w, acc))

def longv(ws: List<&2, String>, +ks: List<&2, String>) -> List<&2, String>:
  longv.go(ws, ks, False{}, [])

# ---------------------------------------------------------------------------
# Protected paths named by a part that is not understood (round 2, P2). The
# text (a command's words, or a tool's values) is lower-cased, '\' is read
# as '/' and runs of '/' as one. When it names a protected path (a tail
# below, followed by the end or a character such as '/', a quote, a space,
# ';', ')' or ',', after any dots, which Windows drops at the end of a name),
# or an 8.3 short name under .claude, under the home folder or for
# BEND_RULES.md, a WriteTree of that path is added to the meaning's known
# part. Known actions only make the verdict stricter, so no law changes;
# self-protection denies. ModelShell uses it for each simple command that is
# not understood, and for text that cannot be lexed; ModelTools for
# SendMessage and other tools. The PowerShell profile folders are matched
# with their Documents parent, so Windows' own
# System32/WindowsPowerShell/v1.0/powershell.exe does not count.

# Arg{tail, target}: a target starting with "~/" is in the home folder; any
# other is read against the project folder and each possible folder.
def nm.table() -> List<&2, T.Arg>:
  [T.Arg{".claude/settings.json", "~/.claude/settings.json"}, T.Arg{".claude/settings.local.json", "~/.claude/settings.local.json"}, T.Arg{".claude/bend-guard", "~/.claude/bend-guard"}, T.Arg{".claude/local-plugins", "~/.claude/local-plugins"}, T.Arg{".claude/plugins", "~/.claude/plugins"}, T.Arg{".claude/shell-snapshots", "~/.claude/shell-snapshots"}, T.Arg{".claude/session-env", "~/.claude/session-env"}, T.Arg{".claude/hooks", "~/.claude/hooks"}, T.Arg{".claude/dev-mods", "~/.claude/dev-mods"}, T.Arg{".claude.json", "~/.claude.json"}, T.Arg{".mcp.json", ".mcp.json"}, T.Arg{"bend_rules.md", "bend_rules.md"}, T.Arg{"documents/windowspowershell", "~/documents/windowspowershell"}, T.Arg{"documents/powershell", "~/documents/powershell"}, T.Arg{".bashrc", "~/.bashrc"}, T.Arg{".bash_profile", "~/.bash_profile"}, T.Arg{".git/hooks", ".git/hooks"}, T.Arg{".git/config", ".git/config"}, T.Arg{".gitconfig", "~/.gitconfig"}, T.Arg{"openrouter.key", "~/.claude/bend-guard/openrouter.key"}, T.Arg{"hkcu:/environment", "~/ntuser.dat"}, T.Arg{"hkey_current_user/environment", "~/ntuser.dat"}, T.Arg{"session manager/environment", "~/ntuser.dat"}, T.Arg{"setx", "~/ntuser.dat"}, T.Arg{"setx.exe", "~/ntuser.dat"}]

# characters that end a named path
def nm.bchar(c: Char) -> Bool:
  match c:
    case Chr{47}:
      True{}
    case Chr{34}:
      True{}
    case Chr{39}:
      True{}
    case Chr{96}:
      True{}
    case Chr{32}:
      True{}
    case Chr{9}:
      True{}
    case Chr{10}:
      True{}
    case Chr{13}:
      True{}
    case Chr{59}:
      True{}
    case Chr{41}:
      True{}
    case Chr{44}:
      True{}
    case Chr{124}:
      True{}
    case Chr{38}:
      True{}
    case Chr{62}:
      True{}
    case Chr{60}:
      True{}
    case Chr{93}:
      True{}
    case Chr{125}:
      True{}
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case Chr{58}:
      True{}
    case _:
      False{}

# the text after a tail: dots and spaces (which Windows drops at the end of
# a name), then the end or a character that ends a path. A '-' (as in
# bend-guard-drafts) or a letter goes on with a longer name.
def nm.after(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{46}, t}:
      nm.after(t)
    case SCon{c, t}:
      nm.bchar(c)

def nm.tilde(c: Char) -> Bool:
  match c:
    case Chr{126}:
      True{}
    case _:
      False{}

# the path part at the start of s (up to '/' or a character that ends a
# path) holds '~' and then a digit: an 8.3 short name. dead: the part has
# ended; prev: the last char was '~'; acc: found so far. A loop (the call is
# last), so long text cannot overflow the stack.
def nm.s83(s: String, dead: Bool, prev: Bool, acc: Bool) -> Bool:
  match s dead:
    case _ True{}:
      acc
    case SNil{} False{}:
      acc
    case SCon{Chr{47}, t} False{}:
      acc
    case SCon{+c, t} False{}:
      nm.s83(t, nm.bchar(c), nm.tilde(c), acc || (Bool.not(nm.bchar(c)) && prev && Char.is_digit(c)))

# s after its first path part and the '/' after it ("" when the part ends
# another way first)
def nm.skip1(s: String, dead: Bool) -> String:
  match s dead:
    case _ True{}:
      ""
    case SNil{} False{}:
      ""
    case SCon{Chr{47}, t} False{}:
      t
    case SCon{+c, t} False{}:
      nm.skip1(t, nm.bchar(c))

def nm.digit1(s: String) -> Bool:
  match s:
    case SCon{c, t}:
      Char.is_digit(c)
    case _:
      False{}

# the checks below run only where s starts with the text they look for
# (a match, so the scan stays linear in the text)
def nm.tail.at(hit: Bool, +s: String, +tail: String) -> Bool:
  match hit:
    case True{}:
      nm.after(String.drop(s, String.length(tail)))
    case False{}:
      False{}

def nm.c83(hit: Bool, +s: String) -> Bool:
  match hit:
    case True{}:
      nm.s83(String.drop(s, 8n), False{}, False{}, False{})
    case False{}:
      False{}

def nm.u83(hit: Bool, +s: String) -> Bool:
  match hit:
    case True{}:
      nm.s83(nm.skip1(String.drop(s, 6n), False{}), False{}, False{}, False{})
    case False{}:
      False{}

def nm.d83(hit: Bool, +s: String) -> Bool:
  match hit:
    case True{}:
      nm.digit1(String.drop(s, 7n))
    case False{}:
      False{}

def nm.one.k(hit: Bool, tg: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      tg <> rest
    case False{}:
      rest

# the targets of the table's tails that s starts with
def nm.tails(xs: List<&2, T.Arg>, +s: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case T.Arg{+tail, tg} <> t:
      nm.one.k(nm.tail.at(String.starts_with(s, tail), s, tail), tg, nm.tails(t, s))

# the targets named at the start of s: tails, and 8.3 short names directly
# under .claude (LOCAL-~1), for .claude itself under the home folder
# (CLAUDE~1), directly under a users folder (users/<name>/DOCUME~1) and for
# BEND_RULES.md (BEND_R~1.MD). Final review (ENV-F5): .NET's
# SetEnvironmentVariable (any scope, also the process's: stricter) is the
# lasting user environment, ~/NTUSER.DAT, as are the table's setx and
# registry Environment keys
def nm.here(+s: String) -> List<&2, String>:
  nm.one.k(String.starts_with(s, "setenvironmentvariable"), "~/ntuser.dat", nm.one.k(nm.c83(String.starts_with(s, ".claude/"), s), "~/.claude", nm.one.k(nm.d83(String.starts_with(s, "claude~"), s), "~/.claude", nm.one.k(nm.u83(String.starts_with(s, "users/"), s), "~", nm.one.k(nm.d83(String.starts_with(s, "bend_r~"), s), "bend_rules.md", nm.tails(nm.table(), s))))))

# a tail or short name can start at c
def nm.lead(c: Char) -> Bool:
  match c:
    case Chr{46}:
      True{}
    case Chr{104}:
      True{}
    case Chr{115}:
      True{}
    case Chr{98}:
      True{}
    case Chr{100}:
      True{}
    case Chr{111}:
      True{}
    case Chr{99}:
      True{}
    case Chr{117}:
      True{}
    case _:
      False{}

def nm.add1(seen: Bool, x: String, acc: List<&2, String>) -> List<&2, String>:
  match seen:
    case True{}:
      acc
    case False{}:
      x <> acc

def nm.addall(xs: List<&2, String>, +acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      acc
    case +x <> t:
      nm.addall(t, nm.add1(elem(x, acc), x, acc))

def nm.at(lead: Bool, +s: String, +acc: List<&2, String>) -> List<&2, String>:
  match lead:
    case True{}:
      nm.addall(nm.here(s), acc)
    case False{}:
      acc

# ---------------------------------------------------------------------------
# Wildcards in a named path (round 2, R2M-3). A tail with a '/' in it
# (.claude/..., .git/..., documents/...) is also found where a word holds a
# wildcard in any of its parts: ~/.cla*/settings.json, .git/h?oks, and the
# text of for f in ~/.claude/*; do .. done. The word runs up to a character
# that ends a path, but '/', '*', '?', '[' and ']' go on with it. Each '/'
# part of the tail must be matched (glob.match) by the word's part at the
# same place; the word may have more parts after them ('/' then follows,
# which nm.after accepts, as it does the word's end). The first character
# stays literal (nm.lead) and starts a path part (ng.start). A word part
# longer than 128 characters matches every name, as in glob.match. Tried
# only where the word holds a wildcard (ng.flags, one pass), so ordinary
# text stays linear (NOTES.md section 8).

def ng.keep(c: Char) -> Bool:
  match c:
    case Chr{47}:
      True{}
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case Chr{93}:
      True{}
    case _:
      False{}

# c goes on with a word
def ng.inw(+c: Char) -> Bool:
  ng.keep(c) || Bool.not(nm.bchar(c))

# c goes on with a word part
def ng.cont(+c: Char) -> Bool:
  ng.inw(c) && Bool.not(Char.is_eq(c, '/'))

def ng.head(xs: List<&2, Bool>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      x

# acc with the flag of c in front: the word from c on holds a wildcard
def ng.flag(+c: Char, +acc: List<&2, Bool>) -> List<&2, Bool>:
  Con{ng.inw(c) && (is_glob_char(c) || ng.head(acc)), acc}

# one flag per character of s, from s reversed (a loop)
def ng.flags(rs: String, +acc: List<&2, Bool>) -> List<&2, Bool>:
  match rs:
    case SNil{}:
      acc
    case SCon{+c, t}:
      ng.flags(t, ng.flag(c, acc))

# a word part: the part, whether a '/' and more of the word follow (sl), the
# text after that '/', and whether it was cut at 129 characters (long)
type NgW is Data:
  NgW.Mk{part: String, sl: Bool, rest: String, long: Bool}

# the part at the start of s; go: the last character went on with the part
# (it was put in acc, reversed); sl: that character was '/'; k: characters
# left before the part is cut
def ng.part(s: String, go: Bool, sl: Bool, k: Nat, acc: String) -> NgW:
  match s go k:
    case _ False{} _:
      NgW.Mk{String.reverse(acc), sl, s, False{}}
    case SNil{} True{} _:
      NgW.Mk{String.reverse(acc), False{}, "", False{}}
    case _ True{} 0n:
      NgW.Mk{String.reverse(acc), False{}, "", True{}}
    case SCon{+c, t} True{} 1n+j:
      ng.part(t, ng.cont(c), Char.is_eq(c, '/'), j, glob.keep(Bool.not(ng.cont(c)), c, acc))

def ng.word(s: String) -> NgW:
  ng.part(s, True{}, False{}, 129n, "")

# the tail's parts ps are matched by the word whose first part is w
def ng.match(ps: List<&2, String>, w: NgW) -> Bool:
  match ps w:
    case Nil{} _:
      True{}
    case _ NgW.Mk{part, sl, rest, True{}}:
      True{}
    case Con{+p, Nil{}} NgW.Mk{+part, sl, rest, False{}}:
      glob.match(part, p)
    case Con{+p, t} NgW.Mk{+part, True{}, rest, False{}}:
      glob.match(part, p) && ng.match(t, ng.word(rest))
    case _ NgW.Mk{part, False{}, rest, False{}}:
      False{}

# a tail's '/' parts
def ng.split(s: String, cur: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SCon{Chr{47}, t}:
      ng.split(t, "", String.reverse(cur) <> acc)
    case SCon{c, t}:
      ng.split(t, SCon{c, cur}, acc)

def ng.try(has: Bool, tail: String, +w: NgW) -> Bool:
  match has:
    case True{}:
      ng.match(ng.split(tail, "", []), w)
    case False{}:
      False{}

# the targets of the table's tails with a '/' that the word w matches
def ng.tails(xs: List<&2, T.Arg>, +w: NgW) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case T.Arg{+tail, tg} <> t:
      nm.one.k(ng.try(String.contains(tail, "/"), tail, w), tg, ng.tails(t, w))

def ng.at(hit: Bool, s: String, +acc: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      nm.addall(ng.tails(nm.table(), ng.word(s)), acc)
    case False{}:
      acc

# a path part can start after c: c ends the word, or is '/' or '='
def ng.start(+c: Char) -> Bool:
  Bool.not(ng.cont(c)) || Char.is_eq(c, '=')

# every target the folded text s names, each once; fs: ng.flags of s; st:
# a path part can start here (the wildcard match is tried only there, so a
# long word is read once, not from each of its characters); lt: look for
# the literal tails and short names; gl: look for wildcard matches
def nm.scan(s: String, fs: List<&2, Bool>, st: Bool, +lt: Bool, +gl: Bool, +acc: List<&2, String>) -> List<&2, String>:
  match s fs:
    case SCon{+c, +t} Con{f, ft}:
      nm.scan(t, ft, ng.start(c), lt, gl, ng.at(gl && f && st && nm.lead(c), SCon{c, t}, nm.at(lt && nm.lead(c), SCon{c, t}, acc)))
    case _ _:
      List.reverse(&2, String, acc)

# lower case, '\' as '/', a run of '/' as one; acc reversed, sl: last was '/'
def nm.fold(s: String, sl: Bool, acc: String) -> String:
  match s sl:
    case SNil{} _:
      String.reverse(acc)
    case SCon{Chr{47}, t} True{}:
      nm.fold(t, True{}, acc)
    case SCon{Chr{92}, t} True{}:
      nm.fold(t, True{}, acc)
    case SCon{Chr{47}, t} False{}:
      nm.fold(t, True{}, SCon{'/', acc})
    case SCon{Chr{92}, t} False{}:
      nm.fold(t, True{}, SCon{'/', acc})
    case SCon{c, t} _:
      nm.fold(t, False{}, SCon{Char.to_lower(c), acc})

# the texts, each followed by a newline (a loop: argv can be long)
def nm.join.go(xs: List<&2, String>, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      nm.join.go(t, acc ++ x ++ "\n")

def nm.join(xs: List<&2, String>) -> String:
  nm.join.go(xs, "")

def nm.pick.l(b: Bool, x: List<&2, String>, y: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      x
    case False{}:
      y

# the targets as WriteTree actions: home ones from the home folder, the
# others from the project folder and each possible folder
def nm.acts(tgs: List<&2, String>, +cwds: List<&2, String>, +root: String, +home: String) -> List<&2, T.Action>:
  match tgs:
    case Nil{}:
      []
    case +g <> t:
      List.append(&2, T.Action, acts.of(path(AKind.WriteTree{}, nm.pick.l(String.starts_with(g, "~"), [root], root <> cwds), home, g)), nm.acts(t, cwds, root, home))

def nm.note(tgs: List<&2, String>) -> String:
  match tgs:
    case Nil{}:
      ""
    case g <> t:
      "the call's text names " ++ g ++ ", which bend-guard protects"

def nm.why(m: T.Meaning, note: String) -> String:
  match m:
    case T.Known{xs}:
      note
    case T.Unknown{w, xs}:
      w ++ "; " ++ note

def nm.add(+m: T.Meaning, xs: List<&2, T.Action>, note: String) -> T.Meaning:
  match xs:
    case Nil{}:
      m
    case a <> t:
      T.Unknown{nm.why(m, note), List.append(&2, T.Action, acts.of(m), a <> t)}

def is_unknown(m: T.Meaning) -> Bool:
  match m:
    case T.Known{xs}:
      False{}
    case T.Unknown{w, xs}:
      True{}


# the protected paths named in texts, as targets (each once)
def named.targets.go(+lt: Bool, +gl: Bool, +s: String) -> List<&2, String>:
  nm.scan(s, ng.flags(String.reverse(s), []), True{}, lt, gl, [])

def named.targets.m(+lt: Bool, +gl: Bool, text: String) -> List<&2, String>:
  named.targets.go(lt, gl, nm.fold(text, False{}, ""))

def named.targets(text: String) -> List<&2, String>:
  named.targets.m(True{}, True{}, text)

# the words of xs not in lit (a loop)
def nm.unlit(xs: List<&2, String>, +lit: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +x <> t:
      nm.unlit(t, lit, nm.one.k(Bool.not(elem(x, lit)), x, acc))

def named.found(+tgs: List<&2, String>, +m: T.Meaning, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  nm.add(m, nm.acts(tgs, cwds, root, home), nm.note(tgs))

# m with a WriteTree of every protected path texts name (home ones from the
# home folder, the others from root and each of cwds)
def named.with(+m: T.Meaning, texts: List<&2, String>, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  named.found(named.targets(nm.join(texts)), m, cwds, root, home)

def named.unk.if(unk: Bool, +m: T.Meaning, +xs: List<&2, String>, +ys: List<&2, String>, +lit: List<&2, String>, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  match unk:
    case True{}:
      named.found(nm.addall(named.targets.m(False{}, True{}, nm.join(nm.unlit(xs, lit, [])) ++ nm.join(ys) ++ nm.join(cwds)), named.targets.m(True{}, False{}, nm.join(xs) ++ nm.join(ys) ++ nm.join(cwds))), m, cwds, root, home)
    case False{}:
      m

# named.with when m is Unknown; m itself when it is Known
# (xs, ys and cwds are its texts: a command's words and its redirects).
# lit: words whose wildcards were all quoted, which bash does not expand;
# they are read for literal names only, not for wildcard matches (round 2,
# R2M-3: find . -not -path "*/.git/*" only filters by that pattern)
def named.unknown(+m: T.Meaning, xs: List<&2, String>, ys: List<&2, String>, lit: List<&2, String>, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  named.unk.if(is_unknown(m), m, xs, ys, lit, cwds, root, home)
