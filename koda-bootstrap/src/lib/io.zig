const std = @import("std");
const value = @import("value");

pub fn register(alloc: std.mem.Allocator, globals: *std.StringHashMapUnmanaged(value.Value)) !void {
    const fns = [_]value.NativeFn{
        .{ .name = "read_line",   .ptr = nativeReadLine },
        .{ .name = "read_file",   .ptr = nativeReadFile },
        .{ .name = "write_file",  .ptr = nativeWriteFile },
        .{ .name = "append_file", .ptr = nativeAppendFile },
        .{ .name = "file_exists", .ptr = nativeFileExists },
    };
    for (fns) |f| try globals.put(alloc, f.name, .{ .native_fn = f });
}

fn nativeReadLine(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = args;
    const stdin = std.Io.File.stdin();
    var buf = std.ArrayListUnmanaged(u8).empty;
    while (true) {
        var ch = [_]u8{0};
        const vecs = [_][]u8{&ch};
        const got = try stdin.readStreaming(io, &vecs);
        if (got == 0 or ch[0] == '\n') break;
        if (ch[0] != '\r') try buf.append(alloc, ch[0]);
    }
    return .{ .string = try buf.toOwnedSlice(alloc) };
}

fn nativeReadFile(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    if (args.len != 1) return error.WrongArgCount;
    const path = switch (args[0]) { .string => |s| s, else => return error.TypeError };
    const content = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .unlimited) catch return error.RuntimeError;
    return .{ .string = content };
}

fn nativeWriteFile(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    if (args.len != 2) return error.WrongArgCount;
    const path    = switch (args[0]) { .string => |s| s, else => return error.TypeError };
    const content = switch (args[1]) { .string => |s| s, else => return error.TypeError };
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = content }) catch return error.RuntimeError;
    _ = alloc;
    return .nil;
}

fn nativeAppendFile(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    if (args.len != 2) return error.WrongArgCount;
    const path    = switch (args[0]) { .string => |s| s, else => return error.TypeError };
    const content = switch (args[1]) { .string => |s| s, else => return error.TypeError };
    const cwd = std.Io.Dir.cwd();
    // Open without truncating (creates if needed, appends otherwise)
    const file = std.Io.Dir.createFile(cwd, io, path, .{ .truncate = false }) catch return error.RuntimeError;
    defer file.close(io);
    const s = file.stat(io) catch return error.RuntimeError;
    file.writePositionalAll(io, content, s.size) catch return error.RuntimeError;
    _ = alloc;
    return .nil;
}

fn nativeFileExists(alloc: std.mem.Allocator, io: std.Io, args: []value.Value) anyerror!value.Value {
    _ = alloc;
    if (args.len != 1) return error.WrongArgCount;
    const path = switch (args[0]) { .string => |s| s, else => return error.TypeError };
    std.Io.Dir.access(std.Io.Dir.cwd(), io, path, .{}) catch return .{ .bool_ = false };
    return .{ .bool_ = true };
}
