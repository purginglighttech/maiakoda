const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "has_key",    .ptr = nativeHasKey },
        .{ .name = "delete_key", .ptr = nativeDeleteKey },
        .{ .name = "entries",    .ptr = nativeEntries },
        .{ .name = "merge",      .ptr = nativeMerge },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

fn nativeHasKey(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const tbl = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const key = switch (args[1]) { .string => |s| s, else => return error.TypeError };
    return .{ .bool_ = tbl.map.contains(key) };
}

fn nativeDeleteKey(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const tbl = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const key = switch (args[1]) { .string => |s| s, else => return error.TypeError };
    _ = tbl.map.remove(key);
    _ = alloc;
    return .nil;
}

fn nativeEntries(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const tbl = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const result = try alloc.create(value.Array);
    result.* = value.Array.init();
    var it = tbl.map.iterator();
    while (it.next()) |entry| {
        const pair = try alloc.create(value.Array);
        pair.* = value.Array.init();
        try pair.items.append(alloc, .{ .string = entry.key_ptr.* });
        try pair.items.append(alloc, entry.value_ptr.*);
        try result.items.append(alloc, .{ .array = pair });
    }
    return .{ .array = result };
}

fn nativeMerge(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const t1 = switch (args[0]) { .table => |t| t, else => return error.TypeError };
    const t2 = switch (args[1]) { .table => |t| t, else => return error.TypeError };
    const tbl = try alloc.create(value.Table);
    tbl.* = value.Table.init();
    var it1 = t1.map.iterator();
    while (it1.next()) |e| try tbl.map.put(alloc, e.key_ptr.*, e.value_ptr.*);
    var it2 = t2.map.iterator();
    while (it2.next()) |e| try tbl.map.put(alloc, e.key_ptr.*, e.value_ptr.*);
    return .{ .table = tbl };
}
