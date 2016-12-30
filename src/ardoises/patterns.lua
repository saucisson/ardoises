local Lpeg = require "lpeg"

local Patterns = {}
Lpeg.locale (Patterns)
Patterns.module =
  (Patterns.alnum + Lpeg.P"-" + Lpeg.P"_" + Lpeg.P".")^1 / tostring
Patterns.identifier =
  (Patterns.alnum + Lpeg.P"-")^1 / tostring
Patterns.repository =
  Lpeg.Ct (
    (Patterns.identifier * Lpeg.P"/" * Patterns.identifier)
    * (Lpeg.P":" * Patterns.identifier)^-1
  ) / function (t)
    return {
      owner      = t [1],
      name       = t [2],
      branch     = t [3],
      repository = t [1] .. "/" .. t [2],
      full       = t [1] .. "/" .. t [2] .. (t [3] and ":" .. t [3] or ""),
    }
  end
Patterns.require =
  Lpeg.Ct (
    Patterns.module * Lpeg.P"@" * Patterns.repository
  ) / function (t)
    t [2].module = t [1]
    return t [2]
  end

return Patterns
