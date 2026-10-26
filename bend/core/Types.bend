# bend-guard: the shared types (plan.md "Shared interfaces"). Every other
# Bend file imports this as T:  import ./Types.bend as T  (from core/), and
# writes T.Path, T.Verdict, T.Allow{}, T.Step.Done{v}, ...
# Two constructors are renamed because Base already declares App and Done,
# and constructor names are global: Tok's App is Tok.App, Step's Done is
# Step.Done. Their JS tags are "Tok.App" and "Step.Done" (bend/NOTES.md).

import Base

type Path is Data:
  # drive "c" only; lower case; no "", ".", ".." segments
  # sentinel: Path{"?", []}
  Path{drive: String, segs: List<&2, String>}

type Action is Data:
  Read{path: Path}          # one file's contents
  ReadTree{path: Path}      # contents of anything at or below path
  ListDir{path: Path}       # names only
  Write{path: Path}         # exactly this path
  WriteTree{path: Path}     # this path or anything below it
  Delete{path: Path}        # exactly this path
  DeleteTree{path: Path}    # removal of this path and everything below it (rm -r, Remove-Item -Recurse, git clean)
  MoveFrom{path: Path}      # source of a move: this tree changes, but it is not a removal for rule 7
  MakeDir{path: Path}
  ChangeDir{path: Path}     # cd inside a shell command; changes no file
  GitRead{}
  GitRef{}                  # new branch from HEAD; changes no file
  GitPush{dir: Path, force: Bool, all: Bool, refs: List<&2, String>, unsure: Bool}   # unsure: some destination not visible
  NpmInstall{pkgs: List<&2, String>}     # every install runs lifecycle scripts
  RunScript{name: String}
  DraftCheck{slug: String}  # the one known form of tools/draft-check.mjs
  Inert{}

type Meaning is Data:
  Known{actions: List<&2, Action>}
  Unknown{why: String, known: List<&2, Action>}   # known: actions of the parts that were understood

type Shell is Data:
  Bash{}
  Pwsh{}

type Tok is Data:
  Word{text: String}
  Seq{}
  And{}
  Or{}
  Pipe{}
  Out{fd: U32}
  Tok.App{fd: U32}          # plan name App; Base owns App
  In{}

type Redir is Data:
  ToFile{path: String, append: Bool}
  FromFile{path: String}

type Simple is Data:
  Simple{argv: List<&2, String>, redirs: List<&2, Redir>}

type Arg is Data:
  Arg{key: String, value: String}

type Stage is Data:
  AtCheck{}
  AtCall{asked: Bool, consent: String}   # consent: raw approval field of tool.call, "" if none

type Call is Data:
  # cwds: possible shell folders, event folder first; [] = not known
  # links: touched paths (or parents) that are symlinks, junctions or multi-link files
  Call{tool: String, args: List<&2, Arg>, cwds: List<&2, String>, root: String, home: String, links: List<&2, String>, agent: Bool, approver: String, interactive: Bool, mode: String, stage: Stage, log_only: Bool}

type Ctx is Data:
  Ctx{root: Path, home: Path, cwd: Path, links: List<&2, Path>, agent: Bool, approver: String, interactive: Bool, mode: String, shell_tool: Bool, stage: Stage, log_only: Bool}

type Rule is Data:
  NoChange{rel: String}
  NoReadOrChange{rel: String}
  TreeDeleteOnlyUnder{rel: String}
  NoForcePush{}
  NoPushTo{branch: String}
  TrustScript{name: String}

type Project is Data:
  Project{root: Path, rules: List<&2, Rule>}

type Verdict is Data:
  Allow{}
  Ask{reason: String}
  Deny{reason: String}

type ClefQ is Data:
  Triage{}
  Veto{}

type ClefAnswer is Data:
  Answer{risky: U32, unsure: U32}   # per thousand
  NoAnswer{}

type Step is Data:
  Step.Done{v: Verdict}     # plan name Done; Base owns Done
  Consult{q: ClefQ, base: Verdict, text: String}
