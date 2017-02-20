local Mt      = {}
local Adapter = setmetatable ({}, Mt)

function _G.print (...)
  Adapter.window.console:log (...)
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
  local Et  = require "etlua"
  local Url = {}
  function Url.parse (url)
    local parser = Adapter.document:createElement "a"
    parser.href = url
    return {
      url       = url,
      scheme    = parser.protocol:match "%w+",
      authority = nil,
      path      = parser.pathname,
      params    = nil,
      query     = parser.search,
      fragment  = nil,
      userinfo  = nil,
      host      = parser.hostname,
      port      = parser.port,
      user      = nil,
      password  = nil,
    }
  end
  function Url.build (t)
    local result
    if t.port then
      result = Et.render ("<%- scheme %>://<%- host %>:<%- port %><%- path %>", t)
    else
      result = Et.render ("<%- scheme %>://<%- host %><%- path %>", t)
    end
    assert (not t.query)
    return result
  end
  return Url
end

package.preload ["copas"] = function ()
  local Coromake = require "coroutine.make"
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
      copas.timeout [co] = Adapter.window:setTimeout (function ()
        Adapter.window:clearTimeout (copas.timeout [co])
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
    Adapter.window:clearTimeout (copas.timeout [co])
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
              Adapter.window.console:log (err)
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
    local websocket = Adapter.js.new (Adapter.window.WebSocket, url, protocol)
    local co        = coroutine.running ()
    function websocket.onopen ()
      what.websocket = websocket
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

Adapter.js        = _G.js
Adapter.window    = _G.js.global
Adapter.document  = _G.js.global.document
Adapter.navigator = _G.js.global.navigator
Adapter.locale    = _G.js.global.navigator.language
Adapter.origin    = _G.js.global.location.origin

function Adapter.tojs (t)
  if type (t) ~= "table" then
    return t
  elseif #t ~= 0 then
    local result = Adapter.js.new (Adapter.window.Array)
    for i = 1, #t do
      result [result.length] = Adapter.tojs (t [i])
    end
    return result
  else
    local result = Adapter.js.new (Adapter.window.Object)
    for k, v in pairs (t) do
      assert (type (k) == "string")
      result [k] = Adapter.tojs (v)
    end
    return result
  end
end

function Mt.__call (_, parameters)
  xpcall (function ()
    local Copas    = require "copas"
    local Et       = require "etlua"
    local Jsonhttp = require "ardoises.jsonhttp"
    Jsonhttp.copas = Jsonhttp.js
    local Client   = require "ardoises.client"
    local Editor   = Adapter.document:getElementById "editor"
    local Layers   = Adapter.document:getElementById "layers"
    Copas.addthread (function ()
      local client  = Client {
        server = Adapter.origin,
        token  = parameters.token,
      }
      local ardoise = client:ardoise (Et.render ("<%- owner %>/<%- name %>:<%- branch %>", parameters.repository))
      local editor  = ardoise:edit ()
      local active  = nil
      local changed = true
      local function render_layer ()
        if active and changed then
          Editor.innerHTML = [[
            <h1 class="text-primary">
              <i class="fully-centered fa fa-spinner fa-pulse fa-5x fa-fw"></i>
            </h1>
          ]]
          Copas.addthread (function ()
            local layer = editor:require (active.name)
            local togui = layer.togui
                       or Adapter.d3_togui
                       or Adapter.default_togui
            togui {
              name   = active.name,
              editor = editor,
              layer  = layer,
              target = Editor,
            }
          end)
        elseif not active and changed then
          Editor.innerHTML = [[
            <h1 class="text-primary">
              <i class="fully-centered fa fa-beer fa-5x fa-fw"></i>
            </h1>
          ]]
        end
      end
      local function render_layers ()
        Copas.addthread (function ()
          local layers = {}
          for name, module in editor:list () do
            layers [#layers+1] = {
              id     = #layers+1,
              name   = name,
              module = module,
            }
          end
          table.sort (layers, function (l, r) return l.name < r.name end)
          Layers.innerHTML = Et.render ([[
              <div class="list-group">
                <div class="list-group-item row">
                  <div class="input-group">
                    <input id="layer-name" type="text" class="form-control" placeholder="Module" />
                    <span id="layer-create" class="input-group-addon"><i class="fa fa-plus fa-inverse" aria-hidden="true"></i></span>
                  </div>
                </div>
                <% for _, layer in ipairs (layers) do %>
                  <div class="list-group-item row">
                    <div class="input-group">
                      <span id="layer-get-<%- layer.id %>" class="input-xlarge uneditable-input"><%= layer.name %></span>
                      <span id="layer-delete-<%- layer.id %>" class="input-group-addon"><i class="fa fa-trash fa-inverse" aria-hidden="true"></i></span>
                    </div>
                  </div>
                <% end %>
              </div>
          ]], {
            repository = parameters.repository,
            layers     = layers,
          })
          do
            local link = Adapter.document:getElementById ("layer-create")
            link.onclick = function ()
              local name = Adapter.document:getElementById ("layer-name").value
              Copas.addthread (function ()
                editor:create (name)
                render_layers ()
              end)
              return false
            end
          end
          for _, layer in ipairs (layers) do
            local link = Adapter.document:getElementById ("layer-get-" .. tostring (layer.id))
            link.onclick = function ()
              Copas.addthread (function ()
                active  = layer
                changed = true
                render_layer ()
              end)
              return false
            end
          end
          for _, layer in ipairs (layers) do
            local link = Adapter.document:getElementById ("layer-delete-" .. tostring (layer.id))
            link.onclick = function ()
              Copas.addthread (function ()
                editor:delete (layer.name)
                if active == layer then
                  active  = nil
                  changed = true
                  render_layer ()
                end
                render_layers ()
              end)
              return false
            end
          end
        end)
      end
      render_layers ()
      render_layer  ()
      while true do
        local type, data = editor:wait ()
        print (type, data)
        if type == "create"
        or type == "delete" then
          render_layers ()
        elseif type == "update" then
          -- TODO
        else
          break
        end
      end
      editor:close ()
    end)
    Copas.loop ()
  end, function (err)
    print ("error:", err)
    print (debug.traceback ())
  end)
end

function Adapter.default_togui (parameters)
  assert (type (parameters) == "table")
  local editor = assert (parameters.editor)
  local layer  = assert (parameters.layer )
  local target = assert (parameters.target)
  target.innerHTML = [[
    <div class="panel panel-default">
      <div class="panel-body">
        <div class="editor" id="layer">
        </div>
      </div>
    </div>
  ]]
  local sourced = Adapter.window.ace:edit "layer"
  sourced:setReadOnly (not editor.permissions.write)
  sourced ["$blockScrolling"] = true
  sourced:setTheme "ace/theme/monokai"
  sourced:getSession ():setMode "ace/mode/lua"
  sourced:setValue (layer.code)
end

function Adapter.d3_togui (parameters)
  assert (type (parameters) == "table")
  local D3       = Adapter.window.d3
  -- local editor = assert (parameters.editor)
  local Copas    = require "copas"
  local Et       = require "etlua"
  local Layer    = require "layeredata"
  local meta     = Layer.key.meta
  local layer    = assert (parameters.layer ).layer
  local target   = assert (parameters.target)
  local width    = 960
  local height   = 500
  local hidden   = {}
  local vertices = Adapter.js.new (Adapter.window.Array)
  local edges    = Adapter.js.new (Adapter.window.Array)
  for key, vertex in pairs (layer.vertices) do
    local data = Adapter.tojs {
      id = vertices.length,
      x  = width  / 2,
      y  = height / 2,
    }
    hidden [data] = {
      id    = vertices.length,
      key   = key,
      proxy = vertex,
    }
    vertices [vertices.length] = data
  end
  for key, edge in pairs (layer.edges) do
    local data = Adapter.tojs {
      id = vertices.length,
      x  = width  / 2,
      y  = height / 2,
    }
    hidden [data] = {
      id    = vertices.length,
      key   = key,
      proxy = edge,
    }
    vertices [vertices.length] = data
    for k, arrow in pairs (edge.arrows) do
      for i = 0, vertices.length-1 do
        local node = vertices [i]
        if arrow.vertex <= hidden [node].proxy then
          local link = Adapter.js.new (Adapter.window.Object)
          link.source = data
          link.target = node
          hidden [link] = {
            id    = edges.length,
            key   = k,
            arrow = arrow,
          }
          edges [edges.length] = link
        end
      end
    end
  end
  target.innerHTML = Et.render ([[
    <svg width="960" height="500" id="layer">
    </svg>
  ]], {
    width  = width,
    height = height,
  })
  local svg = D3:select "#layer"
  local g   = svg:append "g"
  local simulation = D3
    :forceSimulation ()
    :force ("link"  , D3:forceLink ():id (function (_, d) return d.id end))
    :force ("charge", D3:forceManyBody ())
    :force ("center", D3:forceCenter (width / 2, height / 2))
  local vertex_size = function (_, vertex)
    if layer [meta].vertex_type <= hidden [vertex].proxy then
      return 10
    elseif layer [meta].edge_type <= hidden [vertex].proxy then
      return 3
    else
      assert (false)
    end
  end
  local drag_start = function (_, vertex)
    simulation:alphaTarget (1):restart ()
    vertex.fx = vertex.x
    vertex.fy = vertex.y
  end
  local drag_drag = function (_, vertex)
    vertex.fx = D3.event.x
    vertex.fy = D3.event.y
  end
  local links = g
    :attr      ("class", "links")
    :selectAll "line"
    :data      (edges)
    :enter     ()
    :append    "line"
  local nodes = g
    :attr      ("class", "nodes")
    :selectAll "circle"
    :data      (vertices)
    :enter     ()
    :append    "circle"
    :attr      ("r", vertex_size)
    :call      (D3:drag ():on ("start", drag_start):on ("drag" , drag_drag))
  local source_x = function (_, d) return d.source.x end
  local source_y = function (_, d) return d.source.y end
  local target_x = function (_, d) return d.target.x end
  local target_y = function (_, d) return d.target.y end
  local x        = function (_, d) return d.x        end
  local y        = function (_, d) return d.y        end
  local tick     = function ()
    links:attr ("x1", source_x)
         :attr ("y1", source_y)
         :attr ("x2", target_x)
         :attr ("y2", target_y)
    nodes:attr ("cx", x)
         :attr ("cy", y)
  end
  simulation:nodes (vertices):on ("tick", tick)
  simulation:force "link":links (edges)
  svg:call (D3:zoom ():on ("zoom", function ()
    g:attr ("transform", D3.event.transform)
  end))
  while true do
    Copas.sleep (1)
  end
end

return Adapter
