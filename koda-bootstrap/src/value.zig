/// Koda runtime value types.
const std = @import("std");

pub const ValueType = enum {
    nil,
    bool_,
    int,
    float,
    string,
    array,
    table,
    closure,
    native_fn,
    task,
};

pub const Value = union(ValueType) {
    nil,
    bool_: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: *Array,
    table: *Table,
    closure: *Closure,
    native_fn: NativeFn,
    task: *Task,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .bool_ => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    pub fn isEqual(self: Value, other: Value) bool {
        return switch (self) {
            .nil => other == .nil,
            .bool_ => |a| switch (other) { .bool_ => |b| a == b, else => false },
            .int => |a| switch (other) {
                .int => |b| a == b,
                .float => |b| @as(f64, @floatFromInt(a)) == b,
                else => false,
            },
            .float => |a| switch (other) {
                .float => |b| a == b,
                .int => |b| a == @as(f64, @floatFromInt(b)),
                else => false,
            },
            .string => |a| switch (other) { .string => |b| std.mem.eql(u8, a, b), else => false },
            .array => |a| switch (other) { .array => |b| a == b, else => false },
            .table => |a| switch (other) { .table => |b| a == b, else => false },
            .closure => |a| switch (other) { .closure => |b| a == b, else => false },
            .native_fn => |a| switch (other) { .native_fn => |b| a.ptr == b.ptr, else => false },
            .task => |a| switch (other) { .task => |b| a == b, else => false },
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_ => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .array => "array",
            .table => "table",
            .closure => "closure",
            .native_fn => "native_fn",
            .task => "task",
        };
    }

    pub fn format(self: Value, alloc: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .nil => alloc.dupe(u8, "null"),
            .bool_ => |b| alloc.dupe(u8, if (b) "true" else "false"),
            .int => |i| std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
            .string => |s| alloc.dupe(u8, s),
            .array => |a| blk: {
                var buf = std.ArrayListUnmanaged(u8).empty;
                try buf.append(alloc, '[');
                for (a.items.items, 0..) |item, idx| {
                    if (idx > 0) try buf.appendSlice(alloc, ", ");
                    const s = try item.format(alloc);
                    defer alloc.free(s);
                    try buf.appendSlice(alloc, s);
                }
                try buf.append(alloc, ']');
                break :blk try buf.toOwnedSlice(alloc);
            },
            .table => |t| blk: {
                var buf = std.ArrayListUnmanaged(u8).empty;
                try buf.append(alloc, '{');
                var it = t.map.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try buf.appendSlice(alloc, ", ");
                    first = false;
                    try buf.appendSlice(alloc, entry.key_ptr.*);
                    try buf.appendSlice(alloc, " = ");
                    const s = try entry.value_ptr.*.format(alloc);
                    defer alloc.free(s);
                    try buf.appendSlice(alloc, s);
                }
                try buf.append(alloc, '}');
                break :blk try buf.toOwnedSlice(alloc);
            },
            .closure => |c| std.fmt.allocPrint(alloc, "<closure:{s}>", .{c.name}),
            .native_fn => |n| std.fmt.allocPrint(alloc, "<native:{s}>", .{n.name}),
            .task => std.fmt.allocPrint(alloc, "<task>", .{}),
        };
    }
};

pub const Array = struct {
    items: std.ArrayListUnmanaged(Value),

    pub fn init() Array {
        return .{ .items = std.ArrayListUnmanaged(Value).empty };
    }

    pub fn deinit(self: *Array, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }
};

pub const Table = struct {
    map: std.StringHashMapUnmanaged(Value),

    pub fn init() Table {
        return .{ .map = .{} };
    }

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    pub fn get(self: *Table, key: []const u8) ?Value {
        return self.map.get(key);
    }

    pub fn set(self: *Table, alloc: std.mem.Allocator, key: []const u8, val: Value) !void {
        try self.map.put(alloc, key, val);
    }
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    lines: std.ArrayListUnmanaged(u32),

    pub fn init() Chunk {
        return .{ .code = std.ArrayListUnmanaged(u8).empty, .constants = std.ArrayListUnmanaged(Value).empty, .lines = std.ArrayListUnmanaged(u32).empty };
    }

    pub fn deinit(self: *Chunk, alloc: std.mem.Allocator) void {
        self.code.deinit(alloc);
        self.constants.deinit(alloc);
        self.lines.deinit(alloc);
    }

    pub fn write(self: *Chunk, alloc: std.mem.Allocator, byte: u8, line: u32) !void {
        try self.code.append(alloc, byte);
        try self.lines.append(alloc, line);
    }

    pub fn addConstant(self: *Chunk, alloc: std.mem.Allocator, val: Value) !u8 {
        try self.constants.append(alloc, val);
        return @intCast(self.constants.items.len - 1);
    }
};

pub const Upvalue = struct {
    name: []const u8,
    index: u8,
    is_local: bool,
};

pub const FunctionProto = struct {
    name: []const u8,
    arity: u8,
    chunk: Chunk,
    upvalues: std.ArrayListUnmanaged(Upvalue),
    is_async: bool,

    pub fn init(alloc: std.mem.Allocator, name: []const u8, arity: u8, is_async: bool) !*FunctionProto {
        const proto = try alloc.create(FunctionProto);
        proto.* = .{
            .name = name,
            .arity = arity,
            .chunk = Chunk.init(),
            .upvalues = std.ArrayListUnmanaged(Upvalue).empty,
            .is_async = is_async,
        };
        return proto;
    }
};

pub const Closure = struct {
    proto: *FunctionProto,
    upvalue_vals: []Value,
    name: []const u8,
};

pub const NativeFn = struct {
    name: []const u8,
    ptr: *const fn (alloc: std.mem.Allocator, io: std.Io, args: []Value) anyerror!Value,
};

pub const TaskStatus = enum { pending, running, done, failed };

pub const Task = struct {
    closure: *Closure,
    args: []Value,
    result: Value,
    status: TaskStatus,
};
