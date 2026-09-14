# vim:set ft= ts=4 sw=4 et:

# Regression tests for IPv6 URI parsing in resty.websocket.client.
#
# The tests assert on the address nginx logs for its connect() attempt rather
# than on a successful handshake. This keeps them deterministic on hosts
# without IPv6 connectivity: the address must survive URI parsing intact even
# when the connection itself cannot be made.

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

no_long_string();

run_tests();

__DATA__

=== TEST 1: bracketed IPv6 host with a port
# The address must be unroutable. A refused connection, which is what a
# reachable [::1] gives, produces no "connect() to" line in the error log.
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua_block {
            local client = require "resty.websocket.client"
            local wb = assert(client:new())
            wb:set_timeout(500)
            -- nosemgrep -- the plaintext scheme is what this block tests
            local ok, err = wb:connect("ws://[fd99::2]:65535/s")
            ngx.say("ok: ", tostring(ok))
            ngx.say("err: ", tostring(err))
        }
    }
--- request
GET /c
--- response_body_like
^ok: nil
err: failed to connect: .*$
--- error_log
connect() to [fd99::2]:65535



=== TEST 2: bracketed IPv6 host without a port defaults to 80
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua_block {
            local client = require "resty.websocket.client"
            local wb = assert(client:new())
            wb:set_timeout(500)
            -- nosemgrep -- the plaintext scheme is what this block tests
            local ok, err = wb:connect("ws://[fd99::1]/s")
            ngx.say("ok: ", tostring(ok))
            ngx.say("err: ", tostring(err))
        }
    }
--- request
GET /c
--- response_body_like
^ok: nil
err: failed to connect: .*$
--- error_log
connect() to [fd99::1]:80



=== TEST 3: bracketed IPv6 host, wss defaults to 443
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua_block {
            local client = require "resty.websocket.client"
            local wb = assert(client:new())
            wb:set_timeout(500)
            local ok, err = wb:connect("wss://[2001:db8::dead:beef]/s")
            ngx.say("ok: ", tostring(ok))
            ngx.say("err: ", tostring(err))
        }
    }
--- request
GET /c
--- response_body_like
^ok: nil
err: failed to connect: .*$
--- error_log
connect() to [2001:db8::dead:beef]:443



=== TEST 4: IPv4 host with a port is unchanged
# A mis-parsed host would surface as a resolver or parse error here, not as a
# refused connection, so the error message alone proves the parse is intact.
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua_block {
            local client = require "resty.websocket.client"
            local wb = assert(client:new())
            wb:set_timeout(500)
            -- nosemgrep -- the plaintext scheme is what this block tests
            local ok, err = wb:connect("ws://127.0.0.1:65535/s")
            ngx.say("ok: ", tostring(ok))
            ngx.say("err: ", tostring(err))
        }
    }
--- request
GET /c
--- response_body
ok: nil
err: failed to connect: connection refused
--- no_error_log
[alert]



=== TEST 5: an unclosed bracket is rejected, not silently mangled
# The fallback host branch must not accept "[", or the trailing (.*) hides the
# bad parse and a mangled host reaches the socket layer.
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua_block {
            local client = require "resty.websocket.client"
            local wb = assert(client:new())
            wb:set_timeout(500)
            -- nosemgrep -- the plaintext scheme is what this block tests
            local ok, err = wb:connect("ws://[fd99::1:65535/s")
            ngx.say("ok: ", tostring(ok))
            ngx.say("err: ", tostring(err))
        }
    }
--- request
GET /c
--- response_body
ok: nil
err: bad websocket uri
--- no_error_log
[alert]
