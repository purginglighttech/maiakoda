const std = @import("std");
const linker_mod = @import("../src/linker.zig");
const codegen_x86 = @import("../src/codegen/x86_64.zig");

fn makeSymbols(allocator: std.mem.Allocator) std.StringHashMap(u32) {
    const m = std.StringHashMap(u32).init(allocator);
    return m;
}

test "ELF magic bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3}, // single ret instruction
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // ELF magic: \x7fELF
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
    try std.testing.expectEqual(@as(u8, 'E'),  elf[1]);
    try std.testing.expectEqual(@as(u8, 'L'),  elf[2]);
    try std.testing.expectEqual(@as(u8, 'F'),  elf[3]);
}

test "ELF class is 64-bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    try std.testing.expectEqual(@as(u8, 2), elf[4]); // ELFCLASS64
    try std.testing.expectEqual(@as(u8, 1), elf[5]); // ELFDATA2LSB
}

test "ELF machine is x86_64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // e_machine at offset 18: 0x3E = 62 = EM_X86_64 (little-endian)
    const machine = @as(u16, elf[18]) | (@as(u16, elf[19]) << 8);
    try std.testing.expectEqual(@as(u16, 62), machine);
}

test "ELF type is executable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // e_type at offset 16: 2 = ET_EXEC
    const e_type = @as(u16, elf[16]) | (@as(u16, elf[17]) << 8);
    try std.testing.expectEqual(@as(u16, 2), e_type);
}

test "ELF entry point is non-zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // e_entry at offset 24 (8 bytes, little-endian)
    var entry: u64 = 0;
    for (0..8) |i| entry |= @as(u64, elf[24 + i]) << @intCast(i * 8);
    try std.testing.expect(entry > 0);
}

test "ELF contains rodata when non-empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    const rodata = "Hello, World!\x00";

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = rodata,
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // The string should appear somewhere in the ELF binary
    const found = std.mem.indexOf(u8, elf, "Hello, World!") != null;
    try std.testing.expect(found);
}

test "missing entry returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    // No symbols at all

    var linker = linker_mod.Linker.init(alloc);
    const result = linker.buildElf(.{
        .text         = &.{0xC3},
        .rodata       = &.{},
        .symbols      = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "nonexistent",
    });
    try std.testing.expectError(error.EntryNotFound, result);
}

test "runtime stub is present in ELF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var symbols = makeSymbols(alloc);
    try symbols.put("main", 0);

    var linker = linker_mod.Linker.init(alloc);
    const elf = try linker.buildElf(.{
        .text       = &.{0xC3},
        .rodata     = &.{},
        .symbols    = &symbols,
        .strings      = &.{},
        .extern_calls = &.{},
        .string_refs  = &.{},
        .entry_name   = "main",
    });
    defer alloc.free(elf);

    // The runtime contains a syscall instruction (0F 05)
    const syscall_bytes = [_]u8{ 0x0F, 0x05 };
    const found = std.mem.indexOf(u8, elf, &syscall_bytes) != null;
    try std.testing.expect(found);
}
