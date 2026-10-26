# bend-guard: the base rule table (design.md component 3). Empty: the base
# policy has only the core protections. A project's table is generated into
# project/Rules.bend by tools/gen.mjs from bend/templates/Rules.bend.

import Base
import ../core/Types.bend as T

def table() -> List<&2, T.Project>:
  []
