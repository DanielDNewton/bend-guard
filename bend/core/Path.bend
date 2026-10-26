# bend-guard: paths. Path.norm turns a raw path string into one canonical
# T.Path{"c", segs} (lower case, no "", ".", ".." segments) or None when the
# path cannot be read safely; under/overlaps/eq/child compare and build paths.
# Plan Task 1.6 (every normaliser rule is listed there); laws in laws/path.
# Segments stay Strings; Seg.eq compares char codes as Nat so that its
# reflexivity, symmetry and transitivity can be proven (bend/NOTES.md "Path").

import Base
import ./Types.bend as T

# ---------------------------------------------------------------------------
# Equality and order

# A char's code as a Nat.
def Seg.code(c: Char) -> Nat:
  match c:
    case Chr{x}:
      U32.to_nat(x)

# Plain equality of two segments, char by char through Nat codes.
def Seg.eq(a: String, b: String) -> Bool:
  match a b:
    case SNil{} SNil{}:
      True{}
    case SNil{} SCon{y, bt}:
      False{}
    case SCon{x, at} SNil{}:
      False{}
    case SCon{x, at} SCon{y, bt}:
      Bool.and(Nat.is_eq(Seg.code(x), Seg.code(y)), Seg.eq(at, bt))

# Same segments, same order, same length.
def eq.segs(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Nil{} y <> yt:
      False{}
    case x <> xt Nil{}:
      False{}
    case x <> xt y <> yt:
      Bool.and(Seg.eq(x, y), eq.segs(xt, yt))

def eq(a: T.Path, b: T.Path) -> Bool:
  match a b:
    case T.Path{ad, axs} T.Path{bd, bxs}:
      Bool.and(Seg.eq(ad, bd), eq.segs(axs, bxs))

# xs is a prefix of ys.
def prefix(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} _:
      True{}
    case x <> xt Nil{}:
      False{}
    case x <> xt y <> yt:
      Bool.and(Seg.eq(x, y), prefix(xt, yt))

# p is root or inside it.
def under(p: T.Path, root: T.Path) -> Bool:
  match p root:
    case T.Path{pd, pxs} T.Path{rd, rxs}:
      Bool.and(Seg.eq(rd, pd), prefix(rxs, pxs))

def overlaps(+p: T.Path, +q: T.Path) -> Bool:
  Bool.or(under(p, q), under(q, p))

def is_sentinel.drive(d: String) -> Bool:
  match d:
    case "?":
      True{}
    case _:
      False{}

def is_sentinel(p: T.Path) -> Bool:
  match p:
    case T.Path{d, xs}:
      is_sentinel.drive(d)

def show(p: T.Path) -> String:
  match p:
    case T.Path{d, xs}:
      d ++ ":/" ++ String.join(xs, "/")

# ---------------------------------------------------------------------------
# Clean segments: no "", "." or ".."

def clean.seg(s: String) -> Bool:
  match s:
    case "":
      False{}
    case ".":
      False{}
    case "..":
      False{}
    case _:
      True{}

def clean.segs(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> xt:
      Bool.and(clean.seg(x), clean.segs(xt))

def clean(p: T.Path) -> Bool:
  match p:
    case T.Path{d, xs}:
      clean.segs(xs)

# ---------------------------------------------------------------------------
# Character and segment helpers

# '*', '?', '[' (globs, left to the models) and '%' (%NAME% forms).
def bad_char.sym(c: Char) -> Bool:
  match c:
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case Chr{37}:
      True{}
    case _:
      False{}

# Control characters, DEL, non-ASCII, and the symbols above.
def bad_char(c: Char) -> Bool:
  match c:
    case Chr{+x}:
      Bool.or(U32.is_lt(x, 32), Bool.or(U32.is_gt(x, 126), bad_char.sym(Chr{x})))

def has_bad(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      Bool.or(bad_char(c), has_bad(t))

# Lower-cases (ASCII) and splits on '/' and '\', keeping empty parts:
# "/a//b" gives ["", "a", "", "b"]. cur is the part so far, reversed.
def split.go(s: String, cur: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SCon{Chr{47}, rest}:
      split.go(rest, "", String.reverse(cur) <> acc)
    case SCon{Chr{92}, rest}:
      split.go(rest, "", String.reverse(cur) <> acc)
    case SCon{c, rest}:
      split.go(rest, SCon{Char.to_lower(c), cur}, acc)

def split(s: String) -> List<&2, String>:
  split.go(s, "", [])

# Drops leading dots and spaces.
def lstrip(s: String) -> String:
  match s:
    case SCon{Chr{46}, rest}:
      lstrip(rest)
    case SCon{Chr{32}, rest}:
      lstrip(rest)
    case other:
      other

# Drops trailing dots and spaces, as Windows does ("specs." and "specs " are "specs").
def rstrip(s: String) -> String:
  String.reverse(lstrip(String.reverse(s)))

def has_colon(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{58}, t}:
      True{}
    case SCon{c, t}:
      has_colon(t)

def is_tilde(c: Char) -> Bool:
  match c:
    case Chr{126}:
      True{}
    case _:
      False{}

# An 8.3 short name: '~' followed by a digit (SPECS~1). prev: the last char was '~'.
def has_short.go(s: String, prev: Bool) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+c, t}:
      Bool.or(Bool.and(prev, Char.is_digit(c)), has_short.go(t, is_tilde(c)))

# The part before the first ':' (an NTFS stream suffix: "a.md:x", "a.md::$DATA").
def strip_stream(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{58}, t}:
      SNil{}
    case SCon{c, t}:
      SCon{c, strip_stream(t)}

def fix.if(bad: Bool, s: String) -> Maybe<&2, String>:
  match bad:
    case True{}:
      None{}
    case False{}:
      Some{s}

def fix.go(+s: String) -> Maybe<&2, String>:
  fix.if(Bool.or(String.is_empty(s), Bool.or(has_colon(s), has_short.go(s, False{}))), s)

# One ordinary segment (not "", "." or ".."), or None: a segment that is only
# dots and spaces, a ':' anywhere but a stream suffix of the last segment, an
# 8.3 short name.
def fix(s: String) -> Maybe<&2, String>:
  fix.go(rstrip(s))

# Removes the stream suffix from the last element only.
def strip_last.go(t: List<&2, String>, h: String) -> List<&2, String>:
  match t:
    case Nil{}:
      [strip_stream(h)]
    case h2 <> t2:
      h <> strip_last.go(t2, h2)

def strip_last(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case h <> t:
      strip_last.go(t, h)

# ---------------------------------------------------------------------------
# Walking the segments onto a base (acc holds the result so far, reversed)

def pop(acc: List<&2, String>) -> List<&2, String>:
  match acc:
    case Nil{}:
      []
    case h <> t:
      t

def step.push(m: Maybe<&2, String>, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case None{}:
      None{}
    case Some{s}:
      Some{s <> acc}

# "" (repeated separators) and "." drop; ".." pops and stops at the drive root.
def step.seg(h: String, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match h:
    case "":
      Some{acc}
    case ".":
      Some{acc}
    case "..":
      Some{pop(acc)}
    case other:
      step.push(fix(other), acc)

def step(h: String, m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case None{}:
      None{}
    case Some{acc}:
      step.seg(h, acc)

def walk.end(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case None{}:
      None{}
    case Some{acc}:
      Some{List.reverse(&2, String, acc)}

def walk.go(xs: List<&2, String>, m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      walk.end(m)
    case h <> t:
      walk.go(t, step(h, m))

# The raw parts xs walked onto the clean base segments.
def walk(xs: List<&2, String>, base: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  walk.go(strip_last(xs), Some{List.reverse(&2, String, base)})

# ---------------------------------------------------------------------------
# Where a path starts: the drive root, the folder (cwd) or home

def start.base(mb: Maybe<&2, List<&2, String>>, xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match mb:
    case None{}:
      None{}
    case Some{b}:
      walk(xs, b)

# After "c:" a separator must follow; "c:" alone or "c:specs" is drive-relative.
def start.drive(xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      None{}
    case h <> t:
      walk(h <> t, [])

def rooted.mnt.drive(d: String, t: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match d:
    case "c":
      walk(t, [])
    case _:
      None{}

def rooted.mnt(xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      None{}
    case d <> t:
      rooted.mnt.drive(d, t)

# A rooted path without a drive letter: only "/c/..." ("/c" too) and
# "/mnt/c/..." are placed (on c:). Under Git Bash "/" is Git's install folder
# and /proc, /dev, /tmp and /cygdrive are virtual (/proc/self/cwd is the
# current folder, /dev/tcp/... is the network), and under PowerShell "\x"
# takes the drive of the folder; so "/" alone, "/x/..." for any other first
# part, "//server/share", "\\?\" and "\\.\" are all None (not known).
# Mapping /tmp to the user's Temp folder is left for later.
def rooted.first(+h: String, t: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match h:
    case "mnt":
      rooted.mnt(t)
    case "c":
      walk(t, [])
    case other:
      None{}

def rooted(xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      None{}
    case h <> t:
      rooted.first(h, t)

# A first part "~x" (~user, ~+, ~-) or "x:..." other than "c:" is None.
def start.other(h: String, t: List<&2, String>, cwdb: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match h:
    case SCon{Chr{126}, r}:
      None{}
    case SCon{x, SCon{Chr{58}, r}}:
      None{}
    case other:
      start.base(cwdb, other <> t)

def start.first(h: String, t: List<&2, String>, cwdb: Maybe<&2, List<&2, String>>, homeb: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match h:
    case "":
      rooted(t)
    case "~":
      start.base(homeb, t)
    case "c:":
      start.drive(t)
    case other:
      start.other(other, t, cwdb)

def start(xs: List<&2, String>, cwdb: Maybe<&2, List<&2, String>>, homeb: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      None{}
    case h <> t:
      start.first(h, t, cwdb, homeb)

def parse.if(bad: Bool, s: String, cwdb: Maybe<&2, List<&2, String>>, homeb: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match bad:
    case True{}:
      None{}
    case False{}:
      start(split(s), cwdb, homeb)

# The segments of s, given the segments of the folder and of home (None when
# not known). Empty strings and bad characters give None.
def parse(+s: String, cwdb: Maybe<&2, List<&2, String>>, homeb: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  parse.if(Bool.or(String.is_empty(s), has_bad(s)), s, cwdb, homeb)

# The segments of an absolute path (used for the folder and home).
def absolute(s: String) -> Maybe<&2, List<&2, String>>:
  parse(s, None{}, None{})

# ---------------------------------------------------------------------------
# Windows compatibility junctions, by position (None for these)

def junc.local.name(h: String) -> Bool:
  match h:
    case "application data":
      True{}
    case "history":
      True{}
    case "temporary internet files":
      True{}
    case _:
      False{}

def junc.local(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.local.name(h)

def junc.appdata.name(h: String, t: List<&2, String>) -> Bool:
  match h:
    case "local":
      junc.local(t)
    case _:
      False{}

def junc.appdata(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.appdata.name(h, t)

def junc.docs.name(h: String) -> Bool:
  match h:
    case "my music":
      True{}
    case "my pictures":
      True{}
    case "my videos":
      True{}
    case _:
      False{}

# Directly inside c:/users/<name>/.
def junc.docs(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.docs.name(h)

def junc.home.name(h: String, t: List<&2, String>) -> Bool:
  match h:
    case "application data":
      True{}
    case "cookies":
      True{}
    case "local settings":
      True{}
    case "my documents":
      True{}
    case "nethood":
      True{}
    case "printhood":
      True{}
    case "recent":
      True{}
    case "sendto":
      True{}
    case "start menu":
      True{}
    case "templates":
      True{}
    case "appdata":
      junc.appdata(t)
    case "documents":
      junc.docs(t)
    case _:
      False{}

def junc.home(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.home.name(h, t)

def junc.user(name: String, t: List<&2, String>) -> Bool:
  match name:
    case "all users":
      True{}
    case "default user":
      True{}
    case _:
      junc.home(t)

def junc.users(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.user(h, t)

def junc.pd.name(h: String) -> Bool:
  match h:
    case "application data":
      True{}
    case "desktop":
      True{}
    case "documents":
      True{}
    case "start menu":
      True{}
    case "templates":
      True{}
    case _:
      False{}

def junc.pd(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.pd.name(h)

def junc.top(h: String, t: List<&2, String>) -> Bool:
  match h:
    case "documents and settings":
      True{}
    case "users":
      junc.users(t)
    case "programdata":
      junc.pd(t)
    case _:
      False{}

def junc(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      junc.top(h, t)

# ---------------------------------------------------------------------------
# The normaliser

def norm.junc.if(hit: Bool, xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match hit:
    case True{}:
      None{}
    case False{}:
      Some{xs}

def norm.junc.go(+xs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  norm.junc.if(junc(xs), xs)

def norm.junc(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case None{}:
      None{}
    case Some{xs}:
      norm.junc.go(xs)

# The last step: a path is only returned when its segments are clean
# (laws/path norm_clean rests on this).
def norm.fin.if(ok: Bool, xs: List<&2, String>) -> Maybe<&2, T.Path>:
  match ok:
    case True{}:
      Some{T.Path{"c", xs}}
    case False{}:
      None{}

def norm.fin.go(+xs: List<&2, String>) -> Maybe<&2, T.Path>:
  norm.fin.if(clean.segs(xs), xs)

def norm.fin(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, T.Path>:
  match m:
    case None{}:
      None{}
    case Some{xs}:
      norm.fin.go(xs)

# raw read from the folder cwd, with "~" as home. cwd and home are absolute
# Windows paths (C:\Users\user); None when raw is not safely readable.
def norm(cwd: String, home: String, raw: String) -> Maybe<&2, T.Path>:
  norm.fin(norm.junc(parse(raw, absolute(cwd), absolute(home))))

# ---------------------------------------------------------------------------
# Building paths from rules

# The parts of a plain relative path: lower case, split on '/' and '\',
# trailing dots and spaces dropped; parts that end up empty ("", ".", "..",
# "...") are dropped, so the result is clean and below p.
def child.keep(s: String, t: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      t
    case other:
      other <> t

def child.parts(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case h <> t:
      child.keep(rstrip(h), child.parts(t))

def child(p: T.Path, rel: String) -> T.Path:
  match p:
    case T.Path{d, xs}:
      T.Path{d, List.append(&2, String, xs, child.parts(split(rel)))}
