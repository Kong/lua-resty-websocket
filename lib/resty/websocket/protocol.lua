-- Copyright (C) Yichun Zhang (agentzh)


local bit = require "bit"
local ffi = require "ffi"


local byte = string.byte
local char = string.char
local sub = string.sub
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
--local tohex = bit.tohex
local tostring = tostring
local concat = table.concat
local rand = math.random
local type = type
local debug = ngx.config.debug
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ffi_new = ffi.new
local ffi_string = ffi.string
local buffer = require "string.buffer"


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local DEBUG = false

local function printf(...)
  return print(string.format(...))
end


local _M = new_tab(0, 5)

_M.new_tab = new_tab
_M._VERSION = '0.2.0'


local types = {
    [0x0] = "continuation",
    [0x1] = "text",
    [0x2] = "binary",
    [0x8] = "close",
    [0x9] = "ping",
    [0xa] = "pong",
}

local str_buf_size = 4096
local str_buf
local c_buf_type = ffi.typeof("char[?]")


local function get_string_buf(size)
    if size > str_buf_size then
        return ffi_new(c_buf_type, size)
    end
    if not str_buf then
        str_buf = ffi_new(c_buf_type, str_buf_size)
    end

    return str_buf
end

local buf = buffer.new(2^24)

function _M.recv_frame(sock, max_payload_len, force_masking)
    local data, err = sock:receive(2)
    if not data then
        return nil, nil, "failed to receive the first 2 bytes: " .. err
    end

    local fst, snd = byte(data, 1, 2)

    local fin = band(fst, 0x80) ~= 0
    -- print("fin: ", fin)

    if band(fst, 0x70) ~= 0 then
        return nil, nil, "bad RSV1, RSV2, or RSV3 bits"
    end

    local opcode = band(fst, 0x0f)
    -- print("opcode: ", tohex(opcode))

    if opcode >= 0x3 and opcode <= 0x7 then
        return nil, nil, "reserved non-control frames"
    end

    if opcode >= 0xb and opcode <= 0xf then
        return nil, nil, "reserved control frames"
    end

    local mask = band(snd, 0x80) ~= 0

    if debug then
        ngx_log(ngx_DEBUG, "recv_frame: mask bit: ", mask and 1 or 0)
    end

    if force_masking and not mask then
        return nil, nil, "frame unmasked"
    end

    local payload_len = band(snd, 0x7f)
    -- print("payload len: ", payload_len)

    if payload_len == 126 then
        local data, err = sock:receive(2)
        if not data then
            return nil, nil, "failed to receive the 2 byte payload length: "
                             .. (err or "unknown")
        end

        payload_len = bor(lshift(byte(data, 1), 8), byte(data, 2))

    elseif payload_len == 127 then
        local data, err = sock:receive(8)
        if not data then
            return nil, nil, "failed to receive the 8 byte payload length: "
                             .. (err or "unknown")
        end

        if byte(data, 1) ~= 0
           or byte(data, 2) ~= 0
           or byte(data, 3) ~= 0
           or byte(data, 4) ~= 0
        then
            return nil, nil, "payload len too large"
        end

        local fifth = byte(data, 5)
        if band(fifth, 0x80) ~= 0 then
            return nil, nil, "payload len too large"
        end

        payload_len = bor(lshift(fifth, 24),
                          lshift(byte(data, 6), 16),
                          lshift(byte(data, 7), 8),
                          byte(data, 8))
    end

    if band(opcode, 0x8) ~= 0 then
        -- being a control frame
        if payload_len > 125 then
            return nil, nil, "too long payload for control frame"
        end

        if not fin then
            return nil, nil, "fragmented control frame"
        end
    end

    -- print("payload len: ", payload_len, ", max payload len: ",
          -- max_payload_len)

    if payload_len > max_payload_len then
        return nil, nil, "exceeding max payload len"
    end

    local rest
    if mask then
        rest = payload_len + 4

    else
        rest = payload_len
    end
    -- print("rest: ", rest)

    local data
    if rest > 0 then
        data, err = sock:receive(rest)
        if not data then
            return nil, nil, "failed to read masking-len and payload: "
                             .. (err or "unknown")
        end
    else
        data = ""
    end

    -- print("received rest")

    if opcode == 0x8 then
        -- being a close frame
        if payload_len > 0 then
            if payload_len < 2 then
                return nil, nil, "close frame with a body must carry a 2-byte"
                                 .. " status code"
            end

            local msg, code
            if mask then
                local fst = bxor(byte(data, 4 + 1), byte(data, 1))
                local snd = bxor(byte(data, 4 + 2), byte(data, 2))
                code = bor(lshift(fst, 8), snd)

                if payload_len > 2 then
                  assert(#buf == 0)

                    -- TODO string.buffer optimizations
                    local bytes = get_string_buf(payload_len - 2)
                    for i = 3, payload_len do
                        bytes[i - 3] = bxor(byte(data, 4 + i),
                                            byte(data, (i - 1) % 4 + 1))
                    end
                    msg = ffi_string(bytes, payload_len - 2)

                else
                    msg = ""
                end

            else
                local fst = byte(data, 1)
                local snd = byte(data, 2)
                code = bor(lshift(fst, 8), snd)

                -- print("parsing unmasked close frame payload: ", payload_len)

                if payload_len > 2 then
                    msg = sub(data, 3)

                else
                    msg = ""
                end
            end

            return msg, "close", code
        end

        return "", "close", nil
    end

    local msg
    if mask then
        buf:set(data)
        local bytes = buf:ref()
        for i = 1, payload_len do
            bytes[3 + i] = bxor(bytes[3 + i], bytes[(i - 1) % 4])
        end
        msg = buf:skip(4):get(payload_len)

    else
        msg = data
    end

    return msg, types[opcode], not fin and "again" or nil
end

local function build_frame(fin, opcode, payload_len, payload, masking)
  assert(#buf == 0)

  buf:putf("%c", bor(opcode, (fin and 0x80 or 0x0)))

  local mask_bit = masking and 0x80 or 0x0

  -- 7 bit length
  if payload_len <= 125 then
    buf:putf("%c", bor(payload_len, mask_bit))

  -- 7 + 16 bit length
  elseif payload_len <= 65535 then
    buf:putf("%c%c%c",
             bor(126, mask_bit),
             band(rshift(payload_len, 8), 0xff),
             band(payload_len, 0xff))

  -- 7 + 64 bit length
  else
    if band(payload_len, 0x7fffffff) < payload_len then
      return nil, "payload too big"
    end

    -- XXX we only support 31-bit length here
    buf:putf("%c%c%c%c%c%c%c%c%c",
             bor(127, mask_bit),
             0, 0, 0, 0,
             band(rshift(payload_len, 24), 0xff),
             band(rshift(payload_len, 16), 0xff),
             band(rshift(payload_len, 8), 0xff),
             band(payload_len, 0xff))
  end

  if masking then
    local key = rand(0xffffffff)
    local mask_offset = #buf

    buf:putf("%c%c%c%c%s",
      band(rshift(key, 24), 0xff),
      band(rshift(key, 16), 0xff),
      band(rshift(key, 8), 0xff),
      band(key, 0xff),
      payload
    )

    local offset = mask_offset + 4
    local ptr = buf:ref()

    for i = 0, payload_len - 1 do
      ptr[offset + i] = bxor(ptr[offset + i], ptr[mask_offset + (i % 4)])
    end

  else
    buf:put(payload)
  end

  return buf:get()
end

_M.build_frame = build_frame

function _M.send_frame(sock, fin, opcode, payload, max_payload_len, masking)
  if not payload then
    payload = ""

  elseif type(payload) ~= "string" then
    payload = tostring(payload)
  end

  local payload_len = #payload

  if payload_len > max_payload_len then
    return nil, "payload too big"
  end

  if band(opcode, 0x8) ~= 0 then
    -- being a control frame
    if payload_len > 125 then
      return nil, "too much payload for control frame"
    end
    if not fin then
      return nil, "fragmented control frame"
    end
  end

  local frame, err = build_frame(fin, opcode, payload_len, payload, masking)
  if not frame then
    return nil, "failed to build frame: " .. err
  end

  local bytes, err = sock:send(frame)
  if not bytes then
    return nil, "failed to send frame: " .. err
  end
  return bytes
end


return _M
