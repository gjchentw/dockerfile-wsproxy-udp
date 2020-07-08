local server = require "resty.websocket.server"
local vstruct = require "vstruct"

local peer_addr = os.getenv("WSPROXY_ADDR")
local peer_port = os.getenv("WSPROXY_PORT")
local with_conn_data = os.getenv("WSPROXY_CONN_DATA")

function build_conn_data()
    local fmt = vstruct.compile("< s32")
    local remote_addr = ngx.var.http_x_real_ip or ngx.var.remote_addr

    return fmt:write({
        remote_addr
    })
end

function connect_udp_server()
    local sock = ngx.socket.udp()
    local ok, err = sock:setpeername(peer_addr, peer_port)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect to peer: ", err)
        return ngx.exit(555)
    end

    if with_conn_data then
        local _, err = sock:send(build_conn_data())
        if err then
           ngx.log(ngx.ERR, "failed to send conn data to peer: ", err)
           return ngx.exit(555)
        end
    end

    return sock
end

function start_websocket_server()
    local ws, err = server:new({
        timeout = 30*60*1000,  -- in milliseconds
        max_payload_len = 65535,
    })
    if not ws then
        ngx.log(ngx.ERR, "failed to new websocket: ", err)
        return ngx.exit(444)
    end
    return ws
end

function ws2sock(ws, sock)
    last_typ = ""
    while true do
        local data, typ, err = ws:recv_frame()
        if err or not data then
            ngx.log(ngx.ERR, "failed to receive a frame: ", err)
            return ngx.exit(444)
        end

        if typ == "continuation" then
            typ = last_typ
        end

        if typ == "binary" then
            _, err = sock:send(data)
            if err then
                ngx.log(ngx.ERR, "failed to send to peer: ", err)
                return ngx.exit(555)
            end
        elseif typ == "close" then
            sock:close()
            local _, err = ws:send_close(1000, "bye")
            if err then
                ngx.log(ngx.ERR, "failed to send the close frame: ", err)
                return
            end
            local code = err
            ngx.log(ngx.INFO, "closing with status code ", code, " and message ", data)
            return
        elseif typ == "ping" then
            -- send a pong frame back:
            local _, err = ws:send_pong(data)
            if err then
                ngx.log(ngx.ERR, "failed to send frame: ", err)
                return
            end
        elseif typ == "pong" then
            -- just discard the incoming pong frame
        else
            ngx.log(ngx.INFO, "received a frame of type ", typ, " and payload ", data)
        end

        last_typ = typ
    end
end

function sock2ws(sock, ws)
    while true do
        sock:settimeout(30*60*1000)
        data, err = sock:receive(1024)

        if not data then
        else
            bytes, err = ws:send_binary(data)
            if not bytes then
                ngx.log(ngx.ERR, "failed to send a binary frame: ", err)
                return ngx.exit(444)
            end
        end
    end
end

local ws = start_websocket_server()
local sock = connect_udp_server()
ngx.log(ngx.ERR, "client connect over websocket, ",
    ngx.var.server_name, ":", ngx.var.server_port, " ", ngx.var.server_protocol)
ngx.thread.spawn(ws2sock, ws, sock)
ngx.thread.spawn(sock2ws, sock, ws)
