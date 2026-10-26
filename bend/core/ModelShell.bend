# bend-guard: what a shell command does (plan.md Task 1.7; design.md
# component 2). Model.shell lexes the text by shell (with the home folder),
# splits it into simple commands, models each in order while following cd,
# and joins the actions. Model.next_cwds gives the possible current folders
# after the text. A command or text that is not modelled and names
# bend-guard's approve tool gets a write of bend-guard's state folder as a
# known part (ModelGit.approve.other), so self-protection denies it.
# Imported as ModelShell; other files write
# ModelShell.Model.shell(...), ModelShell.Model.next_cwds(...).
# Model.bend is imported as MH here, because this file defines Model.command
# and friends itself.

import Base
import ./Types.bend as T
import ./Path.bend as Path
import ./Lex.bend as Lex
import ./Cmd.bend as Cmd
import ./Model.bend as MH
import ./ModelFiles.bend as ModelFiles
import ./ModelGit.bend as ModelGit

# ---------------------------------------------------------------------------
# One command (argv[0] is the name)

# --version and friends: one word in the list, nothing else
def ver.is(args: List<&2, String>, +vs: List<&2, String>) -> Bool:
  match args:
    case Con{x, Nil{}}:
      MH.elem(x, vs)
    case _:
      False{}

def ver.if(ok: Bool, m: T.Meaning) -> T.Meaning:
  match ok:
    case True{}:
      MH.inert()
    case False{}:
      m

# npm ls / npm list with --all, --depth=N, --json, --long, --parseable and
# package names: prints the installed tree
def npm.ls.o(o: MH.Opts) -> T.Meaning:
  match o:
    case MH.Opts.Bad{why}:
      MH.unknown(why)
    case MH.Opts.Ok{fl, vs, ops, lo}:
      MH.inert()

def npm.ls(rest: List<&2, String>) -> T.Meaning:
  MH.why_prefix("npm ls: ", npm.ls.o(MH.parse(MH.spec("a", "", [T.Arg{"--all", "a"}, T.Arg{"--depth=", "d"}, T.Arg{"--json", "j"}, T.Arg{"--long", "l"}, T.Arg{"--parseable", "p"}], False{}, False{}), rest)))

# npm.sub: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KShNpmSub is Data:
  KShNpmSub.Ls{}
  KShNpmSub.View{}
  KShNpmSub.Outdated{}
  KShNpmSub.Rest{}

type KShNpmSubE is Data:
  KShNpmSubE.Mk{name: String, k: KShNpmSub}

def npm.sub.tab() -> List<&2, KShNpmSubE>:
  [KShNpmSubE.Mk{"ls", KShNpmSub.Ls{}}, KShNpmSubE.Mk{"list", KShNpmSub.Ls{}}, KShNpmSubE.Mk{"view", KShNpmSub.View{}}, KShNpmSubE.Mk{"info", KShNpmSub.View{}}, KShNpmSubE.Mk{"show", KShNpmSub.View{}}, KShNpmSubE.Mk{"v", KShNpmSub.View{}}, KShNpmSubE.Mk{"outdated", KShNpmSub.Outdated{}}]

def npm.sub.go(xs: List<&2, KShNpmSubE>, hit: Bool, k: KShNpmSub, +w: String) -> KShNpmSub:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KShNpmSub.Rest{}
    case KShNpmSubE.Mk{n, k2} <> t False{}:
      npm.sub.go(t, String.eq(n, w), k2, w)

def npm.sub.find(xs: List<&2, KShNpmSubE>, +w: String) -> KShNpmSub:
  npm.sub.go(xs, False{}, KShNpmSub.Rest{}, w)

def npm.sub.k(key: KShNpmSub, +sub: String, +rest: List<&2, String>, sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KShNpmSub.Ls{}:
      npm.ls(rest)
    case KShNpmSub.View{}:
      ModelGit.claude.pick(ModelGit.claude.any(rest), home, ModelFiles.npm.view(cwds, home, rest))
    case KShNpmSub.Outdated{}:
      ModelFiles.npm.outdated(cwds, home, rest)
    case KShNpmSub.Rest{}:
      ver.if(ver.is(sub <> rest, ["--version", "-v"]), ModelGit.npm.claude(sh, cwds, home, sub <> rest))

def npm.sub(+sub: String, +rest: List<&2, String>, sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  npm.sub.k(npm.sub.find(npm.sub.tab(), sub), sub, rest, sh, cwds, home)

# npm --version, npm -v and npm ls here; the rest is ModelGit's
def npm.pre(sh: T.Shell, +cwds: List<&2, String>, +home: String, args: List<&2, String>) -> T.Meaning:
  match args:
    case Nil{}:
      ModelGit.npm.claude(sh, cwds, home, [])
    case sub <> rest:
      npm.sub(sub, rest, sh, cwds, home)

# node --version / -v; the rest is ModelGit's
def node.pre(sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  ver.if(ver.is(args, ["--version", "-v"]), ModelGit.node(sh, cwds, home, args))

# git --version; the rest is ModelGit's
def git.pre(sh: T.Shell, +cwds: List<&2, String>, +home: String, +args: List<&2, String>) -> T.Meaning:
  ver.if(ver.is(args, ["--version"]), ModelGit.git(sh, cwds, home, args))

# Bash, a name not listed: node's own program (node.exe, or a path to
# C:\Program Files\nodejs\node.exe) goes to the node model; anything else is
# not modelled, and is bend-guard's approve step (the user's alone) when one of its
# words names the approve tool (ModelGit.approve.other)
def cmd.bash.other(isnode: Bool, +name: String, args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match isnode:
    case True{}:
      ModelGit.node(T.Bash{}, cwds, home, args)
    case False{}:
      ModelGit.approve.cmd(home, name, args, ModelFiles.other(name))

# Bash, a name not listed above: the round-2 commands (ModelFiles.tx.bash),
# then the round-3 commands (ModelFiles.tx3), then the other names
def cmd.bash.r3(m: Maybe<&2, T.Meaning>, +name: String, args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match m:
    case Some{x}:
      x
    case None{}:
      cmd.bash.other(ModelGit.node_exe(cwds, home, name), name, args, cwds, home)

def cmd.bash.tx(m: Maybe<&2, T.Meaning>, +name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>) -> T.Meaning:
  match m:
    case Some{x}:
      x
    case None{}:
      cmd.bash.r3(ModelFiles.tx3(T.Bash{}, name, cwds, home, lit, args), name, args, cwds, home)

# Bash: the commands of plan Task 1.7, git, npm and node, python --version,
# and the round-2 commands; names match exactly
# unset NAME...: plain names that may be assigned (Lex.var.name_ok) change no
# file; Lex has already forgotten them
def unset.ok(args: List<&2, String>) -> Bool:
  match args:
    case Nil{}:
      True{}
    case +a <> t:
      Nat.is_eq(Lex.var.ilen(a), String.length(a)) && Bool.not(String.is_empty(a)) && Lex.var.name_ok(a) && unset.ok(t)

def unset(args: List<&2, String>) -> T.Meaning:
  ver.if(unset.ok(args), MH.unknown("unset: only plain variable names are modelled"))

# lit: words whose wildcards were all quoted (Lex.LexOut), which bash does
# not expand (grep's patterns)
# cmd.bash: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KShCmdBash is Data:
  KShCmdBash.Rm{}
  KShCmdBash.Mv{}
  KShCmdBash.Cp{}
  KShCmdBash.Cat{}
  KShCmdBash.Head{}
  KShCmdBash.Tail{}
  KShCmdBash.Ls{}
  KShCmdBash.Grep{}
  KShCmdBash.Unset{}
  KShCmdBash.Mkdir{}
  KShCmdBash.Touch{}
  KShCmdBash.Cd{}
  KShCmdBash.Echo{}
  KShCmdBash.Printf{}
  KShCmdBash.Ln{}
  KShCmdBash.Git{}
  KShCmdBash.Npm{}
  KShCmdBash.Node{}
  KShCmdBash.Python{}
  KShCmdBash.Rest{}

type KShCmdBashE is Data:
  KShCmdBashE.Mk{name: String, k: KShCmdBash}

def cmd.bash.tab() -> List<&2, KShCmdBashE>:
  [KShCmdBashE.Mk{"rm", KShCmdBash.Rm{}}, KShCmdBashE.Mk{"mv", KShCmdBash.Mv{}}, KShCmdBashE.Mk{"cp", KShCmdBash.Cp{}}, KShCmdBashE.Mk{"cat", KShCmdBash.Cat{}}, KShCmdBashE.Mk{"head", KShCmdBash.Head{}}, KShCmdBashE.Mk{"tail", KShCmdBash.Tail{}}, KShCmdBashE.Mk{"ls", KShCmdBash.Ls{}}, KShCmdBashE.Mk{"grep", KShCmdBash.Grep{}}, KShCmdBashE.Mk{"unset", KShCmdBash.Unset{}}, KShCmdBashE.Mk{"mkdir", KShCmdBash.Mkdir{}}, KShCmdBashE.Mk{"touch", KShCmdBash.Touch{}}, KShCmdBashE.Mk{"cd", KShCmdBash.Cd{}}, KShCmdBashE.Mk{"echo", KShCmdBash.Echo{}}, KShCmdBashE.Mk{"pwd", KShCmdBash.Echo{}}, KShCmdBashE.Mk{"true", KShCmdBash.Echo{}}, KShCmdBashE.Mk{"printf", KShCmdBash.Printf{}}, KShCmdBashE.Mk{"ln", KShCmdBash.Ln{}}, KShCmdBashE.Mk{"git", KShCmdBash.Git{}}, KShCmdBashE.Mk{"npm", KShCmdBash.Npm{}}, KShCmdBashE.Mk{"node", KShCmdBash.Node{}}, KShCmdBashE.Mk{"python", KShCmdBash.Python{}}, KShCmdBashE.Mk{"python3", KShCmdBash.Python{}}, KShCmdBashE.Mk{"py", KShCmdBash.Python{}}]

def cmd.bash.go(xs: List<&2, KShCmdBashE>, hit: Bool, k: KShCmdBash, +w: String) -> KShCmdBash:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KShCmdBash.Rest{}
    case KShCmdBashE.Mk{n, k2} <> t False{}:
      cmd.bash.go(t, String.eq(n, w), k2, w)

def cmd.bash.find(xs: List<&2, KShCmdBashE>, +w: String) -> KShCmdBash:
  cmd.bash.go(xs, False{}, KShCmdBash.Rest{}, w)

def cmd.bash.k(key: KShCmdBash, +name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>) -> T.Meaning:
  match key:
    case KShCmdBash.Rm{}:
      ModelFiles.rm(cwds, home, args)
    case KShCmdBash.Mv{}:
      ModelFiles.mv(cwds, home, args)
    case KShCmdBash.Cp{}:
      ModelFiles.cp(cwds, home, args)
    case KShCmdBash.Cat{}:
      ModelFiles.cat(T.Bash{}, cwds, home, args)
    case KShCmdBash.Head{}:
      ModelFiles.head(T.Bash{}, cwds, home, args)
    case KShCmdBash.Tail{}:
      ModelFiles.tail(T.Bash{}, cwds, home, args)
    case KShCmdBash.Ls{}:
      ModelFiles.ls(T.Bash{}, cwds, home, args)
    case KShCmdBash.Grep{}:
      ModelFiles.grep_lit(T.Bash{}, cwds, home, lit, args)
    case KShCmdBash.Unset{}:
      unset(args)
    case KShCmdBash.Mkdir{}:
      ModelFiles.mkdir(cwds, home, args)
    case KShCmdBash.Touch{}:
      ModelFiles.touch(cwds, home, args)
    case KShCmdBash.Cd{}:
      ModelFiles.cd(T.Bash{}, cwds, home, args)
    case KShCmdBash.Echo{}:
      MH.inert()
    case KShCmdBash.Printf{}:
      ModelFiles.printf(args)
    case KShCmdBash.Ln{}:
      ModelFiles.ln(args)
    case KShCmdBash.Git{}:
      git.pre(T.Bash{}, cwds, home, args)
    case KShCmdBash.Npm{}:
      npm.pre(T.Bash{}, cwds, home, args)
    case KShCmdBash.Node{}:
      node.pre(T.Bash{}, cwds, home, args)
    case KShCmdBash.Python{}:
      ver.if(ver.is(args, ["--version", "-V"]), cmd.bash.other(False{}, name, args, cwds, home))
    case KShCmdBash.Rest{}:
      cmd.bash.tx(ModelFiles.tx.bash(name, cwds, home, args), name, args, cwds, home, lit)

def cmd.bash(+name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>) -> T.Meaning:
  cmd.bash.k(cmd.bash.find(cmd.bash.tab(), name), name, args, cwds, home, lit)

# PowerShell, a name not listed below: the round-3 programs that exist
# there (ModelFiles.tx3: gh, curl.exe, rg, tasklist, netstat, where.exe,
# pip), then the cmdlets
def cmd.pwsh.r3(m: Maybe<&2, T.Meaning>, +cwds: List<&2, String>, +home: String, +name: String, args: List<&2, String>) -> T.Meaning:
  match m:
    case Some{x}:
      x
    case None{}:
      ModelGit.cmdlet(cwds, home, name, args)

# PowerShell (name lower-cased): cd and its aliases here; git, npm, node as
# under bash; every other name goes to ModelGit.cmdlet (plan Task 1.8), so
# the bash names of Task 1.7 are not read the bash way here
# cmd.pwsh: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KShCmdPwsh is Data:
  KShCmdPwsh.Cd{}
  KShCmdPwsh.Git{}
  KShCmdPwsh.Npm{}
  KShCmdPwsh.Node{}
  KShCmdPwsh.Rest{}

type KShCmdPwshE is Data:
  KShCmdPwshE.Mk{name: String, k: KShCmdPwsh}

def cmd.pwsh.tab() -> List<&2, KShCmdPwshE>:
  [KShCmdPwshE.Mk{"cd", KShCmdPwsh.Cd{}}, KShCmdPwshE.Mk{"chdir", KShCmdPwsh.Cd{}}, KShCmdPwshE.Mk{"sl", KShCmdPwsh.Cd{}}, KShCmdPwshE.Mk{"set-location", KShCmdPwsh.Cd{}}, KShCmdPwshE.Mk{"git", KShCmdPwsh.Git{}}, KShCmdPwshE.Mk{"npm", KShCmdPwsh.Npm{}}, KShCmdPwshE.Mk{"node", KShCmdPwsh.Node{}}]

def cmd.pwsh.go(xs: List<&2, KShCmdPwshE>, hit: Bool, k: KShCmdPwsh, +w: String) -> KShCmdPwsh:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KShCmdPwsh.Rest{}
    case KShCmdPwshE.Mk{n, k2} <> t False{}:
      cmd.pwsh.go(t, String.eq(n, w), k2, w)

def cmd.pwsh.find(xs: List<&2, KShCmdPwshE>, +w: String) -> KShCmdPwsh:
  cmd.pwsh.go(xs, False{}, KShCmdPwsh.Rest{}, w)

def cmd.pwsh.k(key: KShCmdPwsh, +name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KShCmdPwsh.Cd{}:
      ModelFiles.cd(T.Pwsh{}, cwds, home, args)
    case KShCmdPwsh.Git{}:
      git.pre(T.Pwsh{}, cwds, home, args)
    case KShCmdPwsh.Npm{}:
      npm.pre(T.Pwsh{}, cwds, home, args)
    case KShCmdPwsh.Node{}:
      node.pre(T.Pwsh{}, cwds, home, args)
    case KShCmdPwsh.Rest{}:
      cmd.pwsh.r3(ModelFiles.tx3(T.Pwsh{}, name, cwds, home, [], args), cwds, home, name, args)

def cmd.pwsh(+name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  cmd.pwsh.k(cmd.pwsh.find(cmd.pwsh.tab(), name), name, args, cwds, home)

# PowerShell: a command with a comma list in its words (round 3, P9) goes
# straight to ModelGit.cmdlet, which reads the list only as the path of a
# file cmdlet and gives Unknown for every other command
def cmd.pwsh.lst(has: Bool, +name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match has:
    case True{}:
      ModelGit.cmdlet(cwds, home, name, args)
    case False{}:
      cmd.pwsh(name, args, cwds, home)

def cmd.sh(sh: T.Shell, +name: String, +args: List<&2, String>, +cwds: List<&2, String>, +home: String, lit: List<&2, String>) -> T.Meaning:
  match sh:
    case T.Bash{}:
      cmd.bash(name, args, cwds, home, lit)
    case T.Pwsh{}:
      cmd.pwsh.lst(ModelGit.lst.any(name <> args), String.to_lower(name), args, cwds, home)

def cmd.argv(sh: T.Shell, +cwds: List<&2, String>, +home: String, lit: List<&2, String>, argv: List<&2, String>) -> T.Meaning:
  match argv:
    case Nil{}:
      MH.unknown("the command is empty")
    case name <> args:
      cmd.sh(sh, name, args, cwds, home, lit)

# ---------------------------------------------------------------------------
# Wrappers (bash): timeout [-s SIG] [-k D] [--foreground]
# [--preserve-status] [-v] DURATION CMD..., time [-p] CMD... and nohup CMD...
# have CMD's meaning; nohup also writes nohup.out in each possible folder.
# Read in one pass over the words, so wrappers may nest. env, xargs, nice
# and stdbuf stay not modelled.

# the reading state: Head (a command or a wrapper comes next), TOpt (inside
# timeout's options; its duration ends them), TVal (the value of -s or -k),
# Time (just after time), Nohup (just after nohup), Cmd (the command's words,
# reversed), Bad. nh: a nohup was seen.
type TxWrap is Data:
  TxWrap.Head{nh: Bool}
  TxWrap.TOpt{nh: Bool}
  TxWrap.TVal{nh: Bool}
  TxWrap.Time{nh: Bool}
  TxWrap.Nohup{}
  TxWrap.Cmd{acc: List<&2, String>, nh: Bool}
  TxWrap.Bad{why: String}

# wr.head: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KShWrHead is Data:
  KShWrHead.Timeout{}
  KShWrHead.Time{}
  KShWrHead.Nohup{}
  KShWrHead.Rest{}

type KShWrHeadE is Data:
  KShWrHeadE.Mk{name: String, k: KShWrHead}

def wr.head.tab() -> List<&2, KShWrHeadE>:
  [KShWrHeadE.Mk{"timeout", KShWrHead.Timeout{}}, KShWrHeadE.Mk{"time", KShWrHead.Time{}}, KShWrHeadE.Mk{"nohup", KShWrHead.Nohup{}}]

def wr.head.go(xs: List<&2, KShWrHeadE>, hit: Bool, k: KShWrHead, +w: String) -> KShWrHead:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KShWrHead.Rest{}
    case KShWrHeadE.Mk{n, k2} <> t False{}:
      wr.head.go(t, String.eq(n, w), k2, w)

def wr.head.find(xs: List<&2, KShWrHeadE>, +w: String) -> KShWrHead:
  wr.head.go(xs, False{}, KShWrHead.Rest{}, w)

def wr.head.k(key: KShWrHead, +w: String, nh: Bool) -> TxWrap:
  match key:
    case KShWrHead.Timeout{}:
      TxWrap.TOpt{nh}
    case KShWrHead.Time{}:
      TxWrap.Time{nh}
    case KShWrHead.Nohup{}:
      TxWrap.Nohup{}
    case KShWrHead.Rest{}:
      TxWrap.Cmd{[w], nh}

def wr.head(+w: String, nh: Bool) -> TxWrap:
  wr.head.k(wr.head.find(wr.head.tab(), w), w, nh)

def wr.dash(dash: Bool, +w: String, nh: Bool, name: String) -> TxWrap:
  match dash:
    case True{}:
      TxWrap.Bad{name ++ ": options are not modelled"}
    case False{}:
      wr.head(w, nh)

def wr.time(+w: String, nh: Bool) -> TxWrap:
  match w:
    case "-p":
      TxWrap.Head{nh}
    case _:
      wr.dash(String.starts_with(w, "-"), w, nh, "time")

def to.durc(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      MH.has_char("0123456789.smhd", c) && to.durc(t)

# a duration: a digit, then digits, . and the units s m h d
def to.dur(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      Char.is_digit(c) && to.durc(t)

def to.word.k(opt: Bool, dur: Bool, nh: Bool) -> TxWrap:
  match opt dur:
    case True{} _:
      TxWrap.TOpt{nh}
    case False{} True{}:
      TxWrap.Head{nh}
    case False{} False{}:
      TxWrap.Bad{"timeout: only -s, -k, --foreground, --preserve-status, -v, a duration and a command are modelled"}

def to.word(+w: String, nh: Bool) -> TxWrap:
  to.word.k(String.starts_with(w, "--signal=") || String.starts_with(w, "--kill-after=") || ((String.starts_with(w, "-s") || String.starts_with(w, "-k")) && Nat.is_lt(2n, String.length(w))), to.dur(w), nh)

# to.opt: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KShToOpt is Data:
  KShToOpt.S{}
  KShToOpt.Foreground{}
  KShToOpt.Rest{}

type KShToOptE is Data:
  KShToOptE.Mk{name: String, k: KShToOpt}

def to.opt.tab() -> List<&2, KShToOptE>:
  [KShToOptE.Mk{"-s", KShToOpt.S{}}, KShToOptE.Mk{"-k", KShToOpt.S{}}, KShToOptE.Mk{"--signal", KShToOpt.S{}}, KShToOptE.Mk{"--kill-after", KShToOpt.S{}}, KShToOptE.Mk{"--foreground", KShToOpt.Foreground{}}, KShToOptE.Mk{"--preserve-status", KShToOpt.Foreground{}}, KShToOptE.Mk{"-v", KShToOpt.Foreground{}}, KShToOptE.Mk{"--verbose", KShToOpt.Foreground{}}]

def to.opt.go(xs: List<&2, KShToOptE>, hit: Bool, k: KShToOpt, +w: String) -> KShToOpt:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KShToOpt.Rest{}
    case KShToOptE.Mk{n, k2} <> t False{}:
      to.opt.go(t, String.eq(n, w), k2, w)

def to.opt.find(xs: List<&2, KShToOptE>, +w: String) -> KShToOpt:
  to.opt.go(xs, False{}, KShToOpt.Rest{}, w)

def to.opt.k(key: KShToOpt, +w: String, nh: Bool) -> TxWrap:
  match key:
    case KShToOpt.S{}:
      TxWrap.TVal{nh}
    case KShToOpt.Foreground{}:
      TxWrap.TOpt{nh}
    case KShToOpt.Rest{}:
      to.word(w, nh)

def to.opt(+w: String, nh: Bool) -> TxWrap:
  to.opt.k(to.opt.find(to.opt.tab(), w), w, nh)

def wr.step(st: TxWrap, +w: String) -> TxWrap:
  match st:
    case TxWrap.Head{nh}:
      wr.head(w, nh)
    case TxWrap.TOpt{nh}:
      to.opt(w, nh)
    case TxWrap.TVal{nh}:
      TxWrap.TOpt{nh}
    case TxWrap.Time{nh}:
      wr.time(w, nh)
    case TxWrap.Nohup{}:
      wr.dash(String.starts_with(w, "-"), w, True{}, "nohup")
    case TxWrap.Cmd{acc, nh}:
      TxWrap.Cmd{w <> acc, nh}
    case TxWrap.Bad{why}:
      TxWrap.Bad{why}

def wr.go(ws: List<&2, String>, st: TxWrap) -> TxWrap:
  match ws:
    case Nil{}:
      st
    case w <> t:
      wr.go(t, wr.step(st, w))

# argv with its wrappers read off
def wr.off(argv: List<&2, String>) -> TxWrap:
  wr.go(argv, TxWrap.Head{False{}})

def wr.nh(nh: Bool, m: T.Meaning, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match nh:
    case True{}:
      MH.join(m, MH.path(MH.AKind.Write{}, cwds, home, "nohup.out"))
    case False{}:
      m

# a wrapper that is not modelled keeps the approve-tool check on the whole
# command line (ModelGit.approve.cmd)
def wr.bad(argv: List<&2, String>, +home: String, why: String) -> T.Meaning:
  match argv:
    case Nil{}:
      MH.unknown(why)
    case name <> args:
      ModelGit.approve.cmd(home, name, args, MH.unknown(why))

def wr.mean(w: TxWrap, argv0: List<&2, String>, +cwds: List<&2, String>, +home: String, lit: List<&2, String>) -> T.Meaning:
  match w:
    case TxWrap.Cmd{acc, nh}:
      wr.nh(nh, cmd.argv(T.Bash{}, cwds, home, lit, List.reverse(&2, String, acc)), cwds, home)
    case TxWrap.Bad{why}:
      wr.bad(argv0, home, why)
    case _:
      wr.bad(argv0, home, "a command is needed")

def wr.last(xs: List<&2, String>, h: String) -> String:
  match xs:
    case Nil{}:
      h
    case x <> t:
      wr.last(t, x)

# the name of the command that runs once the wrappers are taken off
def wr.name(w: TxWrap) -> String:
  match w:
    case TxWrap.Cmd{acc, nh}:
      wr.last(acc, "")
    case _:
      ""

def wr.first(argv: List<&2, String>) -> String:
  match argv:
    case Nil{}:
      ""
    case n <> t:
      n

# A command that is not understood may be handed a protected file through a
# wildcard in its words (python x.py ~/.claude/*, python x.py *.md at the
# project root). Its words whose wildcards bash expands (all but lit) get a
# WriteTree on every protected name a wildcard can match, with the folder
# placed as rm's wildcards are (MH.glob.with; round 2, R2M-3). Skipped when
# the reason already has that note (rm, Remove-Item). Only known actions
# are added to an Unknown, so no law changes.
# the words of ws that hold a wildcard and are not in lit, reversed (a
# loop: argv can be long)
def cmd.unlit(ws: List<&2, String>, +lit: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      acc
    case +w <> t:
      cmd.unlit(t, lit, MH.nm.one.k(MH.has_glob(w) && Bool.not(MH.elem(w, lit)), w, acc))

# ws has more than n words
def cmd.many(ws: List<&2, String>, n: Nat) -> Bool:
  match ws n:
    case Nil{} _:
      False{}
    case Con{w, t} 0n:
      True{}
    case Con{w, t} 1n+k:
      cmd.many(t, k)

# more than 64 words with a wildcard are not checked one by one (each adds
# actions, and a long list would overflow the stack later): the call then
# gets a WriteTree of the home folder, which self-protection refuses
def cmd.gw.k(many: Bool, +m: T.Meaning, +sh: T.Shell, +cwds: List<&2, String>, +home: String, ws: List<&2, String>) -> T.Meaning:
  match many:
    case True{}:
      MH.glob.add(m, MH.acts.of(MH.path(MH.AKind.WriteTree{}, cwds, home, "~")), "; more than 64 words hold a wildcard, which bend-guard does not check one by one")
    case False{}:
      MH.glob.with(m, sh, MH.AKind.WriteTree{}, cwds, home, List.reverse(&2, String, ws))

def cmd.gw.ws(+m: T.Meaning, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +ws: List<&2, String>) -> T.Meaning:
  cmd.gw.k(cmd.many(ws, 64n), m, sh, cwds, home, ws)

def cmd.gw(unk: Bool, +m: T.Meaning, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>, argv: List<&2, String>) -> T.Meaning:
  match unk:
    case True{}:
      cmd.gw.ws(m, sh, cwds, home, cmd.unlit(argv, lit, []))
    case False{}:
      m

def cmd.glob(+m: T.Meaning, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>, argv: List<&2, String>) -> T.Meaning:
  cmd.gw(MH.is_unknown(m) && Bool.not(String.contains(MH.why.of(m), "can match the name")), m, sh, cwds, home, lit, argv)

# the meaning of one command line (argv[0] the name), run from any of cwds;
# under bash after taking off its wrappers
def Model.command.go(sh: T.Shell, +cwds: List<&2, String>, +home: String, lit: List<&2, String>, +argv: List<&2, String>) -> T.Meaning:
  match sh:
    case T.Bash{}:
      wr.mean(wr.off(argv), argv, cwds, home, lit)
    case T.Pwsh{}:
      cmd.argv(T.Pwsh{}, cwds, home, [], argv)

def Model.command(+sh: T.Shell, +cwds: List<&2, String>, +home: String, +lit: List<&2, String>, +argv: List<&2, String>) -> T.Meaning:
  cmd.glob(Model.command.go(sh, cwds, home, lit, argv), sh, cwds, home, lit, argv)

# ---------------------------------------------------------------------------
# Redirects: > and >> write the file, < reads it. /dev/null, /dev/stdout and
# /dev/stderr (bash), $null (PowerShell) and nul write nothing. Every other
# /dev/... or /proc/... target is not known (Path.norm gives None).

def redir.null(sh: T.Shell, +p: String) -> Bool:
  match sh:
    case T.Bash{}:
      String.eq(p, "/dev/null") || String.eq(p, "/dev/stdout") || String.eq(p, "/dev/stderr") || String.eq(String.to_lower(p), "nul")
    case T.Pwsh{}:
      String.eq(p, "$null") || String.eq(String.to_lower(p), "nul")

# a target with a wildcard also gets a Write on every protected name it can
# match (MH.glob.with; round 2, P2)
def redir.out(null: Bool, +sh: T.Shell, +cwds: List<&2, String>, +home: String, +p: String) -> T.Meaning:
  match null:
    case True{}:
      MH.nothing()
    case False{}:
      MH.glob.with(MH.path(MH.AKind.Write{}, cwds, home, p), sh, MH.AKind.Write{}, cwds, home, [p])

def redir(r: T.Redir, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match r:
    case T.ToFile{+p, ap}:
      redir.out(redir.null(sh, p), sh, cwds, home, p)
    case T.FromFile{p}:
      MH.path(MH.AKind.Read{}, cwds, home, p)

def redirs(rs: List<&2, T.Redir>, +sh: T.Shell, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match rs:
    case Nil{}:
      MH.nothing()
    case r <> t:
      MH.join(redir(r, sh, cwds, home), redirs(t, sh, cwds, home))

def redir.texts(rs: List<&2, T.Redir>) -> List<&2, String>:
  match rs:
    case Nil{}:
      []
    case T.ToFile{p, ap} <> t:
      p <> redir.texts(t)
    case T.FromFile{p} <> t:
      p <> redir.texts(t)

# a simple command: the command's actions, then its redirects'. When it is
# not understood, a protected path named in its words (after variables are
# put in), its redirects or the folders it runs in is added to its known
# part (MH.named.unknown; round 2, P2). root: the project folder, which
# places a project file such as BEND_RULES.md along with cwds.
def Model.simple(+sh: T.Shell, +cwds: List<&2, String>, +root: String, +home: String, +lit: List<&2, String>, s: T.Simple) -> T.Meaning:
  match s:
    case T.Simple{+argv, +rs}:
      MH.named.unknown(MH.join(Model.command(sh, cwds, home, lit, argv), MH.why_prefix("redirect: ", redirs(rs, sh, cwds, home))), argv, redir.texts(rs), lit, cwds, root, home)

# ---------------------------------------------------------------------------
# Following the current folder through the text

def is_unknown(m: T.Meaning) -> Bool:
  match m:
    case T.Known{xs}:
      False{}
    case T.Unknown{w, xs}:
      True{}

def is_cd(sh: T.Shell, +name: String) -> Bool:
  match sh:
    case T.Bash{}:
      String.eq(name, "cd")
    case T.Pwsh{}:
      MH.elem(String.to_lower(name), ["cd", "chdir", "sl", "set-location"])

# an unknown command of this name may have changed the shell's folder: under
# bash the builtins that can (and cd itself); under PowerShell any command,
# since a script or function can call Set-Location and it stays
def may_cd(sh: T.Shell, +name: String) -> Bool:
  match sh:
    case T.Bash{}:
      MH.elem(name, ["cd", "pushd", "popd", "source", ".", "eval", "exec", "builtin", "command"])
    case T.Pwsh{}:
      True{}

# the folders of the ChangeDir actions, as Path.show writes them
def cd_dirs(xs: List<&2, T.Action>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case T.ChangeDir{p} <> t:
      Path.show(p) <> cd_dirs(t)
    case a <> t:
      cd_dirs(t)

def canon.one(m: Maybe<&2, T.Path>, c: String) -> String:
  match m:
    case Some{p}:
      Path.show(p)
    case None{}:
      c

# each folder in the form Path.show writes (so that duplicates are seen), or
# as it is when it does not normalise
def canon(cwds: List<&2, String>, +home: String) -> List<&2, String>:
  match cwds:
    case Nil{}:
      []
    case +c <> t:
      canon.one(Path.norm(c, home, "."), c) <> canon(t, home)

def dedupe.add(seen: Bool, x: String, acc: List<&2, String>) -> List<&2, String>:
  match seen:
    case True{}:
      acc
    case False{}:
      x <> acc

def dedupe(xs: List<&2, String>, +acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +x <> t:
      dedupe(t, dedupe.add(MH.elem(x, acc), x, acc))

def cap.k(over: Bool, xs: List<&2, String>) -> List<&2, String>:
  match over:
    case True{}:
      []
    case False{}:
      xs

# more than 8 possible folders: not known any more
def cap(+xs: List<&2, String>) -> List<&2, String>:
  cap.k(Nat.is_lt(8n, List.length(&2, String, xs)), xs)

# Folders through the text (bash): cwds are the possible folders now, fail
# the folders the shell may be in instead if a cd earlier in the current &&
# chain failed (None: one of them is not known). A command right after &&
# runs only if every command before it in the chain succeeded, so it uses
# cwds alone; after ; || | or a newline, fail joins cwds again. PowerShell
# 5.1 has no &&, so there every command joins them first.

# cwds joined with fail; [] (not known) wins
def merge.k(f: List<&2, String>, +cwds: List<&2, String>) -> List<&2, String>:
  match f cwds:
    case Nil{} _:
      cwds
    case _ Nil{}:
      []
    case _ _:
      cap(dedupe(List.append(&2, String, cwds, f), []))

def merge(+cwds: List<&2, String>, fail: Maybe<&2, List<&2, String>>) -> List<&2, String>:
  match fail:
    case None{}:
      []
    case Some{f}:
      merge.k(f, cwds)

# after a known cd: its own folders (the old ones go to fail)
def after_cd(m: T.Meaning) -> List<&2, String>:
  match m:
    case T.Known{xs}:
      cap(dedupe(cd_dirs(xs), []))
    case T.Unknown{w, xs}:
      []

# a cd may fail: the folders before it join fail; a cd from a folder that is
# not known makes fail not known
def fail.add(fail: Maybe<&2, List<&2, String>>, cwds: List<&2, String>, +home: String) -> Maybe<&2, List<&2, String>>:
  match fail cwds:
    case None{} _:
      None{}
    case _ Nil{}:
      None{}
    case Some{f} c <> t:
      Some{List.append(&2, String, f, canon(c <> t, home))}

def after_other(may: Bool, unk: Bool, cwds: List<&2, String>) -> List<&2, String>:
  match may unk:
    case True{} True{}:
      []
    case _ _:
      cwds

def next.k(iscd: Bool, +m: T.Meaning, +sh: T.Shell, +name: String, +cwds: List<&2, String>, +home: String) -> List<&2, String>:
  match iscd:
    case True{}:
      after_cd(m)
    case False{}:
      after_other(may_cd(sh, name), is_unknown(m), cwds)

def next.f(iscd: Bool, fail: Maybe<&2, List<&2, String>>, +cwds: List<&2, String>, +home: String) -> Maybe<&2, List<&2, String>>:
  match iscd:
    case True{}:
      fail.add(fail, cwds, home)
    case False{}:
      fail

def simple.nm(sh: T.Shell, argv: List<&2, String>) -> String:
  match sh:
    case T.Bash{}:
      wr.name(wr.off(argv))
    case T.Pwsh{}:
      wr.first(argv)

# the command's name (under bash, after its wrappers: time cd x is a cd)
def simple_name(sh: T.Shell, s: T.Simple) -> String:
  match s:
    case T.Simple{argv, rs}:
      simple.nm(sh, argv)

# the meaning so far, the possible folders now, and the folders if a cd in
# the current && chain failed
type Run is Data:
  Run.Mk{m: T.Meaning, cwds: List<&2, String>, fail: Maybe<&2, List<&2, String>>}

def is_bash(sh: T.Shell) -> Bool:
  match sh:
    case T.Bash{}:
      True{}
    case T.Pwsh{}:
      False{}

def pick.l(b: Bool, x: List<&2, String>, y: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      x
    case False{}:
      y

def pick.f(b: Bool, x: Maybe<&2, List<&2, String>>, y: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match b:
    case True{}:
      x
    case False{}:
      y

# m: the meaning of the simple command named name, run from cwds
def step.m(+m: T.Meaning, +name: String, +sh: T.Shell, +cwds: List<&2, String>, fail: Maybe<&2, List<&2, String>>, +home: String, acc: T.Meaning) -> Run:
  +iscd = is_cd(sh, name)
  Run.Mk{MH.join(acc, m), next.k(iscd, m, sh, name, cwds, home), next.f(iscd, fail, cwds, home)}

# a command right after && (bash) keeps the folders; any other joins fail
def step.go(+aa: Bool, +s: T.Simple, +sh: T.Shell, +root: String, +home: String, +lit: List<&2, String>, acc: T.Meaning, +cwds: List<&2, String>, +fail: Maybe<&2, List<&2, String>>) -> Run:
  +c0 = pick.l(aa, cwds, merge(cwds, fail))
  step.m(Model.simple(sh, c0, root, home, lit, s), simple_name(sh, s), sh, c0, pick.f(aa, fail, Some{[]}), home, acc)

def step(p: Cmd.Part, +sh: T.Shell, +root: String, +home: String, +lit: List<&2, String>, r: Run) -> Run:
  match p r:
    case Cmd.Part.Mk{s, aa} Run.Mk{acc, cwds, fail}:
      step.go(aa && is_bash(sh), s, sh, root, home, lit, acc, cwds, fail)

def run.go(ps: List<&2, Cmd.Part>, +sh: T.Shell, +root: String, +home: String, +lit: List<&2, String>, r: Run) -> Run:
  match ps:
    case Nil{}:
      r
    case p <> t:
      run.go(t, sh, root, home, lit, step(p, sh, root, home, lit, r))

# text that cannot be lexed or split is not modelled either: it is the
# approve step when the text names the approve tool (ModelGit.approve.other),
# and a protected path named anywhere in it (or in the folders it runs in)
# is added to its known part (MH.named.with; round 2, P2)
def run.whole(+text: String, +cwds: List<&2, String>, +root: String, +home: String, why: String) -> T.Meaning:
  MH.named.with(ModelGit.approve.other(home, [text], MH.unknown(why)), text <> cwds, cwds, root, home)

def run.split(r: Maybe<&2, List<&2, Cmd.Part>>, +sh: T.Shell, +cwds: List<&2, String>, +root: String, +home: String, lit: List<&2, String>, +text: String) -> Run:
  match r:
    case None{}:
      Run.Mk{run.whole(text, cwds, root, home, "the command line has a part that is not modelled (an empty command, a shell keyword, a variable assignment or a redirect without a file)"), [], Some{[]}}
    case Some{ps}:
      run.go(ps, sh, root, home, lit, Run.Mk{MH.nothing(), cwds, Some{[]}})

def run.lex(r: Maybe<&2, Lex.LexOut>, +sh: T.Shell, +cwds: List<&2, String>, +root: String, +home: String, +text: String) -> Run:
  match r:
    case None{}:
      Run.Mk{run.whole(text, cwds, root, home, "the command text uses shell syntax that bend-guard does not read (such as variables, $(...), a comma list, a comment, a quote that is not closed, or a non-ASCII character)"), [], Some{[]}}
    case Some{Lex.LexOut.Mk{ts, lit}}:
      run.split(Cmd.parts(ts), sh, cwds, root, home, lit, text)

def lex.pw(m: Maybe<&2, List<&2, T.Tok>>) -> Maybe<&2, Lex.LexOut>:
  match m:
    case Some{ts}:
      Some{Lex.LexOut.Mk{ts, []}}
    case None{}:
      None{}

def lex(sh: T.Shell, home: String, text: String) -> Maybe<&2, Lex.LexOut>:
  match sh:
    case T.Bash{}:
      Lex.bash(home, text)
    case T.Pwsh{}:
      lex.pw(Lex.pwsh(home, text))

def run(+sh: T.Shell, +cwds: List<&2, String>, +root: String, +home: String, +text: String) -> Run:
  run.lex(lex(sh, home, text), sh, cwds, root, home, text)

def run.m(r: Run) -> T.Meaning:
  match r:
    case Run.Mk{m, c, f}:
      m

# at the end, any cd in the last && chain may have failed
def run.cwds(r: Run) -> List<&2, String>:
  match r:
    case Run.Mk{m, c, f}:
      merge(c, f)

# ---------------------------------------------------------------------------
# The plan's interface

# lex (by shell, with home), split, model each simple command in order
# following cd, join all actions; an unknown part makes the whole Unknown and
# keeps the actions of the parts that were understood. root: the project
# folder (round 2, P2: it places a protected project file that a part that
# is not understood names)
def heredoc.if(hit: Bool, +m: T.Meaning, +text: String, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  match hit:
    case True{}:
      MH.named.with(m, [text], cwds, root, home)
    case False{}:
      m

# A heredoc's body is standard input, which no part's words show, but a
# program that is not understood (python - <<'EOF') may run it as code: when
# the text has a heredoc and a part is not understood, the whole text is
# read for protected paths too.
def Model.shell(sh: T.Shell, +cwds: List<&2, String>, +root: String, +home: String, +text: String) -> T.Meaning:
  +m = run.m(run(sh, cwds, root, home, text))
  heredoc.if(String.contains(text, "<<") && is_unknown(m), m, text, cwds, root, home)

# the possible current folders after the text (at most 8; [] = not known)
def Model.next_cwds(sh: T.Shell, cwds: List<&2, String>, home: String, text: String) -> List<&2, String>:
  run.cwds(run(sh, cwds, "", home, text))
