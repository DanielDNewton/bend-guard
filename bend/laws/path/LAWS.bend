# bend-guard: laws about paths (plan Task 1.6). Proven in PROOF.bend.
# under(p, root): p is root or inside it. overlaps(p, q): one is under the other.

import Base
import ../../core/Types.bend as T
import ../../core/Path.bend as Path

# Every path is under itself.
law under_refl:
  for +p: T.Path
  {Path.under(p, p) == True{} : Bool}

# A child built from a rule's relative path is under its parent.
law under_child:
  for +p: T.Path
  for x: String
  {Path.under(Path.child(p, x), p) == True{} : Bool}

# Under a path that is under c means under c.
law under_trans:
  for a: T.Path
  for b: T.Path
  for c: T.Path
  for +h1: {Path.under(a, b) == True{} : Bool}
  for +h2: {Path.under(b, c) == True{} : Bool}
  {Path.under(a, c) == True{} : Bool}

law overlaps_sym:
  for +a: T.Path
  for +b: T.Path
  {Path.overlaps(a, b) == Path.overlaps(b, a) : Bool}

# A path under b overlaps b.
law under_overlaps:
  for +a: T.Path
  for +b: T.Path
  for h: {Path.under(a, b) == True{} : Bool}
  {Path.overlaps(a, b) == True{} : Bool}

# Equal paths: the first is under the second.
law eq_under:
  for a: T.Path
  for b: T.Path
  for +h: {Path.eq(a, b) == True{} : Bool}
  {Path.under(a, b) == True{} : Bool}

# Two folders that both contain p are nested one in the other.
law ancestors_comparable:
  for p: T.Path
  for a: T.Path
  for b: T.Path
  for +h1: {Path.under(p, a) == True{} : Bool}
  for +h2: {Path.under(p, b) == True{} : Bool}
  {Path.overlaps(a, b) == True{} : Bool}

# A normalised path has no "", "." or ".." segments (over the whole normaliser).
law norm_clean:
  for cwd: String
  for home: String
  for raw: String
  for p: T.Path
  for h: {Path.norm(cwd, home, raw) == Some{p} : Maybe<&2, T.Path>}
  {Path.clean(p) == True{} : Bool}
