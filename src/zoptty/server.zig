//! zoptty backend — minimal proof: TCP control + UDP cell data.
//!
//! Flow:
//!   1. TCP listens on 127.0.0.1:TCP_PORT
//!   2. UDP binds on 127.0.0.1:UDP_PORT
//!   3. On TCP accept:
//!      a. Send Handshake (version, udp_port, cell size) framed on TCP.
//!      b. Receive ResizeEvent from client (includes client's UDP port).
//!      c. Encode a dummy one-row CellPacket via frame_encoder,
//!         send over UDP to client.
//!      d. Close.
//!
//! This is not a full server — just verifies:
//!   - TCP frame in/out works
//!   - UDP send + frame_encoder wire format works
//!
//! For now the "terminal state" is a 5-cell hardcoded row:
//!   H e l l o  on white-on-black.

const std = @import("std");
const net = std.Io.net;

const protocol = @import("protocol.zig");
const frame_encoder = @import("frame_encoder.zig");

const log = std.log.scoped(.zoptty_server);

const TCP_PORT: u16 = 7001;
const UDP_PORT: u16 = 7002;

// ---------------------------------------------------------------------------
// TCP framing: [u32_le length][u8 type][payload]
// ---------------------------------------------------------------------------

const FrameType = enum(u8) {
    handshake = 1,
    resize_event = 4,
    _,
};

/// Write a TCP frame: [len:u32 LE][type:u8][body...]
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

/// Read a full TCP frame into buf. Returns (type, payload_len).
fn readFrame(
    r: *std.Io.Reader,
    buf: []u8,
) !struct { frame_type: FrameType, len: usize } {
    var header: [5]u8 = undefined;
    try r.readSliceAll(&header);
    const total_len = std.mem.readInt(u32, header[0..4], .little);
    const body_len = total_len - 1; // minus type byte
    if (body_len > buf.len) return error.FrameTooLarge;
    try r.readSliceAll(buf[0..body_len]);
    return .{ .frame_type = @enumFromInt(header[4]), .len = body_len };
}

// ---------------------------------------------------------------------------
// Wire body structs
// ---------------------------------------------------------------------------

/// Handshake body (after frame header).
const HandshakeBody = extern struct {
    version: u32 = 1,
    server_udp_port: u16,
    cell_width: f32 = 10.0,
    cell_height: f32 = 20.0,
    font_data_len: u32 = 0,
};

/// ResizeEvent body. Derived from DESIGN.md InputEvent, extended with
/// client_udp_port for this transport.
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

    // Bind TCP listener.
    const tcp_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", TCP_PORT) catch unreachable;
    var tcp_server = try tcp_addr.listen(io, .{});
    defer tcp_server.deinit(io);
    log.info("TCP listening on 127.0.0.1:{}", .{TCP_PORT});

    // Bind UDP socket.
    const udp_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", UDP_PORT) catch unreachable;
    var udp_sock = try udp_addr.bind(io, .{ .mode = .dgram });
    defer udp_sock.close(io);
    log.info("UDP bound on 127.0.0.1:{}", .{UDP_PORT});

    // Accept one client, serve, exit.
    var tcp_stream = try tcp_server.accept(io);
    defer tcp_stream.close(io);
    log.info("TCP accepted client", .{});

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = tcp_stream.reader(io, &rbuf);
    var writer = tcp_stream.writer(io, &wbuf);

    try serveClient(gpa, io, &reader.interface, &writer.interface, &udp_sock);
}

fn serveClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    tcp_r: *std.Io.Reader,
    tcp_w: *std.Io.Writer,
    udp: *net.Socket,
) !void {
    // 1. Send handshake over TCP.
    const hs: HandshakeBody = .{ .server_udp_port = UDP_PORT };
    try writeFrame(tcp_w, .handshake, std.mem.asBytes(&hs));
    log.info("sent Handshake", .{});

    // 2. Wait for ResizeEvent.
    var buf: [4096]u8 = undefined;
    const frame = try readFrame(tcp_r, &buf);
    if (frame.frame_type != .resize_event) {
        log.err("expected resize_event, got {t}", .{frame.frame_type});
        return error.UnexpectedFrame;
    }
    const resize: ResizeBody = std.mem.bytesAsValue(ResizeBody, buf[0..@sizeOf(ResizeBody)]).*;
    log.info("got Resize: cols={} rows={} client_udp={}", .{
        resize.cols, resize.rows, resize.client_udp_port,
    });

    // 3. Encode and send one dummy CellPacket over UDP.
    var encoder: frame_encoder.PacketEncoder = .init(gpa);
    defer encoder.deinit();

    const cols: u16 = resize.cols;
    const cols_usize: usize = @intCast(cols);
    const bg = try gpa.alloc(protocol.CellBg, cols_usize);
    defer gpa.free(bg);
    const cps = try gpa.alloc(u21, cols_usize);
    defer gpa.free(cps);
    const styles = try gpa.alloc(protocol.FgStyle, cols_usize);
    defer gpa.free(styles);

    const black: protocol.CellBg = .{ 0, 0, 0, 255 };
    const white_style: protocol.FgStyle = .{
        .color = .{ 255, 255, 255, 255 },
        .atlas = 0,
        .flags = .{},
    };
    for (bg) |*b| b.* = black;
    for (styles) |*s| s.* = white_style;
    for (cps, 0..) |*c, i| c.* = switch (i) {
        0 => 'H',
        1 => 'e',
        2 => 'l',
        3 => 'l',
        4 => 'o',
        else => ' ',
    };

    var result = try encoder.encodeRowSplit(0, cols, bg, cps, styles, null);
    defer result.deinit(gpa);

    const client_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", resize.client_udp_port) catch unreachable;
    for (result.packets) |pkt| {
        try udp.send(io, &client_addr, pkt);
        log.info("sent CellPacket via UDP ({} bytes)", .{pkt.len});
    }
}

// Silence unused warnings when only subset of imports used.
comptime {
    _ = @import("compression.zig");
    _ = @import("frame_decoder.zig");
}
