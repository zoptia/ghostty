//! zoptty test client — connects to the server, receives Handshake,
//! sends ResizeEvent, waits for a CellPacket on UDP, decodes it.
//!
//! Prints the decoded row's codepoints so we can eyeball end-to-end.

const std = @import("std");
const net = std.Io.net;

const protocol = @import("protocol.zig");
const frame_decoder = @import("frame_decoder.zig");

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

fn writeFrame(
    w: *std.Io.Writer,
    frame_type: FrameType,
    body: []const u8,
) !void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(body.len + 1), .little);
    header[4] = @intFromEnum(frame_type);
    try w.writeAll(&header);
    try w.writeAll(body);
    try w.flush();
}

fn readFrame(
    r: *std.Io.Reader,
    buf: []u8,
) !struct { frame_type: FrameType, len: usize } {
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
    log.info("TCP connected to 127.0.0.1:{}", .{SERVER_TCP});

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = tcp.reader(io, &rbuf);
    var writer = tcp.writer(io, &wbuf);
    const tcp_r = &reader.interface;
    const tcp_w = &writer.interface;

    // 2. Read Handshake from TCP.
    var buf: [4096]u8 = undefined;
    const hs_frame = try readFrame(tcp_r, &buf);
    if (hs_frame.frame_type != .handshake) return error.UnexpectedFrame;
    const hs = std.mem.bytesAsValue(HandshakeBody, buf[0..@sizeOf(HandshakeBody)]).*;
    log.info("Handshake: version={} server_udp={} cell={}x{}", .{
        hs.version, hs.server_udp_port, hs.cell_width, hs.cell_height,
    });

    // 3. Bind local UDP socket.
    const udp_bind: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", CLIENT_UDP) catch unreachable;
    var udp = try udp_bind.bind(io, .{ .mode = .dgram });
    defer udp.close(io);
    log.info("UDP bound on 127.0.0.1:{}", .{CLIENT_UDP});

    // 4. Send ResizeEvent (telling server our UDP port).
    const resize: ResizeBody = .{
        .cols = COLS,
        .rows = ROWS,
        .client_udp_port = CLIENT_UDP,
        .width_px = @as(u32, COLS) * 10,
        .height_px = @as(u32, ROWS) * 20,
    };
    try writeFrame(tcp_w, .resize_event, std.mem.asBytes(&resize));
    log.info("sent Resize cols={} rows={}", .{ COLS, ROWS });

    // 5. Receive UDP CellPacket.
    var udp_buf: [2048]u8 = undefined;
    const msg = try udp.receive(io, &udp_buf);
    log.info("received UDP datagram {} bytes from {f}", .{
        msg.data.len, msg.from,
    });

    // 6. Decode.
    var client_state: frame_decoder.ClientState = .init(gpa);
    defer client_state.deinit();
    try client_state.resize(ROWS, COLS);

    try frame_decoder.decodePacket(msg.data, &client_state);

    // 7. Print decoded row 0 codepoints.
    const row0_start: usize = 0;
    const row0_end: usize = @intCast(COLS);
    const row0_cps = client_state.fg_codepoints[row0_start..row0_end];
    std.debug.print("row 0: |", .{});
    for (row0_cps) |cp| {
        if (cp == 0) {
            std.debug.print(".", .{});
        } else {
            var utf8_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch 0;
            std.debug.print("{s}", .{utf8_buf[0..n]});
        }
    }
    std.debug.print("|\n", .{});
}

comptime {
    _ = @import("compression.zig");
    _ = @import("frame_encoder.zig");
}
