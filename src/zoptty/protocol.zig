///! Wire protocol data structures for ghostty-web.
///!
///! Defines the binary format used between the native server and browser
///! client over WebTransport/QUIC.  The only data packet is `CellPacket`.
///! See DESIGN.md for the full specification.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Protocol uses direct memory mapping of extern structs.
    // All Ghostty-supported platforms (x86_64, aarch64, wasm32) are LE.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

// ---------------------------------------------------------------------------
// CellPacket header
// ---------------------------------------------------------------------------

pub const PacketFlags = packed struct(u8) {
    has_cursor: bool = false,
    has_split: bool = false, // set when row is split across packets
    _reserved: u6 = 0,
};

pub const CellPacketHeader = extern struct {
    sequence: u32,
    row: u16,
    flags: PacketFlags,
    dict_sizes: DictSizes,

    pub const size = 8;

    comptime {
        std.debug.assert(@sizeOf(CellPacketHeader) == size);
    }
};

/// Packed dictionary sizes in one byte.
///   bits [2:0] = bg dictionary size (0-6)
///   bits [7:3] = fg dictionary size (0-30)
pub const DictSizes = packed struct(u8) {
    bg: u3 = 0,
    fg: u5 = 0,

    pub fn bgCount(self: DictSizes) usize {
        return @intCast(self.bg);
    }

    pub fn fgCount(self: DictSizes) usize {
        return @intCast(self.fg);
    }
};

// ---------------------------------------------------------------------------
// Split info (present only when flags.has_split = true)
// ---------------------------------------------------------------------------

pub const SplitInfo = extern struct {
    col_start: u16,
    col_count: u16,

    pub const size = 4;

    comptime {
        std.debug.assert(@sizeOf(SplitInfo) == size);
    }
};

// ---------------------------------------------------------------------------
// Cursor (present only when flags.has_cursor = true)
// ---------------------------------------------------------------------------

pub const CursorStyle = enum(u8) {
    block = 0,
    bar = 1,
    underline = 2,
    block_hollow = 3,
};

pub const CursorFlags = packed struct(u8) {
    visible: bool = true,
    blinking: bool = false,
    _reserved: u6 = 0,
};

pub const CursorInfo = extern struct {
    x: u16,
    style: CursorStyle,
    flags: CursorFlags,

    pub const size = 4;

    comptime {
        std.debug.assert(@sizeOf(CursorInfo) == size);
    }
};

// ---------------------------------------------------------------------------
// CellBg — background color, 4 bytes RGBA
// ---------------------------------------------------------------------------

pub const CellBg = [4]u8;

// ---------------------------------------------------------------------------
// FgStyle — foreground style, 5 bytes
// ---------------------------------------------------------------------------

pub const FgStyle = extern struct {
    color: [4]u8 align(1),
    atlas: u8 align(1),
    flags: StyleFlags align(1) = .{},

    pub const size = 6;

    comptime {
        std.debug.assert(@sizeOf(FgStyle) == size);
    }

    pub fn eql(self: FgStyle, other: FgStyle) bool {
        return std.mem.eql(u8, &self.color, &other.color) and
            self.atlas == other.atlas and
            @as(u8, @bitCast(self.flags)) == @as(u8, @bitCast(other.flags));
    }
};

pub const StyleFlags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: Underline = .none,
    _reserved: u1 = 0,

    pub const Underline = enum(u2) {
        none = 0,
        single = 1,
        double = 2,
        dotted = 3,
    };
};

// ---------------------------------------------------------------------------
// cell_map byte encoding
//
//   bits [2:0] = bg code (3 bits)
//     0     = skip (do not update)
//     1-6   = bg_dict[code - 1]
//     7     = overflow: read 4 bytes from overflow stream
//
//   bits [7:3] = fg code (5 bits)
//     0     = skip (do not update)
//     1-30  = fg_dict[code - 1], read UTF-8 codepoint from overflow
//     31    = overflow: read UTF-8 codepoint + FgStyle from overflow
// ---------------------------------------------------------------------------

pub const CellCode = packed struct(u8) {
    bg: u3,
    fg: u5,

    pub const bg_skip: u3 = 0;
    pub const bg_overflow: u3 = 7;
    pub const bg_max_dict: u3 = 6;

    pub const fg_skip: u5 = 0;
    pub const fg_overflow: u5 = 31;
    pub const fg_max_dict: u5 = 30;

    pub fn bgIsSkip(self: CellCode) bool {
        return self.bg == bg_skip;
    }

    pub fn bgIsOverflow(self: CellCode) bool {
        return self.bg == bg_overflow;
    }

    pub fn bgDictIndex(self: CellCode) ?usize {
        if (self.bg == bg_skip or self.bg == bg_overflow) return null;
        return @as(usize, self.bg) - 1;
    }

    pub fn fgIsSkip(self: CellCode) bool {
        return self.fg == fg_skip;
    }

    pub fn fgIsOverflow(self: CellCode) bool {
        return self.fg == fg_overflow;
    }

    pub fn fgDictIndex(self: CellCode) ?usize {
        if (self.fg == fg_skip or self.fg == fg_overflow) return null;
        return @as(usize, self.fg) - 1;
    }
};

// ---------------------------------------------------------------------------
// Handshake (server -> client, reliable stream, once per connection)
// ---------------------------------------------------------------------------

pub const HandshakeHeader = extern struct {
    version: u32,
    cell_width_bits: u32, // f32 stored as u32 bits
    cell_height_bits: u32,
    font_data_len: u32,
    // followed by font_data_len bytes of font file (TTF/OTF/woff2)

    pub const current_version: u32 = 1;
    pub const size = 16;

    comptime {
        std.debug.assert(@sizeOf(HandshakeHeader) == size);
    }

    pub fn cellWidth(self: HandshakeHeader) f32 {
        return @bitCast(self.cell_width_bits);
    }

    pub fn cellHeight(self: HandshakeHeader) f32 {
        return @bitCast(self.cell_height_bits);
    }
};

// ---------------------------------------------------------------------------
// Input events (client -> server, reliable stream)
// ---------------------------------------------------------------------------

pub const InputEventType = enum(u8) {
    key_press = 0,
    key_release = 1,
    mouse = 2,
    paste = 3,
    resize = 4,
};

pub const InputModifiers = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    _reserved: u4 = 0,
};

pub const MouseAction = enum(u8) {
    press = 0,
    release = 1,
    motion = 2,
    scroll = 3,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CellPacketHeader size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CellPacketHeader));
}

test "DictSizes packing" {
    const ds = DictSizes{ .bg = 5, .fg = 20 };
    const byte: u8 = @bitCast(ds);
    const back: DictSizes = @bitCast(byte);
    try std.testing.expectEqual(@as(u3, 5), back.bg);
    try std.testing.expectEqual(@as(u5, 20), back.fg);
}

test "CellCode packing" {
    const code = CellCode{ .bg = 7, .fg = 31 };
    const byte: u8 = @bitCast(code);
    const back: CellCode = @bitCast(byte);
    try std.testing.expect(back.bgIsOverflow());
    try std.testing.expect(back.fgIsOverflow());
}

test "CellCode skip" {
    const code = CellCode{ .bg = 0, .fg = 0 };
    try std.testing.expect(code.bgIsSkip());
    try std.testing.expect(code.fgIsSkip());
}

test "CellCode dict index" {
    const code = CellCode{ .bg = 3, .fg = 15 };
    try std.testing.expectEqual(@as(usize, 2), code.bgDictIndex().?);
    try std.testing.expectEqual(@as(usize, 14), code.fgDictIndex().?);
}

test "FgStyle size" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(FgStyle));
}

test "StyleFlags packing" {
    const flags = StyleFlags{ .bold = true, .italic = true, .underline = .double };
    const byte: u8 = @bitCast(flags);
    const back: StyleFlags = @bitCast(byte);
    try std.testing.expect(back.bold);
    try std.testing.expect(back.italic);
    try std.testing.expect(!back.strikethrough);
    try std.testing.expectEqual(StyleFlags.Underline.double, back.underline);
}

test "CursorInfo size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(CursorInfo));
}

test "HandshakeHeader size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(HandshakeHeader));
}
