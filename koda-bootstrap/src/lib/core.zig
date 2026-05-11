const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "is_nil",      .ptr = nativeIsNil },
        .{ .name = "is_int",      .ptr = nativeIsInt },
        .{ .name = "is_float",    .ptr = nativeIsFloat },
        .{ .name = "is_string",   .ptr = nativeIsString },
        .{ .name = "is_array",    .ptr = nativeIsArray },
        .{ .name = "is_table",    .ptr = nativeIsTable },
        .{ .name = "is_function", .ptr = nativeIsFunction },
        .{ .name = "is_bool",     .ptr = nativeIsBool },
        .{ .name = "to_bool",     .ptr = nativeToBool },
        .{ .name = "panic",       .ptr = nativePanic },
        .{ .name = "todo",        .ptr = nativeTodo },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

fn nativeIsNil(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .nil };
}

fn nativeIsInt(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .int };
}

fn nativeIsFloat(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .float };
}

fn nativeIsString(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .string };
}

fn nativeIsArray(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .array };
}

fn nativeIsTable(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .table };
}

fn nativeIsFunction(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .closure or args[0] == .native_fn };
}

fn nativeIsBool(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0] == .bool_ };
}

fn nativeToBool(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    return .{ .bool_ = args[0].isTruthy() };
}

fn nativePanic(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len < 1) return error.WrongArgCount;
    const msg = try args[0].format(alloc);
    std.debug.print("panic: {s}\n", .{msg});
    alloc.free(msg);
    return error.RuntimeError;
}

fn nativeTodo(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io; _ = args;
    std.debug.print("todo: not yet implemented\n", .{});
    return error.RuntimeError;
}
