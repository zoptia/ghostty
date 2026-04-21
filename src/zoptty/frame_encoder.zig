///! CellPacket encoder: converts terminal row data into the wire format.
///!
///! The encoder maintains per-row state from the previous frame to detect
///! changes and encode skip codes. It produces self-contained CellPacket
///! byte sequences ready for QUIC datagram transmission.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");

const CellBg = protocol.CellBg;
const FgStyle = protocol.FgStyle;
const CellCode = protocol.CellCode;
const CellPacketHeader = protocol.CellPacketHeader;
const CursorInfo = protocol.CursorInfo;

const CellInput = compression.CellInput;

pub const PacketEncoder = struct {
    alloc: Allocator,

    /// Global sequence counter (monotonically increasing).
    sequence: u32 = 0,

    /// Previous frame state per row for skip detection.
    /// Indexed by row number.
    prev_bg: ?[][]CellBg = null,
    prev_fg_cp: ?[][]u21 = null,
    prev_fg_style: ?[][]FgStyle = null,
    prev_rows: u16 = 0,
    prev_cols: u16 = 0,

    pub fn init(alloc: Allocator) PacketEncoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PacketEncoder) void {
        self.freePrevState();
    }

    fn freePrevState(self: *PacketEncoder) void {
        if (self.prev_bg) |rows| {
            for (rows) |row| self.alloc.free(row);
            self.alloc.free(rows);
        }
        if (self.prev_fg_cp) |rows| {
            for (rows) |row| self.alloc.free(row);
            self.alloc.free(rows);
        }
        if (self.prev_fg_style) |rows| {
            for (rows) |row| self.alloc.free(row);
            self.alloc.free(rows);
        }
        self.prev_bg = null;
        self.prev_fg_cp = null;
        self.prev_fg_style = null;
    }

    /// Default QUIC datagram MTU budget.
    pub const default_mtu: usize = 1200;

    /// Result of encoding a row.
    pub const EncodeRowResult = struct {
        data: []u8,
        exceeds_mtu: bool,
    };

    /// Result of encoding a row with potential splitting.
    pub const EncodeRowMultiResult = struct {
        packets: [][]u8,

        pub fn deinit(self: *EncodeRowMultiResult, alloc: Allocator) void {
            for (self.packets) |pkt| alloc.free(pkt);
            alloc.free(self.packets);
        }
    };

    /// Encode a single row into a CellPacket byte sequence.
    /// Returns owned data and whether it exceeds the MTU.
    /// Caller must free `result.data` with `self.alloc`.
    pub fn encodeRow(
        self: *PacketEncoder,
        row: u16,
        cols: u16,
        bg_cells: []const CellBg,
        fg_codepoints: []const u21,
        fg_styles: []const FgStyle,
        cursor: ?CursorInfo,
    ) !EncodeRowResult {
        const cols_usize: usize = @intCast(cols);
        std.debug.assert(bg_cells.len == cols_usize);
        std.debug.assert(fg_codepoints.len == cols_usize);
        std.debug.assert(fg_styles.len == cols_usize);

        const cells = try self.buildCellInputs(row, cols, bg_cells, fg_codepoints, fg_styles);
        defer self.alloc.free(cells);

        const data = try self.encodeCells(row, cols, cells, cursor);

        // Save current state for next frame's skip detection.
        try self.savePrevRow(row, cols, bg_cells, fg_codepoints, fg_styles);

        self.sequence +%= 1;

        return .{
            .data = data,
            .exceeds_mtu = data.len > default_mtu,
        };
    }

    /// Encode a row, automatically splitting into multiple packets if
    /// the single-packet encoding exceeds the MTU. Columns are grouped
    /// by type similarity so each packet has a pure dictionary and
    /// minimal overflow.
    ///
    /// Returns a list of packets. Caller must call `result.deinit(alloc)`.
    pub fn encodeRowSplit(
        self: *PacketEncoder,
        row: u16,
        cols: u16,
        bg_cells: []const CellBg,
        fg_codepoints: []const u21,
        fg_styles: []const FgStyle,
        cursor: ?CursorInfo,
    ) !EncodeRowMultiResult {
        const cols_usize: usize = @intCast(cols);
        std.debug.assert(bg_cells.len == cols_usize);
        std.debug.assert(fg_codepoints.len == cols_usize);
        std.debug.assert(fg_styles.len == cols_usize);

        const cells = try self.buildCellInputs(row, cols, bg_cells, fg_codepoints, fg_styles);
        defer self.alloc.free(cells);

        // Try single packet first.
        const single = try self.encodeCells(row, cols, cells, cursor);

        if (single.len <= default_mtu) {
            // Fits in one packet.
            try self.savePrevRow(row, cols, bg_cells, fg_codepoints, fg_styles);
            self.sequence +%= 1;

            const packets = try self.alloc.alloc([]u8, 1);
            packets[0] = single;
            return .{ .packets = packets };
        }

        // Doesn't fit — split by type similarity.
        self.alloc.free(single);

        // 8-bit type ID per cell for grouping.
        var type_ids = try self.alloc.alloc(u8, cols_usize);
        defer self.alloc.free(type_ids);

        for (cells, 0..) |cell, i| {
            if (!cell.changed) {
                type_ids[i] = 0; // skip cells don't need grouping
            } else {
                // Hash bg + fg style into a type ID.
                type_ids[i] = computeTypeId(cell.bg, cell.fg_style) | 1; // ensure non-zero
            }
        }

        // Count frequency of each non-zero type.
        var freq: [256]u32 = [_]u32{0} ** 256;
        for (type_ids) |tid| {
            if (tid != 0) freq[tid] += 1;
        }

        // Sort types by frequency descending. Collect unique types.
        var sorted_types: [256]u8 = undefined;
        var num_types: usize = 0;
        for (0..256) |t| {
            if (freq[t] > 0) {
                sorted_types[num_types] = @intCast(t);
                num_types += 1;
            }
        }
        // Simple insertion sort on freq descending.
        for (1..num_types) |i| {
            const key = sorted_types[i];
            var j: usize = i;
            while (j > 0 and freq[sorted_types[j - 1]] < freq[key]) {
                sorted_types[j] = sorted_types[j - 1];
                j -= 1;
            }
            sorted_types[j] = key;
        }

        // Greedily assign types to groups.
        // Each group collects types until estimated size approaches MTU.
        var group_membership = try self.alloc.alloc(u8, cols_usize); // group index per col
        defer self.alloc.free(group_membership);
        @memset(group_membership, 0xFF); // 0xFF = unassigned

        var type_to_group: [256]u8 = [_]u8{0xFF} ** 256;
        var current_group: u8 = 0;
        var group_size_est: usize = CellPacketHeader.size + cols_usize; // header + cell_map (fixed)
        var types_in_group: usize = 0;

        for (sorted_types[0..num_types]) |tid| {
            // Estimate: each cell of this type adds overflow bytes.
            const cell_overflow_est: usize = 6; // rough avg: UTF-8(2) + maybe bg(4)
            const type_contribution = freq[tid] * cell_overflow_est + 5; // +5 for dict entry

            if (types_in_group > 0 and group_size_est + type_contribution > default_mtu * 85 / 100) {
                // Start a new group.
                current_group += 1;
                group_size_est = CellPacketHeader.size + cols_usize;
                types_in_group = 0;
            }

            type_to_group[tid] = current_group;
            group_size_est += type_contribution;
            types_in_group += 1;
        }

        const num_groups: usize = @as(usize, current_group) + 1;

        // Assign columns to groups.
        for (type_ids, 0..) |tid, i| {
            if (tid != 0) {
                group_membership[i] = type_to_group[tid];
            }
        }

        // Encode each group as a separate packet.
        var packet_list = try self.alloc.alloc([]u8, num_groups);
        errdefer {
            for (packet_list) |p| {
                if (p.len > 0) self.alloc.free(p);
            }
            self.alloc.free(packet_list);
        }
        @memset(packet_list, &.{});

        for (0..num_groups) |g| {
            // Build CellInput with only this group's columns changed.
            var group_cells = try self.alloc.alloc(CellInput, cols_usize);
            defer self.alloc.free(group_cells);

            for (0..cols_usize) |i| {
                if (group_membership[i] == @as(u8, @intCast(g))) {
                    group_cells[i] = cells[i];
                } else {
                    // Mark as skip for this packet.
                    group_cells[i] = cells[i];
                    group_cells[i].changed = false;
                }
            }

            // First group gets the cursor.
            const group_cursor = if (g == 0) cursor else null;
            packet_list[g] = try self.encodeCells(row, cols, group_cells, group_cursor);
        }

        // All split packets share the same sequence (they represent the
        // same row at the same point in time). Advance once.
        self.sequence +%= 1;

        try self.savePrevRow(row, cols, bg_cells, fg_codepoints, fg_styles);

        return .{ .packets = packet_list };
    }

    fn buildCellInputs(
        self: *PacketEncoder,
        row: u16,
        cols: u16,
        bg_cells: []const CellBg,
        fg_codepoints: []const u21,
        fg_styles: []const FgStyle,
    ) ![]CellInput {
        const cols_usize: usize = @intCast(cols);
        var cells = try self.alloc.alloc(CellInput, cols_usize);

        for (0..cols_usize) |i| {
            const changed = self.isCellChanged(row, i, bg_cells[i], fg_codepoints[i], fg_styles[i]);
            cells[i] = .{
                .bg = bg_cells[i],
                .fg_codepoint = fg_codepoints[i],
                .fg_style = fg_styles[i],
                .changed = changed,
            };
        }

        return cells;
    }

    fn encodeCells(
        self: *PacketEncoder,
        row: u16,
        cols: u16,
        cells: []const CellInput,
        cursor: ?CursorInfo,
    ) ![]u8 {
        var enc_result = try compression.encode(self.alloc, cells);
        defer compression.freeEncodeResult(self.alloc, &enc_result);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.alloc);

        _ = cols;

        const flags = protocol.PacketFlags{
            .has_cursor = cursor != null,
        };
        const hdr = CellPacketHeader{
            .sequence = self.sequence,
            .row = row,
            .flags = flags,
            .dict_sizes = enc_result.dict_sizes,
        };
        try buf.appendSlice(self.alloc, std.mem.asBytes(&hdr));

        if (cursor) |cur| {
            try buf.appendSlice(self.alloc, std.mem.asBytes(&cur));
        }

        for (enc_result.bg_dict) |entry| {
            try buf.appendSlice(self.alloc, &entry);
        }
        for (enc_result.fg_dict) |entry| {
            try buf.appendSlice(self.alloc, std.mem.asBytes(&entry));
        }

        try buf.appendSlice(self.alloc, enc_result.cell_map);
        try buf.appendSlice(self.alloc, enc_result.overflow);

        return buf.toOwnedSlice(self.alloc);
    }

    fn computeTypeId(bg: CellBg, fg_style: FgStyle) u8 {
        // Simple hash combining bg and fg style into 0-255.
        var h: u8 = 0;
        for (bg) |b| h = h *% 31 +% b;
        for (fg_style.color) |b| h = h *% 31 +% b;
        h = h *% 31 +% fg_style.atlas;
        return h;
    }

    /// Resize tracking: call when terminal dimensions change.
    /// Clears all previous state so the next frame is a full update.
    pub fn resize(self: *PacketEncoder, rows: u16, cols: u16) !void {
        self.freePrevState();

        const rows_usize: usize = @intCast(rows);
        const cols_usize: usize = @intCast(cols);

        self.prev_bg = try self.alloc.alloc([]CellBg, rows_usize);
        self.prev_fg_cp = try self.alloc.alloc([]u21, rows_usize);
        self.prev_fg_style = try self.alloc.alloc([]FgStyle, rows_usize);

        for (0..rows_usize) |r| {
            self.prev_bg.?[r] = try self.alloc.alloc(CellBg, cols_usize);
            @memset(self.prev_bg.?[r], .{ 0, 0, 0, 0 }); // sentinel: won't match anything
            self.prev_fg_cp.?[r] = try self.alloc.alloc(u21, cols_usize);
            @memset(self.prev_fg_cp.?[r], 0xFFFF); // sentinel
            self.prev_fg_style.?[r] = try self.alloc.alloc(FgStyle, cols_usize);
            @memset(self.prev_fg_style.?[r], .{ .color = .{ 0xFF, 0xFF, 0xFF, 0x00 }, .atlas = 0xFF });
        }

        self.prev_rows = rows;
        self.prev_cols = cols;
    }

    fn isCellChanged(self: *PacketEncoder, row: u16, col: usize, bg: CellBg, fg_cp: u21, fg_style: FgStyle) bool {
        if (self.prev_bg == null) return true;
        if (row >= self.prev_rows or col >= self.prev_cols) return true;

        const r: usize = @intCast(row);
        if (!std.mem.eql(u8, &self.prev_bg.?[r][col], &bg)) return true;
        if (self.prev_fg_cp.?[r][col] != fg_cp) return true;
        if (!self.prev_fg_style.?[r][col].eql(fg_style)) return true;

        return false;
    }

    fn savePrevRow(
        self: *PacketEncoder,
        row: u16,
        cols: u16,
        bg_cells: []const CellBg,
        fg_codepoints: []const u21,
        fg_styles: []const FgStyle,
    ) !void {
        const need_resize = self.prev_bg == null or
            cols != self.prev_cols or
            row >= self.prev_rows;

        if (need_resize) {
            try self.resize(@max(self.prev_rows, row + 1), cols);
        }

        const r: usize = @intCast(row);
        const c: usize = @intCast(cols);
        @memcpy(self.prev_bg.?[r][0..c], bg_cells);
        @memcpy(self.prev_fg_cp.?[r][0..c], fg_codepoints);
        @memcpy(self.prev_fg_style.?[r][0..c], fg_styles);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "PacketEncoder - first row is full update" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 'H', 'i', 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    const result = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    defer testing.allocator.free(result.data);

    try testing.expect(result.data.len >= CellPacketHeader.size + 4);
    try testing.expect(!result.exceeds_mtu);

    const hdr: *const CellPacketHeader = @alignCast(@ptrCast(result.data[0..CellPacketHeader.size]));
    try testing.expectEqual(@as(u32, 0), hdr.sequence);
    try testing.expectEqual(@as(u16, 0), hdr.row);
}

test "PacketEncoder - second call has skips" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 'A', 'B', 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    const r1 = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    defer testing.allocator.free(r1.data);

    const r2 = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    defer testing.allocator.free(r2.data);

    try testing.expect(r2.data.len <= r1.data.len);

    const hdr2: *const CellPacketHeader = @alignCast(@ptrCast(r2.data[0..CellPacketHeader.size]));
    const dict_start = CellPacketHeader.size;
    const bg_dict_size = hdr2.dict_sizes.bgCount() * 4;
    const fg_dict_size = hdr2.dict_sizes.fgCount() * FgStyle.size;
    const map_start = dict_start + bg_dict_size + fg_dict_size;

    for (r2.data[map_start..][0..4]) |byte| {
        try testing.expectEqual(@as(u8, 0x00), byte);
    }
}

test "PacketEncoder - sequence increments" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 2;
    const cp = [_]u21{ 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 2;

    for (0..5) |i| {
        const result = try encoder.encodeRow(0, 2, &bg, &cp, &style, null);
        defer testing.allocator.free(result.data);
        const hdr: *const CellPacketHeader = @alignCast(@ptrCast(result.data[0..CellPacketHeader.size]));
        try testing.expectEqual(@as(u32, @intCast(i)), hdr.sequence);
    }
}

test "PacketEncoder - with cursor" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 0, 0, 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;
    const cursor = CursorInfo{ .x = 2, .style = .bar, .flags = .{ .visible = true } };

    const result = try encoder.encodeRow(0, 4, &bg, &cp, &style, cursor);
    defer testing.allocator.free(result.data);

    const hdr: *const CellPacketHeader = @alignCast(@ptrCast(result.data[0..CellPacketHeader.size]));
    try testing.expect(hdr.flags.has_cursor);

    const cur: *const CursorInfo = @alignCast(@ptrCast(result.data[CellPacketHeader.size..][0..CursorInfo.size]));
    try testing.expectEqual(@as(u16, 2), cur.x);
    try testing.expectEqual(protocol.CursorStyle.bar, cur.style);
}

test "PacketEncoder - exceeds_mtu flag" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    // Small row — should not exceed MTU.
    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 'A', 0, 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    const result = try encoder.encodeRow(0, 4, &bg, &cp, &style, null);
    defer testing.allocator.free(result.data);

    try testing.expect(!result.exceeds_mtu);
}

test "encodeRowSplit - small row returns single packet" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** 4;
    const cp = [_]u21{ 'A', 'B', 0, 0 };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** 4;

    var result = try encoder.encodeRowSplit(0, 4, &bg, &cp, &style, null);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.packets.len);
    try testing.expect(result.packets[0].len <= PacketEncoder.default_mtu);
}

test "encodeRowSplit - decode all packets recovers data" {
    const frame_decoder = @import("frame_decoder.zig");
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    // Build a row with many different styles to potentially force splitting.
    const cols = 128;
    var bg: [cols]CellBg = undefined;
    var cp: [cols]u21 = undefined;
    var fg_s: [cols]FgStyle = undefined;

    for (0..cols) |i| {
        bg[i] = .{ @intCast(i % 8 * 30), @intCast(i % 5 * 50), 0, 255 };
        cp[i] = 'A' + @as(u21, @intCast(i % 26));
        fg_s[i] = .{ .color = .{ @intCast(i % 10 * 25), @intCast(i % 7 * 35), 100, 255 }, .atlas = 0 };
    }

    var result = try encoder.encodeRowSplit(0, cols, &bg, &cp, &fg_s, null);
    defer result.deinit(testing.allocator);

    // Decode all packets.
    var state = frame_decoder.ClientState.init(testing.allocator);
    defer state.deinit();
    try state.resize(1, cols);

    for (result.packets) |pkt| {
        try frame_decoder.decodePacket(pkt, &state);
    }

    // Verify all cells.
    for (0..cols) |i| {
        try testing.expectEqualSlices(u8, &bg[i], &state.bg_cells[i]);
        try testing.expectEqual(cp[i], state.fg_codepoints[i]);
    }
}

test "encodeRowSplit - all packets share same sequence" {
    var encoder = PacketEncoder.init(testing.allocator);
    defer encoder.deinit();

    const cols = 4;
    const bg = [_]CellBg{.{ 0, 0, 0, 255 }} ** cols;
    const cp = [_]u21{ 'A', 'B', 'C', 'D' };
    const style = [_]FgStyle{.{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }} ** cols;

    var result = try encoder.encodeRowSplit(0, cols, &bg, &cp, &style, null);
    defer result.deinit(testing.allocator);

    // All split packets should share the same sequence.
    var first_seq: ?u32 = null;
    for (result.packets) |pkt| {
        var hdr: CellPacketHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), pkt[0..CellPacketHeader.size]);
        if (first_seq) |seq| {
            try testing.expectEqual(seq, hdr.sequence);
        } else {
            first_seq = hdr.sequence;
        }
    }
}
