
const std = @import("std");

const Forker = @import("forker");
const args = @import("args.zig");
const frontend = @import("frontend.zig");

fn help(raw_writer: anytype) !void {
    var buffer = std.io.bufferedWriter(raw_writer);
    defer buffer.flush() catch {};
    var writer = buffer.writer();

    try writer.writeAll(
        \\
        \\    Forker CLI
        \\    forker [option ...] [definition [setting ...] ...]
        \\
        \\process definition
        \\    --always expr             execv path
        \\    --once expr               execv path
        \\    --on signal internal:fn   internal func
        \\    --on signal expr          execv path
        \\
        \\internal functions
        \\    internal:restart          restart all processes
        \\
        \\process setting
        \\    ...
        \\
        \\
    );

    inline for (&[_]struct { []const u8, type } {
        .{ "options", Options }
    }) |category| {
        try writer.print("{s}\n", .{ category[0] });

        inline for (@typeInfo(category[1]).@"struct".fields) |field| {
            const fancy_type = switch (field.@"type") {
                []const u8 => "string (default " ++ field.defaultValue().? ++ ")",
                ?[]const u8 => "string (default none)",
                bool => "",
                u3, u16, u32, u64 => @typeName(field.@"type") ++ " (default " ++ std.fmt.comptimePrint("{}", .{ field.defaultValue().? }) ++ ")",
                ?u3, ?u16, ?u32, ?u64 => @typeName(field.@"type") ++ " (default none)",
                else => @typeName(field.@"type")
            };

            try writer.print("    --{s} {s}\n", .{ field.name, fancy_type });
        }

        try writer.writeAll("\n");
    }
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    var arguments = args.Arguments(std.process.ArgIterator).init_second(std.process.args());

    const run_config,
    const run_actions,
    const run_options = arguments.parse(Options, allocator) catch |err| {
        switch (err) {
            // error.InvalidCharacter => std.debug.print("error: {s}: invalid numeric '{s}'\n", .{ arguments.current_option, arguments.current_value }),
            // error.Overflow => std.debug.print("error: {s}: {s} doesn't fit in type {s}\n", .{ arguments.current_option, arguments.current_value, arguments.current_type }),
            error.ArgumentExpected => std.debug.print("error: {s}: expected option value\n", .{ arguments.current_option }),
            error.OptionNotFound => std.debug.print("error: {s}: unknown option\n", .{  arguments.current_value }),
            error.SignalNotFound => std.debug.print("error: {s}: signal {s} is invalid\n", .{ arguments.current_option, arguments.current_value }),
            error.OutOfMemory => std.debug.print("error: out of memory\n", .{})
        }
        return 1;
    };

    if (run_options.doptions)
        std.debug.print("{any}\n{any}\n{any}\n", .{ run_config, run_actions, run_options });

    if (run_options.help) {
        try help(stdout);
        return 0;
    }

    if (!run_options.idle and run_config.len == 0)
        return 0;

    if (run_options.quiet)
        quiet = true;

    return try run(allocator, run_config, run_actions);
}

pub const std_options = std.Options { .logFn = log };

const Options = struct {
    idle: bool = false,
    quiet: bool = false,
    doptions: bool = false,
    help: bool = false
};

var gpa = std.heap.GeneralPurposeAllocator(.{}) {};

const stdout = std.io
    .getStdOut()
    .writer();

var quiet = false;

fn log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args_: anytype
) void {
    if (quiet) return;

    const message = switch (scope) {
        // .libforker => "Forker: " ++ format,
        else => format
    };

    const prefix = switch (level) {
        .debug => "(debug) ",
        .err => "(err) ",
        else => ""
    };

    nosuspend stdout.print(prefix ++ message ++ "\n", args_) catch return;
}

fn run(
    allocator: std.mem.Allocator,
    run_config: []const frontend.Config,
    run_actions: []const frontend.Action
) !u8 {
    var executables: std.ArrayListUnmanaged(Forker.Executable) = .empty;
    defer executables.deinit(allocator);

    var actions: std.ArrayListUnmanaged(Forker.Action) = .empty;
    defer actions.deinit(allocator);

    for (run_config) |*config| {
        try executables.append(allocator, config.executable());
    }

    for (run_actions) |*action| switch (action.execute) {
        .internal => |func| {
            try actions.append(allocator, .{
                .signal = action.signal,
                .trigger = .{ .func = func } });
        },
        .shell => |*execute| {
            const idx = executables.items.len;
            try actions.append(allocator, .{
                .signal = action.signal,
                .trigger = .{ .process_idx = idx } });
            try executables.append(allocator, execute.executable(.deferred));
        }
    };

    var forker = Forker {
        .processes = executables.items,
        .actions = actions.items };
    Forker.start(&forker);
    return forker.exit_code;
}
