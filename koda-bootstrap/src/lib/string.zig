const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "split",        .ptr = nativeSplit },
        .{ .name = "join",         .ptr = nativeJoin },
        .{ .name = "trim",         .ptr = nativeTrim },
        .{ .name = "trim_left",    .ptr = nativeTrimLeft },
        .{ .name = "trim_right",   .ptr = nativeTrimRight },
        .{ .name = "starts_with",  .ptr = nativeStartsWith },
        .{ .name = "ends_with",    .ptr = nativeEndsWith },
        .{ .name = "contains_str", .ptr = nativeContainsStr },
        .{ .name = "to_upper",     .ptr = nativeToUpper },
        .{ .name = "to_lower",     .ptr = nativeToLower },
        .{ .name = "replace_str",  .ptr = nativeReplaceStr },
        .{ .name = "char_at",      .ptr = nativeCharAt },
        .{ .name = "bytes",        .ptr = nativeBytes },
        .{ .name = "repeat_str",   .ptr = nativeRepeatStr },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

fn nativeSplit(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s   = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const sep = switch (args[1]) { .string => |v| v, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    if (sep.len == 0) {
        for (s) |c| {
            const part = try alloc.dupe(u8, &[_]u8{c});
            try arr.items.append(alloc, .{ .string = part });
        }
    } else {
        var it = std.mem.splitSequence(u8, s, sep);
        while (it.next()) |part| {
            const dup = try alloc.dupe(u8, part);
            try arr.items.append(alloc, .{ .string = dup });
        }
    }
    return .{ .array = arr };
}

fn nativeJoin(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const arr = switch (args[0]) { .array => |a| a, else => return error.TypeError };
    const sep = switch (args[1]) { .string => |s| s, else => return error.TypeError };
    var buf = std.ArrayListUnmanaged(u8).empty;
    for (arr.items.items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(alloc, sep);
        const s = try item.format(alloc);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }
    return .{ .string = try buf.toOwnedSlice(alloc) };
}

fn nativeTrim(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    return .{ .string = std.mem.trim(u8, s, " \t\r\n") };
}

fn nativeTrimLeft(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    return .{ .string = std.mem.trimStart(u8, s, " \t\r\n") };
}

fn nativeTrimRight(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    return .{ .string = std.mem.trimEnd(u8, s, " \t\r\n") };
}

fn nativeStartsWith(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s      = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const prefix = switch (args[1]) { .string => |v| v, else => return error.TypeError };
    return .{ .bool_ = std.mem.startsWith(u8, s, prefix) };
}

fn nativeEndsWith(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s      = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const suffix = switch (args[1]) { .string => |v| v, else => return error.TypeError };
    return .{ .bool_ = std.mem.endsWith(u8, s, suffix) };
}

fn nativeContainsStr(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc; _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s   = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const sub = switch (args[1]) { .string => |v| v, else => return error.TypeError };
    return .{ .bool_ = std.mem.containsAtLeast(u8, s, 1, sub) };
}

fn nativeToUpper(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const buf = try alloc.dupe(u8, s);
    for (buf) |*c| c.* = std.ascii.toUpper(c.*);
    return .{ .string = buf };
}

fn nativeToLower(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const buf = try alloc.dupe(u8, s);
    for (buf) |*c| c.* = std.ascii.toLower(c.*);
    return .{ .string = buf };
}

fn nativeReplaceStr(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 3) return error.WrongArgCount;
    const s    = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const from = switch (args[1]) { .string => |v| v, else => return error.TypeError };
    const to   = switch (args[2]) { .string => |v| v, else => return error.TypeError };
    const result = try std.mem.replaceOwned(u8, alloc, s, from, to);
    return .{ .string = result };
}

fn nativeCharAt(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s   = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const idx = switch (args[1]) { .int => |i| i,    else => return error.TypeError };
    const i: usize = if (idx < 0) @intCast(@as(i64, @intCast(s.len)) + idx) else @intCast(idx);
    if (i >= s.len) return error.IndexOutOfBounds;
    const ch = try alloc.dupe(u8, &[_]u8{s[i]});
    return .{ .string = ch };
}

fn nativeBytes(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 1) return error.WrongArgCount;
    const s = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const arr = try alloc.create(value.Array);
    arr.* = value.Array.init();
    for (s) |c| try arr.items.append(alloc, .{ .int = c });
    return .{ .array = arr };
}

fn nativeRepeatStr(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = io;
    if (args.len != 2) return error.WrongArgCount;
    const s   = switch (args[0]) { .string => |v| v, else => return error.TypeError };
    const n   = switch (args[1]) { .int => |i| i,    else => return error.TypeError };
    if (n <= 0) return .{ .string = "" };
    var buf = std.ArrayListUnmanaged(u8).empty;
    var i: i64 = 0;
    while (i < n) : (i += 1) try buf.appendSlice(alloc, s);
    return .{ .string = try buf.toOwnedSlice(alloc) };
}
