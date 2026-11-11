const std = @import("std");
const posix = std.posix;
const ac = @import("ac");
const BatchState = ac.batch.BatchState;
const Gobler = ac.gobler.Gobler;
const Responder = ac.responder.Responder;

pub fn main(init: std.process.Init) !void {
    // Ignore SIGPIPE
    var act: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
    act.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &act, null);

    const allocator = init.gpa;

    var env_map = init.environ_map;

    const sqlite_path = env_map.get("SQLITE_PATH") orelse "seed/feed.db";
    const jwt_secret = env_map.get("JWT_SECRET") orelse "twelve-dollar-challenge";
    const host = env_map.get("HOST") orelse "127.0.0.1";
    const port_str = env_map.get("PORT") orelse "3000";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 3000;

    // Initialize Auth
    ac.auth.init(jwt_secret);

    // Initialize Database
    var sqlite_path_buf: [4096:0]u8 = undefined;
    if (sqlite_path.len >= sqlite_path_buf.len) return error.PathTooLong;
    @memcpy(sqlite_path_buf[0..sqlite_path.len], sqlite_path);
    sqlite_path_buf[sqlite_path.len] = 0;
    const sqlite_path_z: [:0]const u8 = sqlite_path_buf[0..sqlite_path.len :0];

    try ac.db.open(sqlite_path_z);
    defer ac.db.close();

    const start_time: std.Io.Timestamp = .now(init.io, .real);
    ac.handler.init(start_time.toSeconds());

    // Stage 1: Gobbler
    var gobler: Gobler = undefined;
    try gobler.init(allocator, host, port);
    defer gobler.deinit();

    // Stage 4: Responder
    var responder = Responder.init();

    // Hot-path zero allocation micro-batch
    var batch: BatchState = .{};

    while (true) {
        // STAGE 1: GOBBLER — Ingest raw TCP stream slices (IORING_RECV_MULTISHOT)
        gobler.gobbleBatch(&batch, true) catch |err| {
            std.debug.print("Gobler error: {}\n", .{err});
            continue;
        };

        if (batch.count == 0) continue;

        const now: std.Io.Timestamp = .now(init.io, .real);
        const now_s = now.toSeconds();

        // STAGE 2: SHAPER & ROUTER — SIMD HTTP tokenization & fast JWT HS256 auth extraction
        ac.sham.shapeAndRoute(&batch, now_s);

        // STAGE 3: HANDLER — Direct mmap SQLite B-Tree walk (Reads) / Prepared VDBE step (Writes)
        ac.handler.handleBatch(&batch, now_s);

        // STAGE 4: RESPONDER — Hardcoded JSON string formatting & batched io_uring write submission
        responder.respondBatch(&batch, &gobler.ring) catch |err| {
            std.debug.print("Responder error: {}\n", .{err});
            continue;
        };
    }
}
