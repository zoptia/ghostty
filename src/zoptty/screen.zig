//! Minimal screen buffer for zoptty MVP.
//!
//! Handles only the essentials to show a shell prompt:
//!   - Printable ASCII / UTF-8 codepoints placed at the cursor
//!   - \n  → next row (cursor column unchanged, LNM-style not emulated)
//!   - \r  → cursor column = 0
//!   - \b  → cursor column -= 1 (no wrap)
//!   - \t  → advance to next tab stop (every 8 cols)
//!   - ESC [ ... CSI sequences are parsed enough to strip them (no effect
//!     on screen state).
//!
//! Deliberately NOT a full terminal emulator. Once zoptty is wired up to
//! ghostty's Terminal engine (Step 2b), this file goes away.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const Screen = struct {
    rows: u16,
    cols: u16,

    /// Flat arrays, row-major, length = rows * cols.
    bg: []protocol.CellBg,
    cp: []u21,
    fg: []protocol.FgStyle,

    /// Per-row dirty flag. Marked true on any write into that row.
    dirty: []bool,

    /// Cursor position.
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,

    /// Parser state for CSI stripping.
    parse: Parse = .normal,

    const Parse = enum { normal, esc, csi };

    const default_bg: protocol.CellBg = .{ 0, 0, 0, 255 };
    const default_fg: protocol.FgStyle = .{
        .color = .{ 230, 230, 230, 255 },
        .atlas = 0,
        .flags = .{},
    };

    pub fn init(alloc: std.mem.Allocator, rows: u16, cols: u16) !Screen {
        const n: usize = @as(usize, rows) * @as(usize, cols);
        const bg = try alloc.alloc(protocol.CellBg, n);
        const cp = try alloc.alloc(u21, n);
        const fg = try alloc.alloc(protocol.FgStyle, n);
        const dirty = try alloc.alloc(bool, rows);
        @memset(bg, default_bg);
        @memset(cp, 0);
        @memset(fg, default_fg);
        @memset(dirty, true); // everything dirty initially
        return .{
            .rows = rows,
            .cols = cols,
            .bg = bg,
            .cp = cp,
            .fg = fg,
            .dirty = dirty,
        };
    }

    pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
        alloc.free(self.bg);
        alloc.free(self.cp);
        alloc.free(self.fg);
        alloc.free(self.dirty);
    }

    fn idx(self: *const Screen, r: u16, col: u16) usize {
        return @as(usize, r) * @as(usize, self.cols) + col;
    }

    /// Feed raw PTY bytes into the screen.
    pub fn write(self: *Screen, bytes: []const u8) void {
        for (bytes) |b| self.writeByte(b);
    }

    fn writeByte(self: *Screen, b: u8) void {
        switch (self.parse) {
            .esc => {
                self.parse = if (b == '[') .csi else .normal;
                return;
            },
            .csi => {
                // Final byte of CSI is 0x40..0x7E. Params are 0x30..0x3F.
                // Intermediates 0x20..0x2F. For simplicity: any byte in
                // 0x40..0x7E ends the sequence.
                if (b >= 0x40 and b <= 0x7E) self.parse = .normal;
                return;
            },
            .normal => {},
        }

        switch (b) {
            0x1B => self.parse = .esc,
            '\n' => {
                if (self.cursor_row + 1 >= self.rows) {
                    self.scrollUp();
                } else {
                    self.cursor_row += 1;
                }
                self.dirty[self.cursor_row] = true;
            },
            '\r' => {
                self.cursor_col = 0;
            },
            0x08 => { // backspace
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            '\t' => {
                self.cursor_col = @min(
                    (self.cursor_col + 8) & ~@as(u16, 7),
                    self.cols - 1,
                );
            },
            0x00...0x06, 0x0B...0x0C, 0x0E...0x1A, 0x1C...0x1F, 0x7F => {
                // Other C0 / DEL — ignore.
            },
            else => {
                // Printable ASCII only for now (no UTF-8 multi-byte).
                if (b < 0x20) return;
                if (self.cursor_col >= self.cols) {
                    // Auto-wrap: move to next row.
                    self.cursor_col = 0;
                    if (self.cursor_row + 1 >= self.rows) {
                        self.scrollUp();
                    } else {
                        self.cursor_row += 1;
                    }
                }
                const i = self.idx(self.cursor_row, self.cursor_col);
                self.cp[i] = b;
                self.bg[i] = default_bg;
                self.fg[i] = default_fg;
                self.dirty[self.cursor_row] = true;
                self.cursor_col += 1;
            },
        }
    }

    fn scrollUp(self: *Screen) void {
        const cols_usize: usize = @intCast(self.cols);
        // Shift rows 1..N to 0..N-1.
        for (0..self.rows - 1) |r| {
            const dst_start = r * cols_usize;
            const src_start = (r + 1) * cols_usize;
            @memcpy(self.bg[dst_start..][0..cols_usize], self.bg[src_start..][0..cols_usize]);
            @memcpy(self.cp[dst_start..][0..cols_usize], self.cp[src_start..][0..cols_usize]);
            @memcpy(self.fg[dst_start..][0..cols_usize], self.fg[src_start..][0..cols_usize]);
        }
        // Clear bottom row.
        const last_start = (@as(usize, self.rows) - 1) * cols_usize;
        @memset(self.bg[last_start..][0..cols_usize], default_bg);
        @memset(self.cp[last_start..][0..cols_usize], 0);
        @memset(self.fg[last_start..][0..cols_usize], default_fg);
        // All rows dirty after scroll.
        @memset(self.dirty, true);
    }

    /// Get a slice view of row N's data. Pointers stay valid until next
    /// write that may reallocate (this impl never does).
    pub fn row(self: *Screen, r: u16) struct {
        bg: []protocol.CellBg,
        cp: []u21,
        fg: []protocol.FgStyle,
    } {
        const start = self.idx(r, 0);
        const cols_usize: usize = @intCast(self.cols);
        return .{
            .bg = self.bg[start..][0..cols_usize],
            .cp = self.cp[start..][0..cols_usize],
            .fg = self.fg[start..][0..cols_usize],
        };
    }
};
