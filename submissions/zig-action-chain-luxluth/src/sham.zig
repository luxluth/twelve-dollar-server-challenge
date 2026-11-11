const std = @import("std");
const batch_mod = @import("batch.zig");
const BatchState = batch_mod.BatchState;
const Route = batch_mod.Route;
const auth_mod = @import("auth.zig");

pub const Method = enum {
    GET,
    POST,
    OTHER,
};

pub fn shapeAndRoute(batch: *BatchState, now_s: i64) void {
    for (0..batch.count) |i| {
        routeSlot(batch, i, now_s);
    }
}

fn routeSlot(batch: *BatchState, i: usize, now_s: i64) void {
    const raw = batch.raw_bufs[i][0..batch.buf_lens[i]];
    if (raw.len < 4) {
        batch.route_ids[i] = .err_not_found;
        return;
    }

    // Find end of request line
    const eol = std.mem.indexOf(u8, raw, "\r\n") orelse std.mem.indexOfScalar(u8, raw, '\n') orelse {
        batch.route_ids[i] = .err_not_found;
        return;
    };
    const req_line = raw[0..eol];

    // Parse method
    var sp_it = std.mem.splitScalar(u8, req_line, ' ');
    const method_str = sp_it.next() orelse {
        batch.route_ids[i] = .err_not_found;
        return;
    };
    const uri = sp_it.next() orelse {
        batch.route_ids[i] = .err_not_found;
        return;
    };

    const method: Method = if (std.mem.eql(u8, method_str, "GET"))
        .GET
    else if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else
        .OTHER;

    // Scan headers & find body start
    const headers_start = eol + (if (raw[eol] == '\r') @as(usize, 2) else @as(usize, 1));
    var body_start: usize = raw.len;
    var auth_header: ?[]const u8 = null;
    var keep_alive = true;

    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |hend| {
        body_start = hend + 4;
        if (hend > headers_start) {
            parseHeaders(raw[headers_start..hend], &auth_header, &keep_alive);
        }
    } else if (std.mem.indexOf(u8, raw, "\n\n")) |hend| {
        body_start = hend + 2;
        if (hend > headers_start) {
            parseHeaders(raw[headers_start..hend], &auth_header, &keep_alive);
        }
    }
    batch.keep_alive[i] = keep_alive;

    const body = if (body_start < raw.len) raw[body_start..] else &.{};

    // Routing
    if (method == .GET and std.mem.eql(u8, uri, "/health")) {
        batch.route_ids[i] = .health;
        return;
    }

    if (method == .GET and std.mem.eql(u8, uri, "/feed")) {
        batch.route_ids[i] = .feed;
        return;
    }

    // Route: GET /posts/:id
    if (method == .GET and std.mem.startsWith(u8, uri, "/posts/")) {
        const id_str = uri["/posts/".len..];
        const post_id = parsePositiveId(id_str) orelse {
            batch.route_ids[i] = .err_invalid_post_id;
            return;
        };
        batch.post_ids[i] = post_id;
        batch.route_ids[i] = .get_post;
        return;
    }

    // Route: POST /posts/:id/like
    // Rule: Auth check FIRST, then ID check!
    if (method == .POST and std.mem.startsWith(u8, uri, "/posts/") and std.mem.endsWith(u8, uri, "/like")) {
        // 1. Auth check
        const auth_res = checkAuth(auth_header, now_s);
        switch (auth_res) {
            .ok => |p| {
                batch.user_ids[i] = p.user_id;
            },
            .err_missing_bearer => {
                batch.route_ids[i] = .err_missing_bearer;
                return;
            },
            .err_invalid_token => {
                batch.route_ids[i] = .err_invalid_token;
                return;
            },
            .err_invalid_payload => {
                batch.route_ids[i] = .err_invalid_payload;
                return;
            },
        }

        // 2. ID check
        const id_part = uri["/posts/".len .. uri.len - "/like".len];
        const post_id = parsePositiveId(id_part) orelse {
            batch.route_ids[i] = .err_invalid_post_id;
            return;
        };
        batch.post_ids[i] = post_id;
        batch.route_ids[i] = .like_post;
        return;
    }

    // Route: POST /posts
    if (method == .POST and std.mem.eql(u8, uri, "/posts")) {
        // 1. Auth check
        const auth_res = checkAuth(auth_header, now_s);
        switch (auth_res) {
            .ok => |p| {
                batch.user_ids[i] = p.user_id;
                const copy_len = @min(p.username.len, batch.authors[i].len);
                @memcpy(batch.authors[i][0..copy_len], p.username[0..copy_len]);
                batch.author_lens[i] = @intCast(copy_len);
            },
            .err_missing_bearer => {
                batch.route_ids[i] = .err_missing_bearer;
                return;
            },
            .err_invalid_token => {
                batch.route_ids[i] = .err_invalid_token;
                return;
            },
            .err_invalid_payload => {
                batch.route_ids[i] = .err_invalid_payload;
                return;
            },
        }

        // 2. Body check
        var decoded_buf: [1024]u8 = undefined;
        const body_res = parseAndValidateBody(body, &decoded_buf);
        switch (body_res) {
            .ok => |trimmed| {
                @memcpy(batch.bodies[i][0..trimmed.len], trimmed);
                batch.body_lens[i] = @intCast(trimmed.len);
                batch.route_ids[i] = .create_post;
            },
            .malformed_json => {
                batch.route_ids[i] = .err_malformed_json;
            },
            .body_required => {
                batch.route_ids[i] = .err_body_required;
            },
            .body_too_long => {
                batch.route_ids[i] = .err_body_too_long;
            },
        }
        return;
    }

    batch.route_ids[i] = .err_not_found;
}

fn parseHeaders(headers: []const u8, auth_out: *?[]const u8, keep_alive_out: *bool) void {
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "Authorization:") or std.mem.startsWith(u8, line, "authorization:")) {
            auth_out.* = std.mem.trim(u8, line["Authorization:".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "Connection:") or std.mem.startsWith(u8, line, "connection:")) {
            const val = std.mem.trim(u8, line["Connection:".len..], " \t");
            if (std.ascii.eqlIgnoreCase(val, "close")) {
                keep_alive_out.* = false;
            }
        }
    }
}

const AuthCheckResult = union(enum) {
    ok: auth_mod.AuthPayload,
    err_missing_bearer,
    err_invalid_token,
    err_invalid_payload,
};

fn checkAuth(auth_header: ?[]const u8, now_s: i64) AuthCheckResult {
    const hdr = auth_header orelse return .err_missing_bearer;
    const res = auth_mod.verifyToken(hdr, now_s);
    switch (res) {
        .ok => |p| return .{ .ok = p },
        .err => |e| switch (e) {
            .missing_bearer => return .err_missing_bearer,
            .invalid_or_expired => return .err_invalid_token,
            .invalid_payload => return .err_invalid_payload,
        },
    }
}

pub fn parsePositiveId(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
    }
    const val = std.fmt.parseInt(i64, s, 10) catch return null;
    if (val <= 0) return null;
    return val;
}

const BodyValidateResult = union(enum) {
    ok: []const u8,
    malformed_json,
    body_required,
    body_too_long,
};

pub fn parseAndValidateBody(raw_body: []const u8, out_buf: []u8) BodyValidateResult {
    const trimmed_input = std.mem.trim(u8, raw_body, " \t\r\n");
    if (trimmed_input.len == 0 or trimmed_input[0] != '{' or trimmed_input[trimmed_input.len - 1] != '}') {
        return .malformed_json;
    }

    // Look for "body"
    const key_pos = std.mem.indexOf(u8, trimmed_input, "\"body\"") orelse {
        // If it's valid JSON but without "body", it's body is required. If bad JSON, malformed.
        // Let's verify if JSON is syntactically malformed
        if (isMalformedJson(trimmed_input)) return .malformed_json;
        return .body_required;
    };

    var p = key_pos + "\"body\"".len;
    while (p < trimmed_input.len and (trimmed_input[p] == ' ' or trimmed_input[p] == '\t' or trimmed_input[p] == '\r' or trimmed_input[p] == '\n')) : (p += 1) {}
    if (p >= trimmed_input.len or trimmed_input[p] != ':') {
        return .malformed_json;
    }
    p += 1;
    while (p < trimmed_input.len and (trimmed_input[p] == ' ' or trimmed_input[p] == '\t' or trimmed_input[p] == '\r' or trimmed_input[p] == '\n')) : (p += 1) {}
    if (p >= trimmed_input.len) return .malformed_json;

    // Body value must be a string
    if (trimmed_input[p] != '"') {
        // Number, array, or object -> "body is required"
        return .body_required;
    }
    p += 1;

    // Decode JSON string escapes
    var out_idx: usize = 0;
    while (p < trimmed_input.len) {
        const c = trimmed_input[p];
        if (c == '"') {
            p += 1;
            break;
        }
        if (c == '\\') {
            p += 1;
            if (p >= trimmed_input.len) return .malformed_json;
            const esc = trimmed_input[p];
            p += 1;
            const ch: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => {
                    if (p + 4 > trimmed_input.len) return .malformed_json;
                    const hex_slice = trimmed_input[p .. p + 4];
                    p += 4;
                    const code_point = std.fmt.parseInt(u21, hex_slice, 16) catch return .malformed_json;
                    var utf8_buf: [4]u8 = undefined;
                    const cp_len = std.unicode.utf8Encode(code_point, &utf8_buf) catch return .malformed_json;
                    if (out_idx + cp_len > out_buf.len) return .body_too_long;
                    @memcpy(out_buf[out_idx..][0..cp_len], utf8_buf[0..cp_len]);
                    out_idx += cp_len;
                    continue;
                },
                else => return .malformed_json,
            };
            if (out_idx >= out_buf.len) return .body_too_long;
            out_buf[out_idx] = ch;
            out_idx += 1;
            continue;
        }
        if (out_idx >= out_buf.len) return .body_too_long;
        out_buf[out_idx] = c;
        out_idx += 1;
        p += 1;
    }

    // Trim decoded string
    const decoded = out_buf[0..out_idx];
    const trimmed = std.mem.trim(u8, decoded, " \t\r\n");
    if (trimmed.len == 0) return .body_required;

    // Check character length (codepoints)
    const cp_count = std.unicode.utf8CountCodepoints(trimmed) catch return .malformed_json;
    if (cp_count > 500) return .body_too_long;

    return .{ .ok = trimmed };
}

fn isMalformedJson(s: []const u8) bool {
    // Basic bracket and quote balance check
    var in_str = false;
    var esc = false;
    var braces: i32 = 0;
    for (s) |c| {
        if (esc) {
            esc = false;
            continue;
        }
        if (c == '\\' and in_str) {
            esc = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (!in_str) {
            if (c == '{') braces += 1;
            if (c == '}') braces -= 1;
        }
    }
    return in_str or braces != 0;
}

test "parsePositiveId" {
    try std.testing.expectEqual(@as(?i64, 1), parsePositiveId("1"));
    try std.testing.expectEqual(@as(?i64, 42), parsePositiveId("42"));
    try std.testing.expectEqual(@as(?i64, null), parsePositiveId("0"));
    try std.testing.expectEqual(@as(?i64, null), parsePositiveId("-1"));
    try std.testing.expectEqual(@as(?i64, null), parsePositiveId("abc"));
    try std.testing.expectEqual(@as(?i64, null), parsePositiveId("1.5"));
}

test "parseAndValidateBody" {
    var buf: [1024]u8 = undefined;
    const r1 = parseAndValidateBody("{\"body\":\"hello world\"}", &buf);
    switch (r1) {
        .ok => |t| try std.testing.expectEqualStrings("hello world", t),
        else => return error.Unexpected,
    }

    const r2 = parseAndValidateBody("{\"body\":\"  trimmed  \"}", &buf);
    switch (r2) {
        .ok => |t| try std.testing.expectEqualStrings("trimmed", t),
        else => return error.Unexpected,
    }

    const r3 = parseAndValidateBody("{\"body\":\"   \"}", &buf);
    try std.testing.expectEqual(BodyValidateResult.body_required, r3);

    const r4 = parseAndValidateBody("{}", &buf);
    try std.testing.expectEqual(BodyValidateResult.body_required, r4);

    const r5 = parseAndValidateBody("{bad json", &buf);
    try std.testing.expectEqual(BodyValidateResult.malformed_json, r5);
}

