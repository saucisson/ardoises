local Et          = require "etlua"
local Content     = _G.js.global.document:getElementById "content"
Content.innerHTML = Et.render ([[
  <div class="section">
    <div class="container-fluid">
      <div class="row">
        <div class="col-sm-12 col-md-8 col-md-offset-2 text-center">
          <h1 class="text-primary">Ardoises</h1>
          <p class="text-info">Collaborative Edition for Formal Models</p>
        </div>
      </div>
    </div>
  </div>

  <div class="section">
    <div class="container-fluid">
      <div class="row">
        <div class="col-sm-12 col-md-8 col-md-offset-2">
          <h1 class="text-primary">Why?</h1>
          <p>
            Ardoises is a formal modeling platform. It aims at providing user-friendly
            edition of models expressed in several formalisms, such as automata, process
            algebra or different breeds of Petri nets. It also offers to launch services
            on the models, for instance to transform it or to check properties . This
            platform differs from most others, because it allows its users to define
            themselves new formalisms, either from scratch or built upon existing ones.
          </p>
        </div>
      </div>
    </div>
  </div>

  <% if not user then %>
  <div class="section">
    <div class="container-fluid">
      <div class="row">
        <div class="col-sm-12 col-md-8 col-md-offset-2 text-center">
          <h1>
            <a href="/login">
              <button type="button" class="btn btn-success">
                Log in <i class="fa fa-inverse fa-sign-in" aria-hidden="true"></i> and discover !
              </button>
            </a>
          </h1>
      </div>
    </div>
  </div>
  <% end %>
]], _G.js.configuration)
