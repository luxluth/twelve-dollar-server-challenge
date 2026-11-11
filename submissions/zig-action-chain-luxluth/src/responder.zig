const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const batch_mod = @import("batch.zig");
const BatchState = batch_mod.BatchState;
const BATCH_SIZE = batch_mod.BATCH_SIZE;

pub const FINAL_BUF_SIZE = 10240;

pub const Responder = struct {
    final_bufs: [BATCH_SIZE][FINAL_BUF_SIZE]u8 align(64) = undefined,
    final_lens: [BATCH_SIZE]usize align(64) = @splat(0),

    pub fn init() Responder {
        return .{};
    }

    pub fn respondBatch(self: *Responder, batch: *BatchState, ring: *IoUring) !void {
        var sends_queued: u32 = 0;

        for (0..batch.count) |i| {
            const fd = batch.fds[i];
            if (fd < 0) continue;

            const status = batch.status_codes[i];
            const reason = switch (status) {
                200 => "200 OK",
                201 => "201 Created",
                400 => "400 Bad Request",
                401 => "401 Unauthorized",
                404 => "404 Not Found",
                500 => "500 Internal Server Error",
                503 => "503 Service Unavailable",
                else => "444 Unexpected Error",
            };

            const body = batch.response_bufs[i][0..batch.response_lens[i]];
            const conn_str = if (batch.keep_alive[i]) "keep-alive" else "close";

            // Format header directly into final_bufs[i]
            var writer = std.Io.Writer.fixed(&self.final_bufs[i]);

            writer.print(
                "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
                .{ reason, body.len, conn_str },
            ) catch continue;

            const header_len = writer.end;
            if (header_len + body.len > FINAL_BUF_SIZE) continue;

            @memcpy(self.final_bufs[i][header_len..][0..body.len], body);
            self.final_lens[i] = header_len + body.len;

            const send_slice = self.final_bufs[i][0..self.final_lens[i]];

            // User data tagged with SEND (type 2) and slot index
            const user_data = (@as(u64, 2) << 32) | @as(u64, @intCast(i));
            _ = ring.send(user_data, fd, send_slice, 0) catch {
                continue;
            };
            sends_queued += 1;
        }

        if (sends_queued > 0) {
            _ = try ring.submit();
        }
    }
};
