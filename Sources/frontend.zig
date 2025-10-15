
const std = @import("std");

const Forker = @import("forker");

pub const Options = struct {
    parallelise: ?[]const u8 = null,
    jobs: u64 = 0,
    retries: u64 = 0,
    idle: bool = false,
    standby: bool = false,
    quiet: bool = false,
    pid: bool = false,
    doptions: bool = false,
    help: bool = false
};

pub const signal_map = std.StaticStringMap(i32).initComptime(.{
    .{ "HUP", std.posix.SIG.HUP },
    .{ "USR1", std.posix.SIG.USR1 },
    .{ "USR2", std.posix.SIG.USR2 },
});

fn restart(forker: *Forker) void {
    forker.do_restart_workers = true;
    forker.signal.post();
}

pub const func_map = std.StaticStringMap(*const fn (*Forker) void).initComptime(.{
    .{ "internal:restart", restart }
});

pub const Action = struct {

    pub const Execute = union(enum) {
        internal: *const fn (*Forker) void,
        shell: Forker.Shell
    };

    signal: i32,
    execute: Execute
};

pub const Config = union(enum) {

    once: Forker.Shell,
    always: Forker.Shell,
    retry: Forker.Shell,

    pub fn executable(self: *const Config, options: *const Options) Forker.Executable {
        return switch (self.*) {
            .once => |*shell| shell.executable(.once, .shared),
            .always => |*shell| shell.executable(.always, .shared),
            .retry => |*shell| shell.executable(.{ .retry = options.retries }, .shared)
        };
    }
};
