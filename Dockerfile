FROM saucisson/openresty
MAINTAINER Alban Linard <alban@linard.fr>

ADD . /src/ardoises
RUN   apk add --no-cache --virtual .build-deps \
          build-base \
          cmake \
          make \
          perl \
          openssl-dev \
  &&  apk add --no-cache libstdc++ \
  &&  cd /src/ardoises/ \
  &&  cp config.lua     /config.lua \
  &&  cp mime.types     /mime.types \
  &&  cp nginx.conf     /nginx.conf \
  &&  cp models.lua     /models.lua \
  &&  cp migrations.lua /migrations.lua \
  &&  cp -r views       /views \
  &&  cp -r static      /static \
  &&  luarocks install  rockspec/netstring-1.0.3-0.rockspec \
  &&  luarocks install  rockspec/lulpeg-develop-0.rockspec \
  &&  luarocks install  rockspec/lua-resty-qless-develop-0.rockspec \
  &&  luarocks install  rockspec/lua-websockets-develop-0.rockspec \
  &&  luarocks make     rockspec/ardoises-master-1.rockspec \
  &&  git config --system user.name  "Ardoises" \
  &&  git config --system user.email "editor@ardoises.ovh" \
  &&  rm -rf            /src/ardoises \
  &&  apk del           .build-deps
