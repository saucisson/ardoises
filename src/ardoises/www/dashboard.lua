local Progress = require "progressbar"
local progress = Progress {
  expected = 1, -- seconds
}

local Copas  = require "copas"
local Client = require "ardoises.client"
local Et     = require "etlua"
local client = Client {
  server = _G.configuration.server,
  token  = _G.configuration.user.tokens.ardoises,
}
local output
progress.finished = true

local Content = _G.js.global.document:getElementById "content"
Content.innerHTML = [[
  <div class="container-fluid">
    <div class="row">
      <div class="col-sm-12 col-md-10 col-lg-8 col-md-offset-1 col-lg-offset-2">
        <p>
          Ardoises are GitHub repositories
          shared with the people <em>you</em> choose.
          In order to create an ardoise,
          please follow the <a href="https://help.github.com/articles/inviting-collaborators-to-a-personal-repository/">Inviting collaborators to a personal repository</a> guide
          and share some repositories with <a href="https://github.com/ardoises"><code>ardoises</code></a>.
        </p>
      </div>
    </div>
    <div class="row">
      <div class="col-sm-6 col-md-5 col-lg-4 col-md-offset-1 col-lg-offset-2">
        <form>
          <div class="input-group">
            <span class="input-group-addon">
              <i class="fa fa-search"></i>
            </span>
            <input id="search"
                   class="form-control"
                   autofocus
                   type="text"/>
          </div>
        </form>
      </div>
    </div>
    <div id="ardoises">
    </div>
  </div>
]]

local Input    = _G.js.global.document:getElementById "search"
local Ardoises = _G.js.global.document:getElementById "ardoises"
local ardoises

Copas.addthread (function ()
  while true do
    Copas.sleep (30) -- seconds
    ardoises = {}
    for ardoise in client:ardoises () do
      ardoises [#ardoises+1] = ardoise
    end
    Copas.wakeup (output)
  end
end)

Copas.addthread (function ()
  while true do
    local back = Input.value
    Copas.sleep (0.5)
    if back ~= Input.value then
      Copas.wakeup (output)
    end
  end
end)

ardoises = {}
for ardoise in client:ardoises () do
  ardoises [#ardoises+1] = ardoise
end
output = Copas.addthread (function ()
  local detailed = {}
  while true do
    local seen     = {}
    local filtered = {}
    for _, ardoise in ipairs (ardoises) do
      ardoise.repository.description = ardoise.repository.description or ""
      if not seen [ardoise.repository.full_name]
      and (ardoise.repository.full_name  :match (Input.value)
        or ardoise.repository.description:match (Input.value)) then
        seen [ardoise.repository.full_name] = true
        filtered [#filtered+1] = ardoise
      end
    end
    table.sort (filtered, function (l, r)
      if (not l.collaborator.permissions.admin and r.collaborator.permissions.admin)
      or (not l.collaborator.permissions.push  and r.collaborator.permissions.push)
      or (not l.collaborator.permissions.pull  and r.collaborator.permissions.pull) then
        return false
      elseif (l.collaborator.permissions.admin and not r.collaborator.permissions.admin)
          or (l.collaborator.permissions.push  and not r.collaborator.permissions.push)
          or (l.collaborator.permissions.pull  and not r.collaborator.permissions.pull) then
        return true
      else
        return l.repository.full_name < r.repository.full_name
      end
    end)
    Ardoises.innerHTML = Et.render ([[
      <div class="row">
        <div class="col-sm-12 col-md-10 col-lg-8 col-md-offset-1 col-lg-offset-2">
          <div class="list-group">
          <% for _, ardoise in ipairs (ardoises) do %>
            <div class="list-group-item">
              <div class="container-fluid">
                <div class="row">
                  <div class="col-sm-12">
                    <div class="row">
                      <div class="col-sm-8">
                        <a href="<%= ardoise.repository.html_url %>">
                          <i class="fa fa-github" aria-hidden="true"></i>
                          <span><%= ardoise.repository.full_name %>:</span>
                        </a>
                        <span><%= ardoise.repository.description or ""%></span>
                      </div>
                      <div class="col-sm-2">
                        <% if ardoise.repository.owner.login == user then %>
                          <a href="https://github.com/<%- ardoise.repository.owner.login %>/<%- ardoise.repository.name %>/settings/collaboration">
                            <div class="input-group input-group-sm">
                              <span class="input-group-addon">
                                <i class="fa fa-users"></i>
                              </span>
                              <span class="input-group-btn">
                                <button type="button" class="btn btn-primary">
                                  Share!
                                </button>
                              </span>
                            </div>
                          </a>
                        <% end %>
                      </div>
                      <div class="col-sm-2">
                        <div class="input-group input-group-sm">
                          <span class="input-group-addon">
                            <i class="fa fa-pencil"></i>
                          </span>
                          <span class="input-group-addon">
                            <% if ardoise.collaborator.permissions.push then %>
                            <i class="fa fa-check text-success"></i>
                            <% else %>
                            <i class="fa fa-ban text-warning"></i>
                            <% end %>
                          </span>
                        </div>
                      </div>
                      <div class="row">
                        <div class="col-sm-12">
                          <div class="input-group input-group-sm">
                          <% for _, branch in ipairs (ardoise.repository.branches) do %>
                          <% if not branch.protected then %>
                            <a href="/views/<%- ardoise.repository.owner.login %>/<%- ardoise.repository.name %>/<%- branch.name %>"
                              aria-label="Editor for <%- ardoise.repository.owner.login %>/<%- ardoise.repository.name %>:<%- branch.name %>">
                              <span class="input-group-btn">
                                <button type="button" class="btn btn-primary">
                                  <%= branch.name %>
                                </button>
                              </span>
                            </a>
                          <% end %>
                          <% end %>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
          </div>
        </div>
      </div>
    ]], {
      ardoises = filtered,
      user     = _G.configuration.user.login,
      detailed = detailed,
    })
    Copas.sleep (-math.huge)
  end
end)
