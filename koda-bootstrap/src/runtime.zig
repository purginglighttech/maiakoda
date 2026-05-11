/// Koda built-in native functions.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");
const lib_core   = @import("lib_core");
const lib_string = @import("lib_string");
const lib_array  = @import("lib_array");
const lib_table  = @import("lib_table");
const lib_math   = @import("lib_math");
const lib_io     = @import("lib_io");
const lib_async  = @import("lib_async");

pub fn registerAll(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "print",   .ptr = nativePrint },
        .{ .name = "println", .ptr = nativePrintln },
        .{ .name = "len",     .ptr = nativeLen },
        .{ .name = "type",    .ptr = nativeType },
        .{ .name = "str",     .ptr = nativeStr },
        .{ .name = "int",     .ptr = nativeInt },
        .{ .name = "float",   .ptr = nativeFloat },
        .{ .name = "push",    .ptr = nativePush },
        .{ .name = "pop",     .ptr = nativePop },
        .{ .name = "keys",    .ptr = nativeKeys },
        .{ .name = "values",  .ptr = nativeValues },
        .{ .name = "assert",  .ptr = nativeAssert },
        .{ .name = "error",   .ptr = nativeError },
    };
    for (fns) |f| {
        try globals.put(alloc, f.name, .{ .native_fn = f });
    }
    try lib_core.register(alloc, globals);
    try lib_string.register(alloc, globals);
    try lib_array.register(alloc, globals);
    try lib_table.register(alloc, globals);
    try lib_math.register(alloc, globals);
    try lib_io.register(alloc, globals);
    try lib_async.register(alloc, globals);
}

fn writeStr(io: std.Io, s: []const u8) !void {
    // In --listen=- test mode, stdout is the IPC pipe; write to stderr to
    // avoid corrupting the protocol. Production builds use stdout as normal.
    const dest = if (builtin.is_test) std.Io.File.stderr() else std.Io.File.stdout();
    try dest.writeStreamingAll(io, s);
}

fn nativePrint(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    for (args, 0..) |arg, i| {
        if (i > 0) try writeStr(io, " ");
        const s = try arg.format(alloc);
        defer alloc.free(s);
        try writeStr(io, s);
    }
    return .nil;
}

fn nativePrintln(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = try nativePrint(alloc, io, args);
    try writeStr(io, "\n");
    return .nil;
}

fn nativeLen(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .string => |s| .{ .int = @intCast(s.len) },
        .array  => |a| .{ .int = @intCast(a.items.items.len) },
        .table  => |t| .{ .int = @intCast(t.map.count()) },
        else    => error.TypeError,
    };
}

fn nativeType(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .string = args[0].typeName() };
}

fn nativeStr(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .string = try args[0].format(alloc) };
}

fn nativeInt(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .int    => args[0],
        .float  => |f| .{ .int = @intFromFloat(f) },
        .string => |s| .{ .int = std.fmt.parseInt(i64, s, 10) catch return error.ValueError },
        .bool_  => |b| .{ .int = if (b) 1 else 0 },
        else    => error.TypeError,
    };
}

fn nativeFloat(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .float  => args[0],
        .int    => |i| .{ .float = @floatFromInt(i) },
        .string => |s| .{ .float = std.fmt.parseFloat(f64, s) catch return error.ValueError },
        else    => error.TypeError,
    };
}

fn nativePush(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    try arr.items.append(alloc, args[1]);
    return .nil;
}

fn nativePop(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    if (arr.items.items.len == 0) return .nil;
    return arr.items.pop() orelse .nil;
}

fn nativeKeys(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const tbl = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    var it = tbl.map.keyIterator();
    while (it.next()) |k| try arr.items.append(alloc, .{ .string = k.* });
    return .{ .array = arr };
}

fn nativeValues(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const tbl = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    var it = tbl.map.valueIterator();
    while (it.next()) |v| try arr.items.append(alloc, v.*);
    return .{ .array = arr };
}

fn nativeAssert(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len < 1) return error.WrongArgCount;
    if (!args[0].isTruthy()) return error.AssertionFailed;
    return .nil;
}

fn nativeError(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const msg = try args[0].format(alloc);
    std.debug.print("error: {s}\n", .{msg});
    alloc.free(msg);
    return error.RuntimeError;
}
