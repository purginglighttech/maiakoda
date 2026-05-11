/// Koda stack-based bytecode interpreter.
const std = @import("std");
const value = @import("value");
const bc = @import("bytecode");
const runtime = @import("runtime");

pub const VmError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    UndefinedVariable,
    DivisionByZero,
    IndexOutOfBounds,
    KeyNotFound,
    WrongArgCount,
    CallNonCallable,
    AssertionFailed,
    RuntimeError,
    OutOfMemory,
    NotImplemented,
    ValueError,
};

const STACK_MAX = 4096;
const FRAMES_MAX = 256;

const IterFrame = struct {
    base_slot: u32,
    kind: union(enum) {
        range: struct { current: i64, end: i64 },
        array: struct { arr: *value.Array, idx: u32 },
    },
};

const CallFrame = struct {
    closure: *value.Closure,
    ip: usize,
    base: u32,
};

pub const Vm = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    stack: [STACK_MAX]value.Value,
    stack_top: u32,
    frames: [FRAMES_MAX]CallFrame,
    frame_count: u32,
    globals: std.StringHashMapUnmanaged(value.Value),
    iter_stack: std.ArrayListUnmanaged(IterFrame),

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Vm {
        var vm = Vm{
            .alloc = alloc,
            .io = io,
            .stack = undefined,
            .stack_top = 0,
            .frames = undefined,
            .frame_count = 0,
            .globals = .{},
            .iter_stack = std.ArrayListUnmanaged(IterFrame).empty,
        };
        try runtime.registerAll(alloc, &vm.globals);
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.globals.deinit(self.alloc);
        self.iter_stack.deinit(self.alloc);
    }

    pub fn interpret(self: *Vm, proto: *value.FunctionProto) VmError!value.Value {
        const closure = self.alloc.create(value.Closure) catch return error.OutOfMemory;
        closure.* = .{ .proto = proto, .upvalue_vals = &.{}, .name = proto.name };
        // Reset stack for a fresh script execution
        self.stack_top = 0;
        // Push closure as slot 0 (implicit "self" for the script frame)
        try self.push(.{ .closure = closure });
        // Push frame
        self.frames[self.frame_count] = .{ .closure = closure, .ip = 0, .base = 0 };
        self.frame_count += 1;
        return self.run();
    }

    fn push(self: *Vm, val: value.Value) VmError!void {
        if (self.stack_top >= STACK_MAX) return error.StackOverflow;
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    fn pop(self: *Vm) VmError!value.Value {
        if (self.stack_top == 0) return error.StackUnderflow;
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    fn peek(self: *Vm, dist: u32) value.Value {
        return self.stack[self.stack_top - 1 - dist];
    }

    fn callValue(self: *Vm, callee: value.Value, arg_count: u8) VmError!value.Value {
        return switch (callee) {
            .closure => |c| {
                if (c.proto.arity != arg_count) return error.WrongArgCount;
                if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;
                // stack: [..., closure, arg0, arg1, ...]
                // base points to the closure (slot 0 of new frame)
                const base: u32 = self.stack_top - arg_count - 1;
                self.frames[self.frame_count] = .{ .closure = c, .ip = 0, .base = base };
                self.frame_count += 1;
                return self.run();
            },
            .native_fn => |nf| {
                const args = self.stack[self.stack_top - arg_count .. self.stack_top];
                const result = nf.ptr(self.alloc, self.io, args) catch |err| return vmError(err);
                self.stack_top -= arg_count + 1;
                return result;
            },
            else => error.CallNonCallable,
        };
    }

    fn run(self: *Vm) VmError!value.Value {
        // Save the frame depth we entered at — return when we drop back to it
        const entry_depth = self.frame_count;

        while (self.frame_count >= entry_depth) {
            const frame = &self.frames[self.frame_count - 1];
            const chunk = &frame.closure.proto.chunk;
            const code = chunk.code.items;

            if (frame.ip >= code.len) {
                // Implicit return nil
                self.frame_count -= 1;
                if (self.frame_count < entry_depth) return .nil;
                self.stack_top = self.frames[self.frame_count].base;
                try self.push(.nil);
                continue;
            }

            const instruction = code[frame.ip];
            frame.ip += 1;

            const op: bc.Op = @enumFromInt(instruction);
            switch (op) {
                .constant => {
                    const idx = code[frame.ip]; frame.ip += 1;
                    try self.push(chunk.constants.items[idx]);
                },
                .nil    => try self.push(.nil),
                .true_  => try self.push(.{ .bool_ = true }),
                .false_ => try self.push(.{ .bool_ = false }),
                .pop    => _ = try self.pop(),

                .add => try self.binaryOp(.add),
                .sub => try self.binaryOp(.sub),
                .mul => try self.binaryOp(.mul),
                .div => try self.binaryOp(.div),
                .mod => try self.binaryOp(.mod),
                .eq  => try self.binaryOp(.eq),
                .ne  => try self.binaryOp(.ne),
                .lt  => try self.binaryOp(.lt),
                .gt  => try self.binaryOp(.gt),
                .le  => try self.binaryOp(.le),
                .ge  => try self.binaryOp(.ge),

                .and_ => {
                    const b = try self.pop(); const a = try self.pop();
                    try self.push(.{ .bool_ = a.isTruthy() and b.isTruthy() });
                },
                .or_ => {
                    const b = try self.pop(); const a = try self.pop();
                    try self.push(.{ .bool_ = a.isTruthy() or b.isTruthy() });
                },
                .not_ => { const v = try self.pop(); try self.push(.{ .bool_ = !v.isTruthy() }); },
                .neg  => {
                    const v = try self.pop();
                    try self.push(switch (v) {
                        .int   => |i| .{ .int = -i },
                        .float => |f| .{ .float = -f },
                        else   => return error.TypeError,
                    });
                },

                .get_global => {
                    const idx = code[frame.ip]; frame.ip += 1;
                    const name = chunk.constants.items[idx].string;
                    const v = self.globals.get(name) orelse return error.UndefinedVariable;
                    try self.push(v);
                },
                .set_global => {
                    const idx = code[frame.ip]; frame.ip += 1;
                    const name = chunk.constants.items[idx].string;
                    const v = try self.pop();
                    self.globals.put(self.alloc, name, v) catch return error.OutOfMemory;
                },
                .get_local => {
                    const slot = code[frame.ip]; frame.ip += 1;
                    try self.push(self.stack[frame.base + slot]);
                },
                .set_local => {
                    const slot = code[frame.ip]; frame.ip += 1;
                    self.stack[frame.base + slot] = try self.pop();
                },
                .get_upvalue => {
                    const idx = code[frame.ip]; frame.ip += 1;
                    try self.push(frame.closure.upvalue_vals[idx]);
                },
                .set_upvalue => {
                    const idx = code[frame.ip]; frame.ip += 1;
                    frame.closure.upvalue_vals[idx] = try self.pop();
                },

                .jump => {
                    const hi = code[frame.ip]; frame.ip += 1;
                    const lo = code[frame.ip]; frame.ip += 1;
                    frame.ip += (@as(usize, hi) << 8) | lo;
                },
                .jump_if_false => {
                    const hi = code[frame.ip]; frame.ip += 1;
                    const lo = code[frame.ip]; frame.ip += 1;
                    const offset = (@as(usize, hi) << 8) | lo;
                    if (!self.peek(0).isTruthy()) frame.ip += offset;
                },
                .loop => {
                    const hi = code[frame.ip]; frame.ip += 1;
                    const lo = code[frame.ip]; frame.ip += 1;
                    frame.ip -= (@as(usize, hi) << 8) | lo;
                },

                .call => {
                    const arg_count = code[frame.ip]; frame.ip += 1;
                    const callee = self.peek(arg_count);
                    switch (callee) {
                        .closure => |c| {
                            if (c.proto.arity != arg_count) return error.WrongArgCount;
                            if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;
                            const base: u32 = self.stack_top - arg_count - 1;
                            self.frames[self.frame_count] = .{ .closure = c, .ip = 0, .base = base };
                            self.frame_count += 1;
                            // Continue in new frame — the while loop will pick it up
                        },
                        .native_fn => |nf| {
                            const args = self.stack[self.stack_top - arg_count .. self.stack_top];
                            const result = nf.ptr(self.alloc, self.io, args) catch |err| return vmError(err);
                            self.stack_top -= arg_count + 1;
                            try self.push(result);
                        },
                        else => return error.CallNonCallable,
                    }
                },

                .return_ => {
                    const result = try self.pop();
                    const returning_base = frame.base;
                    self.frame_count -= 1;
                    self.stack_top = returning_base;
                    try self.push(result);
                    if (self.frame_count < entry_depth) return result;
                },

                .closure => {
                    const proto_idx = code[frame.ip]; frame.ip += 1;
                    const proto_val = chunk.constants.items[proto_idx];
                    const template = proto_val.closure;
                    const uv_count = template.proto.upvalues.items.len;
                    const uv_vals = self.alloc.alloc(value.Value, uv_count) catch return error.OutOfMemory;
                    for (0..uv_count) |i| {
                        const is_local = code[frame.ip] != 0; frame.ip += 1;
                        const idx2 = code[frame.ip]; frame.ip += 1;
                        uv_vals[i] = if (is_local)
                            self.stack[frame.base + idx2]
                        else
                            frame.closure.upvalue_vals[idx2];
                    }
                    const new_closure = self.alloc.create(value.Closure) catch return error.OutOfMemory;
                    new_closure.* = .{ .proto = template.proto, .upvalue_vals = uv_vals, .name = template.name };
                    try self.push(.{ .closure = new_closure });
                },

                .await_ => {
                    const v = try self.pop();
                    switch (v) {
                        .task => |t| try self.push(t.result),
                        else  => try self.push(v),
                    }
                },
                .spawn => {
                    const arg_count = code[frame.ip]; frame.ip += 1;
                    const callee_val = self.peek(arg_count);
                    switch (callee_val) {
                        .closure => |c| {
                            // Run synchronously. callValue uses the stack already set up (closure + args).
                            // After it returns, stack is cleaned up with result on top.
                            const result = try self.callValue(.{ .closure = c }, arg_count);
                            // stack_top already points past the closure+args (cleaned by return_)
                            // result is already on the stack; we need to replace it with a task
                            _ = try self.pop(); // pop the result that return_ pushed
                            const task = self.alloc.create(value.Task) catch return error.OutOfMemory;
                            task.* = .{ .closure = c, .args = &.{}, .result = result, .status = .done };
                            try self.push(.{ .task = task });
                        },
                        else => return error.CallNonCallable,
                    }
                },

                .pipe => {
                    const rhs = try self.pop();
                    const lhs = try self.pop();
                    switch (rhs) {
                        .closure => |c| {
                            // push closure, push arg, call
                            try self.push(.{ .closure = c });
                            try self.push(lhs);
                            if (c.proto.arity != 1) return error.WrongArgCount;
                            if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;
                            const base: u32 = self.stack_top - 2;
                            self.frames[self.frame_count] = .{ .closure = c, .ip = 0, .base = base };
                            self.frame_count += 1;
                        },
                        .native_fn => |nf| {
                            var args = [_]value.Value{lhs};
                            const result = nf.ptr(self.alloc, self.io, &args) catch |err| return vmError(err);
                            try self.push(result);
                        },
                        else => return error.CallNonCallable,
                    }
                },

                .create_table => {
                    const tbl = self.alloc.create(value.Table) catch return error.OutOfMemory;
                    tbl.* = value.Table.init();
                    try self.push(.{ .table = tbl });
                },
                .table_get => {
                    const key_idx = code[frame.ip]; frame.ip += 1;
                    const key = chunk.constants.items[key_idx].string;
                    const tbl_val = try self.pop();
                    const tbl = switch (tbl_val) { .table => |t| t, else => return error.TypeError };
                    try self.push(tbl.get(key) orelse .nil);
                },
                .table_set => {
                    const key_idx = code[frame.ip]; frame.ip += 1;
                    const key = chunk.constants.items[key_idx].string;
                    const val2 = try self.pop();
                    const tbl_val = self.peek(0);
                    const tbl = switch (tbl_val) { .table => |t| t, else => return error.TypeError };
                    tbl.set(self.alloc, key, val2) catch return error.OutOfMemory;
                },

                .create_array => {
                    _ = code[frame.ip]; frame.ip += 1;
                    const arr = self.alloc.create(value.Array) catch return error.OutOfMemory;
                    arr.* = value.Array.init();
                    try self.push(.{ .array = arr });
                },
                .array_get => {
                    const key_val = try self.pop();
                    const obj_val = try self.pop();
                    switch (obj_val) {
                        .array => |arr| {
                            const idx = switch (key_val) { .int => |i| i, else => return error.TypeError };
                            const i: usize = if (idx < 0) @intCast(@as(i64, @intCast(arr.items.items.len)) + idx) else @intCast(idx);
                            if (i >= arr.items.items.len) return error.IndexOutOfBounds;
                            try self.push(arr.items.items[i]);
                        },
                        .string => |s| {
                            const idx = switch (key_val) { .int => |i| i, else => return error.TypeError };
                            const i: usize = if (idx < 0) @intCast(@as(i64, @intCast(s.len)) + idx) else @intCast(idx);
                            if (i >= s.len) return error.IndexOutOfBounds;
                            try self.push(.{ .int = s[i] });
                        },
                        .table => |tbl| {
                            const key_s = switch (key_val) { .string => |s| s, else => return error.TypeError };
                            try self.push(tbl.get(key_s) orelse .nil);
                        },
                        else => return error.TypeError,
                    }
                },
                .array_set => {
                    const key_val = try self.pop();
                    const obj_val = try self.pop();
                    const new_val = try self.pop();
                    switch (obj_val) {
                        .array => |arr| {
                            const idx = switch (key_val) { .int => |i| i, else => return error.TypeError };
                            const i: usize = if (idx < 0) @intCast(@as(i64, @intCast(arr.items.items.len)) + idx) else @intCast(idx);
                            if (i >= arr.items.items.len) return error.IndexOutOfBounds;
                            arr.items.items[i] = new_val;
                        },
                        .table => |tbl| {
                            const key_s = switch (key_val) { .string => |s| s, else => return error.TypeError };
                            tbl.set(self.alloc, key_s, new_val) catch return error.OutOfMemory;
                        },
                        else => return error.TypeError,
                    }
                },
                .array_append => {
                    const val2 = try self.pop();
                    const arr_val = self.peek(0);
                    const arr = switch (arr_val) { .array => |a| a, else => return error.TypeError };
                    arr.items.append(self.alloc, val2) catch return error.OutOfMemory;
                },

                .make_range => {
                    const end_val = try self.pop();
                    const start_val = try self.pop();
                    const s2 = switch (start_val) { .int => |i| i, else => return error.TypeError };
                    const e = switch (end_val) { .int => |i| i, else => return error.TypeError };
                    // Range stored as array: [start, end, current_value]
                    const arr = self.alloc.create(value.Array) catch return error.OutOfMemory;
                    arr.* = value.Array.init();
                    arr.items.append(self.alloc, .{ .int = s2 }) catch return error.OutOfMemory;
                    arr.items.append(self.alloc, .{ .int = e }) catch return error.OutOfMemory;
                    arr.items.append(self.alloc, .{ .int = s2 }) catch return error.OutOfMemory;
                    try self.push(.{ .array = arr });
                },

                .iter_next => {
                    const hi = code[frame.ip]; frame.ip += 1;
                    const lo = code[frame.ip]; frame.ip += 1;
                    const exit_offset = (@as(usize, hi) << 8) | lo;
                    const iter_val = self.peek(0);
                    switch (iter_val) {
                        .array => |arr| {
                            if (arr.items.items.len == 3) {
                                // Range: [start, end, current]
                                const end2 = arr.items.items[1].int;
                                const cur = arr.items.items[2].int;
                                if (cur >= end2) {
                                    frame.ip += exit_offset;
                                } else {
                                    arr.items.items[2] = .{ .int = cur + 1 };
                                    try self.push(.{ .int = cur });
                                }
                            } else {
                                return error.NotImplemented;
                            }
                        },
                        else => return error.TypeError,
                    }
                },
            }
        }
        return .nil;
    }

    fn binaryOp(self: *Vm, op: bc.Op) VmError!void {
        const b = try self.pop();
        const a = try self.pop();
        switch (op) {
            .add => try self.push(try numericBinop(a, b, op, self.alloc)),
            .sub, .mul, .div, .mod => try self.push(try numericBinop(a, b, op, self.alloc)),
            .eq  => try self.push(.{ .bool_ = a.isEqual(b) }),
            .ne  => try self.push(.{ .bool_ = !a.isEqual(b) }),
            .lt  => try self.push(.{ .bool_ = try numericCmp(a, b, .lt) }),
            .gt  => try self.push(.{ .bool_ = try numericCmp(a, b, .gt) }),
            .le  => try self.push(.{ .bool_ = try numericCmp(a, b, .le) }),
            .ge  => try self.push(.{ .bool_ = try numericCmp(a, b, .ge) }),
            else => unreachable,
        }
    }

    fn vmError(err: anyerror) VmError {
        return switch (err) {
            error.TypeError       => error.TypeError,
            error.WrongArgCount   => error.WrongArgCount,
            error.AssertionFailed => error.AssertionFailed,
            error.OutOfMemory     => error.OutOfMemory,
            error.ValueError      => error.ValueError,
            else                  => error.RuntimeError,
        };
    }
};

fn numericBinop(a: value.Value, b: value.Value, op: bc.Op, alloc: std.mem.Allocator) VmError!value.Value {
    if (op == .add) {
        if (a == .string and b == .string) {
            const s = std.mem.concat(alloc, u8, &.{ a.string, b.string }) catch return error.OutOfMemory;
            return .{ .string = s };
        }
    }
    switch (a) {
        .int => |ai| switch (b) {
            .int   => |bi| return switch (op) {
                .add => .{ .int = ai + bi },
                .sub => .{ .int = ai - bi },
                .mul => .{ .int = ai * bi },
                .div => if (bi == 0) error.DivisionByZero else .{ .int = @divTrunc(ai, bi) },
                .mod => if (bi == 0) error.DivisionByZero else .{ .int = @rem(ai, bi) },
                else => unreachable,
            },
            .float => |bf| return floatOp(@floatFromInt(ai), bf, op),
            else   => return error.TypeError,
        },
        .float => |af| switch (b) {
            .float => |bf| return floatOp(af, bf, op),
            .int   => |bi| return floatOp(af, @floatFromInt(bi), op),
            else   => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

fn floatOp(a: f64, b: f64, op: bc.Op) VmError!value.Value {
    return switch (op) {
        .add => .{ .float = a + b },
        .sub => .{ .float = a - b },
        .mul => .{ .float = a * b },
        .div => if (b == 0.0) error.DivisionByZero else .{ .float = a / b },
        .mod => .{ .float = @mod(a, b) },
        else => unreachable,
    };
}

fn numericCmp(a: value.Value, b: value.Value, op: bc.Op) VmError!bool {
    const af: f64 = switch (a) {
        .int   => |i| @floatFromInt(i),
        .float => |f| f,
        else   => return error.TypeError,
    };
    const bf: f64 = switch (b) {
        .int   => |i| @floatFromInt(i),
        .float => |f| f,
        else   => return error.TypeError,
    };
    return switch (op) {
        .lt => af < bf,
        .gt => af > bf,
        .le => af <= bf,
        .ge => af >= bf,
        else => unreachable,
    };
}
