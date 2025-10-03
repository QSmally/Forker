
const builtin = @import("builtin");
const std = @import("std");

pub fn register_signal(signal: u6, handler: anytype) void {
    const sigaction = std.posix.Sigaction {
        .handler = .{ .handler = handler },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.SIGINFO };
    std.posix.sigaction(signal, &sigaction, null);
}

pub fn wait() ?std.posix.WaitPidResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(-1, &status, @intCast(std.posix.W.NOHANG));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return if (rc != 0)
                .{ .pid = @intCast(rc), .status = @bitCast(status) } else
                null,
            .INTR => continue,
            .CHILD => return null, // For WNOHANG, where waitpid() returns immediately if no process already terminated. Null without WNOHANG is impossible.
            else => unreachable
        }
    }
}
