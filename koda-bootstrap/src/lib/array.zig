const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "contains",    .ptr = nativeContains },
        .{ .name = "reverse",     .ptr = nativeReverse },
        .{ .name = "concat",      .ptr = nativeConcat },
        .{ .name = "arr_slice",   .ptr = nativeSlice },
        .{ .name = "index_of",    .ptr = nativeIndexOf },
        .{ .name = "flatten",     .ptr = nativeFlatten },
        .{ .name = "arr_sort",    .ptr = nativeSort },
        .{ .name = "unique",      .ptr = nativeUnique },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

fn nativeContains(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    for (arr.items.items) |item| {
        if (item.isEqual(args[1])) return .{ .bool_ = true };
    }
    return .{ .bool_ = false };
}

fn nativeReverse(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const src = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    var i = src.items.items.len;
    while (i > 0) {
        i -= 1;
        try arr.items.append(alloc, src.items.items[i]);
    }
    return .{ .array = arr };
}

fn nativeConcat(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const a = switch (args[0]) { .array => |v| v, else => return error.TypeError };
    const b = switch (args[1]) { .array => |v| v, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    for (a.items.items) |item| try arr.items.append(alloc, item);
    for (b.items.items) |item| try arr.items.append(alloc, item);
    return .{ .array = arr };
}

fn nativeSlice(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 3) return error.WrongArgCount;
    const src   = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    const start = switch (args[1]) { .int => |i| i,   else => return error.TypeError };
    const end   = switch (args[2]) { .int => |i| i,   else => return error.TypeError };
    const len: i64 = @intCast(src.items.items.len);
    const s: usize = @intCast(@max(0, if (start < 0) len + start else start));
    const e: usize = @intCast(@min(len, if (end < 0) len + end else end));
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    if (s < e) {
        for (src.items.items[s..e]) |item| try arr.items.append(alloc, item);
    }
    return .{ .array = arr };
}

fn nativeIndexOf(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    for (arr.items.items, 0..) |item, i| {
        if (item.isEqual(args[1])) return .{ .int = @intCast(i) };
    }
    return .{ .int = -1 };
}

fn nativeFlatten(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const src = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    for (src.items.items) |item| {
        switch (item) {
            .array => |inner| for (inner.items.items) |v| try arr.items.append(alloc, v),
            else => try arr.items.append(alloc, item),
        }
    }
    return .{ .array = arr };
}

fn nativeSort(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    std.mem.sort(value.Value, arr.items.items, {}, struct {
        fn lessThan(_: void, a: value.Value, b: value.Value) bool {
            return switch (a) {
                .int   => |ai| switch (b) { .int => |bi| ai < bi, .float => |bf| @as(f64, @floatFromInt(ai)) < bf, else => true },
                .float => |af| switch (b) { .float => |bf| af < bf, .int => |bi| af < @as(f64, @floatFromInt(bi)), else => true },
                .string => |as2| switch (b) { .string => |bs| std.mem.lessThan(u8, as2, bs), else => false },
                else   => false,
            };
        }
    }.lessThan);
    _ = alloc;
    return .nil;
}

fn nativeUnique(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const src = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    for (src.items.items) |item| {
        var found = false;
        for (arr.items.items) |existing| {
            if (existing.isEqual(item)) { found = true; break; }
        }
        if (!found) try arr.items.append(alloc, item);
    }
    return .{ .array = arr };
}
