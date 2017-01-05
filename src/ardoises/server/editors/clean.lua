local Config   = require "lapis.config".get ()
local Database = require "lapis.db"
local Http     = require "ardoises.jsonhttp".resty
local Mime     = require "mime"
local Model    = require "ardoises.server.model"

local Clean = {}

function Clean.perform ()
  local editors = Model.editors:select [[ where starting = false ]]
  for _, editor in ipairs (editors or {}) do
    if editor.docker then
      local info, status = Http {
        url     = editor.docker,
        method  = "GET",
        headers = {
          ["Authorization"] = "Basic " .. Mime.b64 (Config.docker.username .. ":" .. Config.docker.api_key),
        },
      }
      if (status == 200 and info.state:lower () ~= "starting" and info.state:lower () ~= "running")
      or  status == 404 then
        editor:update {
          url = Database.NULL,
        }
      end
    end
    if editor.docker and not editor.url then
      Http {
        url     = editor.docker,
        method  = "DELETE",
        headers = {
          ["Authorization"] = "Basic " .. Mime.b64 (Config.docker.username .. ":" .. Config.docker.api_key),
        },
      }
      editor:update {
        docker = Database.NULL,
      }
    end
    if not editor.url and not editor.docker then
      editor:delete ()
    end
  end
end

return Clean
