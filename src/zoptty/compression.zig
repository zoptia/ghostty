///! cell_map encoding and decoding for CellPacket.
///!
///! Each cell in a row is encoded as one byte:
///!   bits [2:0] = bg code (skip / dict / overflow)
///!   bits [7:3] = fg code (skip / dict / overflow)
///!
///! The overflow stream is a tightly packed byte sequence driven entirely
///! by the cell_map: the decoder reads each cell_map byte and consumes
///! 0-13 bytes from the overflow based on the bg/fg codes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

const CellBg = protocol.CellBg;
const FgStyle = protocol.FgStyle;
const CellCode = protocol.CellCode;
const DictSizes = protocol.DictSizes;

/// A cell's visual identity used for dictionary building.
pub const CellInput = struct {
    bg: CellBg,
    fg_codepoint: u21, // 0 = no foreground character
    fg_style: FgStyle,
    changed: bool, // false = skip
};

/// Result of encoding a row into cell_map + overflow.
pub const EncodeResult = struct {
    cell_map: []u8,
    overflow: []u8,
    dict_sizes: DictSizes,
    bg_dict: []CellBg,
    fg_dict: []FgStyle,
};

// ---------------------------------------------------------------------------
// Histogram helpers
// ---------------------------------------------------------------------------

fn HistEntry(comptime T: type) type {
    return struct {
        value: T,
        count: u32,
    };
}

fn DictResult(comptime T: type, comptime max_dict: usize) type {
    return struct {
        dict: [max_dict]T,
        len: usize,
    };
}

fn buildDict(
    comptime T: type,
    comptime max_entries: usize,
    comptime max_dict: usize,
    items: []const T,
    skip_flags: []const bool,
    eql_fn: fn (T, T) bool,
) DictResult(T, max_dict) {
    var hist: [max_entries]HistEntry(T) = undefined;
    var hist_len: usize = 0;

    for (items, skip_flags) |item, skip| {
        if (skip) continue;

        var found = false;
        for (hist[0..hist_len]) |*entry| {
            if (eql_fn(entry.value, item)) {
                entry.count += 1;
                found = true;
                break;
            }
        }
        if (!found and hist_len < max_entries) {
            hist[hist_len] = .{ .value = item, .count = 1 };
            hist_len += 1;
        }
    }

    // Sort descending by count.
    if (hist_len < 2) {
        var result: DictResult(T, max_dict) = .{
            .dict = undefined,
            .len = @min(hist_len, max_dict),
        };
        for (0..result.len) |i| {
            result.dict[i] = hist[i].value;
        }
        return result;
    }
    for (1..hist_len) |i| {
        const key = hist[i];
        var j: usize = i;
        while (j > 0 and hist[j - 1].count < key.count) {
            hist[j] = hist[j - 1];
            j -= 1;
        }
        hist[j] = key;
    }

    var result: DictResult(T, max_dict) = .{
        .dict = undefined,
        .len = @min(hist_len, max_dict),
    };
    for (0..result.len) |i| {
        result.dict[i] = hist[i].value;
    }
    return result;
}

fn cellBgEql(a: CellBg, b: CellBg) bool {
    return std.mem.eql(u8, &a, &b);
}

fn fgStyleEql(a: FgStyle, b: FgStyle) bool {
    return a.eql(b);
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Encode a row of cells into cell_map + overflow.
/// Caller owns all returned slices and must free with `alloc`.
pub fn encode(
    alloc: Allocator,
    cells: []const CellInput,
) !EncodeResult {
    const cols = cells.len;

    // Build skip flags.
    var bg_skips = try alloc.alloc(bool, cols);
    defer alloc.free(bg_skips);
    var fg_skips = try alloc.alloc(bool, cols);
    defer alloc.free(fg_skips);

    var bg_values = try alloc.alloc(CellBg, cols);
    defer alloc.free(bg_values);
    var fg_values = try alloc.alloc(FgStyle, cols);
    defer alloc.free(fg_values);

    for (cells, 0..) |cell, i| {
        bg_skips[i] = !cell.changed;
        fg_skips[i] = !cell.changed;
        bg_values[i] = cell.bg;
        fg_values[i] = cell.fg_style;
    }

    // Build dictionaries.
    const bg_result = buildDict(CellBg, 32, 6, bg_values, bg_skips, cellBgEql);
    const fg_result = buildDict(FgStyle, 64, 30, fg_values, fg_skips, fgStyleEql);

    // Allocate outputs.
    var cell_map = try alloc.alloc(u8, cols);
    errdefer alloc.free(cell_map);

    // Worst case overflow: cols * 13 bytes.
    var overflow_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer overflow_buf.deinit(alloc);

    // Encode each cell.
    for (cells, 0..) |cell, i| {
        var code: CellCode = .{ .bg = 0, .fg = 0 };

        // bg
        if (cell.changed) {
            code.bg = bgLookup(&bg_result.dict, bg_result.len, &cell.bg);
            if (code.bg == CellCode.bg_overflow) {
                try overflow_buf.appendSlice(alloc, &cell.bg);
            }
        }

        // fg
        if (cell.changed) {
            if (cell.fg_codepoint == 0) {
                // Empty cell: use a dict/overflow entry but write the
                // null marker (0xC0) instead of a UTF-8 codepoint.
                // 0xC0 is an invalid UTF-8 lead byte, so it's unambiguous.
                code.fg = fgLookup(&fg_result.dict, fg_result.len, &cell.fg_style);
                try overflow_buf.append(alloc, 0xC0);

                if (code.fg == CellCode.fg_overflow) {
                    try overflow_buf.appendSlice(alloc, std.mem.asBytes(&cell.fg_style));
                }
            } else {
                code.fg = fgLookup(&fg_result.dict, fg_result.len, &cell.fg_style);

                // Write UTF-8 codepoint.
                var utf8_buf: [4]u8 = undefined;
                const cp_len = std.unicode.utf8Encode(cell.fg_codepoint, &utf8_buf) catch 0;
                if (cp_len > 0) {
                    try overflow_buf.appendSlice(alloc, utf8_buf[0..cp_len]);
                }

                // If overflow, also write FgStyle.
                if (code.fg == CellCode.fg_overflow) {
                    try overflow_buf.appendSlice(alloc, std.mem.asBytes(&cell.fg_style));
                }
            }
        }

        cell_map[i] = @bitCast(code);
    }

    // Copy dictionaries to owned slices.
    var bg_dict = try alloc.alloc(CellBg, bg_result.len);
    errdefer alloc.free(bg_dict);
    for (0..bg_result.len) |i| bg_dict[i] = bg_result.dict[i];

    var fg_dict = try alloc.alloc(FgStyle, fg_result.len);
    errdefer alloc.free(fg_dict);
    for (0..fg_result.len) |i| fg_dict[i] = fg_result.dict[i];

    return .{
        .cell_map = cell_map,
        .overflow = try overflow_buf.toOwnedSlice(alloc),
        .dict_sizes = .{
            .bg = @intCast(bg_result.len),
            .fg = @intCast(fg_result.len),
        },
        .bg_dict = bg_dict,
        .fg_dict = fg_dict,
    };
}

fn bgLookup(dict: *const [6]CellBg, dict_len: usize, bg: *const CellBg) u3 {
    for (0..dict_len) |i| {
        if (std.mem.eql(u8, &dict[i], bg)) {
            return @intCast(i + 1);
        }
    }
    return CellCode.bg_overflow;
}

fn fgLookup(dict: *const [30]FgStyle, dict_len: usize, style: *const FgStyle) u5 {
    for (0..dict_len) |i| {
        if (dict[i].eql(style.*)) {
            return @intCast(i + 1);
        }
    }
    return CellCode.fg_overflow;
}

/// Free all slices returned by `encode`.
pub fn freeEncodeResult(alloc: Allocator, result: *EncodeResult) void {
    alloc.free(result.cell_map);
    alloc.free(result.overflow);
    alloc.free(result.bg_dict);
    alloc.free(result.fg_dict);
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

/// Output cell from decoding.
pub const DecodedCell = struct {
    bg: ?CellBg, // null = skip
    fg_codepoint: ?u21, // null = skip
    fg_style: ?FgStyle, // null = skip
};

/// Decode a cell_map + overflow into an array of DecodedCell.
/// `out` must have exactly `cols` entries.
pub fn decode(
    cell_map: []const u8,
    overflow: []const u8,
    bg_dict: []const CellBg,
    fg_dict: []const FgStyle,
    out: []DecodedCell,
) !usize {
    std.debug.assert(cell_map.len == out.len);

    var ptr: usize = 0;

    for (cell_map, 0..) |byte, i| {
        const code: CellCode = @bitCast(byte);
        var cell: DecodedCell = .{ .bg = null, .fg_codepoint = null, .fg_style = null };

        // bg
        if (code.bgIsOverflow()) {
            if (ptr + 4 > overflow.len) return error.UnexpectedEndOfData;
            cell.bg = overflow[ptr..][0..4].*;
            ptr += 4;
        } else if (code.bgDictIndex()) |idx| {
            if (idx >= bg_dict.len) return error.InvalidDictIndex;
            cell.bg = bg_dict[idx];
        }

        // fg
        if (!code.fgIsSkip()) {
            // Read codepoint: 0xC0 = null marker (empty cell), else UTF-8.
            if (ptr >= overflow.len) return error.UnexpectedEndOfData;
            if (overflow[ptr] == 0xC0) {
                cell.fg_codepoint = 0;
                ptr += 1;
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(overflow[ptr]) catch return error.InvalidUtf8;
                if (ptr + cp_len > overflow.len) return error.UnexpectedEndOfData;
                cell.fg_codepoint = std.unicode.utf8Decode(overflow[ptr..][0..cp_len]) catch return error.InvalidUtf8;
                ptr += cp_len;
            }

            // Style: dict or overflow.
            if (code.fgIsOverflow()) {
                if (ptr + FgStyle.size > overflow.len) return error.UnexpectedEndOfData;
                var style: FgStyle = undefined;
                @memcpy(std.mem.asBytes(&style), overflow[ptr..][0..FgStyle.size]);
                ptr += FgStyle.size;
                cell.fg_style = style;
            } else if (code.fgDictIndex()) |idx| {
                if (idx >= fg_dict.len) return error.InvalidDictIndex;
                cell.fg_style = fg_dict[idx];
            }
        }

        out[i] = cell;
    }

    return ptr;
}

pub const DecodeError = error{
    UnexpectedEndOfData,
    InvalidDictIndex,
    InvalidUtf8,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encode/decode roundtrip - all skip" {
    const cells = [_]CellInput{
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0, .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }, .changed = false },
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0, .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }, .changed = false },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 0), result.overflow.len);

    var decoded: [2]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expect(decoded[0].bg == null);
    try testing.expect(decoded[0].fg_codepoint == null);
}

test "encode/decode roundtrip - bg only change" {
    const black = CellBg{ 0, 0, 0, 255 };
    const red = CellBg{ 255, 0, 0, 255 };
    const cells = [_]CellInput{
        .{ .bg = black, .fg_codepoint = 0, .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }, .changed = true },
        .{ .bg = red, .fg_codepoint = 0, .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }, .changed = true },
        .{ .bg = black, .fg_codepoint = 0, .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 }, .changed = false },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [3]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqualSlices(u8, &black, &decoded[0].bg.?);
    try testing.expectEqualSlices(u8, &red, &decoded[1].bg.?);
    try testing.expect(decoded[2].bg == null); // skip
}

test "encode/decode roundtrip - fg with ASCII" {
    const white_style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    const cells = [_]CellInput{
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 'H', .fg_style = white_style, .changed = true },
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 'i', .fg_style = white_style, .changed = true },
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0, .fg_style = white_style, .changed = false },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [3]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqual(@as(u21, 'H'), decoded[0].fg_codepoint.?);
    try testing.expectEqual(@as(u21, 'i'), decoded[1].fg_codepoint.?);
    try testing.expect(decoded[0].fg_style.?.eql(white_style));
    try testing.expect(decoded[2].fg_codepoint == null); // skip
}

test "encode/decode roundtrip - CJK UTF-8" {
    const style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    const cells = [_]CellInput{
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0x4F60, .fg_style = style, .changed = true }, // 你
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0x597D, .fg_style = style, .changed = true }, // 好
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [2]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqual(@as(u21, 0x4F60), decoded[0].fg_codepoint.?);
    try testing.expectEqual(@as(u21, 0x597D), decoded[1].fg_codepoint.?);
}

test "encode/decode roundtrip - fg overflow style" {
    // Create cells with many different fg styles to force overflow.
    var cells: [10]CellInput = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{
            .bg = .{ 0, 0, 0, 255 },
            .fg_codepoint = 'A' + @as(u21, @intCast(i)),
            .fg_style = .{ .color = .{ @intCast(i * 25), 0, 0, 255 }, .atlas = 0 },
            .changed = true,
        };
    }

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [10]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    for (cells, decoded) |input, output| {
        try testing.expectEqual(input.fg_codepoint, output.fg_codepoint.?);
        try testing.expect(output.fg_style.?.eql(input.fg_style));
    }
}

test "encode/decode roundtrip - mixed skip and update" {
    const black = CellBg{ 0, 0, 0, 255 };
    const white_s = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    const green_s = FgStyle{ .color = .{ 0, 255, 0, 255 }, .atlas = 0 };

    const cells = [_]CellInput{
        .{ .bg = black, .fg_codepoint = 'a', .fg_style = white_s, .changed = true },
        .{ .bg = black, .fg_codepoint = 0, .fg_style = white_s, .changed = false }, // skip
        .{ .bg = black, .fg_codepoint = 'c', .fg_style = green_s, .changed = true },
        .{ .bg = black, .fg_codepoint = 0, .fg_style = white_s, .changed = false }, // skip
        .{ .bg = black, .fg_codepoint = 'e', .fg_style = white_s, .changed = true },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [5]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqual(@as(u21, 'a'), decoded[0].fg_codepoint.?);
    try testing.expect(decoded[1].fg_codepoint == null); // skip
    try testing.expectEqual(@as(u21, 'c'), decoded[2].fg_codepoint.?);
    try testing.expect(decoded[2].fg_style.?.eql(green_s));
    try testing.expect(decoded[3].fg_codepoint == null); // skip
    try testing.expectEqual(@as(u21, 'e'), decoded[4].fg_codepoint.?);
}

test "encode/decode roundtrip - bg overflow (>6 colors)" {
    // 8 different bg colors → 6 fit in dict, 2 overflow.
    var cells: [8]CellInput = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{
            .bg = .{ @intCast(i * 30), @intCast(i * 20), @intCast(i * 10), 255 },
            .fg_codepoint = 0,
            .fg_style = .{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 },
            .changed = true,
        };
    }

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    // Should have 6 dict entries max.
    try testing.expect(result.dict_sizes.bgCount() <= 6);
    // overflow should have 2 × 4 = 8 bytes for the 2 overflow bg cells.
    try testing.expect(result.overflow.len >= 8);

    var decoded: [8]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    for (cells, decoded) |input, output| {
        try testing.expectEqualSlices(u8, &input.bg, &output.bg.?);
    }
}

test "encode/decode roundtrip - fg style overflow (>30 styles)" {
    // 32 different fg styles → 30 fit in dict, 2 overflow.
    var cells: [32]CellInput = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{
            .bg = .{ 0, 0, 0, 255 },
            .fg_codepoint = 'A' + @as(u21, @intCast(i % 26)),
            .fg_style = .{ .color = .{ @intCast(i * 8), @intCast(i * 7), @intCast(i * 3), 255 }, .atlas = 0 },
            .changed = true,
        };
    }

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    try testing.expect(result.dict_sizes.fgCount() <= 30);

    var decoded: [32]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    for (cells, decoded) |input, output| {
        try testing.expectEqual(input.fg_codepoint, output.fg_codepoint.?);
        try testing.expect(output.fg_style.?.eql(input.fg_style));
    }
}

test "encode/decode roundtrip - bg overflow + fg overflow same cell" {
    // Force both bg and fg overflow on the same cell (13 bytes max).
    // First 6 cells consume all bg dict slots, next cell overflows.
    // First 30 cells consume all fg dict slots (different styles each).
    var cells: [32]CellInput = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{
            .bg = .{ @intCast(i * 8), @intCast(i * 7), @intCast(i * 3), 255 },
            .fg_codepoint = 'a' + @as(u21, @intCast(i % 26)),
            .fg_style = .{ .color = .{ @intCast(255 - i * 8), @intCast(i * 5), 0, 255 }, .atlas = 0 },
            .changed = true,
        };
    }

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [32]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    for (cells, decoded) |input, output| {
        try testing.expectEqualSlices(u8, &input.bg, &output.bg.?);
        try testing.expectEqual(input.fg_codepoint, output.fg_codepoint.?);
        try testing.expect(output.fg_style.?.eql(input.fg_style));
    }
}

test "encode/decode roundtrip - 4-byte UTF-8 (emoji)" {
    const style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 1 }; // color atlas for emoji
    const cells = [_]CellInput{
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0x1F600, .fg_style = style, .changed = true }, // 😀
        .{ .bg = .{ 0, 0, 0, 255 }, .fg_codepoint = 0x1F680, .fg_style = style, .changed = true }, // 🚀
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [2]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqual(@as(u21, 0x1F600), decoded[0].fg_codepoint.?);
    try testing.expectEqual(@as(u21, 0x1F680), decoded[1].fg_codepoint.?);
    try testing.expectEqual(@as(u8, 1), decoded[0].fg_style.?.atlas); // color atlas
}

test "encode/decode roundtrip - single column" {
    const cells = [_]CellInput{
        .{ .bg = .{ 255, 0, 0, 255 }, .fg_codepoint = 'X', .fg_style = .{ .color = .{ 0, 255, 0, 255 }, .atlas = 0 }, .changed = true },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.cell_map.len);

    var decoded: [1]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, &decoded[0].bg.?);
    try testing.expectEqual(@as(u21, 'X'), decoded[0].fg_codepoint.?);
}

test "encode/decode roundtrip - all cells changed (full update)" {
    const style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    var cells: [80]CellInput = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{
            .bg = .{ 0, 0, 0, 255 },
            .fg_codepoint = 'A' + @as(u21, @intCast(i % 26)),
            .fg_style = style,
            .changed = true,
        };
    }

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [80]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    for (cells, decoded) |input, output| {
        try testing.expectEqual(input.fg_codepoint, output.fg_codepoint.?);
    }
    // No cell should be skip.
    for (decoded) |cell| {
        try testing.expect(cell.bg != null);
    }
}

test "encode/decode roundtrip - bg change only (fg skip)" {
    const red = CellBg{ 255, 0, 0, 255 };
    const style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };
    const cells = [_]CellInput{
        .{ .bg = red, .fg_codepoint = 0, .fg_style = style, .changed = true },
        .{ .bg = red, .fg_codepoint = 0, .fg_style = style, .changed = true },
    };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    var decoded: [2]DecodedCell = undefined;
    _ = try decode(result.cell_map, result.overflow, result.bg_dict, result.fg_dict, &decoded);

    try testing.expectEqualSlices(u8, &red, &decoded[0].bg.?);
    // codepoint=0 with changed=true is transmitted (not skipped),
    // so the client knows the cell was cleared.
    try testing.expectEqual(@as(u21, 0), decoded[0].fg_codepoint.?);
}

test "overflow size - typical row" {
    const black = CellBg{ 0, 0, 0, 255 };
    const style = FgStyle{ .color = .{ 255, 255, 255, 255 }, .atlas = 0 };

    // 128 cols, 5 changed with ASCII characters.
    var cells: [128]CellInput = undefined;
    for (&cells) |*cell| {
        cell.* = .{ .bg = black, .fg_codepoint = 0, .fg_style = style, .changed = false };
    }
    cells[10] = .{ .bg = black, .fg_codepoint = 'a', .fg_style = style, .changed = true };
    cells[20] = .{ .bg = black, .fg_codepoint = 'b', .fg_style = style, .changed = true };
    cells[30] = .{ .bg = black, .fg_codepoint = 'c', .fg_style = style, .changed = true };
    cells[40] = .{ .bg = black, .fg_codepoint = 'd', .fg_style = style, .changed = true };
    cells[50] = .{ .bg = black, .fg_codepoint = 'e', .fg_style = style, .changed = true };

    var result = try encode(testing.allocator, &cells);
    defer freeEncodeResult(testing.allocator, &result);

    // cell_map = 128 bytes, overflow = 5 codepoints (1 byte each ASCII)
    try testing.expectEqual(@as(usize, 128), result.cell_map.len);
    try testing.expectEqual(@as(usize, 5), result.overflow.len);
}
