
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
        \\    --retry expr              execv path
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
    var run_options = arguments.parse(Options, allocator) catch |err| {
        switch (err) {
            error.InvalidCharacter => std.debug.print("error: {s}: invalid numeric '{s}'\n", .{ arguments.current_option, arguments.current_value }),
            error.Overflow => std.debug.print("error: {s}: {s} doesn't fit in type {s}\n", .{ arguments.current_option, arguments.current_value, arguments.current_type }),
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

    if (run_options.standby)
        run_options.idle = true; // implicit

    if (run_options.jobs == 0)
        run_options.jobs = std.Thread.getCpuCount() catch 4;

    if (run_options.quiet)
        quiet = true;
    const debug = std.posix.getenv("DEBUG_ENABLED") orelse "0";

    if (std.mem.eql(u8, debug, "1"))
        quiet = false;

    return try run(allocator, run_config, run_actions, run_options);
}

pub const std_options = std.Options { .logFn = log };

const Options = struct {
    parallelise: ?[]const u8 = null,
    jobs: u64 = 0,
    idle: bool = false,
    standby: bool = false,
    quiet: bool = false,
    doptions: bool = false,
    help: bool = false
};

var gpa = std.heap.GeneralPurposeAllocator(.{}) {};

const stdin = std.io
    .getStdIn()
    .reader();

const stdout = std.io
    .getStdOut()
    .writer();

var quiet = false;

fn log(
    comptime level: std.log.Level,
    comptime _: @Type(.enum_literal),
    comptime format: []const u8,
    args_: anytype
) void {
    if (quiet) return;

    const prefix = switch (level) {
        .debug => "(debug) ",
        .err => "(err) ",
        else => ""
    };

    nosuspend stdout.print(prefix ++ format ++ "\n", args_) catch return;
}

fn run(
    allocator: std.mem.Allocator,
    run_config: []const frontend.Config,
    run_actions: []const frontend.Action,
    run_options: Options
) !u8 {
    var executables: std.ArrayListUnmanaged(Forker.Executable) = .empty;
    defer executables.deinit(allocator);

    var actions: std.ArrayListUnmanaged(Forker.Action) = .empty;
    defer actions.deinit(allocator);

    for (run_config) |*config| {
        try executables.append(allocator, config.executable());
    }

    if (run_options.parallelise) |expr| {
        const shell = Forker.Shell.init_expr(expr);
        var job_queue = Forker.JobQueue {};
        var jobs: usize = 0;

        std.log.debug("max jobs {}", .{ run_options.jobs });

        while (try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) |line| {
            defer allocator.free(line);
            if (line.len == 0) continue;

            const pipe = try std.posix.pipe();
            errdefer std.posix.close(pipe[0]); // read end
            defer std.posix.close(pipe[1]); // write end

            const file = std.fs.File { .handle = pipe[1] };
            try file.writeAll(line);
            try file.writeAll("\n");

            var executable = shell.executable(.once, .{ .pipe = pipe[0] });
            executable.queue = &job_queue;
            std.log.debug("parallelise: {s}", .{ line });

            var list: *std.ArrayListUnmanaged(Forker.Executable) = if (jobs >= run_options.jobs)
                &job_queue.queue else
                &executables;
            try list.append(allocator, executable);

            jobs += 1;
        }
    }

    if (!run_options.idle and executables.items.len == 0)
        return 0;

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
            try executables.append(allocator, execute.executable(.deferred, .shared));
        }
    };

    std.log.debug("concurrent jobs {}", .{ executables.items.len });

    var forker = Forker {
        .processes = executables.items,
        .actions = actions.items,
        .standby = run_options.standby };
    Forker.start(&forker);
    return forker.exit_code;
}
