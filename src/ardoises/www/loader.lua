-- _G.js
-- _G.window
-- _G.js.global
-- _G.js.global.document
-- _G.js.global.navigator
-- _G.js.global.navigator.language
-- _G.js.global.location.origin
local Coromake
do
  local xhr = _G.js.new (_G.window.XMLHttpRequest)
  xhr:open ("GET", "/lua/coroutine.make", false)
  assert (pcall (xhr.send, xhr))
  assert (xhr.status == 200)
  Coromake = load (xhr.responseText, "coroutine.make") ()
end

local function tojs (t)
  if type (t) ~= "table" then
    return t
  elseif #t ~= 0 then
    local result = _G.js.new (_G.window.Array)
    for i = 1, #t do
      result [result.length] = tojs (t [i])
    end
    return result
  else
    local result = _G.js.new (_G.window.Object)
    for k, v in pairs (t) do
      assert (type (k) == "string")
      result [k] = tojs (v)
    end
    return result
  end
end

package.preload ["tojs"] = function ()
  return tojs
end

package.preload ["jit"] = function ()
  return false
end

package.preload ["lpeg"] = function ()
  return require "lulpeg"
end

package.preload ["cjson"] = function ()
  return require "dkjson"
end

package.preload ["rapidjson"] = function ()
  return require "dkjson"
end

package.preload ["socket.url"] = function ()
  return require "net.url"
end

package.preload ["progressbar"] = function ()
  local Copas       = require "copas"
  local Progress_mt = {}
  local Progress    = setmetatable ({}, Progress_mt)
  function Progress_mt.__call (_, options)
    local Content  = _G.js.global.document:getElementById "progress-bar"
    local progress = setmetatable ({
      finished = false,
      elapsed  = 0,
      expected = options.expected or 5,    -- seconds
      step     = options.step     or 0.1, -- seconds
    }, Progress)
    Content.innerHTML = [[
      <div class="container-fluid">
        <div class="row">
          <div class="col-sm-12">
            <div class="progress">
              <div id="progress"
                   class="progress-bar progress-bar-primary progress-bar-striped active"
                   role="progressbar"
                   aria-valuenow="0"
                   aria-valuemin="0"
                   aria-valuemax="100"
                   style="width:0%">
              </div>
            </div>
          </div>
        </div>
      </div>
    ]]
    local Element = _G.js.global.document:getElementById "progress"
    Copas.addthread (function ()
      Copas.sleep (0.5)
      while not progress.finished do
        local speed = (100 - progress.elapsed) / (progress.expected / progress.step)
        progress.elapsed = progress.elapsed + speed
        Element:setAttribute ("style", "width:" .. tostring (progress.elapsed) .. "%")
        Copas.sleep (math.random (0, 2 * progress.step))
      end
      Element:setAttribute ("style", "width:100%")
      Copas.sleep (0.5)
      Content.innerHTML = ""
    end)
    Copas.addthread (function ()
      Copas.sleep (2 * progress.expected)
      if progress.finished then
        Content.innerHTML = ""
        return
      end
      Content.innerHTML = [[
        <section>
          <div class="container-fluid">
            <div class="row">
              <div class="col-sm-12 col-md-8 col-md-offset-2">
                <div class="alert alert-danger">
                  <p><strong>It takes too long...</strong></p>
                  <p>We will try to reload this page.
                  If the problem persists, <a href="https://gitter.im/ardoises/Lobby">please contact us</a>.
                </div>
              </div>
            </div>
          </div>
        </section>
      ]]
      Copas.sleep (5)
      if progress.finished then
        Content.innerHTML = ""
        return
      end
      _G.js.global.location:reload ()
    end)
    return progress
  end
  return Progress
end

package.preload ["ardoises.jsonhttp.copas"] = function ()
  local Common = require "ardoises.jsonhttp.common"
  local Copas  = require "copas"
  local Json   = require "cjson"
  return Common (function (request)
    assert (type (request) == "table")
    local running = {
      copas = Copas.running,
      co    = coroutine.running (),
    }
    local response, json, err
    if request.headers then
      request.headers ["User-Agent"] = nil
    end
    local r1 = _G.window:fetch (request.url, tojs {
      method   = request.method or "GET",
      headers  = request.headers,
      body     = request.body,
      mode     = "cors",
      redirect = "follow",
      cache    = "force-cache",
    })
    local r2 = r1 ["then"] (r1, function (_, r)
      assert (r.status >= 200 and r.status < 400)
      response = r
      return response:text ()
    end)
    local r3 = r2 ["then"] (r2, function (_, text)
      json = Json.decode (text)
      if running.copas then
        Copas.wakeup (running.copas)
      else
        coroutine.resume (running.co)
      end
    end)
    r2:catch (function (_, e)
      err = e
      print (e)
      if running.copas then
        Copas.wakeup (running.copas)
      else
        coroutine.resume (running.co)
      end
    end)
    r3:catch (function (_, e)
      err = e
      if running.copas then
        Copas.wakeup (running.copas)
      else
        coroutine.resume (running.co)
      end
    end)
    if running.copas then
      Copas.sleep (-math.huge)
    else
      coroutine.yield ()
    end
    if json then
      local headers  = {}
      local iterator = response.headers:entries ()
      repeat
        local data = iterator:next ()
        if data.value then
          headers [data.value [0]] = data.value [1]
        end
      until data.done
      return {
        status  = response.status,
        headers = headers,
        body    = json,
      }
    else
      return nil, err
    end
  end)
end

package.preload ["copas"] = function ()
  local copas    = {
    co        = nil,
    running   = nil,
    waiting   = {},
    ready     = {},
    timeout   = {},
    coroutine = Coromake (),
  }
  function copas.addthread (f, ...)
    local co = copas.coroutine.create (f)
    copas.ready [co] = {
      parameters = { ... },
    }
    if copas.co and coroutine.status (copas.co) == "suspended" then
      coroutine.resume (copas.co)
    end
    return co
  end
  function copas.sleep (time)
    time = time or -math.huge
    local co = copas.running
    if time > 0 then
      copas.timeout [co] = _G.window:setTimeout (function ()
        _G.window:clearTimeout (copas.timeout [co])
        copas.wakeup (co)
      end, time * 1000)
    end
    if time ~= 0 then
      copas.waiting [co] = true
      copas.ready   [co] = nil
      copas.coroutine.yield ()
    end
  end
  function copas.wakeup (co)
    _G.window:clearTimeout (copas.timeout [co])
    copas.timeout [co] = nil
    copas.waiting [co] = nil
    copas.ready   [co] = true
    if copas.co and coroutine.status (copas.co) == "suspended" then
      coroutine.resume (copas.co)
    end
  end
  function copas.loop ()
    copas.co = coroutine.create (function ()
      while true do
        for to_run, t in pairs (copas.ready) do
          if copas.coroutine.status (to_run) == "suspended" then
            copas.running = to_run
            local ok, err = copas.coroutine.resume (to_run, type (t) == "table" and table.unpack (t.parameters))
            copas.running = nil
            if not ok then
              _G.window.console:log (err)
            end
          end
        end
        for co in pairs (copas.ready) do
          if copas.coroutine.status (co) == "dead" then
            copas.waiting [co] = nil
            copas.ready   [co] = nil
          end
        end
        if  not next (copas.ready  )
        and not next (copas.waiting) then
          copas.co = nil
          return
        elseif not next (copas.ready) then
          coroutine.yield ()
        end
      end
    end)
    coroutine.resume (copas.co)
  end
  return copas
end

package.preload ["websocket"] = function ()
  local Copas     = require "copas"
  local Websocket = {}
  Websocket.__index = Websocket
  Websocket.client  = {}
  function Websocket.client.copas (options)
    return setmetatable ({
      websocket = nil,
      error     = nil,
      receiver  = nil,
      messages  = {},
      timeout   = options.timeout or 30, -- seconds
    }, Websocket)
  end
  function Websocket.connect (what, url, protocol)
    local websocket = _G.js.new (_G.window.WebSocket, url, protocol)
    local co        = coroutine.running ()
    function websocket.onopen ()
      what.websocket = websocket
      what.state     = "OPEN"
      Copas.wakeup (co)
    end
    function websocket.onmessage (_, event)
      what.messages [#what.messages+1] = event.data
      Copas.wakeup (what.receiver)
    end
    function websocket.onerror (_, event)
      what.websocket = nil
      what.error     = event
      Copas.wakeup (co)
    end
    function websocket.onclose (_, event)
      what.websocket = nil
      what.error     = event
      what.state     = "CLOSED"
      Copas.wakeup (co)
    end
    Copas.sleep (what.timeout)
    if not what.websocket then
      return nil, what.error
    end
    return what
  end
  function Websocket:send (text)
    self.websocket:send (text)
    return true
  end
  function Websocket:receive ()
    local message
    repeat
      self.receiver = coroutine.running ()
      message = self.messages [1]
      if message then
        table.remove (self.messages, 1)
      else
        Copas.sleep (-math.huge)
      end
    until message
    return message
  end
  function Websocket:close ()
    self.websocket:close ()
    return true
  end
  return Websocket
end

function _G.print (...)
  _G.window.console:log (...)
end

function _G.require (name)
  if package.loaded [name] then
    return package.loaded [name]
  end
  local reasons = {}
  for _, searcher in ipairs (package.searchers) do
    local loader, value = searcher (name)
    if type (loader) == "function" then
      local loaded = loader (value)
      package.loaded [name] = loaded
      return loaded
    elseif type (loader) == "string" then
      reasons [#reasons+1] = loader
    end
  end
  error ("module " .. name .. " not found:" .. table.concat (reasons))
end

-- Taken from lua.vm.js:
local function load_lua_over_http (url)
  local Copas   = require "copas"
  local running = {
    copas = Copas and Copas.running,
    co    = coroutine.running (),
  }
  local response, err
  local r1 = _G.window:fetch (url, tojs {
    method   = "GET",
    mode     = "cors",
    redirect = "follow",
    cache    = "force-cache",
  })
  local r2 = r1 ["then"] (r1, function (_, r)
    assert (r.status >= 200 and r.status < 400)
    return r:text ()
  end)
  local r3 = r2 ["then"] (r2, function (_, text)
    response = text
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  r2:catch (function (_, e)
    err = e
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  r3:catch (function (_, e)
    err = e
    if running.copas then
      Copas.wakeup (running.copas)
    else
      coroutine.resume (running.co)
    end
  end)
  if running.copas then
    Copas.sleep (-math.huge)
  else
    coroutine.yield ()
  end
  if response then
    return load (response, url, "t")
  else
    return nil, err
  end
end

package.searchers [#package.searchers] = nil
package.searchers [#package.searchers] = nil
table.insert (package.searchers, function (mod_name)
  return package.preload [mod_name] or "not in package.preload"
end)
table.insert (package.searchers, function (mod_name)
  if not mod_name:match "/" then
    local full_url  = "/lua/" .. mod_name
    local func, err = load_lua_over_http (full_url)
    if func ~= nil then return func end
    return "\n    " .. tostring (err)
  end
end)
