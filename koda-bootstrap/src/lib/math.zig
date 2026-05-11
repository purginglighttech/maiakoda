const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "floor",   .ptr = nativeFloor },
        .{ .name = "ceil",    .ptr = nativeCeil },
        .{ .name = "round",   .ptr = nativeRound },
        .{ .name = "sqrt",    .ptr = nativeSqrt },
        .{ .name = "abs",     .ptr = nativeAbs },
        .{ .name = "min",     .ptr = nativeMin },
        .{ .name = "max",     .ptr = nativeMax },
        .{ .name = "pow",     .ptr = nativePow },
        .{ .name = "log",     .ptr = nativeLog },
        .{ .name = "sin",     .ptr = nativeSin },
        .{ .name = "cos",     .ptr = nativeCos },
        .{ .name = "tan",     .ptr = nativeTan },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
    try globals.put(alloc, "PI", .{ .float = std.math.pi });
}

fn toFloat(v: value.Value) !f64 {
    return switch (v) {
        .int   => |i| @floatFromInt(i),
        .float => |f| f,
        else   => error.TypeError,
    };
}

fn nativeFloor(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @floor(try toFloat(args[0])) };
}

fn nativeCeil(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @ceil(try toFloat(args[0])) };
}

fn nativeRound(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @round(try toFloat(args[0])) };
}

fn nativeSqrt(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @sqrt(try toFloat(args[0])) };
}

fn nativeAbs(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return switch (args[0]) {
        .int   => |i| .{ .int   = if (i < 0) -i else i },
        .float => |f| .{ .float = @abs(f) },
        else   => error.TypeError,
    };
}

fn nativeMin(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const a = try toFloat(args[0]);
    const b = try toFloat(args[1]);
    const result = if (a < b) a else b;
    // preserve int type when both inputs are ints
    if (args[0] == .int and args[1] == .int)
        return .{ .int = if (args[0].int < args[1].int) args[0].int else args[1].int };
    return .{ .float = result };
}

fn nativeMax(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const a = try toFloat(args[0]);
    const b = try toFloat(args[1]);
    const result = if (a > b) a else b;
    if (args[0] == .int and args[1] == .int)
        return .{ .int = if (args[0].int > args[1].int) args[0].int else args[1].int };
    return .{ .float = result };
}

fn nativePow(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    return .{ .float = std.math.pow(f64, try toFloat(args[0]), try toFloat(args[1])) };
}

fn nativeLog(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @log(try toFloat(args[0])) };
}

fn nativeSin(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @sin(try toFloat(args[0])) };
}

fn nativeCos(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @cos(try toFloat(args[0])) };
}

fn nativeTan(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .float = @tan(try toFloat(args[0])) };
}
