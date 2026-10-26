# bend-guard: the order of verdicts, Allow < Ask < Deny (plan.md Task 1.2).
# Imported as Verdict:  import ./Verdict.bend as Verdict  (core/), so callers
# write Verdict.rank, Verdict.max, Verdict.is_deny. Laws: laws/verdict/.

import Base
import ./Types.bend as T

# Allow 0n, Ask 1n, Deny 2n
def rank(v: T.Verdict) -> Nat:
  match v:
    case T.Allow{}:
      0n
    case T.Ask{r}:
      1n
    case T.Deny{r}:
      2n

# the stricter of the two; on a tie the left one (and its reason) is kept
def max(x: T.Verdict, y: T.Verdict) -> T.Verdict:
  match x y:
    case T.Allow{} b:
      b
    case T.Ask{r} T.Allow{}:
      T.Ask{r}
    case T.Ask{r} T.Ask{s}:
      T.Ask{r}
    case T.Ask{r} T.Deny{s}:
      T.Deny{s}
    case T.Deny{r} _:
      T.Deny{r}

def is_allow(v: T.Verdict) -> Bool:
  match v:
    case T.Allow{}:
      True{}
    case T.Ask{r}:
      False{}
    case T.Deny{r}:
      False{}

def is_ask(v: T.Verdict) -> Bool:
  match v:
    case T.Allow{}:
      False{}
    case T.Ask{r}:
      True{}
    case T.Deny{r}:
      False{}

def is_deny(v: T.Verdict) -> Bool:
  match v:
    case T.Allow{}:
      False{}
    case T.Ask{r}:
      False{}
    case T.Deny{r}:
      True{}
