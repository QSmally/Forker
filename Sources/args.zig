
const std = @import("std");

const Forker = @import("forker");
const frontend = @import("frontend.zig");

// https://github.com/QSmally/QCPU-CLI/blob/6ca9bf79931a5232a7eecfccf6b87f3b3b7305aa/Sources/qcpu.zig#L196
pub fn Arguments(comptime T: type) type {
    return struct {

        const ArgumentsType = @This();

        iterator: T,

        current_option: []const u8 = undefined,
        current_type: []const u8 = undefined,
        current_value: []const u8 = undefined,

        pub fn init(iterator: T) ArgumentsType {
            return .{ .iterator = iterator };
        }

        pub fn init_second(iterator: T) ArgumentsType {
            var arguments = ArgumentsType.init(iterator);
            _ = arguments.iterator.skip();
            return arguments;
        }

        pub fn next(self: *ArgumentsType) ?[]const u8 {
            const slice: []const u8 = @ptrCast(self.iterator.next() orelse return null);
            self.current_value = slice;
            return slice;
        }

        const Error = error { ArgumentExpected };

        pub fn expect(self: *ArgumentsType) Error![]const u8 {
            return self.next() orelse error.ArgumentExpected;
        }

        fn is_option(self: *ArgumentsType, option: []const u8, argument: []const u8) bool {
            self.current_option = option;
            return std.mem.eql(u8, option, argument);
        }

        pub fn parse(self: *ArgumentsType, comptime OptionsType: type, allocator: std.mem.Allocator) !struct {
            []const frontend.Config,
            []const frontend.Action,
            OptionsType
        } {
            var run_config: std.ArrayListUnmanaged(frontend.Config) = .empty;
            var run_actions: std.ArrayListUnmanaged(frontend.Action) = .empty;
            var run_options = OptionsType {};

            arg: while (self.next()) |argument| {
                if (std.mem.eql(u8, "--", argument))
                    break;
                inline for (@typeInfo(OptionsType).@"struct".fields) |option| {
                    const name = "--" ++ option.name;
                    const Type = option.@"type";

                    self.current_option = name;
                    self.current_type = @typeName(Type);

                    if (std.mem.eql(u8, name, argument)) {
                        const value = val: switch (Type) {
                            bool => true,

                            u16, u24, u32, u64 => {
                                const inherit = 0;
                                const input = try self.expect();
                                break :val try std.fmt.parseInt(Type, input, inherit);
                            },

                            []const u8,
                            ?[]const u8 => try self.expect(),

                            else => @compileError("bug: unsupported option type: " ++ @typeName(Type))
                        };

                        @field(run_options, option.name) = value;
                        continue :arg;
                    }
                }

                if (self.is_option(argument, "--always")) {
                    try run_config.append(allocator, .{ .always = Forker.Shell.init_expr(try self.expect()) });
                    continue :arg;
                }

                if (self.is_option(argument, "--once")) {
                    try run_config.append(allocator, .{ .once = Forker.Shell.init_expr(try self.expect()) });
                    continue :arg;
                }

                if (self.is_option(argument, "--on")) {
                    const signal = frontend.signal_map.get(try self.expect()) orelse return error.SignalNotFound;
                    const action_str = try self.expect();

                    const execute: frontend.Action.Execute = if (frontend.func_map.get(action_str)) |internal_func|
                        .{ .internal = internal_func } else
                        .{ .shell = Forker.Shell.init_expr(action_str) };
                    try run_actions.append(allocator, .{
                        .signal = signal,
                        .execute = execute });
                    continue :arg;
                }

                return error.OptionNotFound;
            }

            return .{
                try run_config.toOwnedSlice(allocator),
                try run_actions.toOwnedSlice(allocator),
                run_options };
        }
    };
}

// Tests

test "arguments iterator" {
    const foo = std.mem.splitScalar(u8, "foo bar roo", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);

    try std.testing.expectEqualSlices(u8, "foo", iterator.next() orelse "x");
    try std.testing.expectEqualSlices(u8, "bar", iterator.next() orelse "x");
    try std.testing.expectEqualSlices(u8, "roo", iterator.next() orelse "x");
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());
}

const TestOptions = struct {
    foo: bool = false,
    bar: bool = false,
    roo: ?[]const u8 = null,
    doo: bool = false,
    loo: u16 = 0
};

test "arguments parser simple correctly" {
    const foo = std.mem.splitScalar(u8, "--foo --bar aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const positional, _, const tagged = try iterator.parse(TestOptions, std.testing.allocator);
    defer std.testing.allocator.free(positional);

    try std.testing.expectEqual(true, tagged.foo);
    try std.testing.expectEqual(true, tagged.bar);
    try std.testing.expectEqual(@as(?[]const u8, null), tagged.roo);
    try std.testing.expectEqual(false, tagged.doo);
    try std.testing.expectEqual(@as(u16, 0), tagged.loo);

    try std.testing.expect(positional.len == 1);
    try std.testing.expectEqualSlices(u8, "aaa", positional[0]);
}

test "arguments parser advanced correctly" {
    const foo = std.mem.splitScalar(u8, "--roo bbb --loo 5 aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const positional, _, const tagged = try iterator.parse(TestOptions, std.testing.allocator);
    defer std.testing.allocator.free(positional);

    try std.testing.expectEqual(false, tagged.foo);
    try std.testing.expectEqual(false, tagged.bar);
    try std.testing.expectEqualSlices(u8, "bbb", tagged.roo.?);
    try std.testing.expectEqual(false, tagged.doo);
    try std.testing.expectEqual(@as(u16, 5), tagged.loo);

    try std.testing.expect(positional.len == 1);
    try std.testing.expectEqualSlices(u8, "aaa", positional[0]);
}

test "arguments parser advanced incorrectly 1" {
    const foo = std.mem.splitScalar(u8, "--roo", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.ArgumentExpected, err);
}

test "arguments parser advanced incorrectly 2" {
    const foo = std.mem.splitScalar(u8, "--loo 0xFFFFFF", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.Overflow, err);
}

test "arguments parser advanced incorrectly 3" {
    const foo = std.mem.splitScalar(u8, "--aaa 0xFFFFFF", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.OptionNotFound, err);
}
