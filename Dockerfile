FROM alpine:edge

ARG RESTY_VERSION="1.11.2.1"

ADD . /src/ardoises

RUN apk add --no-cache --virtual .build-deps \
        build-base \
        cmake \
        make \
        openssl-dev \
        pcre-dev \
        perl \
        python3 \
        readline-dev \
        zlib-dev \
 && apk add --no-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ \
        dockerize \
 && apk add --no-cache \
        curl \
        git \
        libstdc++ \
        openssl \
        pcre \
        readline \
        unzip \
        zlib \
 && pip3 install hererocks \
 && hererocks --luajit=2.1 --luarocks=^ --compat=5.2 /usr \
 && luarocks install luasec \
 && cd /tmp \
 && curl -fSL https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz -o openresty-${RESTY_VERSION}.tar.gz \
 && tar xzf openresty-${RESTY_VERSION}.tar.gz \
 && cd /tmp/openresty-${RESTY_VERSION} \
 && ./configure --with-ipv6 \
                --with-pcre-jit \
                --with-threads \
                --with-luajit=/usr \
 && make \
 && make install \
 && rm -rf openresty-${RESTY_VERSION}.tar.gz openresty-${RESTY_VERSION} \
 && ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log \
 && ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log \
 && cd /src/ardoises/ \
 && cp -r data/* / \
 && cp -r views  /views \
 && cp -r static /static \
 && luarocks install rockspec/lulpeg-develop-0.rockspec \
 && luarocks install rockspec/lua-resty-qless-develop-0.rockspec \
 && luarocks install rockspec/lua-websockets-develop-0.rockspec \
 && luarocks make    rockspec/ardoises-master-1.rockspec \
 && git config --system user.name  "Ardoises" \
 && git config --system user.email "editor@ardoises.ovh" \
 && rm -rf /src/ardoises \
 && apk del .build-deps

ENV PATH /usr/local/openresty/bin/:$PATH
