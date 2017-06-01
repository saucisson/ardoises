local C3       = require "c3"
local Coromake = require "coroutine.make"
local Uuid     = require "uuid"

Uuid.seed ()

local Data = setmetatable ({}, {
  __tostring = function () return "Data" end
})
local Proxy = setmetatable ({}, {
  __tostring = function () return "Proxy" end
})
local Reference = setmetatable ({}, {
  __tostring = function () return "Reference" end
})
local Key = setmetatable ({
  __tostring = function (self) return "-" .. self.name .. "-" end
}, {
  __tostring = function () return "Key" end
})

local IgnoreNone   = {}
local IgnoreKeys   = { __mode = "k"  }
local IgnoreValues = { __mode = "v"  }
--local IgnoreAll    = { __mode = "kv" }

local Read_Only = {
  __index    = function () assert (false) end,
  __newindex = function () assert (false) end,
}

-- ----------------------------------------------------------------------
-- ## Data
-- ----------------------------------------------------------------------

Data.key = setmetatable ({
  checks   = setmetatable ({ name = "checks"   }, Key),
  defaults = setmetatable ({ name = "defaults" }, Key),
  deleted  = setmetatable ({ name = "deleted"  }, Key),
  labels   = setmetatable ({ name = "labels"   }, Key),
  meta     = setmetatable ({ name = "meta"     }, Key),
  refines  = setmetatable ({ name = "refines"  }, Key),
}, Read_Only)

Data.tag = setmetatable ({
  null      = setmetatable ({ name = "null"      }, Key),
  computing = setmetatable ({ name = "computing" }, Key),
}, Read_Only)

Data.coroutine  = Coromake ()
Data.hidden     = setmetatable ({}, IgnoreKeys  )
Data.loaded     = setmetatable ({}, IgnoreValues)
Data.children   = setmetatable ({}, IgnoreKeys  )
Data.references = setmetatable ({}, IgnoreKeys  )

function Data.new (t)
  assert (t == nil or type (t) == "table")
  t = t or {}
  assert (t.above    == nil or getmetatable (t.above   ) == Proxy)
  assert (t.write_to == nil or getmetatable (t.write_to) == Proxy)
  local layer = setmetatable ({}, Data)
  Data.hidden [layer] = {
    name         = t.name      or Uuid (),
    above        = t.above     or nil,
    data         = t.data      or {},
    write_to     = t.write_to  or nil,
    observers    = {},
    replacements = setmetatable ({}, { __mode = "k" }),
  }
  local hidden = Data.hidden [layer]
  local ref
  local proxy = Proxy.new (layer)
  if t.above then
    ref = Data.ref (t.above)
    proxy [Data.key.refines] = { t.above }
    Data.replace (proxy, t.above)
  else
    ref = Reference.new (proxy)
  end
  hidden.proxy = proxy
  hidden.ref   = ref
  Data.loaded [hidden.name] = proxy
  return proxy, ref
end

function Data.__tostring (layer)
  assert (getmetatable (layer) == Data)
  return "layer:" .. tostring (Data.hidden [layer].name)
end

function Data.require (name)
  local loaded = Data.loaded [name]
  if loaded then
    local layer = Data.hidden [loaded].layer
    local info  = Data.hidden [layer]
    return info.proxy, info.ref
  else
    local layer, ref = Data.new {
      name = name,
    }
    require (name) (Data, layer, ref)
    Data.loaded [name] = layer
    return layer, ref
  end
end

function Data.clear ()
  local Metatable = IgnoreNone
  Data.caches = {
    index        = setmetatable ({}, Metatable),
    pairs        = setmetatable ({}, Metatable),
    ipairs       = setmetatable ({}, Metatable),
    len          = setmetatable ({}, Metatable),
    check        = setmetatable ({}, Metatable),
    exists       = setmetatable ({}, Metatable),
    dependencies = setmetatable ({}, Metatable),
    resolve      = setmetatable ({}, Metatable),
    lt           = setmetatable ({}, Metatable),
  }
  Data.statistics = {
    index        = setmetatable ({}, Metatable),
    pairs        = setmetatable ({}, Metatable),
    ipairs       = setmetatable ({}, Metatable),
    len          = setmetatable ({}, Metatable),
    check        = setmetatable ({}, Metatable),
    exists       = setmetatable ({}, Metatable),
    dependencies = setmetatable ({}, Metatable),
  }
  Data.messages = setmetatable ({}, IgnoreKeys)
end

function Data.replace (proxy, with)
  assert (getmetatable (proxy) == Proxy)
  assert (getmetatable (with ) == Proxy or with == nil)
  local layer = Data.hidden [proxy].layer
  Data.hidden [layer].replacements [proxy] = with
end

function Data.ref (proxy)
  assert (getmetatable (proxy) == Proxy)
  local layer = Data.hidden [proxy].layer
  local ref   = Data.hidden [layer].ref
  for _, key in ipairs (Data.hidden [proxy].keys) do
    ref = ref [key]
  end
  return ref
end

function Data.is_empty (proxy)
  assert (getmetatable (proxy) == Proxy and #Data.hidden [proxy].keys == 0)
  local layer = Data.hidden [proxy].layer
  local data  = Data.hidden [layer].data
  return not not next (data)
end

function Data.write_to (proxy, to)
  assert (getmetatable (proxy) == Proxy and #Data.hidden [proxy].keys == 0)
  assert (not to or getmetatable (to) == Proxy)
  local layer    = Data.hidden [proxy].layer
  local info     = Data.hidden [layer]
  local previous = info.write_to
  info.write_to  = to
  return previous
end

function Data.dump (proxy)
  assert (getmetatable (proxy) == Proxy and #Data.hidden [proxy].keys == 0)
  local layer  = Data.hidden [proxy].layer
  local labels = {}
  if Data.hidden [layer].data [Data.key.labels] then
    for label, _ in pairs (Data.hidden [layer].data [Data.key.labels]) do
      labels [label] = true
    end
  end
  local layers_n    = 1
  local seen_layers = {}
  local seen_keys   = {}
  local function convert (x)
    if type (x) == "string" then
      return string.format ("%q", x)
    elseif type (x) == "number"
        or type (x) == "boolean" then
      return tostring (x)
    elseif getmetatable (x) == Key then
      seen_keys [x] = true
      return x.name
    elseif getmetatable (x) == Proxy then
      local p = Data.hidden [x]
      local l = Data.hidden [p.layer]
      local result = "Data.require " .. string.format ("%q", l.name)
      for _, v in ipairs (p.keys) do
        local s
        if type (v) == "string" then
          s = v:match "^[_%a][_%w]*$"
          and "." .. v
           or "[" .. convert (v) .. "]"
        else
          s = "[" .. convert (v) .. "]"
        end
        result  = result .. s
      end
      return result
    elseif getmetatable (x) == Reference then
      local reference = Data.hidden [x]
      local result
      if labels [reference.from] then
        result = "ref"
      else
        for name, p in pairs (Data.loaded) do
          local l   = Data.hidden [p].layer
          local ref = Data.hidden [l].ref
          if ref and Data.hidden [ref].from == reference.from then
            seen_layers [name] = layers_n
            result   = "r" .. tostring (layers_n)
            layers_n = layers_n+1
            break
          end
        end
        if not result then
          result = "Data.reference (" .. string.format ("%q", reference.from) .. ")"
        end
      end
      for _, v in ipairs (reference.keys) do
        local s
        if type (v) == "string" then
          s = v:match "^[_%a][_%w]*$"
          and "." .. v
           or "[" .. convert (v) .. "]"
        else
          s = "[" .. convert (v) .. "]"
        end
        result  = result .. s
      end
      return result
    elseif type (x) == "table" then
      local result = {}
      for k, v in pairs (x) do
        if k == Data.key.labels then
          local ls = {}
          for kl, vl in pairs (v) do
            if not labels [kl] then
              ls [convert (kl)] = convert (vl)
            end
          end
          if next (ls) then
            result [convert (k)] = ls
          end
        else
          result [convert (k)] = convert (v)
        end
      end
      return result
    elseif type (x) == "function" then
      return nil, "cannot dump functions"
    else
      assert (false)
    end
  end
  local function indent (x, level)
    local indentation = ""
    for _ = 1, level do
      indentation = indentation .. "  "
    end
    if type (x) == "string" then
      return x
    elseif type (x) == "table" then
      local lines = {}
      for k, v in pairs (x) do
        local match = k:match [[^"([_%a][_%w]*)"$]]
        local key
        if match then
          key = match
        else
          key = "[" .. k .. "]"
        end
        lines [#lines+1] = {
          key   = key,
          value = indent (v, level+1),
        }
      end
      table.sort (lines, function (l, r) return l.key < r.key end)
      for i, line in ipairs (lines) do
        lines [i] = indentation .. "  " .. line.key .. " = " .. line.value .. ","
      end
      return "{\n" .. table.concat (lines, "\n") .. "\n" .. indentation .. "}"
    else
      assert (false)
    end
  end
  local result = {
    [[return function (Data, layer, ref)]],
    [[end]],
  }
  local locals    = {}
  local imports   = {}
  local contents  = {}
  local keys      = {}
  -- body
  local body  = convert (Data.hidden [layer].data)
  local lines = {}
  for k, v in pairs (body) do
    local match = k:match [[^"([_%a][_%w]*)"$]]
    local key
    if match then
      key = "." .. match
    else
      key = " [" .. k .. "]"
    end
    lines [#lines+1] = {
      key   = key,
      value = indent (v, 1),
    }
  end
  table.sort (lines, function (l, r) return l.key < r.key end)
  for _, line in ipairs (lines) do
    contents [#contents+1] = "  layer" .. line.key .. " = " .. line.value
  end
  -- locals
  for x in pairs (seen_keys) do
    keys [#keys+1] = x
  end
  table.sort (keys, function (l, r) return l.name < r.name end)
  for _, t in ipairs (keys) do
    locals [#locals+1] = "  local " .. t.name .. " = Data.key." .. t.name
  end
  -- imports
  for x, n in pairs (seen_layers) do
    local key   = "local l" .. tostring (n) .. ", r" .. tostring (n)
    local value = "Data.require " .. string.format ("%q", x)
    imports [#imports+1] = {
      key   = key,
      value = value,
    }
  end
  table.sort (imports, function (l, r) return l.key < r.key end)
  for i, t in ipairs (imports) do
    imports [i] = "  " .. t.key .. " = " .. t.value
  end
  -- output
  if #locals ~= 0 then
    table.insert (result, #result, table.concat (locals, "\n"))
  end
  if #imports ~= 0 then
    table.insert (result, #result, table.concat (imports, "\n"))
  end
  if #contents ~= 0 then
    table.insert (result, #result, table.concat (contents, "\n"))
  end
  return table.concat (result, "\n")
end

function Data.merge (source, target)
  assert (getmetatable (source) == Proxy and #Data.hidden [source].keys == 0)
  assert (getmetatable (target) == Proxy and #Data.hidden [target].keys == 0)
  local function iterate (s, t)
    assert (type (s) == "table")
    assert (getmetatable (t) == Proxy)
    for k, v in pairs (s) do
      if k == Data.key.checks
      or k == Data.key.defaults
      or k == Data.key.labels
      or v == Data.key.deleted
      or k == Data.key.refines
      or getmetatable (v) == Reference
      or getmetatable (v) == Proxy
      or type (v) ~= "table"
      then
        t [k] = v
      elseif type (t [k]) == "table" then
        iterate (v, t [k])
      else
        t [k] = {}
        iterate (v, t [k])
      end
    end
  end
  source = Data.hidden [source].layer
  iterate (Data.hidden [source].data, target)
end

-- ----------------------------------------------------------------------
-- ## Observers
-- ----------------------------------------------------------------------

local Observer = {}
Observer.__index = Observer

function Data.observe (proxy, f)
  assert (getmetatable (proxy) == Proxy)
  assert (type (f) == "function" or (getmetatable (f) and getmetatable (f).__call))
  local layer    = Data.hidden [proxy].layer
  local observer = setmetatable ({}, Observer)
  Data.hidden [observer] = {
    layer   = layer,
    handler = f,
  }
  return observer:enable ()
end

function Observer.enable (observer)
  assert (getmetatable (observer) == Observer)
  local layer = Data.hidden [observer].layer
  local info  = Data.hidden [layer]
  info.observers [observer] = true
  return observer
end

function Observer.disable (observer)
  assert (getmetatable (observer) == Observer)
  local layer = Data.hidden [observer].layer
  local info  = Data.hidden [layer]
  info.observers [observer] = nil
  return observer
end

-- ----------------------------------------------------------------------
-- ## Proxies
-- ----------------------------------------------------------------------

function Proxy.new (layer)
  assert (getmetatable (layer) == Data)
  local proxy = setmetatable ({}, Proxy)
  Data.hidden [proxy] = {
    layer  = layer,
    keys   = {},
    parent = false,
  }
  return proxy
end

function Proxy.__tostring (proxy)
  assert (getmetatable (proxy) == Proxy)
  local result = {}
  local hidden = Data.hidden [proxy]
  local keys   = hidden.keys
  result [1]   = tostring (hidden.layer)
  for i = 1, #keys do
    result [i+1] = "[" .. tostring (keys [i]) .. "]"
  end
  return table.concat (result, " ")
end

function Proxy.messages (proxy)
  assert (getmetatable (proxy) == Proxy)
  return Data.messages [proxy]
end

function Proxy.child (proxy, key)
  assert (getmetatable (proxy) == Proxy)
  assert (key ~= nil)
  local layer = Data.hidden [proxy].layer
  key         = Data.hidden [layer].replacements [key] or key
  local found = Data.children [proxy]
            and Data.children [proxy] [key]
  if found then
    return found
  end
  local result = setmetatable ({}, Proxy)
  local hidden = Data.hidden [proxy]
  local keys   = {}
  for i, k in ipairs (hidden.keys) do
    keys [i] = k
  end
  keys [#keys+1] = key
  Data.hidden [result] = {
    layer  = hidden.layer,
    keys   = keys,
    parent = proxy,
  }
  Data.children [proxy] = Data.children [proxy]
                        or setmetatable ({}, IgnoreValues)
  Data.children [proxy] [key] = result
  return result
end

function Proxy.check (proxy)
  assert (getmetatable (proxy) == Proxy)
  local cache = Data.caches.check
  if cache [proxy] then
    return
  end
  cache [proxy] = true
  local hidden = Data.hidden [proxy]
  for _, key in ipairs (hidden.keys) do
    if getmetatable (key) == Key then
      return
    end
  end
  local checks = proxy [Data.key.checks]
  if not checks then
    return
  end
  local messages = Data.messages [proxy] or {}
  for _, f in Proxy.__pairs (checks) do
    assert (type (f) == "function")
    local co = Data.coroutine.wrap (function ()
      return f (proxy)
    end)
    for id, data in co do
      messages [id] = data or {}
    end
  end
  if next (messages) then
    Data.messages [proxy] = messages
  else
    Data.messages [proxy] = nil
  end
end

function Proxy.check_all (proxy)
  assert (getmetatable (proxy) == Proxy)
  local seen = {}
  local function iterate (x)
    assert (getmetatable (x) == Proxy)
    seen [x] = true
    Proxy.check (x)
    for _, child in Data.pairs (x) do
      if getmetatable (child) == Proxy and not seen [child] then
        iterate (child)
      end
    end
  end
  iterate (proxy)
end

function Proxy.__index (proxy, key)
  assert (getmetatable (proxy) == Proxy)
  local child  = Proxy.child (proxy, key)
  local cached = Data.caches.index [child]
  if cached == Data.tag.null
  or cached == Data.tag.computing then
    return nil
  elseif cached ~= nil then
    return cached
  end
  local result
  Data.statistics.index [child] = (Data.statistics.index [child] or 0) + 1
  Data.caches    .index [child] = Data.tag.computing
  if Proxy.exists (child) then
    for _, value in Proxy.dependencies (child) do
      if value ~= nil then
        if getmetatable (value) == Reference then
          result = Reference.resolve (value, child)
        elseif getmetatable (value) == Proxy then
          result = value
        elseif value == Data.key.deleted then
          result = nil
        elseif type (value) == "table" then
          result = child
        else
          result = value
        end
        break
      end
    end
  end
  if result == nil then
    Data.caches.index [child] = Data.tag.null
  else
    Data.caches.index [child] = result
  end
  if Data.check and getmetatable (result) == Proxy then
    Proxy.check (result)
  end
  return result
end

function Proxy.raw (proxy)
  assert (getmetatable (proxy) == Proxy)
  local hidden  = Data.hidden [proxy]
  local layer   = Data.hidden [hidden.layer]
  local current = layer.data
  local keys    = hidden.keys
  for _, key in ipairs (keys) do
    if  type (current) == "table"
    and getmetatable (current) ~= Proxy
    and getmetatable (current) ~= Reference then
      current = current [key]
    else
      current = nil
    end
  end
  return current
end

function Proxy.__newindex (proxy, key, value)
  assert (getmetatable (proxy) == Proxy)
  assert ( type (key) ~= "table"
        or getmetatable (key) == Proxy
        or getmetatable (key) == Reference
        or getmetatable (key) == Key)
  local layer     = Data.hidden [proxy].layer
  local info      = Data.hidden [layer]
  local keys      = Data.hidden [proxy].keys
  key             = Data.hidden [layer].replacements [key] or key
  local coroutine = Coromake ()
  local observers = {}
  for observer in pairs (info.observers) do
    observers [observer] = assert (coroutine.create (Data.hidden [observer].handler))
  end
  local old_value = proxy [key]
  for _, co in pairs (observers) do
    assert (coroutine.resume (co, coroutine, proxy, key, old_value))
  end
  if info.write_to then
    assert (info.write_to ~= false)
    local newp = info.write_to
    for _, k in ipairs (keys) do
      newp = Proxy.child (newp, k)
    end
    newp [key] = value
  else
    local current = info.data
    for _, k in ipairs (keys) do
      if current [k] == nil then
        current [k] = {}
      end
      current = current [k]
    end
    if value == nil then
      current [key] = Data.key.deleted
    else
      current [key] = value
    end
  end
  local new_value = proxy [key]
  for _, co in pairs (observers) do
    coroutine.resume (co, new_value)
  end
  Data.clear ()
  if Data.check then
    Proxy.check (proxy)
  end
end

function Proxy.keys (proxy)
  assert (getmetatable (proxy) == Proxy)
  local hidden    = Data.hidden [proxy]
  local coroutine = Coromake ()
  return coroutine.wrap (function ()
    for i, key in ipairs (hidden.keys) do
      coroutine.yield (i, key)
    end
  end)
end

function Proxy.exists (proxy)
  assert (getmetatable (proxy) == Proxy)
  if Data.caches.exists [proxy] ~= nil then
    return Data.caches.exists [proxy]
  end
  Data.statistics.exists [proxy] = (Data.statistics.exists [proxy] or 0) + 1
  local result = false
  local hidden = Data.hidden [proxy]
  if hidden.parent then
    for _, raw in Proxy.dependencies (hidden.parent) do
      if  type (raw) == "table"
      and getmetatable (raw) ~= Proxy
      and getmetatable (raw) ~= Reference
      and raw [hidden.keys [#hidden.keys]] ~= nil then
        local value = raw [hidden.keys [#hidden.keys]]
        if  getmetatable (value) == Reference then
          result = true
        else
          result = true
        end
        break
      end
    end
  else
    result = Proxy.raw (proxy) ~= nil
         and Proxy.raw (proxy) ~= Data.key.deleted
  end
  Data.caches.exists [proxy] = result
  return result
end

local function reverse (t)
  for i = 1, math.floor (#t / 2) do
    t [i], t [#t-i+1] = t [#t-i+1], t [i]
  end
  return t
end

function Proxy.dependencies (proxy)
  assert (getmetatable (proxy) == Proxy)
  local cache  = Data.caches.dependencies
  local result = cache [proxy]
  local dependencies_cache = setmetatable ({}, IgnoreKeys)
  local refines_cache      = setmetatable ({}, IgnoreKeys)
  if result == nil then
    Data.statistics.dependencies [proxy] = (Data.statistics.dependencies [proxy] or 0) + 1
    if Proxy.exists (proxy) then
      local refines, dependencies
      local c3 = C3 {
        superclass = function (p)
          return p and refines (p) or {}
        end,
      }

      dependencies = function (x)
        assert (getmetatable (x) == Proxy)
        local found = dependencies_cache [x]
        if found == Data.tag.null then
          return nil
        elseif found ~= nil then
          assert (found ~= Data.tag.computing)
          return found
        end
        dependencies_cache [x] = Data.tag.computing
        local all = c3 (x)
        reverse (all)
        dependencies_cache [x] = all ~= nil and all or Data.tag.null
        return all
      end

      refines = function (x)
        assert (getmetatable (x) == Proxy)
        local found = refines_cache [x]
        if found == Data.tag.null then
          return nil
        elseif found ~= nil then
          assert (found ~= Data.tag.computing)
          return found
        end
        refines_cache [x] = Data.tag.computing
        local hidden      = Data.hidden [x]
        local raw         = Proxy.raw (x)
        local all         = {}
        local refinments  = {
          refines = {},
          parents = {},
        }
        for _, key in ipairs (hidden.keys) do
          if key == Data.key.defaults
          or key == Data.key.refines then
            refines_cache [proxy] = all ~= nil and all or Data.tag.null
            return all
          end
        end
        local in_special = getmetatable (hidden.keys [#hidden.keys]) == Key
        repeat
          if getmetatable (raw) == Proxy then
            raw = Proxy.raw (raw)
          elseif getmetatable (raw) == Reference then
            raw = Reference.resolve (raw, proxy)
          end
        until getmetatable (raw) ~= Proxy and getmetatable (raw) ~= Reference
        if type (raw) == "table" then
          for _, refine in ipairs (raw [Data.key.refines] or {}) do
            refinments.refines [#refinments.refines+1] = refine
          end
        end
        if hidden.parent then
          local exists  = Proxy.exists (x)
          local key     = hidden.keys [#hidden.keys]
          local parents = {}
          for parent in Proxy.dependencies (hidden.parent) do
            parents [#parents+1] = parent
          end
          reverse (parents)
          for _, parent in ipairs (parents) do
            local child = Proxy.child (parent, key)
            if parent ~= hidden.parent and Proxy.exists (child) then
              refinments.parents [#refinments.parents+1] = child
            end
            local raw_parent = Proxy.raw (parent)
            if not in_special and exists and raw_parent then
              repeat
                if getmetatable (raw_parent) == Proxy then
                  raw_parent = Proxy.raw (raw_parent)
                elseif getmetatable (raw_parent) == Reference then
                  raw_parent = Reference.resolve (raw_parent, proxy)
                end
              until getmetatable (raw_parent) ~= Proxy and getmetatable (raw_parent) ~= Reference
              for _, default in ipairs (raw_parent and raw_parent [Data.key.defaults] or {}) do
                refinments.parents [#refinments.parents+1] = default
              end
            end
          end
        end
        local parent    = Data.hidden [proxy].parent
        local flattened = {}
        local seen      = {
          [x] = true,
        }
        for _, container in ipairs {
          refinments.parents,
          refinments.refines,
        } do
          for _, refine in ipairs (container) do
            while refine and getmetatable (refine) == Reference do
              refine = Reference.resolve (refine, parent)
            end
            if getmetatable (refine) == Proxy then
              flattened [#flattened+1] = refine
            end
          end
        end
        for i = #flattened, 1, -1 do
          local element = flattened [i]
          if not seen [element] then
            seen [element] = true
            all  [#all+1 ] = element
          end
        end
        reverse (all)
        refines_cache [proxy] = all ~= nil and all or Data.tag.null
        return all
      end

      result = dependencies (proxy)
    else
      result = {}
    end
    cache [proxy] = result
  end
  return coroutine.wrap (function ()
    for _, x in ipairs (result) do
      coroutine.yield (x, Proxy.raw (x))
    end
  end)
end

function Proxy.__lt (lhs, rhs)
  assert (getmetatable (lhs) == Proxy)
  assert (getmetatable (rhs) == Proxy)
  if not Data.caches.lt [lhs] then
    Data.caches.lt [lhs] = setmetatable ({}, IgnoreNone)
  end
  if Data.caches.lt [lhs] [rhs] ~= nil then
    return Data.caches.lt [lhs] [rhs]
  end
  for p in Proxy.dependencies (rhs, { all = true }) do
    if getmetatable (p) == Proxy and p == lhs then
      Data.caches.lt [lhs] [rhs] = true
      return true
    end
  end
  Data.caches.lt [lhs] [rhs] = false
  return false
end

function Proxy.__le (lhs, rhs)
  if lhs == rhs then
    return true
  else
    return Proxy.__lt (lhs, rhs)
  end
end

function Proxy.project (proxy, what)
  assert (getmetatable (proxy) == Proxy)
  assert (getmetatable (what ) == Proxy)
  local lhs_proxy = Data.hidden [proxy]
  local rhs_proxy = Data.hidden [what]
  local rhs_layer = Data.hidden [rhs_proxy.layer]
  local result    = rhs_layer.proxy
  for _, key in ipairs (lhs_proxy.keys) do
    result = type (result) == "table"
         and result [key]
          or nil
  end
  return result
end

function Proxy.parent (proxy)
  assert (getmetatable (proxy) == Proxy)
  local hidden = Data.hidden [proxy]
  return hidden.parent
end

function Proxy.__len (proxy)
  assert (getmetatable (proxy) == Proxy)
  local cache = Data.caches.len
  if cache [proxy] then
    return cache [proxy]
  end
  for i = 1, math.huge do
    if proxy [i] == nil then
      cache [proxy] = i-1
      return i-1
    end
  end
end

function Proxy.__ipairs (proxy)
  assert (getmetatable (proxy) == Proxy)
  local cache = Data.caches.ipairs
  if cache [proxy] then
    return coroutine.wrap (function ()
      for i, v in ipairs (cache [proxy]) do
        coroutine.yield (i, v)
      end
    end)
  end
  Data.statistics.ipairs [proxy] = (Data.statistics.ipairs [proxy] or 0) + 1
  local coroutine = Coromake ()
  local cached = {}
  for i = 1, math.huge do
    local result = proxy [i]
    if result == nil then
      break
    end
    result = proxy [i]
    cached [i] = result
  end
  cache [proxy] = cached
  return coroutine.wrap (function ()
    for i, result in ipairs (cache [proxy]) do
      coroutine.yield (i, result)
    end
  end)
end

function Proxy.__pairs (proxy)
  assert (getmetatable (proxy) == Proxy)
  local coroutine = Coromake ()
  local cache     = Data.caches.pairs
  if cache [proxy] then
    return coroutine.wrap (function ()
      for k, v in pairs (cache [proxy]) do
        coroutine.yield (k, v)
      end
    end)
  end
  Data.statistics.pairs [proxy] = (Data.statistics.pairs [proxy] or 0) + 1
  local result = {}
  for _, current in Proxy.dependencies (proxy) do
    while getmetatable (current) == Reference do
      current = Reference.resolve (current, proxy)
    end
    local iter
    if getmetatable (current) == Proxy then
      iter = Proxy.__pairs
    elseif type (current) == "table" then
      iter = pairs
    end
    if iter then
      for k in iter (current) do
        if  result  [k] == nil
        and getmetatable (k) ~= Data.Key then
          result [k] = proxy [k]
        end
      end
    end
  end
  cache [proxy] = result
  return coroutine.wrap (function ()
    for k, v in pairs (result) do
      coroutine.yield (k, v)
    end
  end)
end

function Reference.new (target)
  local found = Data.references [target]
  if found then
    return found
  end
  if type (target) == "string" then
    local result = setmetatable ({}, Reference)
    Data.hidden [result] = {
      from = target,
      keys = {},
    }
    Data.references [target] = result
    return result
  elseif getmetatable (target) == Proxy then
    local label = Uuid ()
    if not target [Data.key.labels] then
      target [Data.key.labels] = {}
    end
    target [Data.key.labels] [label] = true
    local result = setmetatable ({}, Reference)
    Data.hidden [result] = {
      from = label,
      keys = {},
    }
    Data.references [target] = result
    return result
  else
    assert (false)
  end
end

function Reference.__tostring (reference)
  assert (getmetatable (reference) == Reference)
  local hidden = Data.hidden [reference]
  local result = {}
  result [1] = tostring (hidden.from)
  result [2] = "->"
  for i, key in ipairs (hidden.keys) do
    result [i+2] = "[" .. tostring (key) .. "]"
  end
  return table.concat (result, " ")
end

function Reference.__index (reference, key)
  if type (key) == "number" then assert (key < 10) end
  assert (getmetatable (reference) == Reference)
  local found = Data.children [reference]
            and Data.children [reference] [key]
  if found then
    return found
  end
  local hidden = Data.hidden [reference]
  local keys = {}
  for i, k in ipairs (hidden.keys) do
    keys [i] = k
  end
  keys [#keys+1] = key
  local result = setmetatable ({}, Reference)
  Data.hidden [result] = {
    parent = reference,
    from   = hidden.from,
    keys   = keys,
  }
  Data.children [reference] = Data.children [reference]
                            or setmetatable ({}, IgnoreValues)
  Data.children [reference] [key] = result
  return result
end

function Reference.resolve (reference, proxy)
  assert (getmetatable (reference) == Reference)
  if getmetatable (proxy) ~= Proxy then
    return nil
  end
  local cache  = Data.caches.resolve
  local cached = cache [proxy]
             and cache [proxy] [reference]
  if cached == Data.tag.null or cached == Data.tag.computing then
    return nil
  elseif cached then
    return cached
  end
  cache [proxy] = cache [proxy] or setmetatable ({}, IgnoreNone)
  local ref_hidden = Data.hidden [reference]
  local current    = proxy
  do
    while current do
      if  current
      and current [Data.key.labels]
      and current [Data.key.labels] [ref_hidden.from] then
        break
      end
      current = Data.hidden [current].parent
    end
    if not current then
      cache [proxy] [reference] = Data.tag.null
      return nil
    end
  end
  for _, key in ipairs (ref_hidden.keys) do
    while getmetatable (current) == Reference do
      current = Reference.resolve (current, proxy)
    end
    if getmetatable (current) ~= Proxy then
      cache [proxy] [reference] = Data.tag.null
      return nil
    end
    current = current [key]
  end
  cache [proxy] [reference] = current
  return current
end

Data.Proxy     = Proxy
Data.Reference = Reference
Data.Key       = Key
Data.reference = Reference.new

-- Lua 5.1 compatibility:
Data.len    = Proxy.__len
Data.pairs  = Proxy.__pairs
Data.ipairs = Proxy.__ipairs

Data.clear ()

return Data
