# bend-guard: what one of Claude's own tools does (plan.md Task 1.9; design.md
# component 2). Model.tool reads the call's flattened arguments by key: each
# modelled tool has an allow-list of keys, and any other key makes the call
# Unknown. Only the values of the keys a model needs are looked at. Shell
# tools go to ModelShell. The inert tools have no file effects, except a
# Skill call that runs the /bend-guard command (the user's alone). CronCreate,
# ArtifactData, LSP and RemoteTrigger are modelled; EnterWorktree,
# ExitWorktree and DesignSync are Unknown with a fixed reason; every other
# tool, every mcp__* tool included, is Unknown.
# Imported as ModelTools; other files write ModelTools.Model.tool(c),
# ModelTools.Model.inert_tools(), ModelTools.Model.next_cwds_tool(c) and
# ModelTools.Model.paths_tool(c). Model.bend is imported as MH, because this
# file defines Model.tool itself.

import Base
import ./Types.bend as T
import ./Path.bend as Path
import ./Meaning.bend as Meaning
import ./Model.bend as MH
import ./ModelGit.bend as ModelGit
import ./ModelShell.bend as ModelShell

# ---------------------------------------------------------------------------
# The inert list (design.md component 2, D2)

# Round 2 (backlog priority 5) adds the tools that only hand back a result,
# keep the session's own task list or background tasks, notify the user, change
# plan mode, list or cancel this session's cron jobs, or answer artifact
# comments. None of them has a path argument (their schemas were checked).
def Model.inert_tools() -> List<&2, String>:
  ["Agent", "Workflow", "Skill", "ToolSearch", "TodoWrite", "WebSearch", "WebFetch", "AskUserQuestion", "ListAgents", "SendMessage", "TaskStop", "StructuredOutput", "SubagentHandback", "ReportFindings", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "GetTask", "BashOutput", "KillShell", "PushNotification", "EnterPlanMode", "ExitPlanMode", "CronList", "CronDelete", "ArtifactComments"]

# ---------------------------------------------------------------------------
# Reading arguments by key. The glue gives an array as the same key repeated,
# in order, and any other value as one text.

# how many times a key the model reads was given
type Got is Data:
  Got.Not{}
  Got.One{v: String}
  Got.Many{}

def tool.vals.if(hit: Bool, v: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      v <> rest
    case False{}:
      rest

def tool.vals.one(a: T.Arg, +key: String, rest: List<&2, String>) -> List<&2, String>:
  match a:
    case T.Arg{k, v}:
      tool.vals.if(String.eq(k, key), v, rest)

# every value given under key, in order
def tool.vals(args: List<&2, T.Arg>, +key: String) -> List<&2, String>:
  match args:
    case Nil{}:
      []
    case a <> t:
      tool.vals.one(a, key, tool.vals(t, key))

def tool.got.t(v: String, t: List<&2, String>) -> Got:
  match t:
    case Nil{}:
      Got.One{v}
    case _:
      Got.Many{}

def tool.got(vs: List<&2, String>) -> Got:
  match vs:
    case Nil{}:
      Got.Not{}
    case v <> t:
      tool.got.t(v, t)

# the key key, which must be given once at most
def tool.get(+args: List<&2, T.Arg>, +key: String) -> Got:
  tool.got(tool.vals(args, key))

def tool.has.l(vs: List<&2, String>) -> Bool:
  match vs:
    case Nil{}:
      False{}
    case _:
      True{}

def tool.has(+args: List<&2, T.Arg>, +key: String) -> Bool:
  tool.has.l(tool.vals(args, key))

def tool.missing(key: String) -> T.Meaning:
  T.Unknown{"the argument " ++ key ++ " is missing", []}

def tool.twice(key: String) -> T.Meaning:
  T.Unknown{"the argument " ++ key ++ " is given more than once", []}

# the first key that is not in ok (keys only; values are not looked at)
def tool.bad.if(isok: Bool, k: String, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match isok:
    case True{}:
      rest
    case False{}:
      Some{k}

def tool.bad.one(a: T.Arg, +ok: List<&2, String>, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match a:
    case T.Arg{+k, v}:
      tool.bad.if(MH.elem(k, ok), k, rest)

def tool.bad(args: List<&2, T.Arg>, +ok: List<&2, String>) -> Maybe<&2, String>:
  match args:
    case Nil{}:
      None{}
    case a <> t:
      tool.bad.one(a, ok, tool.bad(t, ok))

# ---------------------------------------------------------------------------
# File tools

# one path under key: required (req) or optional, given once at most
def tool.path(g: Got, req: Bool, +k: MH.AKind, key: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g req:
    case Got.One{v} _:
      MH.path(k, cwds, home, v)
    case Got.Many{} _:
      tool.twice(key)
    case Got.Not{} True{}:
      tool.missing(key)
    case Got.Not{} False{}:
      MH.nothing()

# Read, Write, Edit, MultiEdit, NotebookEdit: one required path
def tool.file(+k: MH.AKind, +key: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  tool.path(tool.get(args, key), True{}, k, key, cwds, home)

# Grep: ReadTree of path, or of each possible folder
def tool.grep.g(g: Got, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case Got.One{v}:
      MH.path(MH.AKind.ReadTree{}, cwds, home, v)
    case Got.Many{}:
      tool.twice("path")
    case Got.Not{}:
      MH.path(MH.AKind.ReadTree{}, cwds, home, ".")

def tool.grep(+args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  tool.grep.g(tool.get(args, "path"), cwds, home)

# ---------------------------------------------------------------------------
# Glob. The pattern is read from path (or each possible folder). Its literal
# folder (the text before the first pattern character, cut at the last / or
# \) is listed: an absolute pattern or one starting with .. lists its own
# folder. A .. after the first pattern character is Unknown, and so is a
# pattern whose folder cannot be placed.

# * ? [ ] { } ( ) ! (brace and extended patterns can hold .. too)
def glob.char(c: Char) -> Bool:
  match c:
    case Chr{42}:
      True{}
    case Chr{63}:
      True{}
    case Chr{91}:
      True{}
    case Chr{93}:
      True{}
    case Chr{123}:
      True{}
    case Chr{125}:
      True{}
    case Chr{40}:
      True{}
    case Chr{41}:
      True{}
    case Chr{33}:
      True{}
    case _:
      False{}

def glob.keep(stop: Bool, c: Char, acc: String) -> String:
  match stop:
    case True{}:
      acc
    case False{}:
      SCon{c, acc}

# the text before the first pattern character, reversed
def glob.pre(s: String, +stop: Bool, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+c, t}:
      glob.pre(t, stop || glob.char(c), glob.keep(stop || glob.char(c), c, acc))

# the literal folder of a pattern, with its last separator ("" for none)
def glob.lit(+pat: String) -> String:
  MH.glob.dir(String.reverse(glob.pre(pat, False{}, "")), T.Pwsh{}, "", "")

def glob.one(m: Maybe<&2, T.Path>, pat: String) -> T.Meaning:
  match m:
    case Some{p}:
      T.Known{[T.ListDir{p}]}
    case None{}:
      T.Unknown{"cannot tell which folder the pattern " ++ pat ++ " lists", []}

def glob.each(bs: List<&2, T.Path>, +home: String, +dir: String, +pat: String) -> T.Meaning:
  match bs:
    case Nil{}:
      MH.nothing()
    case b <> t:
      MH.join(glob.one(Path.norm(Path.show(b), home, dir), pat), glob.each(t, home, dir, pat))

def glob.at(m: Maybe<&2, List<&2, T.Path>>, +home: String, +dir: String, +pat: String, why: String) -> T.Meaning:
  match m:
    case Some{bs}:
      glob.each(bs, home, dir, pat)
    case None{}:
      T.Unknown{why, []}

def glob.rest(up: Bool, m: Maybe<&2, List<&2, T.Path>>, +home: String, +dir: String, +pat: String, why: String) -> T.Meaning:
  match up:
    case True{}:
      T.Unknown{"the pattern " ++ pat ++ " can reach above its folder, which is not modelled", []}
    case False{}:
      glob.at(m, home, MH.pick.s(String.is_empty(dir), ".", dir), pat, why)

def glob.split(+dir: String, +pat: String, m: Maybe<&2, List<&2, T.Path>>, +home: String, why: String) -> T.Meaning:
  glob.rest(String.contains(String.drop(pat, String.length(dir)), ".."), m, home, dir, pat, why)

def glob.base(g: Got, +pat: String, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case Got.One{+b}:
      glob.split(glob.lit(pat), pat, MH.resolve(cwds, home, b), home, MH.path.why(cwds, b))
    case Got.Many{}:
      tool.twice("path")
    case Got.Not{}:
      glob.split(glob.lit(pat), pat, MH.resolve(cwds, home, "."), home, MH.path.why(cwds, "."))

def glob.pat(g: Got, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case Got.One{pat}:
      glob.base(tool.get(args, "path"), pat, cwds, home)
    case Got.Many{}:
      tool.twice("pattern")
    case Got.Not{}:
      tool.missing("pattern")

def tool.glob(+args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  glob.pat(tool.get(args, "pattern"), args, cwds, home)

# ---------------------------------------------------------------------------
# Shell tools

def tool.shell.g(g: Got, sh: T.Shell, cwds: List<&2, String>, root: String, home: String) -> T.Meaning:
  match g:
    case Got.One{text}:
      ModelShell.Model.shell(sh, cwds, root, home, text)
    case Got.Many{}:
      tool.twice("command")
    case Got.Not{}:
      tool.missing("command")

def tool.shell(sh: T.Shell, +args: List<&2, T.Arg>, cwds: List<&2, String>, root: String, home: String) -> T.Meaning:
  tool.shell.g(tool.get(args, "command"), sh, cwds, root, home)

# ---------------------------------------------------------------------------
# Artifact. file_path and file_paths are read and root is read as a tree, by
# any action (publish reads them; other actions do not use them). read with
# out_dir writes into out_dir (Unknown, keeping that write, when a path or
# paths value has '..' or ':' or starts with '/' or '\', since the file is
# saved at <out_dir>/<path>); read with path or paths but no out_dir saves
# to a folder Bend cannot see, so it is Unknown. list, open, pin, unpin and
# quickstart touch no file; delete and any other action are Unknown.

# a published path v may leave out_dir (the tool saves to <out_dir>/<v>, and
# whether the server refuses '..' is not known): it holds '..' or ':', or
# starts with '/' or '\'
def art.lead(s: String) -> Bool:
  match s:
    case SCon{Chr{47}, t}:
      True{}
    case SCon{Chr{92}, t}:
      True{}
    case _:
      False{}

def art.leaves(+v: String) -> Bool:
  String.contains(v, "..") || String.contains(v, ":") || art.lead(v)

def art.leaves.any(vs: List<&2, String>) -> Bool:
  match vs:
    case Nil{}:
      False{}
    case v <> t:
      art.leaves(v) || art.leaves.any(t)

# the write of out_dir, Unknown (with the write kept as its known part) when
# a published path may leave out_dir
def art.out(bad: Bool, m: T.Meaning) -> T.Meaning:
  match bad m:
    case True{} T.Known{xs}:
      T.Unknown{"an artifact path that leaves out_dir is not modelled", xs}
    case _ _:
      m

def art.read(g: Got, wants: Bool, bad: Bool, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g wants:
    case Got.One{d} _:
      art.out(bad, MH.path(MH.AKind.WriteTree{}, cwds, home, d))
    case Got.Many{} _:
      tool.twice("out_dir")
    case Got.Not{} True{}:
      T.Unknown{"saving an artifact's file without out_dir writes to a folder that is not known", []}
    case Got.Not{} False{}:
      MH.nothing()

# art.act: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KToArtAct is Data:
  KToArtAct.Publish{}
  KToArtAct.Read{}
  KToArtAct.Rest{}

type KToArtActE is Data:
  KToArtActE.Mk{name: String, k: KToArtAct}

def art.act.tab() -> List<&2, KToArtActE>:
  [KToArtActE.Mk{"publish", KToArtAct.Publish{}}, KToArtActE.Mk{"read", KToArtAct.Read{}}, KToArtActE.Mk{"list", KToArtAct.Publish{}}, KToArtActE.Mk{"open", KToArtAct.Publish{}}, KToArtActE.Mk{"pin", KToArtAct.Publish{}}, KToArtActE.Mk{"unpin", KToArtAct.Publish{}}, KToArtActE.Mk{"quickstart", KToArtAct.Publish{}}]

def art.act.go(xs: List<&2, KToArtActE>, hit: Bool, k: KToArtAct, +w: String) -> KToArtAct:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KToArtAct.Rest{}
    case KToArtActE.Mk{n, k2} <> t False{}:
      art.act.go(t, String.eq(n, w), k2, w)

def art.act.find(xs: List<&2, KToArtActE>, +w: String) -> KToArtAct:
  art.act.go(xs, False{}, KToArtAct.Rest{}, w)

def art.act.k(key: KToArtAct, +a: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match key:
    case KToArtAct.Publish{}:
      MH.nothing()
    case KToArtAct.Read{}:
      art.read(tool.get(args, "out_dir"), tool.has(args, "path") || tool.has(args, "paths"), art.leaves.any(tool.vals(args, "path")) || art.leaves.any(tool.vals(args, "paths")), cwds, home)
    case KToArtAct.Rest{}:
      T.Unknown{"the action " ++ a ++ " is not modelled", []}

def art.act(+a: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  art.act.k(art.act.find(art.act.tab(), a), a, args, cwds, home)

def art.action(g: Got, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match g:
    case Got.One{a}:
      art.act(a, args, cwds, home)
    case Got.Many{}:
      tool.twice("action")
    case Got.Not{}:
      MH.nothing()

def tool.artifact(+args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  MH.join(tool.path(tool.get(args, "file_path"), False{}, MH.AKind.Read{}, "file_path", cwds, home), MH.join(MH.paths(tool.vals(args, "file_paths"), MH.AKind.Read{}, cwds, home), MH.join(tool.path(tool.get(args, "root"), False{}, MH.AKind.ReadTree{}, "root", cwds, home), art.action(tool.get(args, "action"), args, cwds, home))))

# ---------------------------------------------------------------------------
# Skill. The /bend-guard command (approve, confirm) is the user's alone: a Skill
# call that runs it is Unknown with a write of bend-guard's state folder as a
# known part, so the self_protection law denies it. Every other skill,
# bend-guard:compile included, is inert.

# the name without leading '/' and spaces
def skill.trim(s: String) -> String:
  match s:
    case SCon{Chr{47}, t}:
      skill.trim(t)
    case SCon{Chr{32}, t}:
      skill.trim(t)
    case SCon{Chr{9}, t}:
      skill.trim(t)
    case SCon{Chr{10}, t}:
      skill.trim(t)
    case SCon{Chr{13}, t}:
      skill.trim(t)
    case other:
      other

# nothing, or a space and then the command's arguments
def skill.end(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_space(c)

# s starts with bend-guard, then nothing or a space
def skill.bg1(+s: String) -> Bool:
  String.starts_with(s, "bend-guard") && skill.end(String.drop(s, 10n))

# some ':' in s is followed by bend-guard, then nothing or a space
def skill.colons(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{58}, +t}:
      skill.bg1(t) || skill.colons(t)
    case SCon{c, t}:
      skill.colons(t)

# s (lower case, trimmed) is the /bend-guard command: bend-guard, or a
# namespaced name (bend-guard:bend-guard, x:bend-guard), followed by nothing
# or a space. Any ':' followed by bend-guard counts, which is stricter than
# looking only at the name. bend-guard:compile is not the command.
def skill.bg(+s: String) -> Bool:
  skill.bg1(s) || skill.colons(s)

def skill.any(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      skill.bg(skill.trim(String.to_lower(x))) || skill.any(t)

def skill.k(hit: Bool, home: String) -> T.Meaning:
  match hit:
    case True{}:
      ModelGit.approve.unknown("/bend-guard: only the user runs this command, by typing it themselves", home)
    case False{}:
      MH.inert()

# an inert tool: no file effects, except a Skill call that runs /bend-guard
def tool.inert(+name: String, args: List<&2, T.Arg>, home: String) -> T.Meaning:
  match name:
    case "Skill":
      skill.k(skill.any(tool.vals(args, "skill")), home)
    case _:
      MH.inert()

# ---------------------------------------------------------------------------
# CronCreate: the job lives only in this session, and its prompt's tool calls
# are checked when they run, so it is inert. A durable value other than
# false (a schedule that could outlive the session) is Unknown.

def cron.all_false(vs: List<&2, String>) -> Bool:
  match vs:
    case Nil{}:
      True{}
    case v <> t:
      String.eq(v, "false") && cron.all_false(t)

def cron.k(ok: Bool) -> T.Meaning:
  match ok:
    case True{}:
      MH.inert()
    case False{}:
      T.Unknown{"durable is set, so the scheduled prompt can outlive this session", []}

def tool.cron(+args: List<&2, T.Arg>) -> T.Meaning:
  cron.k(cron.all_false(tool.vals(args, "durable")))

# ---------------------------------------------------------------------------
# ArtifactData: the shared database of a published artifact. file_path (set,
# update) reads a local file; out_dir (get, list, query) writes the documents
# under it, at <out_dir>/<collection>/<doc_id>.json, and the schema refuses
# '.' and '..' segments in collection and doc_id. A batch's writes are given
# as JSON text, one entry each: every "file_path":"<text>" in them is read.
# Any other mention of file_path in writes, or a file_path with an escape
# other than \\ \" \/, is Unknown.

# the JSON string's text up to its closing quote (acc: reversed text so far;
# esc: after a backslash); None for another escape or no closing quote
def ad.str(s: String, esc: Bool, acc: String) -> Maybe<&2, String>:
  match s esc:
    case SNil{} _:
      None{}
    case SCon{Chr{92}, t} True{}:
      ad.str(t, False{}, SCon{Chr{92}, acc})
    case SCon{Chr{34}, t} True{}:
      ad.str(t, False{}, SCon{Chr{34}, acc})
    case SCon{Chr{47}, t} True{}:
      ad.str(t, False{}, SCon{Chr{47}, acc})
    case SCon{c, t} True{}:
      None{}
    case SCon{Chr{92}, t} False{}:
      ad.str(t, True{}, acc)
    case SCon{Chr{34}, t} False{}:
      Some{String.reverse(acc)}
    case SCon{c, t} False{}:
      ad.str(t, False{}, SCon{c, acc})

# the text after file_path: must go on ":" and a JSON string
def ad.key(s: String) -> Maybe<&2, String>:
  match s:
    case SCon{Chr{34}, SCon{Chr{58}, SCon{Chr{34}, t}}}:
      ad.str(t, False{}, "")
    case _:
      None{}

def ad.cons(m: Maybe<&2, String>, r: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m r:
    case Some{p} Some{ps}:
      Some{p <> ps}
    case _ _:
      None{}

# word: file_path starts here; q: the char before it is '"'
def ad.here(word: Bool, q: Bool, s: String, r: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match word q:
    case True{} True{}:
      ad.cons(ad.key(String.drop(s, 9n)), r)
    case True{} False{}:
      None{}
    case False{} _:
      r

def ad.isq(c: Char) -> Bool:
  match c:
    case Chr{34}:
      True{}
    case _:
      False{}

# every file_path value in a writes entry; None when one cannot be read
def ad.scan(s: String, q: Bool) -> Maybe<&2, List<&2, String>>:
  match s:
    case SNil{}:
      Some{[]}
    case SCon{+c, +t}:
      ad.here(String.starts_with(SCon{c, t}, "file_path"), q, SCon{c, t}, ad.scan(t, ad.isq(c)))

def ad.both(a: Maybe<&2, List<&2, String>>, b: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match a b:
    case Some{x} Some{y}:
      Some{List.append(&2, String, x, y)}
    case _ _:
      None{}

def ad.entries(vs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match vs:
    case Nil{}:
      Some{[]}
    case v <> t:
      ad.both(ad.scan(v, False{}), ad.entries(t))

def ad.writes(m: Maybe<&2, List<&2, String>>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  match m:
    case Some{ps}:
      MH.paths(ps, MH.AKind.Read{}, cwds, home)
    case None{}:
      T.Unknown{"a batch write's file_path is not plain text, so the file it reads cannot be placed", []}

def tool.artdata(+args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String) -> T.Meaning:
  MH.join(MH.inert(), MH.join(tool.path(tool.get(args, "file_path"), False{}, MH.AKind.Read{}, "file_path", cwds, home), MH.join(tool.path(tool.get(args, "out_dir"), False{}, MH.AKind.WriteTree{}, "out_dir", cwds, home), ad.writes(ad.entries(tool.vals(args, "writes")), cwds, home))))

# ---------------------------------------------------------------------------
# LSP: asks the language server about filePath, which is read. Every
# operation except documentSymbol can also show code from other files of the
# workspace (a hover shows the declaration of an imported name), so it reads
# the project folder as a tree too.

# the project folder as a tree
def lsp.tree(+cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  MH.path(MH.AKind.ReadTree{}, cwds, home, root)

def lsp.name(+o: String, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match o:
    case "documentSymbol":
      MH.nothing()
    case _:
      lsp.tree(cwds, home, root)

def lsp.op(g: Got, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match g:
    case Got.One{o}:
      lsp.name(o, cwds, home, root)
    case Got.Many{}:
      tool.twice("operation")
    case Got.Not{}:
      lsp.tree(cwds, home, root)

def tool.lsp(+args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  MH.join(tool.file(MH.AKind.Read{}, "filePath", args, cwds, home), lsp.op(tool.get(args, "operation"), cwds, home, root))

# ---------------------------------------------------------------------------
# RemoteTrigger: list, get, list_runs and get_run_log only read the cloud
# routines; every other action starts or changes a cloud session.

def rt.starts() -> T.Meaning:
  T.Unknown{"starts a session bend-guard does not check", []}

def rt.name(+a: String) -> T.Meaning:
  match a:
    case "list":
      MH.inert()
    case "get":
      MH.inert()
    case "list_runs":
      MH.inert()
    case "get_run_log":
      MH.inert()
    case _:
      rt.starts()

def rt.act(g: Got) -> T.Meaning:
  match g:
    case Got.One{a}:
      rt.name(a)
    case Got.Many{}:
      tool.twice("action")
    case Got.Not{}:
      rt.starts()

# Tools that are always Unknown, with a fixed reason
def tool.fixed(+name: String) -> Maybe<&2, String>:
  match name:
    case "EnterWorktree":
      Some{"EnterWorktree: the worktree's copy of the project's protected folders is not covered by the rules, which name the main folder only"}
    case "ExitWorktree":
      Some{"ExitWorktree: the worktree's copy of the project's protected folders is not covered by the rules, which name the main folder only"}
    case "DesignSync":
      Some{"DesignSync: uploads files from a local folder to a design project, which is not modelled"}
    case _:
      None{}

# ---------------------------------------------------------------------------
# Allow-lists and dispatch

def tool.shell_keys() -> List<&2, String>:
  ["command", "description", "timeout", "run_in_background", "dangerouslyDisableSandbox"]

# None: the tool is not modelled
# tool.keys: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KToToolKeys is Data:
  KToToolKeys.Read{}
  KToToolKeys.Write{}
  KToToolKeys.Edit{}
  KToToolKeys.MultiEdit{}
  KToToolKeys.NotebookEdit{}
  KToToolKeys.Glob{}
  KToToolKeys.Grep{}
  KToToolKeys.Bash{}
  KToToolKeys.Monitor{}
  KToToolKeys.CronCreate{}
  KToToolKeys.ArtifactData{}
  KToToolKeys.LSP{}
  KToToolKeys.RemoteTrigger{}
  KToToolKeys.Artifact{}
  KToToolKeys.Rest{}

type KToToolKeysE is Data:
  KToToolKeysE.Mk{name: String, k: KToToolKeys}

def tool.keys.tab() -> List<&2, KToToolKeysE>:
  [KToToolKeysE.Mk{"Read", KToToolKeys.Read{}}, KToToolKeysE.Mk{"Write", KToToolKeys.Write{}}, KToToolKeysE.Mk{"Edit", KToToolKeys.Edit{}}, KToToolKeysE.Mk{"MultiEdit", KToToolKeys.MultiEdit{}}, KToToolKeysE.Mk{"NotebookEdit", KToToolKeys.NotebookEdit{}}, KToToolKeysE.Mk{"Glob", KToToolKeys.Glob{}}, KToToolKeysE.Mk{"Grep", KToToolKeys.Grep{}}, KToToolKeysE.Mk{"Bash", KToToolKeys.Bash{}}, KToToolKeysE.Mk{"PowerShell", KToToolKeys.Bash{}}, KToToolKeysE.Mk{"Monitor", KToToolKeys.Monitor{}}, KToToolKeysE.Mk{"CronCreate", KToToolKeys.CronCreate{}}, KToToolKeysE.Mk{"ArtifactData", KToToolKeys.ArtifactData{}}, KToToolKeysE.Mk{"LSP", KToToolKeys.LSP{}}, KToToolKeysE.Mk{"RemoteTrigger", KToToolKeys.RemoteTrigger{}}, KToToolKeysE.Mk{"Artifact", KToToolKeys.Artifact{}}]

def tool.keys.go(xs: List<&2, KToToolKeysE>, hit: Bool, k: KToToolKeys, +w: String) -> KToToolKeys:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KToToolKeys.Rest{}
    case KToToolKeysE.Mk{n, k2} <> t False{}:
      tool.keys.go(t, String.eq(n, w), k2, w)

def tool.keys.find(xs: List<&2, KToToolKeysE>, +w: String) -> KToToolKeys:
  tool.keys.go(xs, False{}, KToToolKeys.Rest{}, w)

def tool.keys.k(key: KToToolKeys, +name: String) -> Maybe<&2, List<&2, String>>:
  match key:
    case KToToolKeys.Read{}:
      Some{["file_path", "offset", "limit", "pages", "allow_large"]}
    case KToToolKeys.Write{}:
      Some{["file_path", "content"]}
    case KToToolKeys.Edit{}:
      Some{["file_path", "old_string", "new_string", "replace_all"]}
    case KToToolKeys.MultiEdit{}:
      Some{["file_path", "edits"]}
    case KToToolKeys.NotebookEdit{}:
      Some{["notebook_path", "cell_id", "new_source", "cell_type", "edit_mode"]}
    case KToToolKeys.Glob{}:
      Some{["path", "pattern"]}
    case KToToolKeys.Grep{}:
      Some{["path", "pattern", "glob", "type", "output_mode", "-A", "-B", "-C", "context", "-i", "-n", "-o", "head_limit", "offset", "multiline"]}
    case KToToolKeys.Bash{}:
      Some{tool.shell_keys()}
    case KToToolKeys.Monitor{}:
      Some{"timeout_ms" <> tool.shell_keys()}
    case KToToolKeys.CronCreate{}:
      Some{["cron", "prompt", "recurring", "durable"]}
    case KToToolKeys.ArtifactData{}:
      Some{["action", "url", "collection", "doc_id", "data", "file_path", "out_dir", "as_level", "query", "writes", "if_version", "field", "old_str", "new_str", "replace_all", "ids"]}
    case KToToolKeys.LSP{}:
      Some{["operation", "filePath", "line", "character", "query"]}
    case KToToolKeys.RemoteTrigger{}:
      Some{["action", "trigger_id", "session_id", "cursor", "body"]}
    case KToToolKeys.Artifact{}:
      Some{["action", "file_path", "file_paths", "root", "out_dir", "path", "paths", "url", "title", "description", "icon", "label", "prompt", "scope", "limit", "capabilities", "page", "intent", "design_systems", "after", "type", "type_query", "pin", "favicon"]}
    case KToToolKeys.Rest{}:
      None{}

def tool.keys(+name: String) -> Maybe<&2, List<&2, String>>:
  tool.keys.k(tool.keys.find(tool.keys.tab(), name), name)

# tool.run: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KToToolRun is Data:
  KToToolRun.Read{}
  KToToolRun.Write{}
  KToToolRun.Edit{}
  KToToolRun.MultiEdit{}
  KToToolRun.NotebookEdit{}
  KToToolRun.Glob{}
  KToToolRun.Grep{}
  KToToolRun.Bash{}
  KToToolRun.PowerShell{}
  KToToolRun.Artifact{}
  KToToolRun.CronCreate{}
  KToToolRun.ArtifactData{}
  KToToolRun.LSP{}
  KToToolRun.RemoteTrigger{}
  KToToolRun.Rest{}

type KToToolRunE is Data:
  KToToolRunE.Mk{name: String, k: KToToolRun}

def tool.run.tab() -> List<&2, KToToolRunE>:
  [KToToolRunE.Mk{"Read", KToToolRun.Read{}}, KToToolRunE.Mk{"Write", KToToolRun.Write{}}, KToToolRunE.Mk{"Edit", KToToolRun.Edit{}}, KToToolRunE.Mk{"MultiEdit", KToToolRun.MultiEdit{}}, KToToolRunE.Mk{"NotebookEdit", KToToolRun.NotebookEdit{}}, KToToolRunE.Mk{"Glob", KToToolRun.Glob{}}, KToToolRunE.Mk{"Grep", KToToolRun.Grep{}}, KToToolRunE.Mk{"Bash", KToToolRun.Bash{}}, KToToolRunE.Mk{"Monitor", KToToolRun.Bash{}}, KToToolRunE.Mk{"PowerShell", KToToolRun.PowerShell{}}, KToToolRunE.Mk{"Artifact", KToToolRun.Artifact{}}, KToToolRunE.Mk{"CronCreate", KToToolRun.CronCreate{}}, KToToolRunE.Mk{"ArtifactData", KToToolRun.ArtifactData{}}, KToToolRunE.Mk{"LSP", KToToolRun.LSP{}}, KToToolRunE.Mk{"RemoteTrigger", KToToolRun.RemoteTrigger{}}]

def tool.run.go(xs: List<&2, KToToolRunE>, hit: Bool, k: KToToolRun, +w: String) -> KToToolRun:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KToToolRun.Rest{}
    case KToToolRunE.Mk{n, k2} <> t False{}:
      tool.run.go(t, String.eq(n, w), k2, w)

def tool.run.find(xs: List<&2, KToToolRunE>, +w: String) -> KToToolRun:
  tool.run.go(xs, False{}, KToToolRun.Rest{}, w)

def tool.run.k(key: KToToolRun, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match key:
    case KToToolRun.Read{}:
      MH.why_prefix("Read: ", tool.file(MH.AKind.Read{}, "file_path", args, cwds, home))
    case KToToolRun.Write{}:
      MH.why_prefix("Write: ", tool.file(MH.AKind.Write{}, "file_path", args, cwds, home))
    case KToToolRun.Edit{}:
      MH.why_prefix("Edit: ", tool.file(MH.AKind.Write{}, "file_path", args, cwds, home))
    case KToToolRun.MultiEdit{}:
      MH.why_prefix("MultiEdit: ", tool.file(MH.AKind.Write{}, "file_path", args, cwds, home))
    case KToToolRun.NotebookEdit{}:
      MH.why_prefix("NotebookEdit: ", tool.file(MH.AKind.Write{}, "notebook_path", args, cwds, home))
    case KToToolRun.Glob{}:
      MH.why_prefix("Glob: ", tool.glob(args, cwds, home))
    case KToToolRun.Grep{}:
      MH.why_prefix("Grep: ", tool.grep(args, cwds, home))
    case KToToolRun.Bash{}:
      tool.shell(T.Bash{}, args, cwds, root, home)
    case KToToolRun.PowerShell{}:
      tool.shell(T.Pwsh{}, args, cwds, root, home)
    case KToToolRun.Artifact{}:
      MH.why_prefix("Artifact: ", tool.artifact(args, cwds, home))
    case KToToolRun.CronCreate{}:
      MH.why_prefix("CronCreate: ", tool.cron(args))
    case KToToolRun.ArtifactData{}:
      MH.why_prefix("ArtifactData: ", tool.artdata(args, cwds, home))
    case KToToolRun.LSP{}:
      MH.why_prefix("LSP: ", tool.lsp(args, cwds, home, root))
    case KToToolRun.RemoteTrigger{}:
      MH.why_prefix("RemoteTrigger: ", rt.act(tool.get(args, "action")))
    case KToToolRun.Rest{}:
      T.Unknown{"tool " ++ name ++ " not modelled", []}

def tool.run(+name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  tool.run.k(tool.run.find(tool.run.tab(), name), name, args, cwds, home, root)

def tool.check(b: Maybe<&2, String>, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match b:
    case Some{k}:
      T.Unknown{name ++ ": argument " ++ k ++ " not modelled", []}
    case None{}:
      tool.run(name, args, cwds, home, root)

def tool.known(ks: Maybe<&2, List<&2, String>>, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match ks:
    case Some{ok}:
      tool.check(tool.bad(args, ok), name, args, cwds, home, root)
    case None{}:
      T.Unknown{"tool " ++ name ++ " not modelled", []}

# a fixed reason first, then the allow-list
def tool.model(f: Maybe<&2, String>, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match f:
    case Some{w}:
      T.Unknown{w, []}
    case None{}:
      tool.known(tool.keys(name), name, args, cwds, home, root)

def tool.go(inert: Bool, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +home: String, +root: String) -> T.Meaning:
  match inert:
    case True{}:
      tool.inert(name, args, home)
    case False{}:
      tool.model(tool.fixed(name), name, args, cwds, home, root)

# ---------------------------------------------------------------------------
# Protected paths named by a call that is not understood (round 2, P2;
# Model.bend named.with). A shell tool's command is read part by part in
# ModelShell. Here: every value of SendMessage and of an MCP or other tool
# that is not modelled, and the values of a modelled tool except its file
# contents. A Known meaning is read only for SendMessage (it can ask another
# session, which bend-guard may not guard, to change the file); it then
# becomes Unknown.

# the values of args whose key is not in skip
def nm.vals(args: List<&2, T.Arg>, +skip: List<&2, String>) -> List<&2, String>:
  match args:
    case Nil{}:
      []
    case T.Arg{+k, v} <> t:
      MH.nm.one.k(Bool.not(MH.elem(k, skip)), v, nm.vals(t, skip))

# a modelled tool's file contents, which are not read
def nm.body() -> List<&2, String>:
  ["content", "old_string", "new_string", "edits", "new_source", "description"]

def nm.texts.m(ks: Maybe<&2, List<&2, String>>, +args: List<&2, T.Arg>) -> List<&2, String>:
  match ks:
    case Some{x}:
      nm.vals(args, nm.body())
    case None{}:
      nm.vals(args, [])

# nm.texts: the names are looked up in a table with String.eq, then
# matched as a constructor (a match on string literals that uses the
# matched name again makes bend hold millions of terms; bend/NOTES.md)
type KToNmTexts is Data:
  KToNmTexts.Bash{}
  KToNmTexts.SendMessage{}
  KToNmTexts.Rest{}

type KToNmTextsE is Data:
  KToNmTextsE.Mk{name: String, k: KToNmTexts}

def nm.texts.tab() -> List<&2, KToNmTextsE>:
  [KToNmTextsE.Mk{"Bash", KToNmTexts.Bash{}}, KToNmTextsE.Mk{"Monitor", KToNmTexts.Bash{}}, KToNmTextsE.Mk{"PowerShell", KToNmTexts.Bash{}}, KToNmTextsE.Mk{"SendMessage", KToNmTexts.SendMessage{}}]

def nm.texts.go(xs: List<&2, KToNmTextsE>, hit: Bool, k: KToNmTexts, +w: String) -> KToNmTexts:
  match xs hit:
    case _ True{}:
      k
    case Nil{} False{}:
      KToNmTexts.Rest{}
    case KToNmTextsE.Mk{n, k2} <> t False{}:
      nm.texts.go(t, String.eq(n, w), k2, w)

def nm.texts.find(xs: List<&2, KToNmTextsE>, +w: String) -> KToNmTexts:
  nm.texts.go(xs, False{}, KToNmTexts.Rest{}, w)

def nm.texts.k(key: KToNmTexts, +name: String, +args: List<&2, T.Arg>) -> List<&2, String>:
  match key:
    case KToNmTexts.Bash{}:
      []
    case KToNmTexts.SendMessage{}:
      nm.vals(args, [])
    case KToNmTexts.Rest{}:
      nm.texts.m(tool.keys(name), args)

def nm.texts(+name: String, +args: List<&2, T.Arg>) -> List<&2, String>:
  nm.texts.k(nm.texts.find(nm.texts.tab(), name), name, args)

def nm.if(scan: Bool, +m: T.Meaning, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  match scan:
    case True{}:
      MH.named.with(m, nm.texts(name, args), cwds, root, home)
    case False{}:
      m

# m with a WriteTree of every protected path the call's values name, when m
# is Unknown or the tool is SendMessage
def protect.other(+m: T.Meaning, +name: String, +args: List<&2, T.Arg>, +cwds: List<&2, String>, +root: String, +home: String) -> T.Meaning:
  nm.if(Meaning.is_unknown(m) || String.eq(name, "SendMessage"), m, name, args, cwds, root, home)

# ---------------------------------------------------------------------------
# The plan's interface

# what the call does; paths are read against every possible folder
def Model.tool(c: T.Call) -> T.Meaning:
  match c:
    case T.Call{+tool, +args, +cwds, +root, +home, links, agent, approver, interactive, mode, stage, log_only}:
      protect.other(tool.go(MH.elem(tool, Model.inert_tools()), tool, args, cwds, home, root), tool, args, cwds, root, home)

# the possible shell folders after the call: Bash and Monitor follow cd as
# bash, PowerShell as PowerShell; other tools leave them unchanged. With no
# command nothing ran (unchanged); a command given twice gives [].
def next.g(g: Got, sh: T.Shell, cwds: List<&2, String>, home: String) -> List<&2, String>:
  match g:
    case Got.One{text}:
      ModelShell.Model.next_cwds(sh, cwds, home, text)
    case Got.Many{}:
      []
    case Got.Not{}:
      cwds

def next.k(+name: String, +args: List<&2, T.Arg>, cwds: List<&2, String>, home: String) -> List<&2, String>:
  match name:
    case "Bash":
      next.g(tool.get(args, "command"), T.Bash{}, cwds, home)
    case "Monitor":
      next.g(tool.get(args, "command"), T.Bash{}, cwds, home)
    case "PowerShell":
      next.g(tool.get(args, "command"), T.Pwsh{}, cwds, home)
    case _:
      cwds

def Model.next_cwds_tool(c: T.Call) -> List<&2, String>:
  match c:
    case T.Call{tool, args, cwds, root, home, links, agent, approver, interactive, mode, stage, log_only}:
      next.k(tool, args, cwds, home)

# Path.show of every path the call touches (for the log)
def Model.paths_tool(c: T.Call) -> List<&2, String>:
  Meaning.paths(Model.tool(c))
