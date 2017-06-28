local Copas    = require "copas"
local tojs     = require "tojs"
local Progress = require "progressbar"
local progress = Progress {
  expected = 5, -- seconds
}

local script = _G.js.global.document:createElement "script"
script:setAttribute ("src", "https://cdnjs.cloudflare.com/ajax/libs/ace/1.2.6/ace.js")
_G.js.global.document.head:appendChild (script)

local Coromake = require "coroutine.make"
local Client   = require "ardoises.client"
local Data     = require "ardoises.data"
local Et       = require "etlua"
local Sandbox  = require "ardoises.sandbox"

local branch = Et.render ("<%- owner %>/<%- repository %>:<%- branch %>", {
  owner      = _G.configuration.repository.owner.login,
  repository = _G.configuration.repository.name,
  branch     = _G.configuration.branch,
})
local Content = _G.js.global.document:getElementById "content"
Content.innerHTML = Et.render ([[
  <section>
    <div class="container-fluid">
      <div class="row" style="height: 90vh; min-height: 90vh;">
        <div class="col-sm-4 col-md-3">
          <div class="list-group">
            <div class="list-group-item text-center">
              <%= branch %>
            </div>
            <div class="list-group-item text-right">
              <div id="editor-type" class="btn-group btn-toggle">
                <button id="editor-text"
                        class="btn btn-sm btn-default"
                        disabled>
                  <i class="fa fa-pencil-square fa-inverse" aria-hidden="true"></i>
                </button>
                <button id="editor-graphical"
                        class="btn btn-sm btn-default"
                        disabled>
                  <i class="fa fa-image fa-inverse" aria-hidden="true"></i>
                </button>
              </div>
            </div>
            <div id="layers"></div>
          </div>
        </div>
        <div class="col-sm-8 col-md-9">
          <div id="ardoise" class="col-sm-12">
          </div>
        </div>
      </div>
    </div>
  </section>
]], {
  branch = branch,
})

local Layers   = _G.js.global.document:getElementById "layers"
local Ardoise  = _G.js.global.document:getElementById "ardoise"
local Type     = _G.js.global.document:getElementById "editor-type"
local As_text  = _G.js.global.document:getElementById "editor-text"
local As_graph = _G.js.global.document:getElementById "editor-graphical"
local active   = nil
local layers   = {}

local client  = Client {
  server = _G.configuration.server,
  token  = _G.configuration.user.tokens.ardoises,
}
local ardoise     = assert (client.ardoises [branch])
Ardoise.innerHTML = ardoise.branch.readme
local editor      = ardoise:edit ()
progress.finished = true

Copas.addthread (function ()
  while true do
    Copas.sleep (10)
    if editor.websocket.state ~= "OPEN" then
      Content.innerHTML = [[
        <section>
          <div class="container-fluid">
            <div class="row">
              <div class="col-sm-12 col-md-8 col-md-offset-2">
                <div class="alert alert-danger">
                  <strong>Disconnected!</strong> This page will be reloaded soon.
                </div>
              </div>
            </div>
          </div>
        </section>
      ]]
      Copas.sleep (5)
      _G.js.global.location:reload ()
    end
  end
end)

local renderers = {
  layers  = nil,
  ardoise = nil,
  active  = nil,
}

renderers.layers = Copas.addthread (function ()
  while true do
    layers = {}
    for name, module in editor:list () do
      layers [#layers+1] = {
        id     = #layers+1,
        name   = name,
        module = module,
      }
    end
    table.sort (layers, function (l, r) return l.name < r.name end)
    Layers.innerHTML = Et.render ([[
      <% if editable then %>
      <div class="list-group-item">
        <div class="input-group">
          <input id="layer-name" type="text" class="form-control" placeholder="New module" />
          <span id="layer-create" class="input-group-addon">
            <i class="fa fa-plus fa-inverse" aria-hidden="true"></i>
          </span>
        </div>
      </div>
      <% end %>
      <% for _, layer in ipairs (layers) do %>
      <div class="list-group-item" id="layer-get-<%- layer.id %>">
        <%= layer.name %>
        <span class="pull-right">
          <button id="layer-close-<%- layer.id %>" class="btn btn-sm btn-warning hidden">
            <i class="fa fa-times" aria-hidden="true"></i>
          </button>
          <% if editable then %>
          <button id="layer-delete-<%- layer.id %>" class="btn btn-sm btn-warning">
            <i class="fa fa-trash" aria-hidden="true"></i>
          </button>
          <% end %>
        </span>
      </div>
      <% end %>
    ]], {
      layers   = layers,
      editable = editor.permissions.push,
    })
    do
      local link = _G.js.global.document:getElementById "layer-create"
      link.onclick = function (_, event)
        event:preventDefault  ()
        event:stopPropagation ()
        local name = _G.js.global.document:getElementById "layer-name".value
        Copas.addthread (function ()
          active = {
            module = editor:create (name),
          }
          Copas.wakeup (renderers.ardoise)
        end)
        return false
      end
    end
    for _, layer in ipairs (layers) do
      local link = _G.js.global.document:getElementById ("layer-get-" .. tostring (layer.id))
      link.onclick = function (_, event)
        event:preventDefault  ()
        event:stopPropagation ()
        Copas.addthread (function ()
          progress = Progress {
            expected = 10, -- seconds
          }
          active = {
            module = layer.module,
          }
          Copas.wakeup (renderers.ardoise)
          Copas.wakeup (renderers.active)
        end)
        return false
      end
    end
    for _, layer in ipairs (layers) do
      local link = _G.js.global.document:getElementById ("layer-close-" .. tostring (layer.id))
      link.onclick = function (_, event)
        event:preventDefault  ()
        event:stopPropagation ()
        Copas.addthread (function ()
          active = nil
          Copas.wakeup (renderers.layers)
          Copas.wakeup (renderers.ardoise)
          Copas.wakeup (renderers.active)
        end)
        return false
      end
    end
    for _, layer in ipairs (layers) do
      local link = _G.js.global.document:getElementById ("layer-delete-" .. tostring (layer.id))
      link.onclick = function (_, event)
        event:preventDefault  ()
        event:stopPropagation ()
        _G.window:swal (tojs {
          title = Et.render ("Do you really want to delete <%- name %>?", layer),
          text  = "You will not be able to recover this layer!",
          type  = "warning",
          showCancelButton  = true,
          confirmButtonText = "Confirm",
          closeOnConfirm    = true,
        }, function ()
          Copas.addthread (function ()
            if active and active.module == layer.module then
              active = nil
            end
            editor:delete (layer.module)
            Copas.wakeup (renderers.ardoise)
          end)
        end)
        return false
      end
    end
    Copas.wakeup (renderers.active)
    Copas.sleep (-math.huge)
  end
end)

Copas.addthread (function ()
  for data in editor:events {} do
    if data.type == "create" or data.type == "delete" then
      Copas.wakeup (renderers.layers)
    end
  end
end)

renderers.active = Copas.addthread (function ()
  while true do
    for _, layer in ipairs (layers) do
      local link  = _G.js.global.document:getElementById ("layer-get-"   .. tostring (layer.id))
      local close = _G.js.global.document:getElementById ("layer-close-" .. tostring (layer.id))
      if active and active.module == layer.module then
        link.classList :add    "active"
        close.classList:remove "hidden"
      else
        link.classList :remove "active"
        close.classList:add    "hidden"
      end
    end
    Copas.sleep (-math.huge)
  end
end)

_G.window:addEventListener ("resize", function ()
  Copas.wakeup (renderers.layers)
  Copas.wakeup (renderers.ardoise)
end, false)

local default_togui

renderers.ardoise = Copas.addthread (function ()
  local renderer
  local current
  local interaction = editor:require "interaction@ardoises/formalisms:dev".layer
  Type.onclick = function ()
    if not As_text.disabled and not As_graph.disabled then
      current = nil
      As_text .classList:toggle "active"
      As_graph.classList:toggle "active"
      Copas.wakeup (renderers.ardoise)
    end
  end
  while true do
    local edited
    if active then
      edited = editor:require (active.module)
    end
    if edited and current == active.module then
      local _ = true -- do nothing
    elseif edited and current ~= active.module then
      Ardoise.innerHTML = ""
      local togui = edited.layer [Data.key.meta]
                and edited.layer [Data.key.meta] [interaction.gui]
                 or default_togui
      if togui == default_togui then
        As_text .classList:remove "active"
        As_graph.classList:remove "active"
        As_text .classList:remove "btn-warning"
        As_graph.classList:remove "btn-warning"
        As_text .classList:add    "btn-default"
        As_graph.classList:add    "btn-default"
        As_text .disabled = true
        As_graph.disabled = true
      else
        As_text .disabled = false
        As_graph.disabled = false
        if As_text.classList:contains "active" then
          As_text .classList:add    "active"
          As_text .classList:add    "btn-warning"
          As_text .classList:remove "btn-default"
          As_graph.classList:remove "btn-warning"
          As_graph.classList:add    "btn-default"
          togui = default_togui
        else
          As_graph.classList:add    "active"
          As_graph.classList:add    "btn-warning"
          As_graph.classList:remove "btn-default"
          As_text .classList:remove "btn-warning"
          As_text .classList:add    "btn-default"
          togui = edited.layer [Data.key.meta] [interaction.gui]
        end
      end
      local coroutine = Coromake ()
      local co        = coroutine.create (togui)
      local ok, err   = coroutine.resume (co, {
        editor    = editor,
        module    = active.module,
        target    = Ardoise,
        coroutine = coroutine,
        progress  = progress,
      })
      if ok then
        renderer = co
      else
        progress.finished = true
        As_text .classList:remove "active"
        As_graph.classList:remove "active"
        As_text .classList:remove "btn-warning"
        As_graph.classList:remove "btn-warning"
        As_text .classList:add    "btn-default"
        As_graph.classList:add    "btn-default"
        As_text .disabled = true
        As_graph.disabled = true
        print (err)
        Ardoise.innerHTML = [[
          <section>
            <div class="container-fluid">
              <div class="row">
                <div class="col-sm-12">
                  <div class="alert alert-danger">
                    <strong>Rendering problem!</strong>
                  </div>
                </div>
              </div>
            </div>
          </section>
        ]]
      end
    else
      if renderer then
        coroutine.resume (renderer)
        renderer = nil
        As_text .classList:remove "active"
        As_graph.classList:remove "active"
        As_text .classList:remove "btn-warning"
        As_graph.classList:remove "btn-warning"
        As_text .classList:add    "btn-default"
        As_graph.classList:add    "btn-default"
        As_text .disabled = true
        As_graph.disabled = true
      end
      Ardoise.innerHTML = ardoise.branch.readme
    end
    current = active and active.module
    Copas.sleep (-math.huge)
  end
end)

default_togui = function (parameters)
  assert (type (parameters) == "table")
  -- local editor        = assert (parameters.editor)
  local module        = assert (parameters.module)
  local target        = assert (parameters.target)
  local coroutine     = assert (parameters.coroutine)
  local guiprogress   = assert (parameters.progress)
  local edited        = editor:require (module)
  local running       = true
  local default_patch = [[
return function (Data, layer, ref)
  -- Write your patch here...
  ...
end
]]
  local top       = _ENV.js.global.document:getElementById "top-bar"   :getBoundingClientRect ()
  local bottom    = _ENV.js.global.document:getElementById "bottom-bar":getBoundingClientRect ()
  local height    = _ENV.window.innerHeight
                  - top.height
                  - bottom.height
  target.innerHTML = Et.render ([[
    <div class="container-fluid">
      <div class="row">
        <div class="col-sm-12">
          <div class="panel panel-default">
            <div class="panel-body">
              <div id="editor-model" class="editor" style="height: <%- model_height %>px;">
              </div>
            </div>
          </div>
        </div>
      </div>
      <% if editable then %>
      <div class="row">
        <div class="col-sm-11">
          <div class="panel panel-default">
            <div class="panel-body">
              <div id="editor-patch" class="editor" style="height: <%- patch_height %>px;">
              </div>
            </div>
          </div>
        </div>
        <div class="col-sm-1">
          <button id="patch-submit" class="btn btn-xs">
            <i class="fa fa-paper-plane fa-inverse" aria-hidden="true"></i>
          </button>
        </div>
      </div>
      <% end %>
    </div>
  ]], {
    editable     = editor.permissions.push,
    model_height = editor.permissions.push and 0.7  * height or height,
    patch_height = editor.permissions.push and 0.25 * height or 0,
  })
  local source = _G.window.ace:edit "editor-model"
  source:setReadOnly (true)
  source ["$blockScrolling"] = true
  source:setTheme "ace/theme/monokai"
  source:getSession ():setMode "ace/mode/lua"
  Copas.addthread (function ()
    for data in editor:events {} do
      if not running then
        return
      end
      if data.type == "update" or data.type == "patch" or data.type == "require" then
        source:setValue (edited.code)
      end
    end
  end)
  local keydown
  local resize = _G.window:addEventListener ("resize", function () end, false)
  if editor.permissions.push then
    local changed = 0
    local patch = _G.window.ace:edit "editor-patch"
    patch:setReadOnly (false)
    patch ["$blockScrolling"] = true
    patch:setTheme "ace/theme/monokai"
    patch:getSession ():setMode "ace/mode/lua"
    patch:setValue (default_patch)
    patch:focus ()
    patch:gotoLine (3, 5, true)
    local submit  = _G.js.global.document:getElementById "patch-submit"
    patch:on ("change", function ()
      changed = os.clock ()
    end)
    Copas.addthread (function ()
      local last = -math.huge
      while running do
        if os.clock () - changed > 1 and changed ~= last then
          last = changed
          local code = patch:getValue ()
          local ok, err = load (code, "patch", "t")
          patch:getSession ():clearAnnotations ()
          if ok then
            submit.disabled = false
            submit.classList:remove "btn-danger"
            submit.classList:add    "btn-success"
          else
            local pattern = [[%[string "patch"%]:(%d+):%s+(.*)]]
            local line, problem = err:match (pattern)
            submit.classList:remove "btn-success"
            submit.classList:add    "btn-danger"
            submit.disabled = true
            patch:getSession ():setAnnotations (tojs {
              { row    = line-1,
                column = 0,
                text   = problem,
                type   = "error",
              },
            })
          end
        end
        Copas.sleep (1)
      end
    end)
    local save = Copas.addthread (function ()
      while running do
        Copas.sleep (-math.huge)
        pcall (function ()
          local chunk, err_chunk = _G.load (patch:getValue (), module.name, "t", Sandbox)
          if not chunk then
            return patch:getSession ():setAnnotations (tojs {
              { row    = 0,
                column = 0,
                text   = tostring (err_chunk),
                type   = "error",
              },
            })
          end
          local ok_loaded, loaded = pcall (chunk)
          if not ok_loaded then
            return patch:getSession ():setAnnotations (tojs {
              { row    = 0,
                column = 0,
                text   = tostring (loaded),
                type   = "error",
              },
            })
          end
          local ok, err = editor:patch (edited, loaded)
          if ok then
            patch:setValue (default_patch)
            patch:gotoLine (3, 5, true)
            patch:focus ()
          else
            return patch:getSession ():setAnnotations (tojs {
              { row    = 0,
                column = 0,
                text   = tostring (err),
                type   = "error",
              },
            })
          end
        end)
      end
    end)
    keydown = _G.js.global.document:addEventListener ("keydown", function (_, e)
      if e.keyCode == 83 and (e.metaKey or e.ctrlKey) and not submit.disabled then
        Copas.wakeup (save)
        return false
      end
    end, false)
    submit.onclick = function ()
      Copas.wakeup (save)
      return false
    end
  end
  source:setValue (edited.code)
  guiprogress.finished = true
  coroutine.yield ()
  running = false
  _G.js.global.document:removeEventListener ("keydown", keydown, false)
  _G.js.global.document:removeEventListener ("resize" , resize , false)
end
