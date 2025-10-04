
const std = @import("std");

const Executable = @import("Executable.zig");

const JobQueue = @This();

mutex: std.Thread.Mutex = .{},
queue: std.ArrayListUnmanaged(Executable) = .empty,

pub fn pop(self: *JobQueue) ?Executable {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.queue.pop();
}
