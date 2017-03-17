package = "ardoises-server"
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
  "luaposix",
  "luasec",
  "luasocket",
  "lua-resty-cookie",
  "lua-resty-http",
  "lua-resty-jwt",
  "lustache",
  "net-url",
  "rapidjson",
  "redis-lua",
}

build = {
  type    = "builtin",
  modules = {
    ["ardoises.jsonhttp"       ] = "src/ardoises/jsonhttp.lua",
    ["ardoises.util.jsonhttp"  ] = "src/ardoises/util/jsonhttp.lua",
    ["ardoises.server"         ] = "src/ardoises/server/init.lua",
    ["ardoises.server.jsonhttp"] = "src/ardoises/server/jsonhttp.lua",
  },
  install = {
    bin = {
      ["ardoises-server"] = "src/ardoises/server/bin.lua",
    },
  },
}
