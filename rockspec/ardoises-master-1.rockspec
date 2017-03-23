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
  "dkjson",
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
    ["ardoises.jsonhttp.common"      ] = "src/ardoises/jsonhttp/common.lua",
    ["ardoises.jsonhttp.copas"       ] = "src/ardoises/jsonhttp/copas.lua",
    ["ardoises.jsonhttp.js"          ] = "src/ardoises/jsonhttp/js.lua",
    ["ardoises.jsonhttp.resty-redis" ] = "src/ardoises/jsonhttp/resty-redis.lua",
    ["ardoises.jsonhttp.socket-redis"] = "src/ardoises/jsonhttp/socket-redis.lua",
    ["ardoises.patterns"             ] = "src/ardoises/patterns.lua",
    ["ardoises.client"               ] = "src/ardoises/client/init.lua",
    ["ardoises.client.js"            ] = "src/ardoises/client/js.lua",
    ["ardoises.client.web"           ] = "src/ardoises/client/web.lua",
    ["ardoises.editor"               ] = "src/ardoises/editor/init.lua",
    ["ardoises.server"               ] = "src/ardoises/server/init.lua",
    ["ardoises.server.config"        ] = "src/ardoises/server/config.lua",
  },
  install = {
    bin = {
      ["ardoises-editor"    ] = "src/ardoises/editor/bin.lua",
      ["ardoises-server"    ] = "src/ardoises/server/bin.lua",
      ["ardoises-clean"     ] = "src/ardoises/util/clean.lua",
      ["ardoises-invitation"] = "src/ardoises/util/invitation.lua",    },
  },
}
