# bend-guard: models of the file commands (plan.md Task 1.7; design.md
# component 2, layer 4): rm, mv, cp, cat, head, tail, ls, grep, mkdir, touch,
# cd (and Set-Location under PowerShell), echo, pwd, true, printf, ln, the
# commands that run other code, and (round 2, tx.bash) text filters such as
# wc, sort, uniq, cut, jq and diff, tee, commands with no file effect such as
# date, which and test, and sed, awk and find without their write and run
# forms. A flag not listed for a command, a missing
# operand, and any form not listed give Unknown (fail closed). Each model
# takes the possible current folders cwds, the home folder and the arguments
# after the command name. Imported as ModelFiles.

import Base
import ./Types.bend as T
import ./Path.bend as Path
import ./Model.bend as Model

# ---------------------------------------------------------------------------
# rm, mkdir, touch: one action per named path, no wildcards

def each.k(g: Bool, none: Bool, ops: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g none:
    case True{} _:
      Model.glob.with(Model.unknown("wildcards (*, ? or [) are not modelled here"), T.Bash{}, k, cwds, home, ops)
    case False{} True{}:
      Model.unknown("nothing is named")
    case False{} False{}:
      Model.paths(ops, k, cwds, home)

def each.o(o: Model.Opts, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      each.k(Model.any_glob(ops), List.is_empty(&2, String, ops), ops, k, cwds, home)

def rm.kind(rec: Bool) -> Model.AKind:
  match rec:
    case True{}:
      Model.AKind.DeleteTree{}
    case False{}:
      Model.AKind.Delete{}

def rm.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, +ops, lo}:
      each.k(Model.any_glob(ops), List.is_empty(&2, String, ops), ops, rm.kind(Model.has_char(fl, 'r') || Model.has_char(fl, 'R')), cwds, home)

# rm -f -r -R -i -v (joined too), --force, --recursive, --: each path is a
# Delete, or a DeleteTree with any recursive flag
def rm(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("rm: ", rm.o(Model.parse(Model.spec("frRiv", "", [T.Arg{"--force", "f"}, T.Arg{"--recursive", "r"}], False{}, True{}), args), cwds, home))

# mkdir -p -v --: MakeDir each path
def mkdir(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("mkdir: ", each.o(Model.parse(Model.spec("pv", "", [], False{}, True{}), args), Model.AKind.MakeDir{}, cwds, home))

# touch, no flags: Write each path
def touch(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("touch: ", each.o(Model.parse(Model.spec("", "", [], False{}, False{}), args), Model.AKind.Write{}, cwds, home))

# ---------------------------------------------------------------------------
# mv and cp

def mvcp.rev(rev: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match rev:
    case Nil{}:
      Model.unknown("a source and a target are needed")
    case Con{d, Nil{}}:
      Model.unknown("a source and a target are needed")
    case Con{d, Con{s, t}}:
      Model.move(List.reverse(&2, String, s <> t), d, k, cwds, home)

# every operand but the last, from the operands reversed
def mvcp.init(rev: List<&2, String>) -> List<&2, String>:
  match rev:
    case Nil{}:
      []
    case d <> t:
      List.reverse(&2, String, t)

# the last operand, from the operands reversed
def mvcp.last(rev: List<&2, String>) -> List<&2, String>:
  match rev:
    case Nil{}:
      []
    case d <> t:
      [d]

# a wildcard: the sources get kind k and the target WriteTree on every
# protected name a wildcard can match (Model.glob.with)
def mvcp.k(g: Bool, dots: Bool, +ops: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g dots:
    case True{} _:
      Model.glob.with(Model.glob.with(Model.unknown("wildcards (*, ? or [) are not modelled here"), T.Bash{}, k, cwds, home, mvcp.init(List.reverse(&2, String, ops))), T.Bash{}, Model.AKind.WriteTree{}, cwds, home, mvcp.last(List.reverse(&2, String, ops)))
    case False{} True{}:
      Model.unknown("a source ending in . or .. (a folder's contents) is not modelled")
    case False{} False{}:
      mvcp.rev(List.reverse(&2, String, ops), k, cwds, home)

def mvcp(+ops: List<&2, String>, +k: Model.AKind, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  mvcp.k(Model.any_glob(ops), Model.any_dotted_end(mvcp.init(List.reverse(&2, String, ops))), ops, k, cwds, home)

def mv.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      mvcp(ops, Model.AKind.MoveFrom{}, cwds, home)

# mv -f -n -i -v --: each source MoveFrom; the target Write{dst} and
# WriteTree{dst/<last part of the source>}
def mv(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("mv: ", mv.o(Model.parse(Model.spec("fniv", "", [], False{}, True{}), args), cwds, home))

def cp.kind(rec: Bool) -> Model.AKind:
  match rec:
    case True{}:
      Model.AKind.ReadTree{}
    case False{}:
      Model.AKind.Read{}

def cp.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      mvcp(ops, cp.kind(Model.has_char(fl, 'r') || Model.has_char(fl, 'R') || Model.has_char(fl, 'a')), cwds, home)

def cp.link(hard: Bool, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match hard:
    case True{}:
      Model.unknown(Model.hard_link_why())
    case False{}:
      Model.why_prefix("cp: ", cp.o(Model.parse(Model.spec("rRfpavn", "", [], False{}, True{}), args), cwds, home))

# cp -r -R -f -p -a -v -n --: each source Read (ReadTree with -r -R -a); the
# target as for mv. cp -l / --link makes hard links: the hard-link reason.
def cp(+cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  cp.link(Model.short_or_long(args, 'l', "--link"), cwds, home, args)

# ---------------------------------------------------------------------------
# cat, head, tail, ls, grep: reads. A path with a wildcard reads the folder
# it can reach (ReadTree, or ListDir for ls).

def rd.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      Model.join(Model.rpaths(ops, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home), Model.wglobs(lo, sh, cwds, home))

# cat -q -v -n -b -A -E -T -s -e -t --: Read each path; no path reads
# standard input (no action)
def cat(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("cat: ", rd.o(Model.parse(Model.spec("qvnbAETset", "", [], False{}, True{}), args), sh, cwds, home))

# head -n N -c N -N -q -v --
def head(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("head: ", rd.o(Model.parse(Model.spec("qv", "nc", [], True{}, True{}), args), sh, cwds, home))

# tail -n N -c N -N -q -v -f -F -s N --follow[=..] --retry --pid=P
# --sleep-interval=N --
def tail(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("tail: ", rd.o(Model.parse(Model.spec("qvfF", "ncs", [T.Arg{"--follow", "f"}, T.Arg{"--follow=", "f"}, T.Arg{"--retry", "R"}, T.Arg{"--pid=", "p"}, T.Arg{"--sleep-interval=", "s"}], True{}, True{}), args), sh, cwds, home))

def ls.k(none: Bool, ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match none:
    case True{}:
      Model.path(Model.AKind.ListDir{}, cwds, home, ".")
    case False{}:
      Model.rpaths(ops, sh, Model.AKind.ListDir{}, Model.AKind.ListDir{}, cwds, home)

def ls.add.k(flag: Bool, w: String, acc: List<&2, String>) -> List<&2, String>:
  match flag:
    case True{}:
      acc
    case False{}:
      w <> acc

def ls.add(dd: Bool, +w: String, acc: List<&2, String>) -> List<&2, String>:
  match dd:
    case True{}:
      w <> acc
    case False{}:
      ls.add.k(String.starts_with(w, "-"), w, acc)

# the words that are not flags: every word not starting with - before --,
# and every word after it
def ls.ops(ws: List<&2, String>, +dd: Bool, acc: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +w <> t:
      ls.ops(t, dd || String.eq(w, "--"), ls.add(dd, w, acc))

def ls.run(+ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  ls.k(List.is_empty(&2, String, ops), ops, sh, cwds, home)

# ls with any flags (no flag of ls writes a file or runs anything; a flag's
# value in its own word, such as -I PAT, is listed as if it were a folder):
# ListDir each path, or each possible folder
def ls(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("ls: ", ls.run(ls.ops(args, False{}, []), sh, cwds, home))

def grep.kind(rec: Bool) -> Model.AKind:
  match rec:
    case True{}:
      Model.AKind.ReadTree{}
    case False{}:
      Model.AKind.Read{}

def grep.fs(none: Bool, rec: Bool, fs: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match none rec:
    case True{} True{}:
      Model.path(Model.AKind.ReadTree{}, cwds, home, ".")
    case True{} False{}:
      Model.nothing()
    case False{} r:
      Model.rpaths(fs, sh, grep.kind(r), Model.AKind.ReadTree{}, cwds, home)

def grep.run(files: Maybe<&2, List<&2, String>>, rec: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match files:
    case None{}:
      Model.unknown("no pattern is given")
    case Some{+fs}:
      grep.fs(List.is_empty(&2, String, fs), rec, fs, sh, cwds, home)

def grep.drop1(ops: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match ops:
    case Nil{}:
      None{}
    case h <> t:
      Some{t}

def grep.first(ops: List<&2, String>) -> List<&2, String>:
  match ops:
    case Nil{}:
      []
    case h <> t:
      [h]

# the operands that are files: all of them with -e, else all but the pattern
def grep.files(hase: Bool, ops: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match hase:
    case True{}:
      Some{ops}
    case False{}:
      grep.drop1(ops)

# the pattern operand (none with -e)
def grep.pat(hase: Bool, ops: List<&2, String>) -> List<&2, String>:
  match hase:
    case True{}:
      []
    case False{}:
      grep.first(ops)

# the patterns come from -e or -f, so no operand is the pattern
def grep.ef(+fl: String) -> Bool:
  Model.has_char(fl, 'e') || Model.has_char(fl, 'f')

def grep.num(ok: Bool, m: T.Meaning) -> T.Meaning:
  match ok:
    case True{}:
      m
    case False{}:
      Model.unknown("-A, -B, -C and -m need a number")

def grep.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String, lit: List<&2, String>) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, +vs, +ops, lo}:
      grep.num(Model.nums_ok(vs, "ABCm"), Model.join(Model.join(grep.run(grep.files(grep.ef(fl), ops), Model.has_char(fl, 'r') || Model.has_char(fl, 'R'), sh, cwds, home), Model.rpaths(List.append(&2, String, Model.vals_for(vs, "f"), Model.vals_for(vs, "Y")), sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home)), Model.wglobs(Model.unlit(List.append(&2, String, grep.pat(grep.ef(fl), ops), lo), lit), sh, cwds, home)))

# grep -r -R -i -n -l -L -v -E -F -P -w -x -c -H -h -o -s -a -I -Z
# -e PAT -f FILE -A N -B N -C N -m N (also --context=N, --max-count=N)
# --include=G --exclude=G --exclude-dir=G --exclude-from=FILE --color[=..]
# --colour[=..] --null --label=L --line-buffered --: the first operand is the
# pattern unless -e or -f is given; each path Read (ReadTree with -r -R; an
# --include or --exclude does not narrow it); -r with no path reads each
# possible folder; no path and no -r reads standard input; -f and
# --exclude-from read their file. A wildcard in the pattern (or in a value
# in its own word) reads the folder it can reach, since bash may expand it
# into file names, unless every wildcard in it was quoted (lit, from
# Lex.LexOut; round 2, P10).
def grep_lit(+sh: T.Shell, +cwds: List<&2, String>, +home: String, lit: List<&2, String>, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("grep: ", grep.o(Model.parse(Model.spec("rRinlLvEFwcHhoPxsaIZ", "eABCmf", [T.Arg{"--include=", "I"}, T.Arg{"--exclude=", "X"}, T.Arg{"--exclude-dir=", "D"}, T.Arg{"--exclude-from=", "Y"}, T.Arg{"--color", "K"}, T.Arg{"--colour", "K"}, T.Arg{"--color=", "K"}, T.Arg{"--colour=", "K"}, T.Arg{"--context=", "C"}, T.Arg{"--max-count=", "m"}, T.Arg{"--null", "Z"}, T.Arg{"--label=", "y"}, T.Arg{"--line-buffered", "U"}], False{}, True{}), args), sh, cwds, home, lit))

def grep(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  grep_lit(sh, cwds, home, [], args)

# ---------------------------------------------------------------------------
# cd and Set-Location: ChangeDir{dir} per possible folder. ModelShell follows
# it for the rest of the text (Model.shell, Model.next_cwds).

def cd.home(m: Maybe<&2, T.Path>) -> T.Meaning:
  match m:
    case Some{p}:
      T.Known{[T.ChangeDir{p}]}
    case None{}:
      Model.unknown("cannot tell where the home folder is")

def cd.one(dash: Bool, +cwds: List<&2, String>, +home: String, x: String) -> T.Meaning:
  match dash:
    case True{}:
      Model.unknown("cd - and flags of cd are not modelled")
    case False{}:
      Model.path(Model.AKind.ChangeDir{}, cwds, home, x)

# bash: cd (home) or cd <dir>
def cd.bash(args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match args:
    case Nil{}:
      cd.home(Path.norm(home, home, "~"))
    case Con{+x, Nil{}}:
      cd.one(String.starts_with(x, "-"), cwds, home, x)
    case _:
      Model.unknown("more than one folder is given")

def cd.flag(ok: Bool, +cwds: List<&2, String>, +home: String, +x: String) -> T.Meaning:
  match ok:
    case True{}:
      cd.one(String.starts_with(x, "-"), cwds, home, x)
    case False{}:
      Model.unknown("only -Path, -LiteralPath or one folder is modelled")

# PowerShell: cd / chdir / sl / Set-Location with no folder (home), one
# positional folder, or -Path / -LiteralPath and a folder (names in any case)
def cd.pwsh(args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match args:
    case Nil{}:
      cd.home(Path.norm(home, home, "~"))
    case Con{+x, Nil{}}:
      cd.one(String.starts_with(x, "-"), cwds, home, x)
    case Con{f, Con{x, Nil{}}}:
      cd.flag(Model.elem(String.to_lower(f), ["-path", "-literalpath"]), cwds, home, x)
    case _:
      Model.unknown("only -Path, -LiteralPath or one folder is modelled")

def cd(sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match sh:
    case T.Bash{}:
      Model.why_prefix("cd: ", cd.bash(args, cwds, home))
    case T.Pwsh{}:
      Model.why_prefix("Set-Location: ", cd.pwsh(args, cwds, home))

# ---------------------------------------------------------------------------
# echo, pwd, true: Inert. printf: Inert without options (-v sets a
# variable) and without %n.

def printf.opt(args: List<&2, String>) -> Bool:
  match args:
    case Nil{}:
      False{}
    case x <> t:
      String.starts_with(x, "-")

def printf.pn(args: List<&2, String>) -> Bool:
  match args:
    case Nil{}:
      False{}
    case x <> t:
      String.contains(x, "%n") || printf.pn(t)

def printf.k(opt: Bool, pn: Bool) -> T.Meaning:
  match opt pn:
    case True{} _:
      Model.unknown("printf: options (such as -v, which sets a variable) are not modelled")
    case False{} True{}:
      Model.unknown("printf: %n is not modelled")
    case False{} False{}:
      Model.inert()

def printf(+args: List<&2, String>) -> T.Meaning:
  printf.k(printf.opt(args), printf.pn(args))

# ---------------------------------------------------------------------------
# Text filters and other commands that only read (round 2). Each command has
# a fixed Spec; any other flag is Unknown. A filter reads each file operand
# (a wildcard reads its folder), reads standard input when none is named,
# and a value in its own word with a wildcard reads its folder (bash may
# expand it into file names). All the defs are tx.<name>; tx.bash picks one
# by command name.

def tx.rd(+sh: T.Shell, +cwds: List<&2, String>, +home: String, name: String, sp: Model.Spec, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(name ++ ": ", rd.o(Model.parse(sp, args), sh, cwds, home))

# known flags only, any operands, no file effect
def inert.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      Model.inert()

def tx.inert(name: String, sp: Model.Spec, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(name ++ ": ", inert.o(Model.parse(sp, args)))

def none.k(none: Bool) -> T.Meaning:
  match none:
    case True{}:
      Model.inert()
    case False{}:
      Model.unknown("operands are not modelled")

# known flags only, no operands, no file effect
def none.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      none.k(List.is_empty(&2, String, ops))

def tx.none(name: String, sp: Model.Spec, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(name ++ ": ", none.o(Model.parse(sp, args)))

# ListDir of each operand, or of each possible folder (du, tree)
def lsd.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      ls.k(List.is_empty(&2, String, ops), ops, sh, cwds, home)

def tx.lsd(+sh: T.Shell, +cwds: List<&2, String>, +home: String, name: String, sp: Model.Spec, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(name ++ ": ", lsd.o(Model.parse(sp, args), sh, cwds, home))

# cut -c -f -d -b LIST -s --complement --output-delimiter=S
def tx.cut(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  tx.rd(sh, cwds, home, "cut", Model.spec("s", "cfdb", [T.Arg{"--complement", "x"}, T.Arg{"--output-delimiter=", "o"}], False{}, True{}), args)

# wc -l -c -m -w -L
def tx.wc(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  tx.rd(sh, cwds, home, "wc", Model.spec("lcmwL", "", [], False{}, True{}), args)

# sort -r -n -u -V -h -f -b -s -g -M -c -z -k KEY -t SEP (and their long
# names); -o, -T, --compress-program and --files0-from are not modelled
def tx.sort(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  tx.rd(sh, cwds, home, "sort", Model.spec("rnuVhfbsgMcz", "kt", [T.Arg{"--reverse", "r"}, T.Arg{"--numeric-sort", "n"}, T.Arg{"--unique", "u"}, T.Arg{"--version-sort", "V"}, T.Arg{"--human-numeric-sort", "h"}, T.Arg{"--ignore-case", "f"}, T.Arg{"--ignore-leading-blanks", "b"}, T.Arg{"--stable", "s"}, T.Arg{"--general-numeric-sort", "g"}, T.Arg{"--month-sort", "M"}, T.Arg{"--check", "c"}, T.Arg{"--zero-terminated", "z"}, T.Arg{"--key=", "k"}, T.Arg{"--field-separator=", "t"}], False{}, True{}), args)

def uniq.k(many: Bool, o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match many:
    case True{}:
      Model.unknown("a second operand is the output file, which is not modelled")
    case False{}:
      rd.o(o, sh, cwds, home)

def uniq.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      uniq.k(Nat.is_lt(1n, List.length(&2, String, ops)), Model.Opts.Ok{fl, vs, ops, lo}, sh, cwds, home)

# uniq -c -d -u -i -f N -s N -w N, at most one operand (a second one is the
# file it writes)
def tx.uniq(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("uniq: ", uniq.o(Model.parse(Model.spec("cdui", "fsw", [], False{}, True{}), args), sh, cwds, home))

# tr -c -C -d -s -t SET1 [SET2]: no file
def tx.tr(args: List<&2, String>) -> T.Meaning:
  tx.inert("tr", Model.spec("cCdst", "", [T.Arg{"--complement", "c"}, T.Arg{"--delete", "d"}, T.Arg{"--squeeze-repeats", "s"}, T.Arg{"--truncate-set1", "t"}], False{}, True{}), args)

# tee -a -i FILE...: Write each file (no wildcards); with none it only
# copies standard input
def tee.k(g: Bool, ops: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case True{}:
      Model.unknown("wildcards (*, ? or [) are not modelled here")
    case False{}:
      Model.join(Model.inert(), Model.paths(ops, Model.AKind.Write{}, cwds, home))

def tee.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      tee.k(Model.any_glob(ops), ops, cwds, home)

def tx.tee(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("tee: ", tee.o(Model.parse(Model.spec("ai", "", [T.Arg{"--append", "a"}, T.Arg{"--ignore-interrupts", "i"}], False{}, True{}), args), cwds, home))

def diff.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      Model.join(Model.rpaths(ops, sh, Model.AKind.ReadTree{}, Model.AKind.ReadTree{}, cwds, home), Model.wglobs(lo, sh, cwds, home))

# diff -u -q -r -N -w -b -B -i -y -a --brief --stat --unified=N: reads both
# operands as trees (a folder operand reads the files in it even without -r);
# --to-file and --from-file are not modelled
def tx.diff(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("diff: ", diff.o(Model.parse(Model.spec("uqrNwbBiya", "", [T.Arg{"--brief", "q"}, T.Arg{"--stat", "S"}, T.Arg{"--unified=", "u"}, T.Arg{"--recursive", "r"}, T.Arg{"--new-file", "N"}, T.Arg{"--ignore-all-space", "w"}, T.Arg{"--ignore-space-change", "b"}, T.Arg{"--ignore-blank-lines", "B"}, T.Arg{"--ignore-case", "i"}, T.Arg{"--side-by-side", "y"}, T.Arg{"--text", "a"}, T.Arg{"--color", "C"}, T.Arg{"--color=", "C"}], False{}, True{}), args), sh, cwds, home))

# date -u -R -I -d STR -r FILE -f FILE (and long names); an operand must be a
# +FORMAT (any other operand sets the clock); -s / --set are not modelled
def date.fmt(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      String.starts_with(x, "+") && date.fmt(t)

def date.k(fmt: Bool, fs: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match fmt:
    case False{}:
      Model.unknown("an operand that does not start with + sets the clock, which is not modelled")
    case True{}:
      Model.join(Model.inert(), Model.rpaths(fs, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home))

def date.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, +vs, ops, lo}:
      date.k(date.fmt(ops), List.append(&2, String, Model.vals_for(vs, "r"), Model.vals_for(vs, "f")), sh, cwds, home)

def tx.date(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("date: ", date.o(Model.parse(Model.spec("uRI", "drf", [T.Arg{"--utc", "u"}, T.Arg{"--universal", "u"}, T.Arg{"--iso-8601", "I"}, T.Arg{"--iso-8601=", "I"}, T.Arg{"--rfc-3339=", "T"}, T.Arg{"--rfc-email", "R"}, T.Arg{"--date=", "d"}, T.Arg{"--reference=", "r"}, T.Arg{"--file=", "f"}], False{}, True{}), args), sh, cwds, home))

def command.k(v: Bool) -> T.Meaning:
  match v:
    case True{}:
      Model.inert()
    case False{}:
      Model.unknown("command runs the command it names, which bend-guard does not follow")

def command.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, ops, lo}:
      command.k(Model.has_char(fl, 'v') || Model.has_char(fl, 'V'))

# command -v / -V NAME: prints how a name would run; without them it runs it
def tx.command(args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("command: ", command.o(Model.parse(Model.spec("pvV", "", [], False{}, True{}), args)))

# hostname with no argument prints the name; with one it may set it
def tx.hostname(args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      Model.inert()
    case _:
      Model.unknown("hostname: an argument may set the computer's name, which is not modelled")

# ---------------------------------------------------------------------------
# jq FILTER FILE...: the first operand is the filter, the rest are read.
# Flags -r -c -e -S -s -n -M -j -C -a -R --tab --indent N, --arg NAME VALUE,
# --argjson NAME JSON. -f/--from-file, --rawfile, --slurpfile, -L, --args,
# --jsonargs are not modelled, nor a filter that imports or includes a module.

type TxJq is Data:
  TxJq.Mk{skip: Nat, dd: Bool, acc: List<&2, String>}

# jq.word: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KFiJqWord is Data:
  KFiJqWord.Arg{}
  KFiJqWord.Indent{}
  KFiJqWord.C{}
  KFiJqWord.Rest{}

type KFiJqWordE is Data:
  KFiJqWordE.Mk{name: String, k: KFiJqWord}

def jq.word.tab() -> List<&2, KFiJqWordE>:
  [KFiJqWordE.Mk{"--arg", KFiJqWord.Arg{}}, KFiJqWordE.Mk{"--argjson", KFiJqWord.Arg{}}, KFiJqWordE.Mk{"--indent", KFiJqWord.Indent{}}, KFiJqWordE.Mk{"--", KFiJqWord.C{}}]

def jq.word.go(xs: List<&2, KFiJqWordE>, hit: Bool, k: KFiJqWord, +w: String) -> KFiJqWord:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KFiJqWord.Rest{}
    case KFiJqWordE.Mk{n, k2} <> t False{}:
      jq.word.go(t, String.eq(n, w), k2, w)

def jq.word.find(xs: List<&2, KFiJqWordE>, +w: String) -> KFiJqWord:
  jq.word.go(xs, False{}, KFiJqWord.Rest{}, w)

def jq.word.k(key: KFiJqWord, +w: String, acc: List<&2, String>) -> TxJq:
  match key:
    case KFiJqWord.Arg{}:
      TxJq.Mk{2n, False{}, acc}
    case KFiJqWord.Indent{}:
      TxJq.Mk{1n, False{}, acc}
    case KFiJqWord.C{}:
      TxJq.Mk{0n, True{}, w <> acc}
    case KFiJqWord.Rest{}:
      TxJq.Mk{0n, False{}, w <> acc}

def jq.word(+w: String, acc: List<&2, String>) -> TxJq:
  jq.word.k(jq.word.find(jq.word.tab(), w), w, acc)

def jq.free(dd: Bool, acc: List<&2, String>, +w: String) -> TxJq:
  match dd:
    case True{}:
      TxJq.Mk{0n, True{}, w <> acc}
    case False{}:
      jq.word(w, acc)

def jq.step.k(skip: Nat, dd: Bool, acc: List<&2, String>, +w: String) -> TxJq:
  match skip:
    case 0n:
      jq.free(dd, acc, w)
    case 1n+k:
      TxJq.Mk{k, dd, acc}

def jq.step(st: TxJq, +w: String) -> TxJq:
  match st:
    case TxJq.Mk{skip, dd, acc}:
      jq.step.k(skip, dd, acc, w)

# drops --arg NAME VALUE, --argjson NAME JSON and --indent N
def jq.go(ws: List<&2, String>, st: TxJq) -> TxJq:
  match ws:
    case Nil{}:
      st
    case w <> t:
      jq.go(t, jq.step(st, w))

def jq.spec() -> Model.Spec:
  Model.spec("rceSsnMjCaR", "", [T.Arg{"--tab", "T"}, T.Arg{"--raw-output", "r"}, T.Arg{"--compact-output", "c"}, T.Arg{"--exit-status", "e"}, T.Arg{"--sort-keys", "S"}, T.Arg{"--slurp", "s"}, T.Arg{"--null-input", "n"}, T.Arg{"--monochrome-output", "M"}, T.Arg{"--join-output", "j"}, T.Arg{"--raw-input", "R"}], False{}, True{})

def jq.filter_ok(+f: String) -> Bool:
  Bool.not(String.contains(f, "import") || String.contains(f, "include"))

def jq.filter(ok: Bool, +f: String, fs: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok:
    case False{}:
      Model.unknown("a filter that imports or includes a module is not modelled")
    case True{}:
      Model.join(Model.wglob(sh, cwds, home, f), Model.rpaths(fs, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home))

def jq.ops(ops: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      Model.inert()
    case +f <> t:
      jq.filter(jq.filter_ok(f), f, t, sh, cwds, home)

def jq.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      jq.ops(ops, sh, cwds, home)

def jq.fin.k(ok: Bool, ws: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok:
    case False{}:
      Model.unknown("--arg, --argjson and --indent need their values")
    case True{}:
      jq.o(Model.parse(jq.spec(), ws), sh, cwds, home)

def jq.fin(st: TxJq, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match st:
    case TxJq.Mk{skip, dd, acc}:
      jq.fin.k(Nat.is_eq(skip, 0n), List.reverse(&2, String, acc), sh, cwds, home)

def tx.jq(+sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("jq: ", jq.fin(jq.go(args, TxJq.Mk{0n, False{}, []}), sh, cwds, home))

# ---------------------------------------------------------------------------
# sed: flags -n -E -r -u --quiet --silent --posix -e SCRIPT
# --expression=SCRIPT, and -i / --in-place with no backup suffix. Each script
# (the first operand when there is no -e) must be commands split by ; or a
# newline, each an optional address (N, $, /re/, N~K; then ,N ,$ ,/re/ or
# ,+K; then an optional !) and one of p d = n q[N] Q[N] y/../../ and
# s<d>..<d>..<d>FLAGS (d one of / | # , :, FLAGS only g i I p and digits).
# Not modelled: -f, -s, -z, -i with a suffix, braces, labels and branches,
# and the commands w W r R e a i c l F z, and the s flags e w m M.
# Reads each file operand (a wildcard reads its folder); with -i also writes
# each one.

type TxSed is Data:
  TxSed.Start{}
  TxSed.N1{}
  TxSed.Tl{}
  TxSed.TlN{}
  TxSed.R1{}
  TxSed.R1E{}
  TxSed.A1{}
  TxSed.Cm{}
  TxSed.Pl{}
  TxSed.N2{}
  TxSed.R2{}
  TxSed.R2E{}
  TxSed.Cmd{}
  TxSed.QN{}
  TxSed.End{}
  TxSed.SD{}
  TxSed.S1{d: Char}
  TxSed.S1E{d: Char}
  TxSed.S2{d: Char}
  TxSed.S2E{d: Char}
  TxSed.SF{}
  TxSed.YD{}
  TxSed.Y1{}
  TxSed.Y1E{}
  TxSed.Y2{}
  TxSed.Y2E{}
  TxSed.Bad{}

def sed.or(b: Bool, x: TxSed, y: TxSed) -> TxSed:
  match b:
    case True{}:
      x
    case False{}:
      y

# a command letter
def sed.cmd(c: Char) -> TxSed:
  match c:
    case Chr{112}:
      TxSed.End{}
    case Chr{100}:
      TxSed.End{}
    case Chr{61}:
      TxSed.End{}
    case Chr{110}:
      TxSed.End{}
    case Chr{113}:
      TxSed.QN{}
    case Chr{81}:
      TxSed.QN{}
    case Chr{115}:
      TxSed.SD{}
    case Chr{121}:
      TxSed.YD{}
    case _:
      TxSed.Bad{}

# after a whole address: !, a space, or the command
def sed.a2(c: Char) -> TxSed:
  match c:
    case Chr{33}:
      TxSed.Cmd{}
    case Chr{32}:
      TxSed.Cmd{}
    case Chr{9}:
      TxSed.Cmd{}
    case other:
      sed.cmd(other)

# after a first address: also a comma
def sed.a1(c: Char) -> TxSed:
  match c:
    case Chr{44}:
      TxSed.Cm{}
    case other:
      sed.a2(other)

def sed.start(+c: Char) -> TxSed:
  match c:
    case Chr{32}:
      TxSed.Start{}
    case Chr{9}:
      TxSed.Start{}
    case Chr{10}:
      TxSed.Start{}
    case Chr{59}:
      TxSed.Start{}
    case Chr{36}:
      TxSed.A1{}
    case Chr{47}:
      TxSed.R1{}
    case _:
      sed.or(Char.is_digit(c), TxSed.N1{}, sed.cmd(c))

def sed.n1(+c: Char) -> TxSed:
  match c:
    case Chr{126}:
      TxSed.Tl{}
    case _:
      sed.or(Char.is_digit(c), TxSed.N1{}, sed.a1(c))

def sed.r1(c: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.R1E{}
    case Chr{47}:
      TxSed.A1{}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      TxSed.R1{}

def sed.cm(+c: Char) -> TxSed:
  match c:
    case Chr{36}:
      TxSed.Cmd{}
    case Chr{47}:
      TxSed.R2{}
    case Chr{43}:
      TxSed.Pl{}
    case _:
      sed.or(Char.is_digit(c), TxSed.N2{}, TxSed.Bad{})

def sed.r2(c: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.R2E{}
    case Chr{47}:
      TxSed.Cmd{}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      TxSed.R2{}

def sed.cmdws(c: Char) -> TxSed:
  match c:
    case Chr{32}:
      TxSed.Cmd{}
    case Chr{9}:
      TxSed.Cmd{}
    case other:
      sed.cmd(other)

# after a whole command: spaces, then ; or a newline
def sed.end(c: Char) -> TxSed:
  match c:
    case Chr{32}:
      TxSed.End{}
    case Chr{9}:
      TxSed.End{}
    case Chr{59}:
      TxSed.Start{}
    case Chr{10}:
      TxSed.Start{}
    case _:
      TxSed.Bad{}

def sed.qn(+c: Char) -> TxSed:
  sed.or(Char.is_digit(c), TxSed.QN{}, sed.end(c))

def sed.sd(+c: Char) -> TxSed:
  match c:
    case Chr{47}:
      TxSed.S1{c}
    case Chr{124}:
      TxSed.S1{c}
    case Chr{35}:
      TxSed.S1{c}
    case Chr{44}:
      TxSed.S1{c}
    case Chr{58}:
      TxSed.S1{c}
    case _:
      TxSed.Bad{}

def sed.s1(+c: Char, +d: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.S1E{d}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      sed.or(Char.is_eq(c, d), TxSed.S2{d}, TxSed.S1{d})

def sed.s2(+c: Char, +d: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.S2E{d}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      sed.or(Char.is_eq(c, d), TxSed.SF{}, TxSed.S2{d})

# the flags of s: g i I p and digits only
def sed.sf(+c: Char) -> TxSed:
  match c:
    case Chr{103}:
      TxSed.SF{}
    case Chr{105}:
      TxSed.SF{}
    case Chr{73}:
      TxSed.SF{}
    case Chr{112}:
      TxSed.SF{}
    case _:
      sed.or(Char.is_digit(c), TxSed.SF{}, sed.end(c))

def sed.yd(c: Char) -> TxSed:
  match c:
    case Chr{47}:
      TxSed.Y1{}
    case _:
      TxSed.Bad{}

def sed.y1(c: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.Y1E{}
    case Chr{47}:
      TxSed.Y2{}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      TxSed.Y1{}

def sed.y2(c: Char) -> TxSed:
  match c:
    case Chr{92}:
      TxSed.Y2E{}
    case Chr{47}:
      TxSed.End{}
    case Chr{10}:
      TxSed.Bad{}
    case _:
      TxSed.Y2{}

def sed.step(st: TxSed, +c: Char) -> TxSed:
  match st:
    case TxSed.Start{}:
      sed.start(c)
    case TxSed.N1{}:
      sed.n1(c)
    case TxSed.Tl{}:
      sed.or(Char.is_digit(c), TxSed.TlN{}, TxSed.Bad{})
    case TxSed.TlN{}:
      sed.or(Char.is_digit(c), TxSed.TlN{}, sed.a1(c))
    case TxSed.R1{}:
      sed.r1(c)
    case TxSed.R1E{}:
      TxSed.R1{}
    case TxSed.A1{}:
      sed.a1(c)
    case TxSed.Cm{}:
      sed.cm(c)
    case TxSed.Pl{}:
      sed.or(Char.is_digit(c), TxSed.N2{}, TxSed.Bad{})
    case TxSed.N2{}:
      sed.or(Char.is_digit(c), TxSed.N2{}, sed.a2(c))
    case TxSed.R2{}:
      sed.r2(c)
    case TxSed.R2E{}:
      TxSed.R2{}
    case TxSed.Cmd{}:
      sed.cmdws(c)
    case TxSed.QN{}:
      sed.qn(c)
    case TxSed.End{}:
      sed.end(c)
    case TxSed.SD{}:
      sed.sd(c)
    case TxSed.S1{d}:
      sed.s1(c, d)
    case TxSed.S1E{d}:
      TxSed.S1{d}
    case TxSed.S2{d}:
      sed.s2(c, d)
    case TxSed.S2E{d}:
      TxSed.S2{d}
    case TxSed.SF{}:
      sed.sf(c)
    case TxSed.YD{}:
      sed.yd(c)
    case TxSed.Y1{}:
      sed.y1(c)
    case TxSed.Y1E{}:
      TxSed.Y1{}
    case TxSed.Y2{}:
      sed.y2(c)
    case TxSed.Y2E{}:
      TxSed.Y2{}
    case TxSed.Bad{}:
      TxSed.Bad{}

def sed.go(s: String, st: TxSed) -> TxSed:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      sed.go(t, sed.step(st, c))

def sed.fin(st: TxSed) -> Bool:
  match st:
    case TxSed.Start{}:
      True{}
    case TxSed.End{}:
      True{}
    case TxSed.QN{}:
      True{}
    case TxSed.SF{}:
      True{}
    case _:
      False{}

# the script is in the whitelisted grammar above
def sed.script_ok(s: String) -> Bool:
  sed.fin(sed.go(s, TxSed.Start{}))

def sed.all(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      sed.script_ok(x) && sed.all(t)

# a short-flag word with i before its end: GNU sed reads the rest as a
# backup suffix (-ie, -i.bak), which writes another file
def sed.isuf(ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      (String.starts_with(w, "-") && Bool.not(String.starts_with(w, "--")) && Model.has_char(String.drop(String.reverse(w), 1n), 'i')) || sed.isuf(t)

def sed.why() -> String:
  "the script uses a command, address or flag that is not modelled (only p, d, =, n, q, Q, y and s with the flags g, i, I, p or a number)"

def sed.mean(+fs: List<&2, String>, inpl: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match inpl:
    case False{}:
      Model.rpaths(fs, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home)
    case True{}:
      Model.join(Model.rpaths(fs, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home), Model.rpaths(fs, sh, Model.AKind.Write{}, Model.AKind.WriteTree{}, cwds, home))

def sed.run(ok: Bool, files: Maybe<&2, List<&2, String>>, inpl: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok files:
    case False{} _:
      Model.unknown(sed.why())
    case True{} None{}:
      Model.unknown("no script is given")
    case True{} Some{fs}:
      sed.mean(fs, inpl, sh, cwds, home)

def sed.scripts(hase: Bool, vs: List<&2, T.Arg>, ops: List<&2, String>) -> List<&2, String>:
  match hase:
    case True{}:
      Model.vals_for(vs, "e")
    case False{}:
      grep.first(ops)

def sed.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, +ops, lo}:
      Model.join(sed.run(sed.all(sed.scripts(Model.has_char(fl, 'e'), vs, ops)), grep.files(Model.has_char(fl, 'e'), ops), Model.has_char(fl, 'i'), sh, cwds, home), Model.wglobs(List.append(&2, String, grep.pat(Model.has_char(fl, 'e'), ops), lo), sh, cwds, home))

def sed.k(suf: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match suf:
    case True{}:
      Model.unknown("-i with a backup suffix is not modelled")
    case False{}:
      sed.o(Model.parse(Model.spec("nEriu", "e", [T.Arg{"--quiet", "n"}, T.Arg{"--silent", "n"}, T.Arg{"--posix", "P"}, T.Arg{"--expression=", "e"}, T.Arg{"--in-place", "i"}, T.Arg{"--regexp-extended", "E"}, T.Arg{"--unbuffered", "u"}], False{}, True{}), args), sh, cwds, home)

def tx.sed(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("sed: ", sed.k(sed.isuf(args), sh, cwds, home, args))

# ---------------------------------------------------------------------------
# awk and gawk: -F SEP, -v NAME=VALUE and one program operand that uses none
# of: system, getline, close, fflush, |, >, @ (includes, loads, indirect
# calls), ENVIRON, PROCINFO, ARGV, ARGC, SYMTAB, FUNCTAB. An operand NAME=VALUE
# is an assignment (not to ARGV, ARGC, ARGIND, ENVIRON, PROCINFO, SYMTAB or
# FUNCTAB); every other operand is read. -f, -e, -i, -l, -E and the other
# flags are not modelled.

def awk.bad() -> List<&2, String>:
  ["system", "getline", "close", "fflush", "|", ">", "@", "ENVIRON", "PROCINFO", "ARGV", "ARGC", "SYMTAB", "FUNCTAB"]

def awk.special() -> List<&2, String>:
  ["ARGV", "ARGC", "ARGIND", "ENVIRON", "PROCINFO", "SYMTAB", "FUNCTAB"]

def awk.has_any(+p: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      String.contains(p, x) || awk.has_any(p, t)

def awk.is_asg(+w: String) -> Bool:
  Model.has_char(w, '=') && Model.is_ident(Model.before_eq(w))

# an assignment (NAME=VALUE with a plain NAME) that does not set a special
# variable
def awk.asg_ok(+w: String) -> Bool:
  awk.is_asg(w) && Bool.not(Model.elem(Model.before_eq(w), awk.special()))

def awk.vs_ok(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      awk.asg_ok(x) && awk.vs_ok(t)

# every operand assignment is allowed
def awk.ops_ok(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      (Bool.not(awk.is_asg(x)) || awk.asg_ok(x)) && awk.ops_ok(t)

def awk.keep(asg: Bool, x: String, rest: List<&2, String>) -> List<&2, String>:
  match asg:
    case True{}:
      rest
    case False{}:
      x <> rest

# the operands that are files (not assignments)
def awk.files(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case +x <> t:
      awk.keep(awk.is_asg(x), x, awk.files(t))

def awk.run(pok: Bool, aok: Bool, +p: String, fs: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match pok aok:
    case False{} _:
      Model.unknown("the program uses something that can run commands, write files or choose other files (system, getline, |, >, @, ARGV, ENVIRON or the like), which is not modelled")
    case True{} False{}:
      Model.unknown("an assignment to ARGV, ARGC, ENVIRON or another special variable is not modelled")
    case True{} True{}:
      Model.join(Model.wglob(sh, cwds, home, p), Model.rpaths(fs, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home))

def awk.ops(ops: List<&2, String>, vs: List<&2, T.Arg>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ops:
    case Nil{}:
      Model.unknown("no program is given")
    case +p <> +t:
      awk.run(Bool.not(awk.has_any(p, awk.bad())), awk.ops_ok(t) && awk.vs_ok(Model.vals_for(vs, "v")), p, awk.files(t), sh, cwds, home)

def awk.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      Model.join(awk.ops(ops, vs, sh, cwds, home), Model.wglobs(lo, sh, cwds, home))

def tx.awk(+sh: T.Shell, +cwds: List<&2, String>, +home: String, name: String, args: List<&2, String>) -> T.Meaning:
  Model.why_prefix(name ++ ": ", awk.o(Model.parse(Model.spec("", "Fv", [], False{}, True{}), args), sh, cwds, home))

# ---------------------------------------------------------------------------
# find START... EXPR: the start points are the words before the first word
# starting with - or equal to ( or ! (default .). Expression words allowed:
# -name -iname -path -ipath -wholename -regex -iregex -type -maxdepth
# -mindepth -size -mtime -mmin -printf (each with a value), -newer FILE
# (reads FILE), -empty -print -print0 -not ! -o -a -or -and ( ) -prune. Any
# other word (-exec, -execdir, -ok, -okdir, -delete, -fprint, -fprint0,
# -fprintf, -fls, -L, -follow, ...) is Unknown. ListDir of each start folder.
# Under bash a wildcard word could expand into find words such as -delete,
# so a wildcard is allowed only after a folder part (src/*.ts) or in a word
# with a literal . and no [ (*.ts): no find word holds / or . .

type TxFk is Data:
  TxFk.Flag{}
  TxFk.Val{}
  TxFk.Newer{}
  TxFk.Bad{}

# find.kind: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KFiFindKind is Data:
  KFiFindKind.Name{}
  KFiFindKind.Newer{}
  KFiFindKind.Empty{}
  KFiFindKind.Rest{}

type KFiFindKindE is Data:
  KFiFindKindE.Mk{name: String, k: KFiFindKind}

def find.kind.tab() -> List<&2, KFiFindKindE>:
  [KFiFindKindE.Mk{"-name", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-iname", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-path", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-ipath", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-wholename", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-regex", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-iregex", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-type", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-maxdepth", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-mindepth", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-size", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-mtime", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-mmin", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-printf", KFiFindKind.Name{}}, KFiFindKindE.Mk{"-newer", KFiFindKind.Newer{}}, KFiFindKindE.Mk{"-empty", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-print", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-print0", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-not", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"!", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-o", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-a", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-or", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-and", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"(", KFiFindKind.Empty{}}, KFiFindKindE.Mk{")", KFiFindKind.Empty{}}, KFiFindKindE.Mk{"-prune", KFiFindKind.Empty{}}]

def find.kind.go(xs: List<&2, KFiFindKindE>, hit: Bool, k: KFiFindKind, +w: String) -> KFiFindKind:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KFiFindKind.Rest{}
    case KFiFindKindE.Mk{n, k2} <> t False{}:
      find.kind.go(t, String.eq(n, w), k2, w)

def find.kind.find(xs: List<&2, KFiFindKindE>, +w: String) -> KFiFindKind:
  find.kind.go(xs, False{}, KFiFindKind.Rest{}, w)

def find.kind.k(key: KFiFindKind, +w: String) -> TxFk:
  match key:
    case KFiFindKind.Name{}:
      TxFk.Val{}
    case KFiFindKind.Newer{}:
      TxFk.Newer{}
    case KFiFindKind.Empty{}:
      TxFk.Flag{}
    case KFiFindKind.Rest{}:
      TxFk.Bad{}

def find.kind(+w: String) -> TxFk:
  find.kind.k(find.kind.find(find.kind.tab(), w), w)

type TxFph is Data:
  TxFph.Start{}
  TxFph.Expr{}
  TxFph.Val{newer: Bool}

type TxFind is Data:
  TxFind.Mk{ok: Bool, why: String, ph: TxFph, starts: List<&2, String>, newer: List<&2, String>}

def find.expr(k: TxFk, ok: Bool, why: String, starts: List<&2, String>, newer: List<&2, String>, w: String) -> TxFind:
  match k:
    case TxFk.Flag{}:
      TxFind.Mk{ok, why, TxFph.Expr{}, starts, newer}
    case TxFk.Val{}:
      TxFind.Mk{ok, why, TxFph.Val{False{}}, starts, newer}
    case TxFk.Newer{}:
      TxFind.Mk{ok, why, TxFph.Val{True{}}, starts, newer}
    case TxFk.Bad{}:
      TxFind.Mk{False{}, Model.pick.s(ok, "the find word " ++ w ++ " is not modelled (only tests such as -name, -type and -maxdepth, and -print, -print0 and -printf)", why), TxFph.Expr{}, starts, newer}

def find.start(isx: Bool, ok: Bool, why: String, starts: List<&2, String>, newer: List<&2, String>, +w: String) -> TxFind:
  match isx:
    case True{}:
      find.expr(find.kind(w), ok, why, starts, newer, w)
    case False{}:
      TxFind.Mk{ok, why, TxFph.Start{}, w <> starts, newer}

def find.addnew(nw: Bool, w: String, newer: List<&2, String>) -> List<&2, String>:
  match nw:
    case True{}:
      w <> newer
    case False{}:
      newer

def find.ph(ph: TxFph, ok: Bool, why: String, starts: List<&2, String>, newer: List<&2, String>, +w: String) -> TxFind:
  match ph:
    case TxFph.Start{}:
      find.start(String.starts_with(w, "-") || String.eq(w, "(") || String.eq(w, "!"), ok, why, starts, newer, w)
    case TxFph.Expr{}:
      find.expr(find.kind(w), ok, why, starts, newer, w)
    case TxFph.Val{nw}:
      TxFind.Mk{ok, why, TxFph.Expr{}, starts, find.addnew(nw, w, newer)}

def find.step(st: TxFind, +w: String) -> TxFind:
  match st:
    case TxFind.Mk{ok, why, ph, starts, newer}:
      find.ph(ph, ok, why, starts, newer, w)

def find.go(ws: List<&2, String>, st: TxFind) -> TxFind:
  match ws:
    case Nil{}:
      st
    case w <> t:
      find.go(t, find.step(st, w))

def find.pending(ph: TxFph) -> Bool:
  match ph:
    case TxFph.Val{nw}:
      True{}
    case _:
      False{}

def find.fin.k(ok: Bool, pend: Bool, why: String, +starts: List<&2, String>, newer: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok pend:
    case False{} _:
      Model.unknown(why)
    case True{} True{}:
      Model.unknown("the last find test needs a value")
    case True{} False{}:
      Model.join(ls.k(List.is_empty(&2, String, starts), starts, sh, cwds, home), Model.rpaths(newer, sh, Model.AKind.Read{}, Model.AKind.ReadTree{}, cwds, home))

def find.fin(st: TxFind, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match st:
    case TxFind.Mk{ok, why, ph, starts, newer}:
      find.fin.k(ok, find.pending(ph), why, List.reverse(&2, String, starts), List.reverse(&2, String, newer), sh, cwds, home)

def find.g1.k(g: Bool, m: Maybe<&2, String>, +w: String) -> Bool:
  match g m:
    case False{} _:
      True{}
    case True{} None{}:
      False{}
    case True{} Some{d}:
      Bool.not(String.eq(d, ".")) || (Model.has_char(w, '.') && Bool.not(Model.has_char(w, '[')))

# a wildcard in w cannot expand into a find word
def find.g1(+sh: T.Shell, +w: String) -> Bool:
  find.g1.k(Model.has_glob(w), Model.glob_dir(sh, False{}, w), w)

def find.globs(ws: List<&2, String>, +sh: T.Shell) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case w <> t:
      find.g1(sh, w) && find.globs(t, sh)

def find.k(gok: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match gok:
    case False{}:
      Model.unknown("a wildcard here could expand into find words such as -delete, which is not modelled (a wildcard after a folder, or with a . in it like *.ts, is)")
    case True{}:
      find.fin(find.go(args, TxFind.Mk{True{}, "", TxFph.Start{}, [], []}), sh, cwds, home)

def tx.find(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("find: ", find.k(find.globs(args, sh), sh, cwds, home, args))

# ---------------------------------------------------------------------------
# The commands above by name (bash). None: not one of them.

# tx.bash: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KFiTxBash is Data:
  KFiTxBash.Cut{}
  KFiTxBash.Wc{}
  KFiTxBash.Sort{}
  KFiTxBash.Uniq{}
  KFiTxBash.Tr{}
  KFiTxBash.Nl{}
  KFiTxBash.Rev{}
  KFiTxBash.Tac{}
  KFiTxBash.Column{}
  KFiTxBash.Fold{}
  KFiTxBash.Expand{}
  KFiTxBash.Paste{}
  KFiTxBash.Comm{}
  KFiTxBash.Cmp{}
  KFiTxBash.Md5sum{}
  KFiTxBash.Sha1sum{}
  KFiTxBash.Sha256sum{}
  KFiTxBash.Od{}
  KFiTxBash.Strings{}
  KFiTxBash.Base64{}
  KFiTxBash.Stat{}
  KFiTxBash.File{}
  KFiTxBash.Diff{}
  KFiTxBash.Jq{}
  KFiTxBash.Tee{}
  KFiTxBash.Du{}
  KFiTxBash.Tree{}
  KFiTxBash.Realpath{}
  KFiTxBash.Basename{}
  KFiTxBash.Dirname{}
  KFiTxBash.Readlink{}
  KFiTxBash.Date{}
  KFiTxBash.Sleep{}
  KFiTxBash.Seq{}
  KFiTxBash.Which{}
  KFiTxBash.Type{}
  KFiTxBash.Command{}
  KFiTxBash.False{}
  KFiTxBash.Whoami{}
  KFiTxBash.Uname{}
  KFiTxBash.Nproc{}
  KFiTxBash.Hostname{}
  KFiTxBash.Sed{}
  KFiTxBash.Awk{}
  KFiTxBash.Gawk{}
  KFiTxBash.Find{}
  KFiTxBash.Rest{}

type KFiTxBashE is Data:
  KFiTxBashE.Mk{name: String, k: KFiTxBash}

def tx.bash.tab() -> List<&2, KFiTxBashE>:
  [KFiTxBashE.Mk{"cut", KFiTxBash.Cut{}}, KFiTxBashE.Mk{"wc", KFiTxBash.Wc{}}, KFiTxBashE.Mk{"sort", KFiTxBash.Sort{}}, KFiTxBashE.Mk{"uniq", KFiTxBash.Uniq{}}, KFiTxBashE.Mk{"tr", KFiTxBash.Tr{}}, KFiTxBashE.Mk{"nl", KFiTxBash.Nl{}}, KFiTxBashE.Mk{"rev", KFiTxBash.Rev{}}, KFiTxBashE.Mk{"tac", KFiTxBash.Tac{}}, KFiTxBashE.Mk{"column", KFiTxBash.Column{}}, KFiTxBashE.Mk{"fold", KFiTxBash.Fold{}}, KFiTxBashE.Mk{"expand", KFiTxBash.Expand{}}, KFiTxBashE.Mk{"paste", KFiTxBash.Paste{}}, KFiTxBashE.Mk{"comm", KFiTxBash.Comm{}}, KFiTxBashE.Mk{"cmp", KFiTxBash.Cmp{}}, KFiTxBashE.Mk{"md5sum", KFiTxBash.Md5sum{}}, KFiTxBashE.Mk{"sha1sum", KFiTxBash.Sha1sum{}}, KFiTxBashE.Mk{"sha256sum", KFiTxBash.Sha256sum{}}, KFiTxBashE.Mk{"od", KFiTxBash.Od{}}, KFiTxBashE.Mk{"strings", KFiTxBash.Strings{}}, KFiTxBashE.Mk{"base64", KFiTxBash.Base64{}}, KFiTxBashE.Mk{"stat", KFiTxBash.Stat{}}, KFiTxBashE.Mk{"file", KFiTxBash.File{}}, KFiTxBashE.Mk{"diff", KFiTxBash.Diff{}}, KFiTxBashE.Mk{"jq", KFiTxBash.Jq{}}, KFiTxBashE.Mk{"tee", KFiTxBash.Tee{}}, KFiTxBashE.Mk{"du", KFiTxBash.Du{}}, KFiTxBashE.Mk{"tree", KFiTxBash.Tree{}}, KFiTxBashE.Mk{"realpath", KFiTxBash.Realpath{}}, KFiTxBashE.Mk{"basename", KFiTxBash.Basename{}}, KFiTxBashE.Mk{"dirname", KFiTxBash.Dirname{}}, KFiTxBashE.Mk{"readlink", KFiTxBash.Readlink{}}, KFiTxBashE.Mk{"date", KFiTxBash.Date{}}, KFiTxBashE.Mk{"sleep", KFiTxBash.Sleep{}}, KFiTxBashE.Mk{"seq", KFiTxBash.Seq{}}, KFiTxBashE.Mk{"which", KFiTxBash.Which{}}, KFiTxBashE.Mk{"type", KFiTxBash.Type{}}, KFiTxBashE.Mk{"command", KFiTxBash.Command{}}, KFiTxBashE.Mk{"false", KFiTxBash.False{}}, KFiTxBashE.Mk{"test", KFiTxBash.False{}}, KFiTxBashE.Mk{"[", KFiTxBash.False{}}, KFiTxBashE.Mk{"whoami", KFiTxBash.Whoami{}}, KFiTxBashE.Mk{"uname", KFiTxBash.Uname{}}, KFiTxBashE.Mk{"nproc", KFiTxBash.Nproc{}}, KFiTxBashE.Mk{"hostname", KFiTxBash.Hostname{}}, KFiTxBashE.Mk{"sed", KFiTxBash.Sed{}}, KFiTxBashE.Mk{"awk", KFiTxBash.Awk{}}, KFiTxBashE.Mk{"gawk", KFiTxBash.Gawk{}}, KFiTxBashE.Mk{"find", KFiTxBash.Find{}}]

def tx.bash.go(xs: List<&2, KFiTxBashE>, hit: Bool, k: KFiTxBash, +w: String) -> KFiTxBash:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KFiTxBash.Rest{}
    case KFiTxBashE.Mk{n, k2} <> t False{}:
      tx.bash.go(t, String.eq(n, w), k2, w)

def tx.bash.find(xs: List<&2, KFiTxBashE>, +w: String) -> KFiTxBash:
  tx.bash.go(xs, False{}, KFiTxBash.Rest{}, w)

def tx.bash.k(key: KFiTxBash, +name: String, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> Maybe<&2, T.Meaning>:
  match key:
    case KFiTxBash.Cut{}:
      Some{tx.cut(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Wc{}:
      Some{tx.wc(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Sort{}:
      Some{tx.sort(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Uniq{}:
      Some{tx.uniq(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Tr{}:
      Some{tx.tr(args)}
    case KFiTxBash.Nl{}:
      Some{tx.rd(T.Bash{}, cwds, home, "nl", Model.spec("p", "bdfhilnsvw", [], False{}, True{}), args)}
    case KFiTxBash.Rev{}:
      Some{tx.rd(T.Bash{}, cwds, home, "rev", Model.spec("", "", [], False{}, True{}), args)}
    case KFiTxBash.Tac{}:
      Some{tx.rd(T.Bash{}, cwds, home, "tac", Model.spec("br", "s", [], False{}, True{}), args)}
    case KFiTxBash.Column{}:
      Some{tx.rd(T.Bash{}, cwds, home, "column", Model.spec("tnxe", "sco", [], False{}, True{}), args)}
    case KFiTxBash.Fold{}:
      Some{tx.rd(T.Bash{}, cwds, home, "fold", Model.spec("bs", "w", [], False{}, True{}), args)}
    case KFiTxBash.Expand{}:
      Some{tx.rd(T.Bash{}, cwds, home, "expand", Model.spec("i", "t", [], False{}, True{}), args)}
    case KFiTxBash.Paste{}:
      Some{tx.rd(T.Bash{}, cwds, home, "paste", Model.spec("sz", "d", [], False{}, True{}), args)}
    case KFiTxBash.Comm{}:
      Some{tx.rd(T.Bash{}, cwds, home, "comm", Model.spec("123z", "", [T.Arg{"--check-order", "c"}, T.Arg{"--nocheck-order", "C"}, T.Arg{"--output-delimiter=", "o"}, T.Arg{"--total", "T"}], False{}, True{}), args)}
    case KFiTxBash.Cmp{}:
      Some{tx.rd(T.Bash{}, cwds, home, "cmp", Model.spec("bls", "in", [], False{}, True{}), args)}
    case KFiTxBash.Md5sum{}:
      Some{tx.rd(T.Bash{}, cwds, home, "md5sum", Model.spec("btz", "", [T.Arg{"--tag", "T"}, T.Arg{"--binary", "b"}, T.Arg{"--text", "t"}, T.Arg{"--zero", "z"}], False{}, True{}), args)}
    case KFiTxBash.Sha1sum{}:
      Some{tx.rd(T.Bash{}, cwds, home, "sha1sum", Model.spec("btz", "", [T.Arg{"--tag", "T"}, T.Arg{"--binary", "b"}, T.Arg{"--text", "t"}, T.Arg{"--zero", "z"}], False{}, True{}), args)}
    case KFiTxBash.Sha256sum{}:
      Some{tx.rd(T.Bash{}, cwds, home, "sha256sum", Model.spec("btz", "", [T.Arg{"--tag", "T"}, T.Arg{"--binary", "b"}, T.Arg{"--text", "t"}, T.Arg{"--zero", "z"}], False{}, True{}), args)}
    case KFiTxBash.Od{}:
      Some{tx.rd(T.Bash{}, cwds, home, "od", Model.spec("bcdfiloxsv", "AtNjwS", [], False{}, True{}), args)}
    case KFiTxBash.Strings{}:
      Some{tx.rd(T.Bash{}, cwds, home, "strings", Model.spec("a", "nte", [], False{}, True{}), args)}
    case KFiTxBash.Base64{}:
      Some{tx.rd(T.Bash{}, cwds, home, "base64", Model.spec("di", "w", [T.Arg{"--decode", "d"}, T.Arg{"--ignore-garbage", "i"}, T.Arg{"--wrap=", "w"}], False{}, True{}), args)}
    case KFiTxBash.Stat{}:
      Some{tx.rd(T.Bash{}, cwds, home, "stat", Model.spec("Lft", "c", [T.Arg{"--format=", "c"}, T.Arg{"--printf=", "p"}, T.Arg{"--dereference", "L"}, T.Arg{"--terse", "t"}], False{}, True{}), args)}
    case KFiTxBash.File{}:
      Some{tx.rd(T.Bash{}, cwds, home, "file", Model.spec("biL", "", [T.Arg{"--mime", "m"}, T.Arg{"--mime-type", "m"}, T.Arg{"--brief", "b"}, T.Arg{"--dereference", "L"}], False{}, True{}), args)}
    case KFiTxBash.Diff{}:
      Some{tx.diff(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Jq{}:
      Some{tx.jq(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Tee{}:
      Some{tx.tee(cwds, home, args)}
    case KFiTxBash.Du{}:
      Some{tx.lsd(T.Bash{}, cwds, home, "du", Model.spec("shac", "d", [T.Arg{"--max-depth=", "d"}, T.Arg{"--summarize", "s"}, T.Arg{"--human-readable", "h"}, T.Arg{"--all", "a"}, T.Arg{"--total", "c"}], False{}, True{}), args)}
    case KFiTxBash.Tree{}:
      Some{tx.lsd(T.Bash{}, cwds, home, "tree", Model.spec("ad", "LI", [], False{}, True{}), args)}
    case KFiTxBash.Realpath{}:
      Some{tx.inert("realpath", Model.spec("esqmLPz", "", [T.Arg{"--relative-to=", "r"}, T.Arg{"--relative-base=", "b"}], False{}, True{}), args)}
    case KFiTxBash.Basename{}:
      Some{tx.inert("basename", Model.spec("az", "s", [T.Arg{"--multiple", "a"}, T.Arg{"--suffix=", "s"}, T.Arg{"--zero", "z"}], False{}, True{}), args)}
    case KFiTxBash.Dirname{}:
      Some{tx.inert("dirname", Model.spec("z", "", [], False{}, True{}), args)}
    case KFiTxBash.Readlink{}:
      Some{tx.inert("readlink", Model.spec("fenmqsvz", "", [], False{}, True{}), args)}
    case KFiTxBash.Date{}:
      Some{tx.date(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Sleep{}:
      Some{tx.inert("sleep", Model.spec("", "", [], False{}, True{}), args)}
    case KFiTxBash.Seq{}:
      Some{tx.inert("seq", Model.spec("w", "sf", [], False{}, True{}), args)}
    case KFiTxBash.Which{}:
      Some{tx.inert("which", Model.spec("a", "", [T.Arg{"--all", "a"}], False{}, True{}), args)}
    case KFiTxBash.Type{}:
      Some{tx.inert("type", Model.spec("afptP", "", [], False{}, True{}), args)}
    case KFiTxBash.Command{}:
      Some{tx.command(args)}
    case KFiTxBash.False{}:
      Some{Model.inert()}
    case KFiTxBash.Whoami{}:
      Some{tx.none("whoami", Model.spec("", "", [], False{}, False{}), args)}
    case KFiTxBash.Uname{}:
      Some{tx.none("uname", Model.spec("asnrvmpio", "", [T.Arg{"--all", "a"}], False{}, False{}), args)}
    case KFiTxBash.Nproc{}:
      Some{tx.none("nproc", Model.spec("", "", [T.Arg{"--all", "a"}, T.Arg{"--ignore=", "i"}], False{}, False{}), args)}
    case KFiTxBash.Hostname{}:
      Some{tx.hostname(args)}
    case KFiTxBash.Sed{}:
      Some{tx.sed(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Awk{}:
      Some{tx.awk(T.Bash{}, cwds, home, "awk", args)}
    case KFiTxBash.Gawk{}:
      Some{tx.awk(T.Bash{}, cwds, home, "gawk", args)}
    case KFiTxBash.Find{}:
      Some{tx.find(T.Bash{}, cwds, home, args)}
    case KFiTxBash.Rest{}:
      None{}

def tx.bash(+name: String, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> Maybe<&2, T.Meaning>:
  tx.bash.k(tx.bash.find(tx.bash.tab(), name), name, cwds, home, args)

# ---------------------------------------------------------------------------
# ln and the commands that run other code: always Unknown

def ln.k(sym: Bool) -> T.Meaning:
  match sym:
    case True{}:
      Model.unknown("ln: makes a symbolic link, which is not modelled")
    case False{}:
      Model.unknown(Model.hard_link_why())

def ln(args: List<&2, String>) -> T.Meaning:
  ln.k(Model.short_or_long(args, 's', "--symbolic"))

def runs_other_code() -> List<&2, String>:
  ["bash", "sh", "zsh", "env", "xargs", "nice", "stdbuf", "node", "python", "python3", "py", "perl", "ruby", "npx", "sudo", "eval", "exec", "source", ".", "time", "nohup", "timeout", "watch"]

def other.k(code: Bool, name: String) -> T.Meaning:
  match code:
    case True{}:
      Model.unknown(name ++ " can run other commands or code, which bend-guard does not follow")
    case False{}:
      Model.unknown("the command " ++ name ++ " is not modelled")

# any other command name
def other(+name: String) -> T.Meaning:
  other.k(Model.elem(name, runs_other_code()), name)

# ---------------------------------------------------------------------------
# Round 3 (backlog P4 and P8): gh and curl in their read-only network forms,
# rg, npm view and outdated, and small read-only commands (df, free, uptime,
# id, ps, pgrep, tasklist, netstat, ss, lsof, where, wait, pip). A read-only
# network call changes no file, like WebFetch. The names are picked from a
# table (r3.table, tx3), so the string match stays small for the checker.
# Every flag not listed is Unknown.

# Under bash, a word whose first character is a wildcard that was not quoted
# can expand into a file name starting with -, which the program would read
# as a flag (a file named --pre=x for rg, -ofile for curl): not modelled.
# Under Windows PowerShell 5.1 an empty argument, or one holding a double
# quote, reaches a program dropped or split into other words: not modelled.
def r3.lead.c(w: String) -> Bool:
  match w:
    case SNil{}:
      False{}
    case SCon{c, t}:
      Model.is_glob_char(c)

def r3.lead.k(g: Bool, w: String) -> Bool:
  match g:
    case True{}:
      r3.lead.c(w)
    case False{}:
      False{}

def r3.lead(ws: List<&2, String>, +lit: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      r3.lead.k(Model.has_glob(w) && Bool.not(Model.elem(w, lit)), w) || r3.lead(t, lit)

def r3.pq(ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      String.is_empty(w) || Model.has_char(w, Chr{34}) || r3.pq(t)

def r3.bad(bad: Bool, why: String, m: T.Meaning) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown(why)
    case False{}:
      m

def r3.guard(sh: T.Shell, args: List<&2, String>, +lit: List<&2, String>, m: T.Meaning) -> T.Meaning:
  match sh:
    case T.Bash{}:
      r3.bad(r3.lead(args, lit), "a word starting with a wildcard that is not quoted can expand into a flag, which is not modelled", m)
    case T.Pwsh{}:
      r3.bad(r3.pq(args), "Windows PowerShell 5.1 passes an empty argument, or one holding a double quote, to a program dropped or split, which is not modelled", m)

def r3.ok(ok: Bool, why: String) -> T.Meaning:
  match ok:
    case True{}:
      Model.inert()
    case False{}:
      Model.unknown(why)

# a value is - (standard input or output) or starts with neither - nor @
# (@ reads a file; a value starting with - may be a flag to the program)
def r3.val_ok(+v: String) -> Bool:
  String.eq(v, "-") || (Bool.not(String.starts_with(v, "-")) && Bool.not(String.starts_with(v, "@")))

def r3.vals_ok(xs: List<&2, T.Arg>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case T.Arg{k, +v} <> t:
      r3.val_ok(v) && r3.vals_ok(t)

def r3.no_at(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      Bool.not(String.starts_with(x, "@")) && r3.no_at(t)

# every method is GET or HEAD
def r3.methods(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      (String.eq(x, "GET") || String.eq(x, "HEAD")) && r3.methods(t)

# no header asks the server to read the call as another method
# (X-HTTP-Method-Override and the like)
def r3.hdr_ok(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      Bool.not(String.contains(Model.glob.lower(x, ""), "override")) && r3.hdr_ok(t)

def r3.digits(+s: String) -> Bool:
  Bool.not(String.is_empty(s)) && Model.all_digits(s)

def r3.all_digits(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      r3.digits(x) && r3.all_digits(t)

# every operand is one of the words in ok (compared lower-cased)
def r3.ops_in(xs: List<&2, String>, +ok: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      Model.elem(Model.glob.lower(x, ""), ok) && r3.ops_in(t, ok)

def r3.one(xs: List<&2, String>) -> Bool:
  match xs:
    case Con{x, Nil{}}:
      True{}
    case _:
      False{}

# s holds at least one character, and only characters of cs
def r3.only.go(s: String, +cs: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Model.has_char(cs, c) && r3.only.go(t, cs)

def r3.only(+s: String, +cs: String) -> Bool:
  Bool.not(String.is_empty(s)) && r3.only.go(s, cs)

def r3.keep(drop: Bool, x: String, acc: List<&2, String>) -> List<&2, String>:
  match drop:
    case True{}:
      acc
    case False{}:
      x <> acc

def r3.hash(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      Model.has_char(x, Chr{35}) || r3.hash(t)

# ---------------------------------------------------------------------------
# gh: known with no file action only for pr view, list, diff, checks and
# status; issue view, list and status; run view and list; repo view;
# release view and list; workflow view and list; and api ENDPOINT with GET
# or HEAD. -w is --workflow only in run list (elsewhere it is --web, which
# opens a browser). api's -f, -F, --field, --raw-field and --input (they
# send a body, so a POST), --web, any value or operand starting with @
# (reads a file), auth, extension, alias, download and checkout forms and
# every other subcommand are Unknown.

type GhK is Data:
  GhK.No{}
  GhK.Read{}
  GhK.RunList{}

def gh.if(ok: Bool) -> GhK:
  match ok:
    case True{}:
      GhK.Read{}
    case False{}:
      GhK.No{}

def gh.run(+sub: String) -> GhK:
  match sub:
    case "view":
      GhK.Read{}
    case "list":
      GhK.RunList{}
    case _:
      GhK.No{}

def gh.kind(+grp: String, +sub: String) -> GhK:
  match grp:
    case "pr":
      gh.if(Model.elem(sub, ["view", "list", "diff", "checks", "status"]))
    case "issue":
      gh.if(Model.elem(sub, ["view", "list", "status"]))
    case "run":
      gh.run(sub)
    case "repo":
      gh.if(String.eq(sub, "view"))
    case "release":
      gh.if(Model.elem(sub, ["view", "list"]))
    case "workflow":
      gh.if(Model.elem(sub, ["view", "list"]))
    case _:
      GhK.No{}

# the long flags whose value may stand in the next word (Model.longv)
def gh.longs() -> List<&2, String>:
  ["--repo", "--json", "--jq", "--template", "--limit", "--state", "--author", "--label", "--search", "--branch", "--status", "--attempt", "--color", "--workflow", "--header", "--method"]

def gh.flags() -> List<&2, T.Arg>:
  [T.Arg{"--repo=", "R"}, T.Arg{"--json=", "j"}, T.Arg{"--jq=", "q"}, T.Arg{"--template=", "t"}, T.Arg{"--limit=", "L"}, T.Arg{"--state=", "s"}, T.Arg{"--author=", "A"}, T.Arg{"--label=", "l"}, T.Arg{"--search=", "S"}, T.Arg{"--branch=", "b"}, T.Arg{"--status=", "u"}, T.Arg{"--attempt=", "a"}, T.Arg{"--color=", "c"}, T.Arg{"--comments", "C"}, T.Arg{"--log", "g"}, T.Arg{"--log-failed", "G"}, T.Arg{"--name-only", "n"}, T.Arg{"--patch", "p"}, T.Arg{"--exit-status", "e"}, T.Arg{"--required", "r"}, T.Arg{"--web=false", "W"}]

def gh.spec(w: Bool) -> Model.Spec:
  match w:
    case True{}:
      Model.spec("", "RqtLsAlSbaw", T.Arg{"--workflow=", "w"} <> gh.flags(), False{}, False{})
    case False{}:
      Model.spec("", "RqtLsAlSba", gh.flags(), False{}, False{})

def gh.read.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      r3.ok(r3.vals_ok(vs) && r3.no_at(ops), "a value starting with - or @ is not modelled (@ reads a file)")

def gh.grp(k: GhK, rest: List<&2, String>) -> T.Meaning:
  match k:
    case GhK.No{}:
      Model.unknown("only the read forms are modelled: pr view, list, diff, checks and status; issue view, list and status; run view and list; repo view; release and workflow view and list; and api with GET")
    case GhK.Read{}:
      gh.read.o(Model.parse(gh.spec(False{}), Model.longv(rest, gh.longs())))
    case GhK.RunList{}:
      gh.read.o(Model.parse(gh.spec(True{}), Model.longv(rest, gh.longs())))

# exactly one endpoint, not graphql (its queries go in fields, and a
# mutation changes the repository)
def gh.api.ep(xs: List<&2, String>) -> Bool:
  match xs:
    case Con{+e, Nil{}}:
      Bool.not(String.eq(e, "graphql")) && Bool.not(String.starts_with(e, "@"))
    case _:
      False{}

def gh.api.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, +vs, ops, lo}:
      r3.ok(r3.vals_ok(vs) && gh.api.ep(ops) && r3.methods(Model.vals_for(vs, "X")) && r3.hdr_ok(Model.vals_for(vs, "H")), "only a GET or HEAD of one REST endpoint, with no fields (-f, -F, --input), no method-override header and no value starting with - or @, is modelled")

def gh.api(args: List<&2, String>) -> T.Meaning:
  gh.api.o(Model.parse(Model.spec("i", "HXqt", [T.Arg{"--paginate", "P"}, T.Arg{"--slurp", "Z"}, T.Arg{"--include", "i"}, T.Arg{"--header=", "H"}, T.Arg{"--method=", "X"}, T.Arg{"--jq=", "q"}, T.Arg{"--template=", "t"}], False{}, False{}), Model.longv(args, gh.longs())))

def gh.two(+a: String, +b: String, rest: List<&2, String>) -> T.Meaning:
  match a:
    case "api":
      gh.api(b <> rest)
    case _:
      gh.grp(gh.kind(a, b), rest)

def gh.args(args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      Model.unknown("gh with no subcommand is not modelled")
    case Con{a, Nil{}}:
      r3.ok(String.eq(a, "--version"), "only gh --version is modelled as one word")
    case Con{a, Con{b, rest}}:
      gh.two(a, b, rest)

# ---------------------------------------------------------------------------
# curl: known when every URL starts with http:// or https://, the method is
# GET or HEAD and only the flags below are used. -o FILE / --output FILE and
# -D FILE / --dump-header FILE write FILE (- and /dev/null write nothing).
# Data, form, upload, config, cookie, netrc, remote-name, create-dirs,
# trace and stderr flags, another scheme or a URL with no scheme, -X other
# than GET or HEAD, a value starting with - or @, a method-override header,
# %output in --write-out (it writes a file) and a wildcard or # in an output
# name are Unknown.

def curl.longs() -> List<&2, String>:
  ["--max-time", "--connect-timeout", "--retry", "--user-agent", "--referer", "--header", "--write-out", "--user", "--proxy", "--url", "--request", "--output", "--dump-header"]

def curl.spec() -> Model.Spec:
  Model.spec("sSLfiIvkq", "mAeHwuxXoD", [T.Arg{"--silent", "s"}, T.Arg{"--show-error", "S"}, T.Arg{"--location", "L"}, T.Arg{"--fail", "f"}, T.Arg{"--fail-with-body", "F"}, T.Arg{"--include", "i"}, T.Arg{"--head", "I"}, T.Arg{"--verbose", "v"}, T.Arg{"--insecure", "k"}, T.Arg{"--compressed", "z"}, T.Arg{"--disable", "q"}, T.Arg{"--max-time=", "m"}, T.Arg{"--connect-timeout=", "c"}, T.Arg{"--retry=", "r"}, T.Arg{"--user-agent=", "A"}, T.Arg{"--referer=", "e"}, T.Arg{"--header=", "H"}, T.Arg{"--write-out=", "w"}, T.Arg{"--user=", "u"}, T.Arg{"--proxy=", "x"}, T.Arg{"--url=", "U"}, T.Arg{"--request=", "X"}, T.Arg{"--output=", "o"}, T.Arg{"--dump-header=", "D"}], False{}, False{})

def curl.url(+u: String) -> Bool:
  String.starts_with(u, "http://") || String.starts_with(u, "https://")

def curl.urls(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      curl.url(x) && curl.urls(t)

def curl.wout(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      Bool.not(String.contains(Model.glob.lower(x, ""), "%output")) && curl.wout(t)

def curl.ok(+vs: List<&2, T.Arg>, +urls: List<&2, String>) -> Bool:
  r3.vals_ok(vs) && Bool.not(List.is_empty(&2, String, urls)) && curl.urls(urls) && r3.methods(Model.vals_for(vs, "X")) && r3.hdr_ok(Model.vals_for(vs, "H")) && curl.wout(Model.vals_for(vs, "w")) && Model.nums_ok(vs, "r")

# the -o and -D targets that write a file (not - or /dev/null)
def curl.outs(xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +x <> t:
      curl.outs(t, r3.keep(String.eq(x, "-") || String.eq(x, "/dev/null"), x, acc))

def curl.w(bad: Bool, outs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match bad:
    case True{}:
      Model.unknown("an output name with a wildcard or # is not modelled")
    case False{}:
      Model.join(Model.inert(), Model.paths(outs, Model.AKind.Write{}, cwds, home))

def curl.k(ok: Bool, +outs: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok:
    case False{}:
      Model.unknown("only GET or HEAD of http:// or https:// URLs with the modelled flags is understood (no data, upload, config, cookie or remote-name flag, no value starting with - or @, no method-override header, no %output in --write-out)")
    case True{}:
      curl.w(Model.any_glob(outs) || r3.hash(outs), outs, cwds, home)

def curl.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, +vs, ops, lo}:
      curl.k(curl.ok(vs, List.append(&2, String, ops, Model.vals_for(vs, "U"))), curl.outs(List.append(&2, String, Model.vals_for(vs, "o"), Model.vals_for(vs, "D")), []), cwds, home)

def tx3.curl(+cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  curl.o(Model.parse(curl.spec(), Model.longv(args, curl.longs())), cwds, home)

# ---------------------------------------------------------------------------
# rg: like grep -r. A ReadTree of each path operand, or of each possible
# folder when there is none; the first operand is the pattern unless -e,
# --files or --type-list is given. --pre, --pre-glob, -z/--search-zip,
# --ignore-file, --hostname-bin (they run programs or read other files) and
# every flag not listed are Unknown. A wildcard in the pattern or in a value
# in its own word reads the folder it can reach, unless it was quoted
# (grep's rule, round 2 P10).

def rg.longs() -> List<&2, String>:
  ["--regexp", "--glob", "--type", "--type-not", "--after-context", "--before-context", "--context", "--max-count", "--color"]

def rg.spec() -> Model.Spec:
  Model.spec("inlcwFuSsvoHNU", "egtTABCm", [T.Arg{"--ignore-case", "i"}, T.Arg{"--line-number", "n"}, T.Arg{"--files-with-matches", "l"}, T.Arg{"--count", "c"}, T.Arg{"--word-regexp", "w"}, T.Arg{"--fixed-strings", "F"}, T.Arg{"--smart-case", "S"}, T.Arg{"--case-sensitive", "s"}, T.Arg{"--invert-match", "v"}, T.Arg{"--only-matching", "o"}, T.Arg{"--with-filename", "H"}, T.Arg{"--no-line-number", "N"}, T.Arg{"--no-heading", "x"}, T.Arg{"--multiline", "U"}, T.Arg{"--hidden", "h"}, T.Arg{"--no-ignore", "y"}, T.Arg{"--json", "j"}, T.Arg{"--files", "1"}, T.Arg{"--type-list", "2"}, T.Arg{"--regexp=", "e"}, T.Arg{"--glob=", "g"}, T.Arg{"--type=", "t"}, T.Arg{"--type-not=", "T"}, T.Arg{"--after-context=", "A"}, T.Arg{"--before-context=", "B"}, T.Arg{"--context=", "C"}, T.Arg{"--max-count=", "m"}, T.Arg{"--color=", "K"}], False{}, True{})

# no operand is the pattern (-e, --files, --type-list)
def rg.nopat(+fl: String) -> Bool:
  Model.has_char(fl, 'e') || Model.has_char(fl, '1') || Model.has_char(fl, '2')

def rg.run(tl: Bool, files: Maybe<&2, List<&2, String>>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match tl:
    case True{}:
      Model.inert()
    case False{}:
      grep.run(files, True{}, sh, cwds, home)

def rg.o(o: Model.Opts, +sh: T.Shell, +cwds: List<&2, String>, +home: String, lit: List<&2, String>) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{+fl, vs, +ops, lo}:
      grep.num(Model.nums_ok(vs, "ABCm"), Model.join(rg.run(Model.has_char(fl, '2'), grep.files(rg.nopat(fl), ops), sh, cwds, home), Model.wglobs(Model.unlit(List.append(&2, String, grep.pat(rg.nopat(fl), ops), lo), lit), sh, cwds, home)))

# ---------------------------------------------------------------------------
# npm view NAME [FIELD] [--json] and npm outdated [--json --long]: they read
# package.json, node_modules and the network and run no scripts, so a Read
# of package.json in each possible folder. NAME must be a registry name (a
# scope's @x/name, a version after @): a path, URL, git, GitHub (x/y) or
# file spec would make npm fetch a repository or read a file.

def npm.name.k(at: Bool, +n: String) -> Bool:
  Bool.not(String.is_empty(n)) && Bool.not(String.starts_with(n, ".")) && Bool.not(String.starts_with(n, "-")) && Bool.not(String.starts_with(n, "~")) && Bool.not(String.starts_with(n, "/")) && Bool.not(Model.has_char(n, Chr{58})) && Bool.not(Model.has_char(n, Chr{35})) && Bool.not(Model.has_char(n, Chr{92})) && (at || Bool.not(Model.has_char(n, Chr{47}))) && Bool.not(String.ends_with(n, ".tgz")) && Bool.not(String.ends_with(n, ".tar")) && Bool.not(String.ends_with(n, ".gz"))

def npm.name(+n: String) -> Bool:
  npm.name.k(String.starts_with(n, "@"), n)

def npm.view.ops(xs: List<&2, String>) -> Bool:
  match xs:
    case Con{+n, Nil{}}:
      npm.name(n)
    case Con{+n, Con{f, Nil{}}}:
      npm.name(n)
    case _:
      False{}

def npm.read.k(ok: Bool, why: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok:
    case True{}:
      Model.join(Model.inert(), Model.path(Model.AKind.Read{}, cwds, home, "package.json"))
    case False{}:
      Model.unknown(why)

def npm.view.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      npm.read.k(npm.view.ops(ops), "only npm view NAME [FIELD] with a registry package name is modelled (no path, URL, git or file spec)", cwds, home)

def npm.out.o(o: Model.Opts, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      npm.read.k(List.is_empty(&2, String, ops), "operands are not modelled", cwds, home)

def npm.view(+cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("npm view: ", r3.bad(Model.any_glob(args), "wildcards (*, ? or [) are not modelled here", npm.view.o(Model.parse(Model.spec("", "", [T.Arg{"--json", "j"}], False{}, False{}), args), cwds, home)))

def npm.outdated(+cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  Model.why_prefix("npm outdated: ", r3.bad(Model.any_glob(args), "wildcards (*, ? or [) are not modelled here", npm.out.o(Model.parse(Model.spec("", "", [T.Arg{"--json", "j"}, T.Arg{"--long", "l"}], False{}, False{}), args), cwds, home)))

# ---------------------------------------------------------------------------
# Small read-only commands (P8). None of them has a file action, except
# where /R FOLDER, which reads that folder's tree.

# ps [aux | ax | auxw | auxww] [-e -f -o FORMAT -p PID --sort KEY]
def ps.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      r3.ok(r3.ops_in(ops, ["aux", "ax", "auxw", "auxww"]) && Model.nums_ok(vs, "p"), "only aux, ax, -e, -f, -o FORMAT, -p PID and --sort KEY are modelled")

# pgrep [-a -l -f -x -u USER] PATTERN
def pgrep.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      r3.ok(r3.one(ops), "exactly one pattern is modelled")

# netstat with Windows and Linux letters; -p is read as a flag and the
# protocol as an operand. An interval operand repeats forever: not modelled.
def netstat.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, ops, lo}:
      r3.ok(r3.ops_in(ops, ["tcp", "udp", "tcpv6", "udpv6", "ip", "ipv6", "icmp", "icmpv6"]), "only protocol names are modelled as operands")

# lsof -n -P -t (joined too), -i [SPEC] or -iSPEC (SPEC :PORT, TCP..., UDP...,
# 4 or 6), -p PID or -pPID; no paths
type LsW is Data:
  LsW.No{}
  LsW.I{}
  LsW.P{}
  LsW.Bad{}

def lsof.spec(+w: String) -> Bool:
  String.starts_with(w, ":") || String.starts_with(Model.glob.lower(w, ""), "tcp") || String.starts_with(Model.glob.lower(w, ""), "udp") || String.eq(w, "4") || String.eq(w, "6")

def lsof.word.k(isi: Bool, isp: Bool, ji: Bool, jp: Bool, fl: Bool) -> LsW:
  match isi isp ji jp fl:
    case True{} _ _ _ _:
      LsW.I{}
    case False{} True{} _ _ _:
      LsW.P{}
    case False{} False{} True{} _ _:
      LsW.No{}
    case False{} False{} False{} True{} _:
      LsW.No{}
    case False{} False{} False{} False{} True{}:
      LsW.No{}
    case False{} False{} False{} False{} False{}:
      LsW.Bad{}

def lsof.word(+w: String) -> LsW:
  lsof.word.k(String.eq(w, "-i"), String.eq(w, "-p"), String.starts_with(w, "-i") && lsof.spec(String.drop(w, 2n)), String.starts_with(w, "-p") && r3.digits(String.drop(w, 2n)), String.starts_with(w, "-") && r3.only(String.drop(w, 1n), "nPt"))

def lsof.pid(ok: Bool) -> LsW:
  match ok:
    case True{}:
      LsW.No{}
    case False{}:
      LsW.Bad{}

def lsof.opt(sp: Bool, +w: String) -> LsW:
  match sp:
    case True{}:
      LsW.No{}
    case False{}:
      lsof.word(w)

def lsof.step(st: LsW, +w: String) -> LsW:
  match st:
    case LsW.No{}:
      lsof.word(w)
    case LsW.I{}:
      lsof.opt(lsof.spec(w), w)
    case LsW.P{}:
      lsof.pid(r3.digits(w))
    case LsW.Bad{}:
      LsW.Bad{}

def lsof.go(ws: List<&2, String>, st: LsW) -> LsW:
  match ws:
    case Nil{}:
      st
    case w <> t:
      lsof.go(t, lsof.step(st, w))

def lsof.fin(st: LsW) -> T.Meaning:
  match st:
    case LsW.No{}:
      Model.inert()
    case LsW.I{}:
      Model.inert()
    case LsW.P{}:
      Model.unknown("the flag -p needs a process number")
    case LsW.Bad{}:
      Model.unknown("only -n, -P, -t, -i [:PORT, TCP or UDP] and -p PID are modelled (no paths)")

# tasklist [/FI FILTER] [/FO FORMAT] [/NH] [/V] (any case; //FI too, as
# Git Bash users write it); /S, /U and /P (another computer) are Unknown
type TlW is Data:
  TlW.No{}
  TlW.V{}
  TlW.Bad{}

def tl.word.k(v: Bool, b: Bool) -> TlW:
  match v b:
    case True{} _:
      TlW.V{}
    case False{} True{}:
      TlW.No{}
    case False{} False{}:
      TlW.Bad{}

def tl.word(+l: String) -> TlW:
  tl.word.k(Model.elem(l, ["/fi", "//fi", "/fo", "//fo"]), Model.elem(l, ["/nh", "//nh", "/v", "//v"]))

def tl.step(st: TlW, w: String) -> TlW:
  match st:
    case TlW.No{}:
      tl.word(Model.glob.lower(w, ""))
    case TlW.V{}:
      TlW.No{}
    case TlW.Bad{}:
      TlW.Bad{}

def tl.go(ws: List<&2, String>, st: TlW) -> TlW:
  match ws:
    case Nil{}:
      st
    case w <> t:
      tl.go(t, tl.step(st, w))

def tl.fin(st: TlW) -> T.Meaning:
  match st:
    case TlW.No{}:
      Model.inert()
    case TlW.V{}:
      Model.unknown("/FI and /FO need a value")
    case TlW.Bad{}:
      Model.unknown("only /FI FILTER, /FO FORMAT, /NH and /V are modelled")

# where [/R FOLDER] NAME...: a ReadTree of FOLDER (it lists the files below
# it), else no file action. Another / or - word and a PATH:NAME form are
# Unknown.
type WhW is Data:
  WhW.Mk{ok: Bool, want: Bool, dirs: List<&2, String>, names: List<&2, String>}

def wh.word.k(isr: Bool, odd: Bool, ok: Bool, dirs: List<&2, String>, names: List<&2, String>, w: String) -> WhW:
  match isr odd:
    case True{} _:
      WhW.Mk{ok, True{}, dirs, names}
    case False{} True{}:
      WhW.Mk{False{}, False{}, dirs, names}
    case False{} False{}:
      WhW.Mk{ok, False{}, dirs, w <> names}

def wh.step.k(want: Bool, ok: Bool, dirs: List<&2, String>, names: List<&2, String>, +w: String) -> WhW:
  match want:
    case True{}:
      WhW.Mk{ok, False{}, w <> dirs, names}
    case False{}:
      wh.word.k(Model.elem(Model.glob.lower(w, ""), ["/r", "//r"]), String.starts_with(w, "/") || String.starts_with(w, "-") || Model.has_char(w, Chr{58}), ok, dirs, names, w)

def wh.step(st: WhW, +w: String) -> WhW:
  match st:
    case WhW.Mk{ok, want, dirs, names}:
      wh.step.k(want, ok, dirs, names, w)

def wh.go(ws: List<&2, String>, st: WhW) -> WhW:
  match ws:
    case Nil{}:
      st
    case w <> t:
      wh.go(t, wh.step(st, w))

def wh.fin.k(ok: Bool, want: Bool, none: Bool, dirs: List<&2, String>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match ok want none:
    case True{} False{} False{}:
      Model.join(Model.inert(), Model.rpaths(dirs, sh, Model.AKind.ReadTree{}, Model.AKind.ReadTree{}, cwds, home))
    case _ _ _:
      Model.unknown("only where [/R FOLDER] NAME... is modelled (no other flag, no PATH:NAME form)")

def wh.fin(st: WhW, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match st:
    case WhW.Mk{ok, want, dirs, +names}:
      wh.fin.k(ok, want, List.is_empty(&2, String, names), dirs, sh, cwds, home)

# pip and pip3: list [--outdated --format X], show NAME..., freeze, --version
def pip.show.o(o: Model.Opts) -> T.Meaning:
  match o:
    case Model.Opts.Bad{why}:
      Model.unknown(why)
    case Model.Opts.Ok{fl, vs, +ops, lo}:
      r3.ok(Bool.not(List.is_empty(&2, String, ops)), "show needs a package name")

def pip.sub(+sub: String, args: List<&2, String>) -> T.Meaning:
  match sub:
    case "list":
      none.o(Model.parse(Model.spec("o", "", [T.Arg{"--outdated", "o"}, T.Arg{"--format=", "f"}], False{}, False{}), Model.longv(args, ["--format"])))
    case "show":
      pip.show.o(Model.parse(Model.spec("", "", [], False{}, False{}), args))
    case "freeze":
      none.o(Model.parse(Model.spec("", "", [], False{}, False{}), args))
    case "--version":
      none.o(Model.parse(Model.spec("", "", [], False{}, False{}), args))
    case _:
      Model.unknown("only pip list, show and freeze are modelled")

def pip.args(args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      Model.unknown("pip with no subcommand is not modelled")
    case sub <> rest:
      pip.sub(sub, rest)

# ---------------------------------------------------------------------------
# The round-3 commands by name (tx3): which shell has each name. Under
# PowerShell curl is Invoke-WebRequest, ps is Get-Process and where is
# Where-Object, so only curl.exe and where.exe are read there.

type Tx3 is Data:
  Tx3.Gh{}
  Tx3.Curl{}
  Tx3.Rg{}
  Tx3.Df{}
  Tx3.Free{}
  Tx3.Uptime{}
  Tx3.Id{}
  Tx3.Ps{}
  Tx3.Pgrep{}
  Tx3.Tasklist{}
  Tx3.Netstat{}
  Tx3.Ss{}
  Tx3.Lsof{}
  Tx3.Where{}
  Tx3.Wait{}
  Tx3.Pip{}
  Tx3.No{}

type Tx3E is Data:
  Tx3E.Mk{name: String, k: Tx3, bash: Bool, pwsh: Bool}

def r3.table() -> List<&2, Tx3E>:
  [Tx3E.Mk{"gh", Tx3.Gh{}, True{}, True{}}, Tx3E.Mk{"gh.exe", Tx3.Gh{}, True{}, True{}}, Tx3E.Mk{"curl", Tx3.Curl{}, True{}, False{}}, Tx3E.Mk{"curl.exe", Tx3.Curl{}, True{}, True{}}, Tx3E.Mk{"rg", Tx3.Rg{}, True{}, True{}}, Tx3E.Mk{"rg.exe", Tx3.Rg{}, True{}, True{}}, Tx3E.Mk{"df", Tx3.Df{}, True{}, False{}}, Tx3E.Mk{"free", Tx3.Free{}, True{}, False{}}, Tx3E.Mk{"uptime", Tx3.Uptime{}, True{}, False{}}, Tx3E.Mk{"id", Tx3.Id{}, True{}, False{}}, Tx3E.Mk{"ps", Tx3.Ps{}, True{}, False{}}, Tx3E.Mk{"pgrep", Tx3.Pgrep{}, True{}, False{}}, Tx3E.Mk{"tasklist", Tx3.Tasklist{}, True{}, True{}}, Tx3E.Mk{"tasklist.exe", Tx3.Tasklist{}, True{}, True{}}, Tx3E.Mk{"netstat", Tx3.Netstat{}, True{}, True{}}, Tx3E.Mk{"netstat.exe", Tx3.Netstat{}, True{}, True{}}, Tx3E.Mk{"ss", Tx3.Ss{}, True{}, False{}}, Tx3E.Mk{"lsof", Tx3.Lsof{}, True{}, False{}}, Tx3E.Mk{"where", Tx3.Where{}, True{}, False{}}, Tx3E.Mk{"where.exe", Tx3.Where{}, True{}, True{}}, Tx3E.Mk{"wait", Tx3.Wait{}, True{}, False{}}, Tx3E.Mk{"pip", Tx3.Pip{}, True{}, True{}}, Tx3E.Mk{"pip3", Tx3.Pip{}, True{}, True{}}]

def r3.on(sh: T.Shell, b: Bool, p: Bool) -> Bool:
  match sh:
    case T.Bash{}:
      b
    case T.Pwsh{}:
      p

def r3.hit(h: Bool, k: Tx3, rest: Tx3) -> Tx3:
  match h:
    case True{}:
      k
    case False{}:
      rest

def r3.find(xs: List<&2, Tx3E>, +sh: T.Shell, +w: String) -> Tx3:
  match xs:
    case Nil{}:
      Tx3.No{}
    case Tx3E.Mk{n, k, b, p} <> t:
      r3.hit(String.eq(n, w) && r3.on(sh, b, p), k, r3.find(t, sh, w))

def tx3.m(k: Tx3, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>, args: List<&2, String>) -> Maybe<&2, T.Meaning>:
  match k:
    case Tx3.No{}:
      None{}
    case Tx3.Gh{}:
      Some{gh.args(args)}
    case Tx3.Curl{}:
      Some{tx3.curl(cwds, home, args)}
    case Tx3.Rg{}:
      Some{rg.o(Model.parse(rg.spec(), Model.longv(args, rg.longs())), sh, cwds, home, lit)}
    case Tx3.Df{}:
      Some{inert.o(Model.parse(Model.spec("hTkmaPil", "", [T.Arg{"--human-readable", "h"}, T.Arg{"--total", "c"}], False{}, True{}), args))}
    case Tx3.Free{}:
      Some{none.o(Model.parse(Model.spec("hmgbkt", "", [T.Arg{"--human", "h"}], False{}, False{}), args))}
    case Tx3.Uptime{}:
      Some{none.o(Model.parse(Model.spec("ps", "", [T.Arg{"--pretty", "p"}, T.Arg{"--since", "s"}], False{}, False{}), args))}
    case Tx3.Id{}:
      Some{inert.o(Model.parse(Model.spec("ugGnrz", "", [], False{}, False{}), args))}
    case Tx3.Ps{}:
      Some{ps.o(Model.parse(Model.spec("ef", "op", [T.Arg{"--sort=", "s"}], False{}, False{}), Model.longv(args, ["--sort"])))}
    case Tx3.Pgrep{}:
      Some{pgrep.o(Model.parse(Model.spec("alfx", "u", [], False{}, False{}), args))}
    case Tx3.Tasklist{}:
      Some{tl.fin(tl.go(args, TlW.No{}))}
    case Tx3.Netstat{}:
      Some{netstat.o(Model.parse(Model.spec("abefnoqrstxyulpiW", "", [], False{}, False{}), args))}
    case Tx3.Ss{}:
      Some{none.o(Model.parse(Model.spec("ltunpas", "", [], False{}, False{}), args))}
    case Tx3.Lsof{}:
      Some{lsof.fin(lsof.go(args, LsW.No{}))}
    case Tx3.Where{}:
      Some{wh.fin(wh.go(args, WhW.Mk{True{}, False{}, [], []}), sh, cwds, home)}
    case Tx3.Wait{}:
      Some{r3.ok(r3.all_digits(args), "only wait with no operand or with process numbers is modelled")}
    case Tx3.Pip{}:
      Some{pip.args(args)}

def tx3.g(m: Maybe<&2, T.Meaning>, +name: String, sh: T.Shell, args: List<&2, String>, +lit: List<&2, String>) -> Maybe<&2, T.Meaning>:
  match m:
    case None{}:
      None{}
    case Some{x}:
      Some{Model.why_prefix(name ++ ": ", r3.guard(sh, args, lit, x))}

# the meaning of a round-3 command under shell sh (name lower-cased under
# PowerShell), or None when name is not one of them there
def tx3(+sh: T.Shell, +name: String, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>, +args: List<&2, String>) -> Maybe<&2, T.Meaning>:
  tx3.g(tx3.m(r3.find(r3.table(), sh, name), sh, cwds, home, lit, args), name, sh, args, lit)
