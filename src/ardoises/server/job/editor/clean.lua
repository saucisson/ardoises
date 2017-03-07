local Database = require "lapis.db"
local Et       = require "etlua"
local Http     = require "ardoises.jsonhttp".resty
local Model    = require "ardoises.server.model"

local Clean = {}

function Clean.perform ()
  local editors = Model.editors:select [[ where starting = false ]]
  for _, editor in ipairs (editors or {}) do
    if editor.docker and not editor.starting then
      local info, status = Http {
        method = "GET",
        url    = Et.render ("docker:///containers/<%- id %>/json", {
          id = editor.docker,
        }),
      }
      if status == 200 and not info.State.Running then
        editor:update {
          url = Database.NULL,
        }
      elseif status == 404 then
        editor:update {
          url = Database.NULL,
        }
      end
    end
    if editor.docker and not editor.url then
      local _, status = Http {
        method = "DELETE",
        url    = Et.render ("docker:///containers/<%- id %>", {
          id = editor.docker,
        }),
        query  = {
          v     = true,
          force = true,
        },
      }
      if status == 204 or status == 404 then
        editor:update {
          docker = Database.NULL,
        }
      end
    end
    if not editor.url and not editor.docker then
      editor:delete ()
    end
  end
end

return Clean
