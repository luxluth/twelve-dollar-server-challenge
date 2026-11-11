const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const BufferGroup = IoUring.BufferGroup;
const batch_mod = @import("batch.zig");
const BatchState = batch_mod.BatchState;
const BATCH_SIZE = batch_mod.BATCH_SIZE;

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn bind(sockfd: c_int, addr: ?*const anyopaque, addrlen: u32) c_int;
extern "c" fn listen(sockfd: c_int, backlog: c_int) c_int;
extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: u32) c_int;
extern "c" fn close(fd: c_int) c_int;

const AF_INET: c_uint = 2;
const SOCK_STREAM: c_uint = 1;
const SOCK_NONBLOCK: c_uint = 0o4000;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const SO_REUSEPORT: c_int = 15;
const IPPROTO_TCP: c_int = 6;
const TCP_NODELAY: c_int = 1;

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = @splat(0),
};

const PENDING_SLOTS = 64;

pub const PendingSlot = struct {
    fd: c_int = -1,
    buf: [8192]u8 = undefined,
    len: usize = 0,
};

pub const Gobler = struct {
    ring: IoUring,
    buf_group: BufferGroup,
    listener_fd: c_int,
    allocator: std.mem.Allocator,
    pending: [PENDING_SLOTS]PendingSlot = @splat(.{}),

    pub const TAG_ACCEPT: u64 = 1;
    pub const TAG_RECV: u64 = 2;
    pub const TAG_SEND: u64 = 3;

    pub fn init(self: *Gobler, allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
        self.allocator = allocator;
        self.ring = try IoUring.init(4096, 0);
        errdefer self.ring.deinit();

        const group_id: u16 = 1;
        const buffers_count: u16 = 4096;
        const buffer_size: u32 = 2048;

        self.buf_group = try BufferGroup.init(
            &self.ring,
            allocator,
            group_id,
            buffer_size,
            buffers_count,
        );
        errdefer self.buf_group.deinit(allocator);

        for (&self.pending) |*s| {
            s.fd = -1;
            s.len = 0;
        }

        // Create listener socket
        const sock_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        if (sock_fd < 0) return error.SocketCreationFailed;
        self.listener_fd = sock_fd;
        errdefer _ = close(sock_fd);

        const one: c_int = 1;
        _ = setsockopt(sock_fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
        _ = setsockopt(sock_fd, SOL_SOCKET, SO_REUSEPORT, &one, @sizeOf(c_int));

        // Parse IP
        const addr = sockaddr_in{
            .sin_family = @intCast(AF_INET),
            .sin_port = std.mem.nativeToBig(u16, port),
            .sin_addr = if (std.mem.eql(u8, host, "0.0.0.0"))
                0
            else
                std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        };

        if (bind(sock_fd, &addr, @sizeOf(sockaddr_in)) != 0) return error.BindFailed;
        if (listen(sock_fd, 65535) != 0) return error.ListenFailed;

        // Queue multishot accept
        _ = try self.ring.accept_multishot(TAG_ACCEPT, sock_fd, null, null, 0);
        _ = try self.ring.submit();
    }

    pub fn deinit(self: *Gobler) void {
        _ = close(self.listener_fd);
        self.buf_group.deinit(self.allocator);
        self.ring.deinit();
    }

    fn findPending(self: *Gobler, fd: c_int) ?*PendingSlot {
        for (&self.pending) |*s| {
            if (s.fd == fd) return s;
        }
        return null;
    }

    fn allocPending(self: *Gobler, fd: c_int) ?*PendingSlot {
        for (&self.pending) |*s| {
            if (s.fd == -1) {
                s.fd = fd;
                s.len = 0;
                return s;
            }
        }
        return null;
    }

    fn clearPending(self: *Gobler, fd: c_int) void {
        for (&self.pending) |*s| {
            if (s.fd == fd) {
                s.fd = -1;
                s.len = 0;
            }
        }
    }

    pub fn gobbleBatch(self: *Gobler, batch: *BatchState, wait: bool) !void {
        batch.reset();

        while (batch.count < BATCH_SIZE) {
            if (self.ring.sq_ready() > 0) {
                _ = self.ring.submit() catch {};
            }

            var cqes: [64]linux.io_uring_cqe = undefined;
            const wait_nr: u32 = if (wait and batch.count == 0) 1 else 0;
            const count = try self.ring.copy_cqes(&cqes, wait_nr);
            if (count == 0) break;

            for (cqes[0..count]) |cqe| {
                const ud = cqe.user_data;
                const tag = ud >> 32;

                if (ud == TAG_ACCEPT) {
                    const client_fd: c_int = @intCast(cqe.res);
                    if (client_fd >= 0) {
                        const one: c_int = 1;
                        _ = setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &one, @sizeOf(c_int));

                        const recv_ud = (TAG_RECV << 32) | @as(u64, @intCast(client_fd));
                        _ = self.buf_group.recv_multishot(recv_ud, client_fd, 0) catch {
                            _ = close(client_fd);
                        };
                    }
                    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                        _ = self.ring.accept_multishot(TAG_ACCEPT, self.listener_fd, null, null, 0) catch {};
                    }
                    _ = self.ring.submit() catch {};
                } else if (tag == TAG_RECV) {
                    const client_fd: c_int = @intCast(ud & 0xffffffff);
                    if (cqe.res <= 0) {
                        _ = close(client_fd);
                        self.clearPending(client_fd);
                        if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                            self.buf_group.put(cqe) catch {};
                        }
                    } else {
                        const data = self.buf_group.get(cqe) catch {
                            if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                                self.buf_group.put(cqe) catch {};
                            }
                            continue;
                        };

                        var req_slice: []const u8 = data;
                        const pslot = self.findPending(client_fd);

                        if (pslot != null or !isRequestComplete(data)) {
                            const slot = pslot orelse self.allocPending(client_fd) orelse {
                                if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                                    self.buf_group.put(cqe) catch {};
                                }
                                continue;
                            };

                            const copy_len = @min(data.len, slot.buf.len - slot.len);
                            @memcpy(slot.buf[slot.len..][0..copy_len], data[0..copy_len]);
                            slot.len += copy_len;

                            if (isRequestComplete(slot.buf[0..slot.len])) {
                                req_slice = slot.buf[0..slot.len];
                                slot.fd = -1;
                                slot.len = 0;
                            } else {
                                if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                                    self.buf_group.put(cqe) catch {};
                                }
                                if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                                    const recv_ud = (TAG_RECV << 32) | @as(u64, @intCast(client_fd));
                                    _ = self.buf_group.recv_multishot(recv_ud, client_fd, 0) catch {};
                                    _ = self.ring.submit() catch {};
                                }
                                continue;
                            }
                        }

                        const b_slot = batch.count;
                        batch.fds[b_slot] = client_fd;
                        const copy_len = @min(req_slice.len, batch.raw_bufs[b_slot].len);
                        @memcpy(batch.raw_bufs[b_slot][0..copy_len], req_slice[0..copy_len]);
                        batch.buf_lens[b_slot] = copy_len;
                        batch.count += 1;

                        if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                            self.buf_group.put(cqe) catch {};
                        }

                        if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                            const recv_ud = (TAG_RECV << 32) | @as(u64, @intCast(client_fd));
                            _ = self.buf_group.recv_multishot(recv_ud, client_fd, 0) catch {};
                            _ = self.ring.submit() catch {};
                        }

                        if (batch.count >= BATCH_SIZE) break;
                    }
                } else if (tag == TAG_SEND) {
                    // Send completion
                }
            }
        }
    }
};

fn getContentLength(req: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, req, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len >= 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const val = std.mem.trim(u8, line[15..], " \t");
            return std.fmt.parseInt(usize, val, 10) catch null;
        }
    }
    return null;
}

fn isRequestComplete(req: []const u8) bool {
    const hend = std.mem.indexOf(u8, req, "\r\n\r\n") orelse std.mem.indexOf(u8, req, "\n\n") orelse return false;
    const is_rn = std.mem.indexOf(u8, req, "\r\n\r\n") != null;
    const body_offset = hend + (if (is_rn) @as(usize, 4) else @as(usize, 2));

    if (std.mem.startsWith(u8, req, "GET")) {
        return true;
    }
    if (std.mem.startsWith(u8, req, "POST")) {
        const cl = getContentLength(req[0..hend]) orelse 0;
        return (req.len - body_offset) >= cl;
    }
    return true;
}
