const std = @import("std");
const batch_mod = @import("batch.zig");
const BatchState = batch_mod.BatchState;
const Route = batch_mod.Route;
const db = @import("db.zig");

var start_time_s: i64 = 0;

pub fn init(start_time: i64) void {
    start_time_s = start_time;
}

pub fn handleBatch(batch: *BatchState, now_s: i64) void {
    var has_writes = false;
    for (0..batch.count) |i| {
        if (batch.route_ids[i] == .create_post or batch.route_ids[i] == .like_post) {
            has_writes = true;
            break;
        }
    }

    db.beginBatch() catch {
        for (0..batch.count) |i| {
            setError(batch, i, 500, "internal server error");
        }
        return;
    };

    for (0..batch.count) |i| {
        handleSlot(batch, i, now_s);
    }

    if (has_writes) {
        db.commitBatch() catch {
            db.rollbackBatch();
            for (0..batch.count) |i| {
                if (batch.route_ids[i] == .create_post or batch.route_ids[i] == .like_post) {
                    setError(batch, i, 500, "internal server error");
                }
            }
            return;
        };
    } else {
        db.commitBatch() catch {
            db.rollbackBatch();
        };
    }
}

fn handleSlot(batch: *BatchState, i: usize, now_s: i64) void {
    const route = batch.route_ids[i];
    switch (route) {
        .empty => {},
        .health => {
            if (db.health()) {
                const uptime = if (now_s >= start_time_s) now_s - start_time_s else 0;
                var buf: [128]u8 = undefined;
                const body = std.fmt.bufPrint(&buf, "{{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":{d}}}", .{uptime}) catch {
                    setError(batch, i, 500, "internal server error");
                    return;
                };
                setResponse(batch, i, 200, body);
            } else {
                setResponse(batch, i, 503, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"database unreachable\"}");
            }
        },
        .feed => {
            const resp_len = db.feed(&batch.response_bufs[i]) catch {
                setError(batch, i, 500, "internal server error");
                return;
            };
            batch.status_codes[i] = 200;
            batch.response_lens[i] = resp_len;
        },
        .get_post => {
            const res = db.getPost(batch.post_ids[i], &batch.response_bufs[i]);
            switch (res) {
                .found => |len| {
                    batch.status_codes[i] = 200;
                    batch.response_lens[i] = len;
                },
                .not_found => {
                    setError(batch, i, 404, "post not found");
                },
                .err => {
                    setError(batch, i, 500, "internal server error");
                },
            }
        },
        .like_post => {
            const res = db.like(batch.user_ids[i], batch.post_ids[i]);
            switch (res) {
                .liked => {
                    var buf: [128]u8 = undefined;
                    const body = std.fmt.bufPrint(&buf, "{{\"liked\":true,\"already_liked\":false,\"post_id\":{d}}}", .{batch.post_ids[i]}) catch {
                        setError(batch, i, 500, "internal server error");
                        return;
                    };
                    setResponse(batch, i, 201, body);
                },
                .already_liked => {
                    var buf: [128]u8 = undefined;
                    const body = std.fmt.bufPrint(&buf, "{{\"liked\":true,\"already_liked\":true,\"post_id\":{d}}}", .{batch.post_ids[i]}) catch {
                        setError(batch, i, 500, "internal server error");
                        return;
                    };
                    setResponse(batch, i, 200, body);
                },
                .not_found => {
                    setError(batch, i, 404, "post not found");
                },
                .err => {
                    setError(batch, i, 500, "internal server error");
                },
            }
        },
        .create_post => {
            const author = batch.authors[i][0..batch.author_lens[i]];
            const body = batch.bodies[i][0..batch.body_lens[i]];
            const resp_len = db.createPost(batch.user_ids[i], author, body, &batch.response_bufs[i]) catch {
                setError(batch, i, 500, "internal server error");
                return;
            };
            batch.status_codes[i] = 201;
            batch.response_lens[i] = resp_len;
        },
        .err_not_found => setError(batch, i, 404, "not found"),
        .err_invalid_post_id => setError(batch, i, 400, "invalid post id"),
        .err_post_not_found => setError(batch, i, 404, "post not found"),
        .err_missing_bearer => setError(batch, i, 401, "missing bearer token"),
        .err_invalid_token => setError(batch, i, 401, "invalid or expired token"),
        .err_invalid_payload => setError(batch, i, 401, "invalid token payload"),
        .err_malformed_json => setError(batch, i, 400, "malformed JSON body"),
        .err_body_required => setError(batch, i, 400, "body is required"),
        .err_body_too_long => setError(batch, i, 400, "body must be at most 500 characters"),
        .err_internal => setError(batch, i, 500, "internal server error"),
    }
}

fn setResponse(batch: *BatchState, i: usize, status: u16, body: []const u8) void {
    batch.status_codes[i] = status;
    @memcpy(batch.response_bufs[i][0..body.len], body);
    batch.response_lens[i] = body.len;
}

fn setError(batch: *BatchState, i: usize, status: u16, msg: []const u8) void {
    batch.status_codes[i] = status;
    const prefix = "{\"error\":\"";
    const suffix = "\"}";
    const total_len = prefix.len + msg.len + suffix.len;
    @memcpy(batch.response_bufs[i][0..prefix.len], prefix);
    @memcpy(batch.response_bufs[i][prefix.len..][0..msg.len], msg);
    @memcpy(batch.response_bufs[i][prefix.len + msg.len ..][0..suffix.len], suffix);
    batch.response_lens[i] = total_len;
}
