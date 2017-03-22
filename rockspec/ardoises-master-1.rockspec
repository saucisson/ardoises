package = "ardoises"
version = "master-1"
source  = {
  url    = "git+https://github.com/ardoises/ardoises.git",
  branch = "master",
}

description = {
  summary    = "Ardoises",
  detailed   = [[]],
  homepage   = "https://github.com/ardoises",
  license    = "MIT/X11",
  maintainer = "Alban Linard <alban@linard.fr>",
}

dependencies = {
  "lua >= 5.1",
  "argparse",
  "copas",
  "coronest",
  "etlua",
  "lpeg",
  "layeredata",
  "luaossl",
  "luaposix",
  "luasec",
  "luasocket",
  "lua-resty-cookie",
  "lua-resty-http",
  "lua-resty-jwt",
  "lua-websockets",
  "lustache",
  "net-url",
  "rapidjson",
  "redis-lua",
}

build = {
  type    = "builtin",
  modules = {
    ["ardoises.js"             ] = "src/ardoises/js.lua",
    ["ardoises.jsonhttp"       ] = "src/ardoises/jsonhttp.lua",
    ["ardoises.patterns"       ] = "src/ardoises/patterns.lua",
    ["ardoises.client"         ] = "src/ardoises/client/init.lua",
    ["ardoises.client.jsonhttp"] = "src/ardoises/client/jsonhttp.lua",
    ["ardoises.editor"         ] = "src/ardoises/editor/init.lua",
    ["ardoises.editor.jsonhttp"] = "src/ardoises/editor/jsonhttp.lua",
    ["ardoises.util.jsonhttp"  ] = "src/ardoises/util/jsonhttp.lua",
    ["ardoises.server"         ] = "src/ardoises/server/init.lua",
    ["ardoises.server.config"  ] = "src/ardoises/server/config.lua",
    ["ardoises.server.jsonhttp"] = "src/ardoises/server/jsonhttp.lua",
  },
  install = {
    bin = {
      ["ardoises-editor"    ] = "src/ardoises/editor/bin.lua",
      ["ardoises-server"    ] = "src/ardoises/server/bin.lua",
      ["ardoises-clean"     ] = "src/ardoises/util/clean.lua",
      ["ardoises-invitation"] = "src/ardoises/util/invitation.lua",    },
  },
}
