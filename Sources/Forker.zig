
const std = @import("std");
const shared = @import("shared.zig");

const Forker = @This();

const log = std.log.scoped(.libforker);

const ManagedState = enum {
    cold,
    running,
    terminating,
    exiting,
    exited
};

processes: []Executable,
actions: []Action,

do_restart_workers: bool = false,

signal: std.Thread.Semaphore = .{},
state_mutex: std.Thread.Mutex = .{},
run_state: ManagedState = .cold,
exit_code: u8 = 0,

/// May only be called once per process.
pub fn start(forker: *Forker) void {
    std.debug.assert(global_instance == null);
    std.debug.assert(forker.run_state == .cold);
    global_instance = forker;

    for (forker.actions) |action|
        shared.register_signal(@intCast(action.signal), on_signal);
    shared.register_signal(std.posix.SIG.INT, on_signal);
    shared.register_signal(std.posix.SIG.TERM, on_signal);
    shared.register_signal(std.posix.SIG.CHLD, on_signal);

    forker.run_state = .running;
    log.debug("Forker pid {}", .{ std.posix.system.getpid() });

    for (forker.processes) |*exec| {
        if (exec.run_state == .running)
            forker.spawn_worker(exec) catch forker.exit(1);
    }

    forker.process_cycle();
    forker.wait();
}

pub const Executable = @import("Executable.zig");
pub const Shell = @import("Shell.zig");

pub const Action = struct {

    pub const Trigger = union(enum) {
        func: *const fn (*Forker) void,
        process_idx: usize
    };

    signal: i32,
    trigger: Trigger
};

var global_instance: ?*Forker = null;

fn instance() *Forker {
    std.debug.assert(global_instance != null);
    return global_instance.?;
}

fn on_signal(signal: i32) callconv(.C) void {
    const self = instance();

    switch (signal) {
        std.posix.SIG.INT,
        std.posix.SIG.TERM => self.exit(0),

        std.posix.SIG.CHLD => while (shared.wait()) |result|
            self.on_worker_exit(result.pid, result.status),

        else => self.perform_triggers(signal)
    }
}

fn process_cycle(self: *Forker) void {
    while (self.run_state != .exiting) {
        self.signal.wait();
        log.debug("wake-up", .{});

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const run_state = self.run_state;
        const do_restart_workers = self.do_restart_workers;

        if (run_state == .terminating)
            self.run_state = .exiting;
        self.do_restart_workers = false;

        var all_done = true;

        for (self.processes) |*fork| {
            if (run_state == .terminating) {
                terminate_worker(fork, false);
                continue;
            }

            const old_run_state = fork.run_state;

            // mark worker as terminating if restarting
            if (do_restart_workers and fork.pid != null and fork.run_state == .running and fork.mode != .deferred)
                fork.run_state = .terminating;

            // terminate the worker
            if (fork.run_state == .terminating)
                terminate_worker(fork, fork.mode == .always and run_state == .running);

            // respawn necessary dead workers
            if (fork.pid == null and fork.run_state == .running)
                self.spawn_worker(fork) catch self.exit(1);

            // check if event loop done
            if (fork.run_state == .running)
                all_done = false;

            log.debug("{s}({s}, {s}) {s} -> {s}", .{
                fork.name,
                @tagName(fork.mode),
                @tagName(run_state),
                @tagName(old_run_state),
                @tagName(fork.run_state) });
        }

        if (all_done) {
            log.debug("all done, performing exit", .{});
            self.run_state = .exiting;
            self.signal.post();
        }
    }
}

fn wait(self: *Forker) void {
    log.debug("clean-up", .{});

    for (self.processes) |*fork| {
        if (fork.pid != null) fork.exit_sync.wait();
    }
}

pub fn exit(self: *Forker, exit_code: u8) void {
    self.run_state = .terminating;
    self.exit_code = exit_code;
    self.signal.post();
}

fn on_worker_exit(self: *Forker, pid: std.posix.pid_t, status: u32) void {
    for (self.processes) |*fork| {
        if (fork.pid != pid) continue;
        fork.on_exit(self);
        log.warn("{s} ({}): exited with status {}", .{ fork.name, pid, status });
        return self.signal.post();
    }

    @panic("bug: untracked worker process");
}

fn spawn_worker(self: *Forker, worker: *Executable) !void {
    const pid = try std.posix.fork();

    if (pid == 0) {
        for (self.actions) |action|
            shared.register_signal(@intCast(action.signal), std.posix.SIG.DFL);
        shared.register_signal(std.posix.SIG.INT, std.posix.SIG.DFL);
        shared.register_signal(std.posix.SIG.TERM, std.posix.SIG.DFL);
        shared.register_signal(std.posix.SIG.CHLD, std.posix.SIG.DFL);

        switch (worker.stdin) {
            .shared => {},
            .copy => {}, // TODO
            .close => std.posix.close(0),
            .pipe => |new_stdin| try std.posix.dup2(new_stdin, 0) 
        }

        return worker.on_fork();
    }

    log.info("{s}: start worker process {}", .{ worker.name, pid });

    worker.pid = pid;
    worker.started_at_ms = std.time.milliTimestamp();
    worker.exit_sync = .{};
    worker.on_forked(self);
}

fn terminate_worker(worker: *Executable, respawn: bool) void {
    if (worker.pid) |pid|
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    worker.run_state = if (respawn) .running else .terminated;
}

fn perform_triggers(self: *Forker, signal: i32) void {
    var wake_up = false;

    for (self.actions) |action| {
        if (action.signal != signal) continue;
        wake_up = true;

        switch (action.trigger) {
            .func => |func| func(self),
            .process_idx => |idx| {
                if (self.processes[idx].run_state != .terminating)
                    self.processes[idx].run_state = .running;
            }
        }
    }

    if (wake_up)
        self.signal.post();
}
