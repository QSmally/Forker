
const std = @import("std");

const Forker = @import("Forker.zig");

const Shell = @This();

exec: union(enum) {
    execv: []const []const u8,
    expr: []const u8
},

pub fn init(execv: []const []const u8) Shell {
    std.debug.assert(execv.len > 0);
    return .{ .exec = .{ .execv = execv } };
}

pub fn init_expr(expr: []const u8) Shell {
    return .{ .exec = .{ .expr = expr } };
}

const vtable = Forker.Executable.VTable {
    .on_fork = on_fork,
    .on_forked = null,
    .on_exit = null };
pub fn executable(self: *const Shell, mode: Forker.Executable.Mode) Forker.Executable {
    return .{
        .context = @constCast(self),
        .vtable = vtable,
        .name = switch (self.exec) {
            .execv => |execv| std.fs.path.basename(execv[0]),
            .expr => "sh"
        },
        .mode = mode };
}

var gpa = std.heap.GeneralPurposeAllocator(.{}) {};

fn on_fork(this: *anyopaque) !void {
    const self: *Shell = @alignCast(@ptrCast(this));
    return std.process.execv(gpa.allocator(), switch (self.exec) {
        .execv => |execv| execv,
        .expr => |expr| &.{ "sh", "-c", expr }
    });
}
