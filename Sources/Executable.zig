
const std = @import("std");

const Forker = @import("Forker.zig");
const JobQueue = @import("JobQueue.zig");

const Executable = @This();

pub const VTable = struct {
    on_fork: *const fn (*anyopaque) anyerror!void,
    on_forked: ?*const fn (*anyopaque, *Forker) void,
    on_exit: ?*const fn (*anyopaque, *Forker) void
};

pub const Mode = union(enum) {
    once,
    always,
    retry: u64,
    deferred
};

pub const ManagedState = enum {
    standby,
    running,
    terminating,
    terminated
};

pub const StdIn = union(enum) {
    shared,
    copy,
    close,
    pipe: std.posix.fd_t
};

context: *anyopaque,
vtable: VTable,
name: []const u8,
mode: Mode,

run_state: ManagedState = .running,
stdin: StdIn = .shared,
queue: ?*JobQueue = null,

pid: ?std.posix.pid_t = null,
last_start_ms: ?i64 = null,
last_exit_code: u32 = undefined,
instance: u64 = 0,
exit_sync: std.Thread.Semaphore = .{},

/// In the child process context.
pub fn on_fork(self: *Executable) noreturn {
    self.vtable.on_fork(self.context) catch |err| {
        std.debug.print("{}\n", .{ err });
        std.process.exit(1);
    };
    std.process.exit(0);
}

/// Main process context.
pub fn on_forked(self: *Executable, forker: *Forker, pid: std.posix.pid_t) void {
    self.pid = pid;
    self.last_start_ms = std.time.milliTimestamp();
    self.instance += 1;
    self.exit_sync = .{};

    if (self.vtable.on_forked) |on_forked_hook|
        on_forked_hook(self.context, forker);
}

/// Main process context.
pub fn on_exit(self: *Executable, forker: *Forker, status: u32) void {
    self.pid = null;
    self.last_exit_code = status;

    self.run_state = switch (self.mode) {
        .once => .terminated,
        .always => .running, // respawn
        .retry => |c| if (status != 0 and (c == 0 or self.instance < c))
            .running else // respawn if failure and under retries
            .terminated,
        .deferred => .standby
    };

    if (self.vtable.on_exit) |on_exit_hook|
        on_exit_hook(self.context, forker);

    if (self.run_state == .terminated) blk: {
        const log = std.log.scoped(.libforker);
        const queue = self.queue orelse break :blk;
        const job = queue.pop() orelse break :blk;

        log.debug("reuse job context, queue len={}", .{ queue.queue.items.len });

        self.context = job.context;
        self.vtable = job.vtable;
        self.name = job.name;
        self.mode = job.mode;
        self.run_state = job.run_state;
        self.stdin = job.stdin;
        self.instance = 0;
    }

    self.exit_sync.post();
}
