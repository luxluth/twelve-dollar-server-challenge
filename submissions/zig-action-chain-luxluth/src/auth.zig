const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const AuthError = enum {
    missing_bearer,
    invalid_or_expired,
    invalid_payload,
};

pub const AuthPayload = struct {
    user_id: i64,
    username: []const u8,
};

pub const AuthResult = union(enum) {
    ok: AuthPayload,
    err: AuthError,
};

var secret_key: []const u8 = "";

pub fn init(secret: []const u8) void {
    secret_key = secret;
}

const b64_table: [256]i8 = blk: {
    var t: [256]i8 = @splat(-1);
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (chars, 0..) |c, i| {
        t[c] = @intCast(i);
    }
    break :blk t;
};

pub fn b64urlDecode(s: []const u8, out: []u8) !usize {
    if (s.len % 4 == 1) return error.InvalidBase64;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var o: usize = 0;
    for (s) |ch| {
        const v = b64_table[ch];
        if (v < 0) return error.InvalidBase64;
        acc = (acc << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= out.len) return error.BufferTooSmall;
            out[o] = @truncate(acc >> bits);
            o += 1;
        }
    }
    return o;
}

pub fn verifyToken(header_val: []const u8, now_s: i64) AuthResult {
    const bearer_prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header_val, bearer_prefix)) {
        return .{ .err = .missing_bearer };
    }
    const token = header_val[bearer_prefix.len..];
    if (token.len == 0) return .{ .err = .missing_bearer };

    // Token has form: header.payload.signature
    var it = std.mem.splitScalar(u8, token, '.');
    const h_part = it.next() orelse return .{ .err = .invalid_or_expired };
    const p_part = it.next() orelse return .{ .err = .invalid_or_expired };
    const s_part = it.next() orelse return .{ .err = .invalid_or_expired };
    if (it.next() != null) return .{ .err = .invalid_or_expired };

    // Decode header
    var h_buf: [256]u8 = undefined;
    const h_len = b64urlDecode(h_part, &h_buf) catch return .{ .err = .invalid_or_expired };
    const header_json = h_buf[0..h_len];

    // Must be HS256
    if (!std.mem.containsAtLeast(u8, header_json, 1, "\"HS256\"")) {
        return .{ .err = .invalid_or_expired };
    }

    // Verify HMAC signature
    var sig_buf: [64]u8 = undefined;
    const sig_len = b64urlDecode(s_part, &sig_buf) catch return .{ .err = .invalid_or_expired };
    if (sig_len != 32) return .{ .err = .invalid_or_expired };

    const signing_input_len = h_part.len + 1 + p_part.len;
    var signing_input_buf: [1024]u8 = undefined;
    if (signing_input_len > signing_input_buf.len) return .{ .err = .invalid_or_expired };
    @memcpy(signing_input_buf[0..h_part.len], h_part);
    signing_input_buf[h_part.len] = '.';
    @memcpy(signing_input_buf[h_part.len + 1 ..][0..p_part.len], p_part);
    const signing_input = signing_input_buf[0..signing_input_len];

    var expected_sig: [32]u8 = undefined;
    HmacSha256.create(&expected_sig, signing_input, secret_key);

    if (!std.crypto.timing_safe.eql([32]u8, expected_sig, sig_buf[0..32].*)) {
        return .{ .err = .invalid_or_expired };
    }

    // Decode payload
    var p_buf: [1024]u8 = undefined;
    const p_len = b64urlDecode(p_part, &p_buf) catch return .{ .err = .invalid_or_expired };
    const payload_json = p_buf[0..p_len];

    // Extract exp
    const exp_val = extractJsonInt(payload_json, "exp") orelse return .{ .err = .invalid_or_expired };
    if (exp_val < now_s) {
        return .{ .err = .invalid_or_expired };
    }

    // Extract sub (must be positive integer string)
    const sub_str = extractJsonString(payload_json, "sub") orelse return .{ .err = .invalid_payload };
    if (sub_str.len == 0) return .{ .err = .invalid_payload };
    for (sub_str) |c| {
        if (c < '0' or c > '9') return .{ .err = .invalid_payload };
    }
    const user_id = std.fmt.parseInt(i64, sub_str, 10) catch return .{ .err = .invalid_payload };
    if (user_id <= 0) return .{ .err = .invalid_payload };

    // Extract username (must be string)
    const username = extractJsonString(payload_json, "username") orelse return .{ .err = .invalid_payload };
    if (username.len == 0) return .{ .err = .invalid_payload };

    return .{ .ok = .{ .user_id = user_id, .username = username } };
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const search_len = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const needle = search_buf[0..search_len.len];

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, needle)) |idx| {
        var p = idx + needle.len;
        // Skip whitespace
        while (p < json.len and (json[p] == ' ' or json[p] == '\t' or json[p] == '\r' or json[p] == '\n')) : (p += 1) {}
        if (p >= json.len or json[p] != ':') {
            pos = p;
            continue;
        }
        p += 1;
        while (p < json.len and (json[p] == ' ' or json[p] == '\t' or json[p] == '\r' or json[p] == '\n')) : (p += 1) {}
        if (p >= json.len or json[p] != '"') {
            return null;
        }
        p += 1;
        const start = p;
        while (p < json.len and json[p] != '"') : (p += 1) {
            if (json[p] == '\\') p += 1;
        }
        if (p > json.len) return null;
        return json[start..p];
    }
    return null;
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const search_len = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const needle = search_buf[0..search_len.len];

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, needle)) |idx| {
        var p = idx + needle.len;
        while (p < json.len and (json[p] == ' ' or json[p] == '\t' or json[p] == '\r' or json[p] == '\n')) : (p += 1) {}
        if (p >= json.len or json[p] != ':') {
            pos = p;
            continue;
        }
        p += 1;
        while (p < json.len and (json[p] == ' ' or json[p] == '\t' or json[p] == '\r' or json[p] == '\n')) : (p += 1) {}
        const start = p;
        if (p < json.len and json[p] == '-') p += 1;
        while (p < json.len and (json[p] >= '0' and json[p] <= '9')) : (p += 1) {}
        if (p == start) return null;
        return std.fmt.parseInt(i64, json[start..p], 10) catch null;
    }
    return null;
}

test "auth verification" {
    init("twelve-dollar-challenge");
    const now: i64 = 1731320000;

    // missing bearer
    try std.testing.expectEqual(AuthResult{ .err = .missing_bearer }, verifyToken("Basic 123", now));
    try std.testing.expectEqual(AuthResult{ .err = .missing_bearer }, verifyToken("", now));

    // invalid token
    try std.testing.expectEqual(AuthResult{ .err = .invalid_or_expired }, verifyToken("Bearer garbage", now));

    // valid token test
    const header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}
    const payload = "eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJhbGljZSIsImlhdCI6MTczMTMxMDAwMCwiZXhwIjoxNzMxMzMwMDAwfQ"; // {"sub":"1","username":"alice","iat":1731310000,"exp":1731330000}
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, header ++ "." ++ payload, "twelve-dollar-challenge");
    var sig_b64: [64]u8 = undefined;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var b_idx: usize = 0;
    var i: usize = 0;
    while (i < 32) : (i += 3) {
        const b0 = sig[i];
        const b1 = if (i + 1 < 32) sig[i + 1] else 0;
        const b2 = if (i + 2 < 32) sig[i + 2] else 0;
        sig_b64[b_idx] = alphabet[b0 >> 2];
        sig_b64[b_idx + 1] = alphabet[((b0 & 3) << 4) | (b1 >> 4)];
        b_idx += 2;
        if (i + 1 < 32) {
            sig_b64[b_idx] = alphabet[((b1 & 15) << 2) | (b2 >> 6)];
            b_idx += 1;
        }
        if (i + 2 < 32) {
            sig_b64[b_idx] = alphabet[b2 & 63];
            b_idx += 1;
        }
    }
    var tok_buf: [256]u8 = undefined;
    const tok = try std.fmt.bufPrint(&tok_buf, "Bearer {s}.{s}.{s}", .{ header, payload, sig_b64[0..b_idx] });
    const res = verifyToken(tok, now);
    switch (res) {
        .ok => |p| {
            try std.testing.expectEqual(@as(i64, 1), p.user_id);
            try std.testing.expectEqualStrings("alice", p.username);
        },
        .err => return error.AuthFailed,
    }
}

