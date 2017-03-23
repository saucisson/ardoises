local Adapter = require "ardoises.client.js"
local Common  = require "ardoises.jsonhttp.common"
local Copas   = require "copas"
local Json    = require "cjson"

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
  local r1 = Adapter.window:fetch (request.url, Adapter.tojs {
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
    return {
      status  = response.status,
      headers = response.headers,
      body    = json,
    }
  else
    return nil, err
  end
end)
