
const std = @import("std");

const Forker = @import("forker");

pub const signal_map = std.StaticStringMap(i32).initComptime(.{
    .{ "HUP", std.posix.SIG.HUP },
    .{ "USR1", std.posix.SIG.USR1 },
    .{ "USR2", std.posix.SIG.USR2 },
});

fn restart(forker: *Forker) void {
    forker.do_restart_workers = true;
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

    always: Forker.Shell,
    once: Forker.Shell,

    pub fn executable(self: *const Config) Forker.Executable {
        return switch (self.*) {
            .always => |*shell| shell.executable(.always, .shared),
            .once => |*shell| shell.executable(.once, .shared)
        };
    }
};
