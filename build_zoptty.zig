//! Standalone build for zoptty subproject.
//!
//! Builds only src/zoptty/* with Zig 0.16. Avoids ghostty's main
//! build.zig to stay independent of the terminal/apprt/renderer tree.
//!
//! Steps:
//!   zig build --build-file build_zoptty.zig test         # codec unit tests
//!   zig build --build-file build_zoptty.zig server       # build server exe
//!   zig build --build-file build_zoptty.zig client       # build client exe
//!   zig build --build-file build_zoptty.zig run-server   # build + run server
//!   zig build --build-file build_zoptty.zig run-client   # build + run client

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Codec module (protocol + frame encode/decode). Used for tests only;
    // the server/client exes pull their own sources from src/zoptty/.
    const codec_mod = b.createModule(.{
        .root_source_file = b.path("src/zoptty/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- tests ----------------------------------------------------------
    {
        const step = b.step("test", "Run zoptty codec unit tests");
        const tests = b.addTest(.{ .root_module = codec_mod });
        step.dependOn(&b.addRunArtifact(tests).step);
    }

    // --- server ---------------------------------------------------------
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/zoptty/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_exe = b.addExecutable(.{ .name = "zoptty-server", .root_module = server_mod });
    {
        const step = b.step("server", "Build zoptty server");
        step.dependOn(&b.addInstallArtifact(server_exe, .{}).step);

        const run_step = b.step("run-server", "Run zoptty server");
        run_step.dependOn(&b.addRunArtifact(server_exe).step);
    }

    // --- client ---------------------------------------------------------
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/zoptty/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const client_exe = b.addExecutable(.{ .name = "zoptty-client", .root_module = client_mod });
    {
        const step = b.step("client", "Build zoptty test client");
        step.dependOn(&b.addInstallArtifact(client_exe, .{}).step);

        const run_step = b.step("run-client", "Run zoptty test client");
        run_step.dependOn(&b.addRunArtifact(client_exe).step);
    }
}
