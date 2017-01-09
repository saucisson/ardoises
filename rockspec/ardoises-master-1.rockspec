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
  "ansicolors",
  "copas",
  "dkjson",
  "etlua",
  "lapis",
  "layeredata",
  "lpeg",
  "luaposix",
  "luasec",
  "luasocket",
  "lua-resty-exec",
  "lua-resty-http",
  "lua-resty-qless", -- FIXME: remove rockspec, fix wercker.yml and Dockerfile
  "lua-websockets",
  "rapidjson",
  "serpent",
  "yaml",
}

build = {
  type    = "builtin",
  modules = {
    ["ardoises.jsonhttp"            ] = "src/ardoises/jsonhttp.lua",
    ["ardoises.patterns"            ] = "src/ardoises/patterns.lua",
    ["ardoises.editor"              ] = "src/ardoises/editor/init.lua",
    ["ardoises.server"              ] = "src/ardoises/server/init.lua",
    ["ardoises.server.config"       ] = "src/ardoises/server/config.lua",
    ["ardoises.server.instance"     ] = "src/ardoises/server/instance.lua",
    ["ardoises.server.model"        ] = "src/ardoises/server/model.lua",
    ["ardoises.server.editors.clean"] = "src/ardoises/server/editors/clean.lua",
    ["ardoises.server.editors.start"] = "src/ardoises/server/editors/start.lua",
  },
  install = {
    bin = {
      ["ardoises-editor"] = "src/ardoises/editor/bin.lua",
      ["ardoises-server"] = "src/ardoises/server/bin.lua",
    },
  },
}
