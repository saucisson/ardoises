local Config   = require "lapis.config".get ()
local Database = require "lapis.db"
local Et       = require "etlua"
local Http     = require "ardoises.jsonhttp".resty
local Json     = require "rapidjson"
local Model    = require "ardoises.server.model"

local Permissions = {}

function Permissions.perform ()
  local repositories, collaborators, status
  repositories, status = Http {
    url     = "https://api.github.com/user/repos",
    method  = "GET",
    headers = {
      ["Accept"       ] = "application/vnd.github.v3+json",
      ["Authorization"] = "token " .. Config.application.token,
      ["User-Agent"   ] = Config.application.name,
    },
  }
  assert (status == 200, status)
  for _, repository in ipairs (repositories) do
    local repo = Model.repositories:find {
      id = repository.id,
    }
    if repo then
      repo:update {
        full_name = repository.full_name,
        contents  = Json.encode (repository),
      }
    else
      Model.repositories:create {
        id        = repository.id,
        full_name = repository.full_name,
        contents  = Json.encode (repository),
      }
    end
    collaborators, status = Http {
      url     = Et.render ("https://api.github.com/repos/<%- owner %>/<%- repository %>/collaborators", {
        owner      = repository.owner.login,
        repository = repository.name,
      }),
      method  = "GET",
      headers = {
        ["Accept"       ] = "application/vnd.github.korra-preview+json",
        ["Authorization"] = "token " .. Config.application.token,
        ["User-Agent"   ] = Config.application.name,
      },
    }
    assert (status == 200, status)
    Database.query (Et.render ([[
      DELETE FROM permissions WHERE repository = <%- repository.id %>;
      <% for _, collaborator in ipairs (collaborators) do %>
        <% if collaborator.permissions.admin then %>
          INSERT INTO permissions (repository, account, permission)
          VALUES (<%- repository.id %>, <%- collaborator.id %>, 'write');
        <% elseif collaborator.permissions.push then %>
          INSERT INTO permissions (repository, account, permission)
          VALUES (<%- repository.id %>, <%- collaborator.id %>, 'write');
        <% elseif collaborator.permissions.pull then %>
          INSERT INTO permissions (repository, account, permission)
          VALUES (<%- repository.id %>, <%- collaborator.id %>, 'read');
        <% end %>
      <% end %>
    ]], {
      repository    = repository,
      collaborators = collaborators,
    }))
  end
  return true
end

return Permissions
