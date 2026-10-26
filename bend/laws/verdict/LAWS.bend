# bend-guard: laws of the verdict order (plan.md Task 1.2). Proven in
# PROOF.bend beside this file.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict

# max never makes the left verdict less strict
law max_ge_left:
  for x: T.Verdict
  for y: T.Verdict
  {Nat.is_le(Verdict.rank(x), Verdict.rank(Verdict.max(x, y))) == True{} : Bool}

# max never makes the right verdict less strict
law max_ge_right:
  for x: T.Verdict
  for y: T.Verdict
  {Nat.is_le(Verdict.rank(y), Verdict.rank(Verdict.max(x, y))) == True{} : Bool}

# a Deny on the left always survives
law deny_is_top:
  for r: String
  for y: T.Verdict
  {Verdict.is_deny(Verdict.max(T.Deny{r}, y)) == True{} : Bool}
