local Content = _G.js.global.document:getElementById "content"
Content.innerHTML = [[
  <div class="container-fluid">
    <div class="row">
      <div class="col-sm-6 col-sm-offset-3 text-center">
        <h1 class="text-primary">Login in progress...</h1>
      </div>
    </div>
    </div>
  </div>
]]

local Progress = require "progressbar"
local progress = Progress {
  expected = 5, -- seconds
}

local Copas = require "copas"
local Http  = require "ardoises.jsonhttp.copas"
local Json  = require "cjson"
local Url   = require "net.url"
local tojs  = require "tojs"

Copas.addthread (function ()
  local data, status = Http {
    url    = "/register",
    query  = Json.decode (_G.configuration.query),
    method = "GET",
  }
  if status ~= 200 then
    Content.innerHTML = [[
      <div class="container-fluid">
        <div class="row">
          <div class="col-sm-6 col-sm-offset-3">
            <div class="alert alert-danger">
              <strong>Problem!</strong> Login is not successful, please retry.
            </div>
          </div>
        </div>
        </div>
      </div>
    ]]
    Copas.sleep (5)
    _G.js.global.location:reload ()
  else
    _G.window.Cookies:set (data.cookie.key, data.cookie.value, tojs {
      secure   = data.cookie.secure,
      samesite = data.cookie.samesite,
      httponly = data.cookie.httponly,
    })
    progress.finished = true
    Copas.sleep (1)
    local location = Url.parse (_G.js.global.location)
    local keys     = {}
    for k in pairs (location.query) do
      keys [k] = true
    end
    for k in pairs (keys) do
      location.query [k] = nil
    end
    _G.js.global.location = Url.build (location)
  end
end)
