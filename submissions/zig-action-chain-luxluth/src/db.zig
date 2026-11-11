const std = @import("std");

pub extern "c" fn ac_db_open(path: [*:0]const u8) c_int;
pub extern "c" fn ac_db_close() void;
pub extern "c" fn ac_db_health() c_int;

pub extern "c" fn ac_db_begin_batch() c_int;
pub extern "c" fn ac_db_commit_batch() c_int;
pub extern "c" fn ac_db_rollback_batch() void;

pub extern "c" fn ac_db_feed(out_buf: [*]u8, cap: usize, out_len: *usize) c_int;
pub extern "c" fn ac_db_get_post(id: i64, out_buf: [*]u8, cap: usize, out_len: *usize) c_int;

pub extern "c" fn ac_db_create_post(
    user_id: i64,
    author: [*]const u8,
    author_len: usize,
    body: [*]const u8,
    body_len: usize,
    out_buf: [*]u8,
    cap: usize,
    out_len: *usize,
) c_int;

pub extern "c" fn ac_db_like(user_id: i64, post_id: i64) c_int;
pub extern "c" fn ac_db_writes_allowed() c_int;

pub fn open(path: [:0]const u8) !void {
    if (ac_db_open(path.ptr) != 0) return error.DbOpenFailed;
}

pub fn close() void {
    ac_db_close();
}

pub fn health() bool {
    return ac_db_health() == 0;
}

pub fn beginBatch() !void {
    if (ac_db_begin_batch() != 0) return error.DbBeginFailed;
}

pub fn commitBatch() !void {
    if (ac_db_commit_batch() != 0) return error.DbCommitFailed;
}

pub fn rollbackBatch() void {
    ac_db_rollback_batch();
}

pub fn feed(out_buf: []u8) !usize {
    var len: usize = 0;
    if (ac_db_feed(out_buf.ptr, out_buf.len, &len) != 0) return error.DbFeedFailed;
    return len;
}

pub const GetPostResult = union(enum) {
    found: usize,
    not_found,
    err,
};

pub fn getPost(id: i64, out_buf: []u8) GetPostResult {
    var len: usize = 0;
    const rc = ac_db_get_post(id, out_buf.ptr, out_buf.len, &len);
    if (rc == 1) return .{ .found = len };
    if (rc == 0) return .not_found;
    return .err;
}

pub fn createPost(user_id: i64, author: []const u8, body: []const u8, out_buf: []u8) !usize {
    var len: usize = 0;
    const rc = ac_db_create_post(
        user_id,
        author.ptr,
        author.len,
        body.ptr,
        body.len,
        out_buf.ptr,
        out_buf.len,
        &len,
    );
    if (rc != 0) return error.DbCreateFailed;
    return len;
}

pub const LikeResult = enum {
    liked,
    already_liked,
    not_found,
    err,
};

pub fn like(user_id: i64, post_id: i64) LikeResult {
    const rc = ac_db_like(user_id, post_id);
    if (rc == 1) return .liked;
    if (rc == 2) return .already_liked;
    if (rc == 0) return .not_found;
    return .err;
}
