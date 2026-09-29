# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use Socket qw(AF_INET6 SOCK_STREAM inet_pton pack_sockaddr_in6);

my $ipv6_available = 0;
eval {
    socket(my $s, AF_INET6, SOCK_STREAM, 0) or return;
    bind($s, pack_sockaddr_in6(0, inet_pton(AF_INET6, "::1"))) or return;
    $ipv6_available = 1;
};

if (!$ipv6_available) {
    plan skip_all => "IPv6 is not available in this environment";
}

repeat_each(2);

plan tests => repeat_each() * blocks() * 4;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_package_cpath "/usr/local/openresty-debug/lualib/?.so;/usr/local/openresty/lualib/?.so;;";
};

$ENV{TEST_NGINX_IPV6_PORT} ||= 1985;
$ENV{TEST_NGINX_IPV6_SSL_PORT} ||= 1986;

no_long_string();
#no_diff();

run_tests();

__DATA__

=== TEST 1: connect to an IPv6 literal
--- http_config eval
qq{
    $::HttpConfig
    server {
        listen [::1]:\$TEST_NGINX_IPV6_PORT;
        server_name ipv6.example.com;

        location = /s {
            content_by_lua '
                local server = require "resty.websocket.server"
                local wb, err = server:new()
                if not wb then
                    ngx.log(ngx.ERR, "failed to new websocket: ", err)
                    return ngx.exit(444)
                end

                local bytes, err = wb:send_text("hello ipv6")
                if not bytes then
                    ngx.log(ngx.ERR, "failed to send the 1st text: ", err)
                    return ngx.exit(444)
                end

                local data, err = wb:recv_frame()
                if not data then
                    ngx.log(ngx.ERR, "failed to receive a frame: ", err)
                    return ngx.exit(444)
                end

                bytes, err = wb:send_text(data)
                if not bytes then
                    ngx.log(ngx.ERR, "failed to send the 2nd text: ", err)
                    return ngx.exit(444)
                end
            ';
        }
    }
}
--- config
    location = /c {
        content_by_lua '
            local client = require "resty.websocket.client"
            local wb, err = client:new()
            if not wb then
                ngx.say("failed to new: ", err)
                return
            end

            local uri = "ws://[::1]:" .. $TEST_NGINX_IPV6_PORT .. "/s"
            local ok, err = wb:connect(uri)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local data, typ, err = wb:recv_frame()
            if not data then
                ngx.say("failed to receive 1st frame: ", err)
                return
            end
            ngx.say("1: received: ", data, " (", typ, ")")

            local bytes, err = wb:send_text("copy: " .. data)
            if not bytes then
                ngx.say("failed to send frame: ", err)
                return
            end

            data, typ, err = wb:recv_frame()
            if not data then
                ngx.say("failed to receive 2nd frame: ", err)
                return
            end
            ngx.say("2: received: ", data, " (", typ, ")")
        ';
    }
--- request
GET /c
--- response_body
1: received: hello ipv6 (text)
2: received: copy: hello ipv6 (text)
--- no_error_log
[error]
[warn]



=== TEST 2: default Host header keeps the IPv6 brackets
--- http_config eval
qq{
    $::HttpConfig
    server {
        listen [::1]:\$TEST_NGINX_IPV6_PORT;
        server_name ipv6.example.com;

        location = /s {
            content_by_lua '
                local server = require "resty.websocket.server"
                local wb, err = server:new()
                if not wb then
                    ngx.log(ngx.ERR, "failed to new websocket: ", err)
                    return ngx.exit(444)
                end

                local bytes, err = wb:send_text("Host: " ..
                                                (ngx.var.http_host or "nil"))
                if not bytes then
                    ngx.log(ngx.ERR, "failed to send text: ", err)
                    return ngx.exit(444)
                end
            ';
        }
    }
}
--- config
    location = /c {
        content_by_lua '
            local client = require "resty.websocket.client"
            local wb, err = client:new()
            if not wb then
                ngx.say("failed to new: ", err)
                return
            end

            local uri = "ws://[::1]:" .. $TEST_NGINX_IPV6_PORT .. "/s"
            local ok, err = wb:connect(uri)
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local data, typ, err = wb:recv_frame()
            if not data then
                ngx.say("failed to receive frame: ", err)
                return
            end

            if data == "Host: [::1]:" .. $TEST_NGINX_IPV6_PORT then
                ngx.say("host header ok")
            else
                ngx.say("unexpected host header: ", data)
            end
        ';
    }
--- request
GET /c
--- response_body
host header ok
--- no_error_log
[error]
[warn]



=== TEST 3: custom host option with brackets and port
--- http_config eval
qq{
    $::HttpConfig
    server {
        listen [::1]:\$TEST_NGINX_IPV6_PORT;
        server_name ipv6.example.com;

        location = /s {
            content_by_lua '
                local server = require "resty.websocket.server"
                local wb, err = server:new()
                if not wb then
                    ngx.log(ngx.ERR, "failed to new websocket: ", err)
                    return ngx.exit(444)
                end

                local bytes, err = wb:send_text("Host: " ..
                                                (ngx.var.http_host or "nil"))
                if not bytes then
                    ngx.log(ngx.ERR, "failed to send text: ", err)
                    return ngx.exit(444)
                end
            ';
        }
    }
}
--- config
    location = /c {
        content_by_lua '
            local client = require "resty.websocket.client"
            local wb, err = client:new()
            if not wb then
                ngx.say("failed to new: ", err)
                return
            end

            local uri = "ws://[::1]:" .. $TEST_NGINX_IPV6_PORT .. "/s"
            local ok, err = wb:connect(uri, {host = "[::1]:9999"})
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local data, typ, err = wb:recv_frame()
            if not data then
                ngx.say("failed to receive frame: ", err)
                return
            end
            ngx.say("received: ", data)
        ';
    }
--- request
GET /c
--- response_body
received: Host: [::1]:9999
--- no_error_log
[error]
[warn]



=== TEST 4: malformed bracketed host is rejected
--- http_config eval: $::HttpConfig
--- config
    location = /c {
        content_by_lua '
            local client = require "resty.websocket.client"
            local wb, err = client:new()
            if not wb then
                ngx.say("failed to new: ", err)
                return
            end

            local ok, err = wb:connect("ws://[bad")
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            ngx.say("unexpectedly connected")
        ';
    }
--- request
GET /c
--- response_body
failed to connect: bad websocket uri
--- no_error_log
[error]
[warn]



=== TEST 5: SSL (wss) over an IPv6 literal
--- http_config eval
qq{
    $::HttpConfig
    server {
        listen [::1]:\$TEST_NGINX_IPV6_SSL_PORT ssl;
        server_name ipv6.example.com;
        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;
        server_tokens off;

        location = /s {
            content_by_lua '
                local server = require "resty.websocket.server"
                local wb, err = server:new()
                if not wb then
                    ngx.log(ngx.ERR, "failed to new websocket: ", err)
                    return ngx.exit(444)
                end

                while true do
                    local data, err = wb:recv_frame()
                    if not data then
                        return ngx.exit(444)
                    end

                    local bytes, err = wb:send_text(data)
                    if not bytes then
                        return ngx.exit(444)
                    end
                end
            ';
        }
    }
}
--- config
    location = /c {
        content_by_lua '
            local client = require "resty.websocket.client"
            local wb, err = client:new()
            if not wb then
                ngx.say("failed to new: ", err)
                return
            end

            local uri = "wss://[::1]:" .. $TEST_NGINX_IPV6_SSL_PORT .. "/s"
            local ok, err = wb:connect(uri, {ssl_verify = false})
            if not ok then
                ngx.say("failed to connect: ", err)
                return
            end

            local bytes, err = wb:send_text("hello wss ipv6")
            if not bytes then
                ngx.say("failed to send frame: ", err)
                return
            end

            local data, typ, err = wb:recv_frame()
            if not data then
                ngx.say("failed to receive frame: ", err)
                return
            end
            ngx.say("received: ", data, " (", typ, ")")
        ';
    }
--- request
GET /c
--- response_body
received: hello wss ipv6 (text)
--- no_error_log
[error]
[warn]
--- timeout: 10
