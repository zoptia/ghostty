//! zoptty test client — connects to the server, renders received
//! CellPackets into a local alternate-screen, and forwards raw
//! keystrokes back to the server over TCP.

const std = @import("std");
const net = std.Io.net;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("termios.h");
});

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
    pty_input = 10,
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

fn stderrWrite(bytes: []const u8) void {
    _ = c.write(2, bytes.ptr, bytes.len);
}

// ---------------------------------------------------------------------------
// Stdin raw-mode handling (on fd 0).
// ---------------------------------------------------------------------------

var saved_termios: c.termios = undefined;
var stdin_was_raw: bool = false;

fn enterRawMode() !void {
    if (c.tcgetattr(0, &saved_termios) != 0) return error.TcgetattrFailed;
    var raw = saved_termios;
    // Input: no break sig, no CR-to-NL, no parity, no strip, no flow.
    raw.c_iflag &= ~@as(c.tcflag_t, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    // Output: keep opost off so terminal codes pass through unchanged.
    raw.c_oflag &= ~@as(c.tcflag_t, c.OPOST);
    // Local: no canonical, no echo, no ext, no signal gen.
    raw.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    // Control: 8-bit chars.
    raw.c_cflag |= c.CS8;
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;
    if (c.tcsetattr(0, c.TCSAFLUSH, &raw) != 0) return error.TcsetattrFailed;
    stdin_was_raw = true;
}

fn restoreStdin() void {
    if (stdin_was_raw) {
        _ = c.tcsetattr(0, c.TCSAFLUSH, &saved_termios);
        stdin_was_raw = false;
    }
}

// ---------------------------------------------------------------------------
// Input thread: reads stdin, sends TCP pty_input frames.
// ---------------------------------------------------------------------------

const InputThreadArgs = struct {
    tcp_w: *std.Io.Writer,
    /// Written by input thread, read by main thread to detect Ctrl-Q exit.
    /// Signal via null-byte convention: when set to true, main should quit.
    quit: *std.atomic.Value(bool),
};

fn inputThread(args: InputThreadArgs) void {
    var buf: [512]u8 = undefined;
    while (!args.quit.load(.monotonic)) {
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) return;
        const un: usize = @intCast(n);

        // Exit on Ctrl-Q (0x11) — terminals rarely send this naturally.
        for (buf[0..un]) |b| if (b == 0x11) {
            args.quit.store(true, .monotonic);
            return;
        };

        writeFrame(args.tcp_w, .pty_input, buf[0..un]) catch |err| {
            log.err("TCP send failed: {}", .{err});
            args.quit.store(true, .monotonic);
            return;
        };
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // TCP connect + handshake + resize.
    const server_addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", SERVER_TCP) catch unreachable;
    var tcp = try server_addr.connect(io, .{ .mode = .stream });
    defer tcp.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = tcp.reader(io, &rbuf);
    var writer = tcp.writer(io, &wbuf);
    const tcp_r = &reader.interface;
    const tcp_w = &writer.interface;

    var buf: [4096]u8 = undefined;
    const hs_frame = try readFrame(tcp_r, &buf);
    if (hs_frame.frame_type != .handshake) return error.UnexpectedFrame;
    const hs = std.mem.bytesAsValue(HandshakeBody, buf[0..@sizeOf(HandshakeBody)]).*;

    const udp_bind: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", CLIENT_UDP) catch unreachable;
    var udp = try udp_bind.bind(io, .{ .mode = .dgram });
    defer udp.close(io);

    const resize: ResizeBody = .{
        .cols = COLS,
        .rows = ROWS,
        .client_udp_port = CLIENT_UDP,
        .width_px = @as(u32, COLS) * @as(u32, @intFromFloat(hs.cell_width)),
        .height_px = @as(u32, ROWS) * @as(u32, @intFromFloat(hs.cell_height)),
    };
    try writeFrame(tcp_w, .resize_event, std.mem.asBytes(&resize));

    var client_state: frame_decoder.ClientState = .init(gpa);
    defer client_state.deinit();
    try client_state.resize(ROWS, COLS);

    // Put stdin in raw mode and enter alternate screen.
    try enterRawMode();
    defer restoreStdin();
    stderrWrite("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
    defer stderrWrite("\x1b[?25h\x1b[?1049l");

    // Spawn input thread.
    var quit: std.atomic.Value(bool) = .init(false);
    const input_tid = try std.Thread.spawn(
        .{},
        inputThread,
        .{InputThreadArgs{ .tcp_w = tcp_w, .quit = &quit }},
    );
    input_tid.detach();

    // Main loop: receive UDP, decode, render.
    var udp_buf: [2048]u8 = undefined;
    var render_buf: std.ArrayList(u8) = .empty;
    defer render_buf.deinit(gpa);

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(100),
        .clock = .awake,
    } };
    while (!quit.load(.monotonic)) {
        const msg = udp.receiveTimeout(io, &udp_buf, timeout) catch |err| switch (err) {
            error.Timeout => continue,
            else => {
                log.err("UDP recv: {}", .{err});
                break;
            },
        };
        frame_decoder.decodePacket(msg.data, &client_state) catch continue;

        render_buf.clearRetainingCapacity();
        try render_buf.appendSlice(gpa, "\x1b[H"); // cursor home
        for (0..ROWS) |r| {
            try render_buf.appendSlice(gpa, "\x1b[2K");
            for (0..COLS) |col| {
                const i = r * @as(usize, COLS) + col;
                const cp = client_state.fg_codepoints[i];
                if (cp == 0) {
                    try render_buf.append(gpa, ' ');
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch {
                        try render_buf.append(gpa, '?');
                        continue;
                    };
                    try render_buf.appendSlice(gpa, utf8_buf[0..n]);
                }
            }
            if (r + 1 < ROWS) try render_buf.append(gpa, '\r');
            if (r + 1 < ROWS) try render_buf.append(gpa, '\n');
        }
        // Show cursor at server's cursor position if any.
        if (client_state.cursor) |cur| {
            var cur_esc: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&cur_esc, "\x1b[{};{}H", .{
                client_state.cursor_row + 1,
                cur.x + 1,
            }) catch "";
            try render_buf.appendSlice(gpa, s);
        }
        stderrWrite(render_buf.items);
    }
}

comptime {
    _ = @import("compression.zig");
    _ = @import("frame_encoder.zig");
}
