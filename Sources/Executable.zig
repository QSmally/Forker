
const std = @import("std");

const Forker = @import("Forker.zig");

const Executable = @This();

pub const VTable = struct {
    on_fork: *const fn (*anyopaque) anyerror!void,
    on_forked: ?*const fn (*anyopaque, *Forker) void,
    on_exit: ?*const fn (*anyopaque, *Forker) void
};

pub const Mode = enum {
    once,
    always,
    deferred
};

pub const ManagedState = enum {
    standby,
    running,
    terminating,
    terminated
};

context: *anyopaque,
vtable: VTable,
name: []const u8,
mode: Mode,
run_state: ManagedState,

pid: ?std.posix.pid_t = null,
started_at_ms: ?i64 = null,
exit_sync: std.Thread.Semaphore = .{},

/// In the forked context.
pub fn on_fork(self: *Executable) void {
    self.vtable.on_fork(self.context) catch |err| {
        std.debug.print("{}\n", .{ err });
        std.process.exit(1);
    };
    std.process.exit(0);
}

pub fn on_forked(self: *Executable, forker: *Forker) void {
    if (self.vtable.on_forked) |on_forked_hook|
        on_forked_hook(self.context, forker);
}

/// Main process context.
pub fn on_exit(self: *Executable, forker: *Forker) void {
    self.pid = null;

    self.run_state = switch (self.mode) {
        .once => .terminated,
        .always => .running, // respawn
        .deferred => .standby
    };

    if (self.vtable.on_exit) |on_exit_hook|
        on_exit_hook(self.context, forker);
    self.exit_sync.post();
}
