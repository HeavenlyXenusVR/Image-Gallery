FROM alpine:3.20

# NOTE: Alpine 3.20's unversioned "luarocks" package is an empty stub (zero
# files) -- the real binary is luarocks-5.1, from the luarocks5.1 package.
# Same gotcha already hit and fixed for the 13 music bots' and SwarmPanel's
# Dockerfiles this session; do not revert to plain "luarocks".
RUN apk add --no-cache \
      luajit luajit-dev luarocks5.1 \
      build-base \
      libsodium-dev openssl-dev \
      git ca-certificates \
      ffmpeg

# luarocks-5.1's own Lua-detection defaults don't find LuaJIT's headers/libs
# (it looks for /usr/include/lua/5.1, not where luajit-dev actually installs
# them), so point it at the real paths before installing anything.
RUN luarocks-5.1 config variables.LUA_INCDIR /usr/include/luajit-2.1 \
 && luarocks-5.1 config variables.LUA_LIBDIR /usr/lib

# Same rock set as SwarmPanel/the bots (lua-shared/README.md), pinned to Lua
# 5.1 semantics so pgmoon/luasec/etc build against LuaJIT's ABI. cjson.safe
# (used throughout src/*.lua for decode-without-throwing) ships inside the
# lua-cjson rock, no separate install needed. copas/lua-websockets are
# installed for parity with httpd.lua's vendored capabilities (WebSocket
# upgrade path) even though this backend does not use WebSockets yet.
RUN luarocks-5.1 install luasocket \
 && luarocks-5.1 install luasec \
 && luarocks-5.1 install lua-cjson \
 && luarocks-5.1 install pgmoon \
 && luarocks-5.1 install luasodium \
 && luarocks-5.1 install lua-websockets \
 && luarocks-5.1 install copas

WORKDIR /app

# Copy backend source (including the vendored lib/swarmlua/pg.lua, copied
# verbatim from lua-shared/swarmlua/, and src/httpd.lua + src/auth.lua +
# ratelimit_mem.lua copied verbatim from SwarmPanel/lua/src/ -- see the
# comments at the top of each file for exactly what was reused vs adapted).
COPY . .

EXPOSE 8788

# GALLERY_DB_PORT in the existing .env is still 3306 (MariaDB) -- this
# backend needs GALLERY_PG_PORT=5432 set in the compose env (see final
# report for the exact docker-compose.yml / .env change needed). All other
# GALLERY_* env vars are read directly from the same .env file the Python
# backend already uses (see lua/src/config.lua's fallback chain).
CMD ["luajit", "main.lua"]
