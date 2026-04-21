//! zoptty backend: TCP control + UDP cell data + PTY-backed shell.
//!
//! Flow:
//!   1. Listen TCP on TCP_PORT, bind UDP on UDP_PORT
//!   2. Accept one client → send Handshake → receive Resize
//!   3. Spawn /bin/bash on a PTY sized to the client's resize
//!   4. Loop:
//!      - Non-blocking read from PTY, feed bytes into Screen
//!      - For each dirty row, encode CellPacket and send on UDP
//!      - 10ms sleep
//!   5. Exit when PTY is closed (shell exits)

const std = @import("std");
const net = std.Io.net;

const protocol = @import("protocol.zig");
const frame_encoder = @import("frame_encoder.zig");
const pty_mod = @import("pty.zig");
const Screen = @import("screen.zig").Screen;

const log = std.log.scoped(.zoptty_server);

const TCP_PORT: u16 = 7001;
const UDP_PORT: u16 = 7002;

// ---------------------------------------------------------------------------
// TCP framing: [u32_le length][u8 type][payload]
// ---------------------------------------------------------------------------

const FrameType = enum(u8) {
    handshake = 1,
    resize_event = 4,
    /// Raw bytes to write directly to the PTY master. The client sends
    /// whatever the user typed (after stdin raw-mode capture) as-is.
    pty_input = 10,
    _,
};

fn writeFrame(w: *std.Io.Writer, frame_type: FrameType, body: []const u8) !void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(body.len + 1), .little);
    header[4] = @intFromEnum(frame_type);
    try w.writeAll(&header);
    try w.writeAll(body);
    try w.flush();
}

fn readFrame(r: *std.Io.Reader, buf: []u8) !struct { frame_type: FrameType, len: usize } {
    var header: [5]u8 = undefined;
    try r.readSliceAll(&header);
    const total_len = std.mem.readInt(u32, header[0..4], .little);
    const body_len = total_len - 1;
    if (body_len > buf.len) return error.FrameTooLarge;
    try r.readSliceAll(buf[0..body_len]);
    return .{ .frame_type = @enumFromInt(header[4]), .len = body_len };
}

// ---------------------------------------------------------------------------
// Wire body structs
// ---------------------------------------------------------------------------

const HandshakeBody = extern struct {
    version: u32 = 1,
    server_udp_port: u16,
    cell_width: f32 = 10.0,
    cell_height: f32 = 20.0,
    font_data_len: u32 = 0,
};

const ResizeBody = extern struct {
    modifiers: u8 = 0,
    _pad: u8 = 0,
    cols: u16,
    rows: u16,
    client_udp_port: u16,
    width_px: u32,
    height_px: u32,
};

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const tcp_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", TCP_PORT) catch unreachable;
    var tcp_server = try tcp_addr.listen(io, .{});
    defer tcp_server.deinit(io);
    log.info("TCP listening on 127.0.0.1:{}", .{TCP_PORT});

    const udp_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", UDP_PORT) catch unreachable;
    var udp_sock = try udp_addr.bind(io, .{ .mode = .dgram });
    defer udp_sock.close(io);
    log.info("UDP bound on 127.0.0.1:{}", .{UDP_PORT});

    var tcp_stream = try tcp_server.accept(io);
    defer tcp_stream.close(io);
    log.info("TCP accepted client", .{});

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = tcp_stream.reader(io, &rbuf);
    var writer = tcp_stream.writer(io, &wbuf);

    try serveClient(gpa, io, &reader.interface, &writer.interface, &udp_sock);
}

/// Input thread: reads pty_input frames from TCP and writes them to PTY master.
/// Exits when TCP read fails (client disconnected or server shutdown).
const InputArgs = struct {
    tcp_r: *std.Io.Reader,
    pty: *pty_mod.Pty,
};

fn inputThread(args: InputArgs) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const frame = readFrame(args.tcp_r, &buf) catch |err| {
            log.info("input thread: read ended ({})", .{err});
            return;
        };
        switch (frame.frame_type) {
            .pty_input => {
                _ = args.pty.write(buf[0..frame.len]) catch |err| {
                    log.warn("PTY write failed: {}", .{err});
                };
            },
            else => log.warn("input thread: unexpected frame type {t}", .{frame.frame_type}),
        }
    }
}

fn serveClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    tcp_r: *std.Io.Reader,
    tcp_w: *std.Io.Writer,
    udp: *net.Socket,
) !void {
    // 1. Handshake.
    const hs: HandshakeBody = .{ .server_udp_port = UDP_PORT };
    try writeFrame(tcp_w, .handshake, std.mem.asBytes(&hs));
    log.info("sent Handshake", .{});

    // 2. Receive resize.
    var fbuf: [4096]u8 = undefined;
    const frame = try readFrame(tcp_r, &fbuf);
    if (frame.frame_type != .resize_event) return error.UnexpectedFrame;
    const resize: ResizeBody = std.mem.bytesAsValue(ResizeBody, fbuf[0..@sizeOf(ResizeBody)]).*;
    log.info("Resize: cols={} rows={} client_udp={}", .{
        resize.cols, resize.rows, resize.client_udp_port,
    });

    const client_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", resize.client_udp_port) catch unreachable;

    // 3. Spawn PTY. Interactive shell so the user can type.
    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-i",
        null,
    };
    var pty = try pty_mod.Pty.spawn(&argv, .{ .rows = resize.rows, .cols = resize.cols });
    defer pty.deinit();
    try pty.setNonBlocking();
    log.info("spawned PTY pid={}", .{pty.pid});

    // Spawn TCP-input thread to forward client keystrokes to PTY.
    var input_thread = try std.Thread.spawn(
        .{},
        inputThread,
        .{InputArgs{ .tcp_r = tcp_r, .pty = &pty }},
    );
    defer input_thread.detach();

    // 4. Screen + encoder.
    var screen = try Screen.init(gpa, resize.rows, resize.cols);
    defer screen.deinit(gpa);

    var encoder: frame_encoder.PacketEncoder = .init(gpa);
    defer encoder.deinit();

    // 5. Main loop.
    var pty_buf: [4096]u8 = undefined;
    while (true) {
        // Read any PTY bytes.
        const n = pty.read(&pty_buf) catch |err| switch (err) {
            error.WouldBlock, error.Interrupted => @as(usize, 0),
            error.EndOfFile => {
                log.info("PTY closed", .{});
                break;
            },
            else => return err,
        };
        if (n > 0) {
            screen.write(pty_buf[0..n]);
        } else if (pty.hasExited()) {
            log.info("shell exited", .{});
            break;
        }

        // Flush dirty rows to UDP.
        for (screen.dirty, 0..) |d, r_usize| {
            if (!d) continue;
            const r: u16 = @intCast(r_usize);
            const row = screen.row(r);
            var result = try encoder.encodeRowSplit(r, resize.cols, row.bg, row.cp, row.fg, null);
            defer result.deinit(gpa);
            for (result.packets) |pkt| {
                udp.send(io, &client_addr, pkt) catch |err| {
                    log.warn("UDP send failed: {}", .{err});
                };
            }
            screen.dirty[r_usize] = false;
        }

        // Small sleep to avoid busy-loop. 10 ms.
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
}

comptime {
    _ = @import("compression.zig");
    _ = @import("frame_decoder.zig");
}
