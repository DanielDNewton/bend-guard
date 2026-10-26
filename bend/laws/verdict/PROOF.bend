# bend-guard: proofs of laws/verdict/LAWS.bend, by case split on both
# verdicts; every case computes to True{}.

import Base
import ../../core/Types.bend as T
import ../../core/Verdict.bend as Verdict
import ./LAWS.bend as Laws

def Laws.max_ge_left(x, y):
  match x y:
    case T.Allow{} T.Allow{}:
      {==}
    case T.Allow{} T.Ask{s}:
      {==}
    case T.Allow{} T.Deny{s}:
      {==}
    case T.Ask{r} T.Allow{}:
      {==}
    case T.Ask{r} T.Ask{s}:
      {==}
    case T.Ask{r} T.Deny{s}:
      {==}
    case T.Deny{r} T.Allow{}:
      {==}
    case T.Deny{r} T.Ask{s}:
      {==}
    case T.Deny{r} T.Deny{s}:
      {==}

def Laws.max_ge_right(x, y):
  match x y:
    case T.Allow{} T.Allow{}:
      {==}
    case T.Allow{} T.Ask{s}:
      {==}
    case T.Allow{} T.Deny{s}:
      {==}
    case T.Ask{r} T.Allow{}:
      {==}
    case T.Ask{r} T.Ask{s}:
      {==}
    case T.Ask{r} T.Deny{s}:
      {==}
    case T.Deny{r} T.Allow{}:
      {==}
    case T.Deny{r} T.Ask{s}:
      {==}
    case T.Deny{r} T.Deny{s}:
      {==}

# max(Deny{r}, y) is Deny{r} without looking at y
def Laws.deny_is_top(r, y):
  {==}
