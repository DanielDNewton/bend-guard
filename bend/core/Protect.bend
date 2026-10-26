# bend-guard: the self-protection set (design.md component 3, plan Task 2.1).
# Protect.covers(table, x, p) is true when p overlaps any protected path:
# bend-guard's own rules, code, state and key, Claude Code's settings, git
# hooks and git config, and other files that decide what runs later.
# Guard.self_hit denies every change that hits it, in log-only mode too.
# Written elsewhere as Protect.covers, Protect.key_file, Protect.set.
#
# Round 2 (2026-10-26): git hooks and git config moved here from Guard's
# built-in rows, so they are never relaxed in log-only mode; shell snapshots,
# session-env, hook-script folders, dev mods, the Startup folder, ~/.ssh/config,
# .npmrc, .curlrc, .wgetrc and gh's config were added.

import Base
import ./Types.bend as T
import ./Path.bend as Path
import ./Call.bend as Call

# The OpenRouter key file: home/.claude/bend-guard/openrouter.key.
def key_file(home: T.Path) -> T.Path:
  Path.child(home, ".claude/bend-guard/openrouter.key")

# Every approved project's BEND_RULES.md, Claude Code settings files and git
# hooks and config (a guarded session in a sub-folder still loads the
# project's settings and runs its hooks).
def set.projects(table: List<&2, T.Project>) -> List<&2, T.Path>:
  match table:
    case Nil{}:
      []
    case T.Project{+root, rules} <> t:
      Path.child(root, "BEND_RULES.md") <> Path.child(root, ".claude/settings.json") <> Path.child(root, ".claude/settings.local.json") <> Path.child(root, ".mcp.json") <> Path.child(root, ".git/hooks") <> Path.child(root, ".git/config") <> set.projects(t)

# Git hooks and git config of the session's repository, the user and the
# system: they decide what git runs later.
def set.git(+r: T.Path, +h: T.Path) -> List<&2, T.Path>:
  Path.child(r, ".git/hooks") <> Path.child(r, ".git/config") <> Path.child(h, ".gitconfig") <> Path.child(h, ".config/git") <> T.Path{"c", ["programdata", "git", "config"]} <> T.Path{"c", ["program files", "git", "etc", "gitconfig"]} <> []

# Final review (2026-10-26, ENV-F1/F3/F4/F5): more home folders and files
# that decide what runs later. The home-owned folders on PATH (Git Bash puts
# ~/bin first, before /usr/bin; pip and python resolve from WindowsApps,
# after the others), so a file there would replace an allowed git, ls or
# pip; npm's global folder (also holds its global npmrc, etc/npmrc); the
# python.org user site folders (a .pth file or usercustomize.py runs at
# every Python start, pip list too; the Store Python's local-packages
# folder is protected by name below); and ~/NTUSER.DAT, the user registry
# that holds the lasting user environment (setx, reg add, *-ItemProperty on
# HKCU:\Environment and SetEnvironmentVariable are refused through it:
# Model.bend nm.here and ModelGit.bend env.w).
def set.env(+h: T.Path) -> List<&2, T.Path>:
  Path.child(h, "bin") <> Path.child(h, ".local/bin") <> Path.child(h, ".cargo/bin") <> Path.child(h, "appdata/roaming/npm") <> Path.child(h, "appdata/local/microsoft/windowsapps") <> Path.child(h, "appdata/local/microsoft/winget/links") <> Path.child(h, "appdata/roaming/python") <> Path.child(h, "ntuser.dat") <> []

# Other files in home that decide what runs later: the shell snapshot that
# Claude Code sources before every Bash command, session environment files,
# hook scripts, development mods, the Startup folders, and the config of ssh,
# npm, curl, wget, gh and pip (round 3: ~/_curlrc, roaming/.curlrc, gh's
# Windows folder and pip's config folders added with the gh/curl/pip models).
def set.later(+h: T.Path) -> List<&2, T.Path>:
  Path.child(h, ".claude/shell-snapshots") <> Path.child(h, ".claude/session-env") <> Path.child(h, ".claude/hooks") <> Path.child(h, ".claude/dev-mods") <> Path.child(h, "appdata/roaming/microsoft/windows/start menu/programs/startup") <> T.Path{"c", ["programdata", "microsoft", "windows", "start menu", "programs", "startup"]} <> Path.child(h, ".ssh/config") <> Path.child(h, ".npmrc") <> Path.child(h, ".curlrc") <> Path.child(h, "appdata/roaming/_curlrc") <> Path.child(h, "_curlrc") <> Path.child(h, "appdata/roaming/.curlrc") <> Path.child(h, ".wgetrc") <> Path.child(h, ".config/gh") <> Path.child(h, "appdata/roaming/github cli") <> Path.child(h, "appdata/roaming/pip") <> Path.child(h, "pip") <> set.env(h)


# The protected paths for session root r and home h. home/.claude.json also
# holds the user MCP server list.
def set.go(+r: T.Path, +h: T.Path, table: List<&2, T.Project>) -> List<&2, T.Path>:
  Path.child(r, "BEND_RULES.md") <> Path.child(r, ".claude/settings.json") <> Path.child(r, ".claude/settings.local.json") <> Path.child(r, ".mcp.json") <> Path.child(h, ".claude/settings.json") <> Path.child(h, ".claude/settings.local.json") <> Path.child(h, ".claude.json") <> Path.child(h, ".claude/local-plugins") <> Path.child(h, ".claude/plugins") <> Path.child(h, ".claude/bend-guard") <> Path.child(h, "documents/powershell") <> Path.child(h, "documents/windowspowershell") <> Path.child(h, "onedrive/documents/powershell") <> Path.child(h, "onedrive/documents/windowspowershell") <> Path.child(h, ".profile") <> Path.child(h, ".bashrc") <> Path.child(h, ".bash_profile") <> Path.child(h, ".bash_login") <> Path.child(h, ".bash_logout") <> Path.child(h, ".inputrc") <> T.Path{"c", ["programdata", "claudecode"]} <> List.append(&2, T.Path, set.git(r, h), List.append(&2, T.Path, set.later(h), set.projects(table)))

def set(table: List<&2, T.Project>, +x: T.Ctx) -> List<&2, T.Path>:
  set.go(Call.Ctx.root(x), Call.Ctx.home(x), table)

# p overlaps some path of ps (a Bool fold, so proofs go by list induction).
def covers.list(ps: List<&2, T.Path>, +p: T.Path) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case q <> t:
      Bool.or(Path.overlaps(p, q), covers.list(t, p))

def covers(table: List<&2, T.Project>, +x: T.Ctx, +p: T.Path) -> Bool:
  covers.list(set(table, x), p)

# ---------------------------------------------------------------------------
# Files by name, in any folder. This is a separate check, not part of covers:
# covers uses overlaps, so a name pattern there would deny every tree change
# above such a file (rm -rf src). Segments are already lower case.
#
# 1. Claude Code settings: a session started in a sub-folder loads that
#    folder's .claude/settings*.json and .mcp.json. Hook scripts: any
#    folder's .claude/hooks (settings point hooks there). Any folder's
#    .npmrc (ENV-F3: npm reads the project's; script-shell and git= pick
#    the programs npm test and npm outdated run), and anything in a
#    local-packages folder (ENV-F4: the Store Python's user site, whose
#    .pth files run at every Python start).
# 2. Git hooks and git config of any repository (named.git).

def named.settings(h: String) -> Bool:
  match h:
    case "settings.json":
      True{}
    case "settings.local.json":
      True{}
    case "hooks":
      True{}
    case _:
      False{}

def named.next(t: List<&2, String>) -> Bool:
  match t:
    case Nil{}:
      False{}
    case h <> r:
      named.settings(h)

def named.last(t: List<&2, String>) -> Bool:
  match t:
    case Nil{}:
      True{}
    case h <> r:
      False{}

def named.at(h: String, t: List<&2, String>) -> Bool:
  match h:
    case ".claude":
      named.next(t)
    case ".mcp.json":
      named.last(t)
    case ".npmrc":
      named.last(t)
    case "local-packages":
      True{}
    case _:
      False{}

def named.segs(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> +t:
      Bool.or(named.at(h, t), named.segs(t))

# Any repository: a git folder (a segment ".git", or ending in ".git" like a
# bare repo.git) with any later segment "hooks", "config" or
# "config.worktree". This covers submodules (.git/modules/<n>/hooks),
# worktrees (.git/worktrees/<w>/config.worktree) and bare repositories.
def segs.git.name(h: String) -> Bool:
  match h:
    case "hooks":
      True{}
    case "config":
      True{}
    case "config.worktree":
      True{}
    case "commondir":
      True{}
    case "gitdir":
      True{}
    case _:
      False{}

def segs.git.any(t: List<&2, String>) -> Bool:
  match t:
    case Nil{}:
      False{}
    case h <> r:
      Bool.or(segs.git.name(h), segs.git.any(r))

def segs.git.if(c: Bool, t: List<&2, String>) -> Bool:
  match c:
    case True{}:
      segs.git.any(t)
    case False{}:
      False{}

def segs.git.at(h: String, t: List<&2, String>) -> Bool:
  segs.git.if(String.ends_with(h, ".git"), t)

def segs.git(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> +t:
      Bool.or(segs.git.at(h, t), segs.git(t))

# q is some folder's .claude/settings.json, .claude/settings.local.json,
# .claude/hooks (or a file in it) or .mcp.json.
def named.claude(q: T.Path) -> Bool:
  match q:
    case T.Path{d, xs}:
      named.segs(xs)

# Final review (ENV-F2): a path whose last part is .git (a .git file says
# "gitdir: <folder>" and points git at another folder's config, in any sub
# folder, not only the root), or HEAD outside a git folder (a folder with
# HEAD, objects and refs is a bare repository that git status finds by
# itself, config and all; git's safe.bareRepository defaults to all).
def git.lastname(h: String, ingit: Bool) -> Bool:
  match h:
    case ".git":
      True{}
    case "head":
      Bool.not(ingit)
    case _:
      False{}

# t: the parts after h; ingit: some part before h ends in .git
def git.last.go(t: List<&2, String>, +h: String, ingit: Bool) -> Bool:
  match t:
    case Nil{}:
      git.lastname(h, ingit)
    case x <> r:
      git.last.go(r, x, Bool.or(ingit, String.ends_with(h, ".git")))

def git.last(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      git.last.go(t, h, False{})

# q is (in) some repository's git hooks, git config, commondir or gitdir,
# or is a .git file or folder, or a bare repository's HEAD.
def named.git(q: T.Path) -> Bool:
  match q:
    case T.Path{d, +xs}:
      Bool.or(segs.git(xs), git.last(xs))

# A change of q by name: Claude Code settings, hook scripts, git hooks and
# git config, in any folder.
def named(+q: T.Path) -> Bool:
  Bool.or(named.claude(q), named.git(q))

def named_dir.name(h: String) -> Bool:
  match h:
    case ".claude":
      True{}
    case _:
      False{}

def named_dir.go(t: List<&2, String>, h: String) -> Bool:
  match t:
    case Nil{}:
      named_dir.name(h)
    case x <> r:
      named_dir.go(r, x)

# q's last part is .claude: writing it as a whole (mv evil src/.claude) can
# put a settings file inside.
def named_dir(q: T.Path) -> Bool:
  match q:
    case T.Path{d, Nil{}}:
      False{}
    case T.Path{d, h <> t}:
      named_dir.go(t, h)

# A change of q by name: a named file, or a .claude folder as a whole.
def named_or_dir(+q: T.Path) -> Bool:
  Bool.or(named(q), named_dir(q))
