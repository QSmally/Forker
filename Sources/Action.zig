
const Forker = @import("Forker.zig");

pub const Trigger = union(enum) {
    func: *const fn (*Forker) void,
    process_idx: usize
};

signal: i32,
trigger: Trigger
