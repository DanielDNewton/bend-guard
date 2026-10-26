# bend-guard: the facts about one call that the policy reads (plan Task 2.1,
# design.md component 3). Call.ctx turns the raw T.Call the glue sends into
# a T.Ctx with normalised paths; the Ctx.* accessors read it.
# Written elsewhere as Call.ctx, Call.Ctx.root, Call.Ctx.dan_said_yes, ...
# (bend/NOTES.md names rule 4). Who may answer an ask is decided here
# (Ctx.can_ask), because Ctx.dan_said_yes needs it and Guard imports Call.

import Base
import ./Types.bend as T
import ./Path.bend as Path

# ---------------------------------------------------------------------------
# Accessors (one match each, so proofs unfold them with no case split)

def Ctx.root(x: T.Ctx) -> T.Path:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      root

def Ctx.home(x: T.Ctx) -> T.Path:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      home

def Ctx.cwd(x: T.Ctx) -> T.Path:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      cwd

def Ctx.links(x: T.Ctx) -> List<&2, T.Path>:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      links

def Ctx.agent(x: T.Ctx) -> Bool:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      agent

def Ctx.shell_tool(x: T.Ctx) -> Bool:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      shell_tool

def Ctx.stage(x: T.Ctx) -> T.Stage:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      stage

def Ctx.log_only(x: T.Ctx) -> Bool:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      log_only

# ---------------------------------------------------------------------------
# Who answers an ask (build brief Q9): a person can be asked only in the main
# loop (not an agent), when the engine says the approver is a person, and in
# an interactive session.

def Ctx.is_person(s: String) -> Bool:
  match s:
    case "person":
      True{}
    case _:
      False{}

def Ctx.can_ask(x: T.Ctx) -> Bool:
  match x:
    case T.Ctx{root, home, cwd, links, agent, approver, interactive, mode, shell_tool, stage, log_only}:
      Bool.and(Bool.not(agent), Bool.and(Ctx.is_person(approver), interactive))

def Ctx.said_yes(s: T.Stage, ca: Bool) -> Bool:
  match s:
    case T.AtCheck{}:
      False{}
    case T.AtCall{asked, consent}:
      Bool.and(asked, ca)

# The user answered this exact call's ask: stage AtCall{asked: True, _} and a
# person could be asked. consent is kept for the log only (brief Q9).
def Ctx.dan_said_yes(+x: T.Ctx) -> Bool:
  Ctx.said_yes(Ctx.stage(x), Ctx.can_ask(x))

# ---------------------------------------------------------------------------
# Call.ctx

# The sentinel path: "cannot read this folder" (drive "?").
def sentinel() -> T.Path:
  T.Path{"?", []}

def ctx.or_sentinel(m: Maybe<&2, T.Path>) -> T.Path:
  match m:
    case Some{p}:
      p
    case None{}:
      sentinel()

# A link that cannot be normalised becomes the whole drive c:/, so every
# action is under it and asks (stricter than the sentinel, which would match
# nothing).
def ctx.or_drive(m: Maybe<&2, T.Path>) -> T.Path:
  match m:
    case Some{p}:
      p
    case None{}:
      T.Path{"c", []}

def ctx.cwd(cwds: List<&2, String>, +root: String, +home: String) -> T.Path:
  match cwds:
    case Nil{}:
      sentinel()
    case h <> t:
      ctx.or_sentinel(Path.norm(root, home, h))

def ctx.links(ls: List<&2, String>, +root: String, +home: String) -> List<&2, T.Path>:
  match ls:
    case Nil{}:
      []
    case h <> t:
      ctx.or_drive(Path.norm(root, home, h)) <> ctx.links(t, root, home)

def ctx.is_shell(s: String) -> Bool:
  match s:
    case "Bash":
      True{}
    case "PowerShell":
      True{}
    case "Monitor":
      True{}
    case _:
      False{}

# Normalises root, home, the first cwd (sentinel when there is none or it is
# not normalisable) and the links; shell_tool for Bash, PowerShell, Monitor.
# A relative cwd or link is read from the root.
def ctx(c: T.Call) -> T.Ctx:
  match c:
    case T.Call{tool, args, cwds, +root, +home, links, agent, approver, interactive, mode, stage, log_only}:
      T.Ctx{ctx.or_sentinel(Path.norm(root, home, root)), ctx.or_sentinel(Path.norm(home, home, home)), ctx.cwd(cwds, root, home), ctx.links(links, root, home), agent, approver, interactive, mode, ctx.is_shell(tool), stage, log_only}
