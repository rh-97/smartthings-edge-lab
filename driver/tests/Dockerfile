# Lua 5.3 (same major version as the hub), LuaSocket, cosock and dkjson,
# plus Python for the virtual devices.
FROM alpine:3.20
RUN apk add --no-cache lua5.3 lua5.3-dev luarocks5.3 build-base openssl-dev python3 \
 && luarocks-5.3 install luasocket \
 && luarocks-5.3 install dkjson \
 && luarocks-5.3 install cosock
WORKDIR /lab
