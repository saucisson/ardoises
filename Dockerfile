FROM ardoises/openresty
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
  &&  luarocks install  rockspec/lua-resty-qless-develop-0.rockspec \
  &&  luarocks install  rockspec/lua-websockets-develop-0.rockspec \
  &&  luarocks make     rockspec/ardoises-master-1.rockspec \
  &&  rm -rf            /src/ardoises \
  &&  apk del .build-deps
