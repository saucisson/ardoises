package = "lulpeg"
version = "develop-0"

source = {
  url    = "git+https://github.com/pygy/LuLPeg.git",
  branch = "master",
}

description = {
  summary     = "LuLPeg",
  detailed    = "LuLPeg, a pure Lua port of LPeg, Roberto Ierusalimschy's Parsing Expression Grammars library. Copyright (C) Pierre-Yves Gerardy.",
  license     = "The Romantic WTF public license",
  maintainer  = "pygy",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type    = "builtin",
  modules = {
    ["lulpeg"] = "lulpeg.lua",
  },
}
