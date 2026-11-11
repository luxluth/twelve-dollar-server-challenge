const std = @import("std");

pub const BATCH_SIZE = 32;
pub const RAW_BUF_SIZE = 2048;
pub const RESP_BUF_SIZE = 8192;

pub const Route = enum(u16) {
    empty = 0,
    health,
    feed,
    get_post,
    create_post,
    like_post,
    // errors
    err_not_found,
    err_invalid_post_id,
    err_post_not_found,
    err_missing_bearer,
    err_invalid_token,
    err_invalid_payload,
    err_malformed_json,
    err_body_required,
    err_body_too_long,
    err_internal,
};

pub const BatchState = struct {
    count: usize = 0,
    fds: [BATCH_SIZE]i32 align(64) = @splat(-1),
    slots: [BATCH_SIZE]u32 align(64) = @splat(0),
    gens: [BATCH_SIZE]u32 align(64) = @splat(0),
    buf_ids: [BATCH_SIZE]u16 align(64) = @splat(0),
    raw_bufs: [BATCH_SIZE][RAW_BUF_SIZE]u8 align(64) = undefined,
    buf_lens: [BATCH_SIZE]usize align(64) = @splat(0),
    route_ids: [BATCH_SIZE]Route align(64) = @splat(Route.empty),
    user_ids: [BATCH_SIZE]i64 align(64) = @splat(0),
    post_ids: [BATCH_SIZE]i64 align(64) = @splat(0),
    authors: [BATCH_SIZE][64]u8 align(64) = undefined,
    author_lens: [BATCH_SIZE]u8 align(64) = @splat(0),
    bodies: [BATCH_SIZE][1024]u8 align(64) = undefined,
    body_lens: [BATCH_SIZE]u16 align(64) = @splat(0),
    status_codes: [BATCH_SIZE]u16 align(64) = @splat(0),
    keep_alive: [BATCH_SIZE]bool align(64) = @splat(true),
    response_bufs: [BATCH_SIZE][RESP_BUF_SIZE]u8 align(64) = undefined,
    response_lens: [BATCH_SIZE]usize align(64) = @splat(0),

    pub fn reset(self: *BatchState) void {
        self.count = 0;
    }
};
