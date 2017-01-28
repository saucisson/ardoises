local Config = require "lapis.config".get ()
local Et     = require "etlua"
local Http   = require "ardoises.jsonhttp".resty

local Invitations = {}

function Invitations.perform ()
  local invitations, status = Http {
    url     = "https://api.github.com/user/repository_invitations",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  if status ~= 200 then
    return nil
  end
  for _, invitation in ipairs (invitations) do
    Http {
      url     = Et.render ("https://api.github.com/user/repository_invitations/<%- id %>", invitation),
      method  = "PATCH",
      headers = {
        ["Accept"       ] = "application/vnd.github.swamp-thing-preview+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = Config.application.name,
      },
    }
  end
  return true
end

return Invitations
