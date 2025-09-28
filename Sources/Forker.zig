
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

    shared.register_signal(std.posix.SIG.INT, on_signal);
    shared.register_signal(std.posix.SIG.TERM, on_signal);
    shared.register_signal(std.posix.SIG.CHLD, on_signal);

    for (forker.processes) |*exec|
        forker.spawn_worker(exec) catch forker.exit(1);
    forker.process_cycle();
    forker.wait();
}

pub const Executable = @import("Executable.zig");
pub const Shell = @import("Shell.zig");

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

        else => {}
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

            // mark worker as terminating if restarting
            if (do_restart_workers and fork.pid != null and fork.run_state == .running)
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
        }

        if (all_done) {
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

fn default_exit(_: i32) callconv(.C) void {
    std.process.exit(0);
}

fn spawn_worker(self: *Forker, worker: *Executable) !void {
    const pid = try std.posix.fork();

    if (pid == 0) {
        shared.register_signal(std.posix.SIG.INT, default_exit);
        shared.register_signal(std.posix.SIG.TERM, default_exit);
        shared.register_signal(std.posix.SIG.CHLD, std.posix.SIG.IGN);
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
