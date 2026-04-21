//! Minimal PTY spawn/read/write for zoptty. POSIX-only (macOS/Linux).

const std = @import("std");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("util.h"); // openpty on macOS/BSD
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

pub const Size = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const Pty = struct {
    master: c_int,
    slave: c_int,
    pid: c.pid_t,

    pub fn spawn(
        argv: [*:null]const ?[*:0]const u8,
        size: Size,
    ) !Pty {
        var master: c_int = 0;
        var slave: c_int = 0;
        var ws: c.winsize = .{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = size.xpixel,
            .ws_ypixel = size.ypixel,
        };

        if (c.openpty(&master, &slave, null, null, &ws) != 0) {
            return error.OpenptyFailed;
        }
        errdefer {
            _ = c.close(master);
            _ = c.close(slave);
        }

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // Child: become session leader, make slave our controlling tty,
            // redirect stdio, exec shell.
            _ = c.close(master);
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            if (slave > 2) _ = c.close(slave);

            _ = c.execvp(argv[0].?, @ptrCast(argv));
            _ = c.write(2, "execvp failed\n", 14);
            c._exit(127);
        }

        return .{ .master = master, .slave = slave, .pid = pid };
    }

    pub fn deinit(self: *Pty) void {
        _ = c.close(self.master);
        _ = c.close(self.slave);
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        const n = c.read(self.master, buf.ptr, buf.len);
        if (n < 0) {
            const errno = std.c._errno().*;
            return switch (errno) {
                c.EAGAIN => error.WouldBlock,
                c.EINTR => error.Interrupted,
                c.EIO => error.EndOfFile,
                else => error.ReadFailed,
            };
        }
        if (n == 0) return error.EndOfFile;
        return @intCast(n);
    }

    pub fn write(self: *Pty, bytes: []const u8) !usize {
        const n = c.write(self.master, bytes.ptr, bytes.len);
        if (n < 0) return error.WriteFailed;
        return @intCast(n);
    }

    pub fn setNonBlocking(self: *Pty) !void {
        const flags = c.fcntl(self.master, c.F_GETFL, @as(c_int, 0));
        if (flags < 0) return error.FcntlFailed;
        if (c.fcntl(self.master, c.F_SETFL, flags | c.O_NONBLOCK) < 0) {
            return error.FcntlFailed;
        }
    }

    pub fn resize(self: *Pty, size: Size) !void {
        var ws: c.winsize = .{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = size.xpixel,
            .ws_ypixel = size.ypixel,
        };
        if (c.ioctl(self.master, c.TIOCSWINSZ, &ws) != 0) {
            return error.ResizeFailed;
        }
    }

    /// Returns true if child has exited; non-blocking.
    pub fn hasExited(self: *Pty) bool {
        var status: c_int = 0;
        const wpid = c.waitpid(self.pid, &status, c.WNOHANG);
        return wpid == self.pid;
    }
};
