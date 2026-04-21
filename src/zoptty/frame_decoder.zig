///! CellPacket decoder: converts wire-format packets back into cell buffers.
///!
///! Designed for both native (testing) and wasm32 (browser) targets.
///! The decoder maintains per-row state and uses sequence numbers to
///! discard stale packets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");

const CellBg = protocol.CellBg;
const FgStyle = protocol.FgStyle;
const CellCode = protocol.CellCode;
const CellPacketHeader = protocol.CellPacketHeader;
const CursorInfo = protocol.CursorInfo;

/// A foreground cell as seen by the renderer.
pub const FgCell = struct {
    codepoint: u21,
    style: FgStyle,
};

/// Client-side terminal state rebuilt from decoded packets.
pub const ClientState = struct {
    alloc: Allocator,
    rows: u16 = 0,
    cols: u16 = 0,

    /// Background cells: flat array [rows * cols].
    bg_cells: []CellBg = &.{},

    /// Foreground cells: flat array [rows * cols].
    /// codepoint = 0 means empty.
    fg_codepoints: []u21 = &.{},
    fg_styles: []FgStyle = &.{},

    /// Per-cell sequence tracking: flat array [rows * cols].
    cell_seq: []u32 = &.{},

    /// Per-row dirty flags (set after decode, caller resets).
    dirty: []bool = &.{},

    /// Last cursor state.
    cursor: ?CursorInfo = null,
    cursor_row: u16 = 0,

    pub fn init(alloc: Allocator) ClientState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ClientState) void {
        self.freeArrays();
    }

    fn freeArrays(self: *ClientState) void {
        if (self.bg_cells.len > 0) self.alloc.free(self.bg_cells);
        if (self.fg_codepoints.len > 0) self.alloc.free(self.fg_codepoints);
        if (self.fg_styles.len > 0) self.alloc.free(self.fg_styles);
        if (self.cell_seq.len > 0) self.alloc.free(self.cell_seq);
        if (self.dirty.len > 0) self.alloc.free(self.dirty);
        self.bg_cells = &.{};
        self.fg_codepoints = &.{};
        self.fg_styles = &.{};
        self.cell_seq = &.{};
        self.dirty = &.{};
    }

    /// Resize buffers. Clears all state.
    pub fn resize(self: *ClientState, rows: u16, cols: u16) !void {
        self.freeArrays();
        self.rows = rows;
        self.cols = cols;

        const cell_count = @as(usize, rows) * @as(usize, cols);
        self.bg_cells = try self.alloc.alloc(CellBg, cell_count);
        @memset(self.bg_cells, .{ 0, 0, 0, 255 });

        self.fg_codepoints = try self.alloc.alloc(u21, cell_count);
        @memset(self.fg_codepoints, 0);

        self.fg_styles = try self.alloc.alloc(FgStyle, cell_count);
        @memset(self.fg_styles, .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 });

        self.cell_seq = try self.alloc.alloc(u32, cell_count);
        @memset(self.cell_seq, 0);

        self.dirty = try self.alloc.alloc(bool, rows);
        @memset(self.dirty, false);

        self.cursor = null;
    }

    /// Get the flat index for (row, col).
    fn idx(self: *const ClientState, row: u16, col: usize) usize {
        return @as(usize, row) * @as(usize, self.cols) + col;
    }
};

pub const DecodeError = error{
    PacketTooSmall,
    InvalidRow,
    UnexpectedEndOfData,
    InvalidDictIndex,
    InvalidUtf8,
    OutOfMemory,
};

/// Decode a CellPacket and apply to client state.
pub fn decodePacket(data: []const u8, state: *ClientState) DecodeError!void {
    if (data.len < CellPacketHeader.size) return error.PacketTooSmall;

    // Read header.
    var hdr: CellPacketHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), data[0..CellPacketHeader.size]);
    var pos: usize = CellPacketHeader.size;

    // Validate row.
    if (hdr.row >= state.rows) return error.InvalidRow;

    // Read cursor (optional).
    if (hdr.flags.has_cursor) {
        if (pos + CursorInfo.size > data.len) return error.UnexpectedEndOfData;
        var cur: CursorInfo = undefined;
        @memcpy(std.mem.asBytes(&cur), data[pos..][0..CursorInfo.size]);
        pos += CursorInfo.size;
        state.cursor = cur;
        state.cursor_row = hdr.row;
    }

    // Read dictionaries.
    const bg_dict_count = hdr.dict_sizes.bgCount();
    const fg_dict_count = hdr.dict_sizes.fgCount();

    var bg_dict: [6]CellBg = undefined;
    for (0..bg_dict_count) |i| {
        if (pos + 4 > data.len) return error.UnexpectedEndOfData;
        bg_dict[i] = data[pos..][0..4].*;
        pos += 4;
    }

    var fg_dict: [30]FgStyle = undefined;
    for (0..fg_dict_count) |i| {
        if (pos + FgStyle.size > data.len) return error.UnexpectedEndOfData;
        @memcpy(std.mem.asBytes(&fg_dict[i]), data[pos..][0..FgStyle.size]);
        pos += FgStyle.size;
    }

    // Read cell_map.
    const cols: usize = @intCast(state.cols);
    if (pos + cols > data.len) return error.UnexpectedEndOfData;
    const cell_map = data[pos..][0..cols];
    pos += cols;

    // Decode cell_map + overflow.
    const overflow = data[pos..];

    const decoded = try state.alloc.alloc(compression.DecodedCell, cols);
    defer state.alloc.free(decoded);

    _ = compression.decode(
        cell_map,
        overflow,
        bg_dict[0..bg_dict_count],
        fg_dict[0..fg_dict_count],
        decoded,
    ) catch return error.UnexpectedEndOfData;

    // Apply to state using cell-level sequence control.
    var any_applied = false;
    for (decoded, 0..) |cell, col| {
        const i = state.idx(hdr.row, col);

        // Skip cells that already have a newer sequence.
        if (state.cell_seq[i] >= hdr.sequence and state.cell_seq[i] != 0) continue;

        // Skip cells with no update (bg=0, fg=0 in cell_map).
        if (cell.bg == null and cell.fg_codepoint == null) continue;

        if (cell.bg) |bg| {
            state.bg_cells[i] = bg;
        }

        if (cell.fg_codepoint) |cp| {
            state.fg_codepoints[i] = cp;
            if (cell.fg_style) |style| {
                state.fg_styles[i] = style;
            }
        }

        state.cell_seq[i] = hdr.sequence;
        any_applied = true;
    }

    // Mark row dirty only if at least one cell was applied.
    if (any_applied) {
        state.dirty[hdr.row] = true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const PacketEncoder = @import("frame_encoder.zig").PacketEncoder;

test "encode/decode roundtrip - basic row" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(2, 4);

    const bg = [_]CellBg{ .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 } };
    const cp = [_]u21{ 'H', 'i', 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    const pkt_result = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, &state.bg_cells[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, &state.bg_cells[1]);
    try testing.expectEqual(@as(u21, 'H'), state.fg_codepoints[0]);
    try testing.expectEqual(@as(u21, 'i'), state.fg_codepoints[1]);
    try testing.expect(state.dirty[0]);
    try testing.expect(!state.dirty[1]);
}

test "encode/decode roundtrip - skip unchanged cells" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 4);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 'A', 'B', 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    // First encode + decode.
    const pkt1_result = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    const pkt1 = pkt1_result.data; defer testing.allocator.free(pkt1);
    try decodePacket(pkt1, &state);

    try testing.expectEqual(@as(u21, 'A'), state.fg_codepoints[0]);

    // Second encode with same data — should skip.
    const pkt2_result = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    const pkt2 = pkt2_result.data; defer testing.allocator.free(pkt2);

    // Reset dirty to verify it gets set again.
    state.dirty[0] = false;
    try decodePacket(pkt2, &state);

    // Data should be unchanged.
    try testing.expectEqual(@as(u21, 'A'), state.fg_codepoints[0]);
}

test "encode/decode roundtrip - CJK characters" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 3);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 3;
    const cp = [_]u21{ 0x4F60, 0x597D, 0 }; // 你好
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 3;

    const pkt_result = try encoder.encodeRow(0, 3, &bg, &cp, &style, null);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    try testing.expectEqual(@as(u21, 0x4F60), state.fg_codepoints[0]);
    try testing.expectEqual(@as(u21, 0x597D), state.fg_codepoints[1]);
}

test "encode/decode roundtrip - cursor" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 4);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 0, 0, 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;
    const cursor = CursorInfo{ .x = 2, .style = .underline, .flags = .{ .visible = true, .blinking = true } };

    const pkt_result = try encoder.encodeRow(0, 4, &bg, &cp, &style, cursor);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    try testing.expect(state.cursor != null);
    try testing.expectEqual(@as(u16, 2), state.cursor.?.x);
    try testing.expectEqual(protocol.CursorStyle.underline, state.cursor.?.style);
    try testing.expect(state.cursor.?.flags.blinking);
}

test "stale packet cells are not applied" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 2);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 2;
    const cp = [_]u21{ 'X', 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 2;

    // Send seq=0.
    const pkt0_result = try encoder.encodeRow(0, 2, &bg, &cp, &style, null);
    const pkt0 = pkt0_result.data; defer testing.allocator.free(pkt0);
    try decodePacket(pkt0, &state);

    // Send seq=1 with different data.
    const cp2 = [_]u21{ 'Y', 0 };
    const pkt1_result = try encoder.encodeRow(0, 2, &bg, &cp2, &style, null);
    const pkt1 = pkt1_result.data; defer testing.allocator.free(pkt1);
    try decodePacket(pkt1, &state);

    try testing.expectEqual(@as(u21, 'Y'), state.fg_codepoints[0]);

    // Replay seq=0 — cell-level sequence should prevent overwrite.
    // Does not return error; stale cells are silently skipped.
    try decodePacket(pkt0, &state);

    // State unchanged: 'Y' not overwritten by stale 'X'.
    try testing.expectEqual(@as(u21, 'Y'), state.fg_codepoints[0]);
}

test "multiple rows" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(3, 2);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 2;
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 2;

    // Row 0.
    const cp0 = [_]u21{ 'A', 'B' };
    const pkt0_result = try encoder.encodeRow(0, 2, &bg, &cp0, &style, null);
    const pkt0 = pkt0_result.data; defer testing.allocator.free(pkt0);
    try decodePacket(pkt0, &state);

    // Row 2.
    const cp2 = [_]u21{ 'C', 'D' };
    const pkt2_result = try encoder.encodeRow(2, 2, &bg, &cp2, &style, null);
    const pkt2 = pkt2_result.data; defer testing.allocator.free(pkt2);
    try decodePacket(pkt2, &state);

    try testing.expectEqual(@as(u21, 'A'), state.fg_codepoints[state.idx(0, 0)]);
    try testing.expectEqual(@as(u21, 'C'), state.fg_codepoints[state.idx(2, 0)]);
    try testing.expectEqual(@as(u21, 0), state.fg_codepoints[state.idx(1, 0)]); // row 1 untouched

    try testing.expect(state.dirty[0]);
    try testing.expect(!state.dirty[1]);
    try testing.expect(state.dirty[2]);
}

test "encode/decode roundtrip - emoji (4-byte UTF-8)" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 3);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 3;
    const cp = [_]u21{ 0x1F600, 0x1F680, 0 }; // 😀 🚀
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 1 }} ** 3;

    const pkt_result = try encoder.encodeRow(0, 3, &bg, &cp, &style, null);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    try testing.expectEqual(@as(u21, 0x1F600), state.fg_codepoints[0]);
    try testing.expectEqual(@as(u21, 0x1F680), state.fg_codepoints[1]);
    try testing.expectEqual(@as(u21, 0), state.fg_codepoints[2]);
}

test "encode/decode roundtrip - large row (128 cols)" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 128);

    var bg: [128]CellBg = undefined;
    var cp: [128]u21 = undefined;
    var style: [128]FgStyle = undefined;

    for (0..128) |i| {
        bg[i] = if (i % 2 == 0) .{ 0, 0, 0, 255 } else .{ 30, 30, 30, 255 };
        cp[i] = if (i < 60) 'A' + @as(u21, @intCast(i % 26)) else 0;
        style[i] = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    }

    const pkt_result = try encoder.encodeRow(0, 128, &bg, &cp, &style, null);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    for (0..60) |i| {
        try testing.expectEqual('A' + @as(u21, @intCast(i % 26)), state.fg_codepoints[i]);
    }
    for (60..128) |i| {
        try testing.expectEqual(@as(u21, 0), state.fg_codepoints[i]);
    }
}

test "encode/decode roundtrip - bg overflow end to end" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 8);

    // 8 different bg colors → 6 in dict, 2 overflow.
    var bg: [8]CellBg = undefined;
    for (&bg, 0..) |*b, i| {
        b.* = .{ @intCast(i * 30), @intCast(i * 20), @intCast(i * 10), 255 };
    }
    const cp = [_]u21{0} ** 8;
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 8;

    const pkt_result = try encoder.encodeRow(0, 8, &bg, &cp, &style, null);
    const pkt = pkt_result.data; defer testing.allocator.free(pkt);

    try decodePacket(pkt, &state);

    for (0..8) |i| {
        try testing.expectEqualSlices(u8, &bg[i], &state.bg_cells[i]);
    }
}

test "encode/decode roundtrip - partial update (only fg changes)" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, 4);

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    // Frame 1: set initial state.
    const cp1 = [_]u21{ 'A', 'B', 'C', 'D' };
    const pkt1_result = try encoder.encodeRow(0, 4, &bg, &cp1, &style, null);
    const pkt1 = pkt1_result.data; defer testing.allocator.free(pkt1);
    try decodePacket(pkt1, &state);

    // Frame 2: change only col 1.
    const cp2 = [_]u21{ 'A', 'X', 'C', 'D' };
    const pkt2_result = try encoder.encodeRow(0, 4, &bg, &cp2, &style, null);
    const pkt2 = pkt2_result.data; defer testing.allocator.free(pkt2);
    try decodePacket(pkt2, &state);

    try testing.expectEqual(@as(u21, 'A'), state.fg_codepoints[0]); // unchanged
    try testing.expectEqual(@as(u21, 'X'), state.fg_codepoints[1]); // updated
    try testing.expectEqual(@as(u21, 'C'), state.fg_codepoints[2]); // unchanged
}
