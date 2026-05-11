const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "sleep_ms",    .ptr = nativeSleepMs },
        .{ .name = "is_done",     .ptr = nativeIsDone },
        .{ .name = "task_result", .ptr = nativeTaskResult },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

// In the bootstrap VM, async runs synchronously. sleep_ms is a no-op.
fn nativeSleepMs(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io; _ = args;
    return .nil;
}

fn nativeIsDone(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .task => |t| .{ .bool_ = t.status == .done },
        else  => .{ .bool_ = true },
    };
}

fn nativeTaskResult(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .task => |t| t.result,
        else  => args[0],
    };
}
