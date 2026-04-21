//! zoptty test client — loops receiving CellPackets and renders the
//! current screen state to the local terminal using ANSI escapes.
//!
//! Not a real renderer — just meant to visually verify end-to-end.

const std = @import("std");
const net = std.Io.net;

const c = @cImport({
    @cInclude("unistd.h");
});

const protocol = @import("protocol.zig");
const frame_decoder = @import("frame_decoder.zig");

fn stderrWrite(bytes: []const u8) void {
    _ = c.write(2, bytes.ptr, bytes.len);
}

const log = std.log.scoped(.zoptty_client);

const SERVER_TCP: u16 = 7001;
const CLIENT_UDP: u16 = 7003;
const COLS: u16 = 80;
const ROWS: u16 = 24;

const FrameType = enum(u8) {
    handshake = 1,
    resize_event = 4,
    _,
};

const HandshakeBody = extern struct {
    version: u32,
    server_udp_port: u16,
    cell_width: f32,
    cell_height: f32,
    font_data_len: u32,
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 1. TCP connect.
    const server_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", SERVER_TCP) catch unreachable;
    var tcp = try server_addr.connect(io, .{ .mode = .stream });
    defer tcp.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = tcp.reader(io, &rbuf);
    var writer = tcp.writer(io, &wbuf);
    const tcp_r = &reader.interface;
    const tcp_w = &writer.interface;

    // 2. Read Handshake.
    var buf: [4096]u8 = undefined;
    const hs_frame = try readFrame(tcp_r, &buf);
    if (hs_frame.frame_type != .handshake) return error.UnexpectedFrame;
    const hs = std.mem.bytesAsValue(HandshakeBody, buf[0..@sizeOf(HandshakeBody)]).*;

    // 3. Bind UDP.
    const udp_bind: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", CLIENT_UDP) catch unreachable;
    var udp = try udp_bind.bind(io, .{ .mode = .dgram });
    defer udp.close(io);

    // 4. Send Resize.
    const resize: ResizeBody = .{
        .cols = COLS,
        .rows = ROWS,
        .client_udp_port = CLIENT_UDP,
        .width_px = @as(u32, COLS) * @as(u32, @intFromFloat(hs.cell_width)),
        .height_px = @as(u32, ROWS) * @as(u32, @intFromFloat(hs.cell_height)),
    };
    try writeFrame(tcp_w, .resize_event, std.mem.asBytes(&resize));

    // 5. Decoder state.
    var client_state: frame_decoder.ClientState = .init(gpa);
    defer client_state.deinit();
    try client_state.resize(ROWS, COLS);

    // 6. Receive loop — print each row's content as it arrives. No
    // alternate-screen rendering for this debug build; just log lines.
    var udp_buf: [2048]u8 = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(2000),
        .clock = .awake,
    } };
    while (true) {
        const msg = udp.receiveTimeout(io, &udp_buf, timeout) catch |err| {
            if (err == error.Timeout) break;
            log.err("UDP recv failed: {}", .{err});
            break;
        };
        frame_decoder.decodePacket(msg.data, &client_state) catch |err| {
            log.warn("decode failed: {}", .{err});
            continue;
        };

        // Print ALL rows that are now non-empty on this receive.
        for (0..ROWS) |r| {
            var row_bytes: [COLS]u8 = undefined;
            var any = false;
            for (row_bytes[0..], 0..COLS) |*d, col| {
                const i = r * @as(usize, COLS) + col;
                const cp = client_state.fg_codepoints[i];
                d.* = if (cp == 0) ' ' else if (cp < 128) @intCast(cp) else '?';
                if (cp != 0) any = true;
            }
            if (any) log.info("row[{}]: {s}", .{ r, std.mem.trimEnd(u8, &row_bytes, " ") });
        }
    }
}

comptime {
    _ = @import("compression.zig");
    _ = @import("frame_encoder.zig");
}
