local Lpeg = require "lpeg"

local Patterns = {}
Lpeg.locale (Patterns)
Patterns.module =
  (Patterns.alnum + Lpeg.P"-" + Lpeg.P"_" + Lpeg.P".")^1 / tostring
Patterns.identifier =
  (Patterns.alnum + Lpeg.P"-")^1 / tostring
Patterns.repository =
  Lpeg.Ct (
      Patterns.identifier
    * Lpeg.P"/"
    * Patterns.identifier
  ) / function (t)
    return {
      owner      = t [1],
      repository = t [2],
      full_name  = t [1] .. "/" .. t [2],
    }
  end
Patterns.branch =
  Lpeg.Ct (
      Patterns.identifier
    * Lpeg.P"/"
    * Patterns.identifier
    * Lpeg.P":"
    * Patterns.identifier
  ) / function (t)
    return {
      owner      = t [1],
      repository = t [2],
      branch     = t [3],
      full_name  = t [1] .. "/" .. t [2] .. ":" .. t [3],
    }
  end
Patterns.require =
  Lpeg.Ct (
    Patterns.module * Lpeg.P"@" * Patterns.branch
  ) / function (t)
    t [2].module = t [1]
    t [2].name   = t [1] .. "@" .. t [2].full_name
    return t [2]
  end
Patterns.authorization =
    Lpeg.P"token"
  * Lpeg.S"\r\n\f\t "^1
  * (Patterns.alnum^1 / tostring)

return Patterns
