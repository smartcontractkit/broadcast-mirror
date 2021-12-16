FROM openresty/openresty:alpine-fat

WORKDIR /app

COPY *.lua /app/
COPY authorized_users authorized_users
COPY networks.json networks.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

EXPOSE 80/tcp

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-string
