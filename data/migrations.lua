local Schema     = require "lapis.db.schema"
local Database   = require "lapis.db"
local permission = [[ permission NOT NULL ]]

return {
  function ()
    Schema.create_table ("accounts", {
      { "id"      , Schema.types.integer { primary_key = true } },
      { "token"   , Schema.types.text    { null        = true } },
      { "contents", Schema.types.text },
    })
  end,
  function ()
    Schema.create_table ("repositories", {
      { "id"       , Schema.types.integer { primary_key = true } },
      { "full_name", Schema.types.text },
      { "contents" , Schema.types.text },
    })
  end,
  function ()
    Database.query [[
      CREATE TYPE permission AS ENUM ('read', 'write')
    ]]
    Schema.create_table ("permissions", {
      { "repository", Schema.types.integer },
      { "account"   , Schema.types.integer },
      { "permission", permission           },
      [[ PRIMARY KEY ("repository", "account") ]],
      [[ FOREIGN KEY ("repository") REFERENCES "repositories" ("id") ON DELETE CASCADE ]],
      -- [[ FOREIGN KEY ("account"   ) REFERENCES "accounts"     ("id") ON DELETE CASCADE ]],
    })
  end,
  function ()
    Schema.create_table ("editors", {
      { "repository", Schema.types.text    { primary_key = true } },
      { "docker"    , Schema.types.text    { null        = true } },
      { "url"       , Schema.types.text    { null        = true } },
      { "starting"  , Schema.types.boolean { default     = true } },
    })
  end,
}
