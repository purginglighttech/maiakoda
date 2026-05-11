/// Maia bootstrap linker.
/// Produces a statically-linked ELF64 executable for Linux x86_64.
///
/// Layout (all sections contiguous in one PT_LOAD segment):
///   ELF header (64 bytes)
///   Program header table
///   .text  (code)
///   .rodata (read-only data: strings)
///   .data  (mutable globals — empty for bootstrap)
///   .bss   (zero-initialized — empty for bootstrap)
///
/// The binary calls a built-in `writeln` implementation that uses the
/// Linux write(2) syscall directly (no libc dependency).

const std = @import("std");
const codegen = @import("codegen/x86_64");

// ── ELF64 constants ───────────────────────────────────────────────────────────

const ELF_MAGIC: u32 = 0x464C457F; // \x7fELF
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1; // little-endian
const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;
const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;
const SHT_NULL: u32 = 0;
const SHT_PROGBITS: u32 = 1;
const SHT_STRTAB: u32 = 3;
const SHF_ALLOC: u64 = 2;
const SHF_EXECINSTR: u64 = 4;
const SHF_WRITE: u64 = 1;

/// Default virtual load address for text segment
const LOAD_ADDR: u64 = 0x400000;
/// Page size
const PAGE_SIZE: u64 = 0x1000;

// ── Linker ────────────────────────────────────────────────────────────────────

pub const LinkerError = error{
    EntryNotFound,
    OutOfMemory,
    WriteError,
};

pub const LinkerInput = struct {
    text: []const u8,
    rodata: []const u8,
    symbols: *const std.StringHashMap(u32),
    strings: []const codegen.StringEntry,
    extern_calls: []const codegen.ExternCallSite,
    string_refs: []const codegen.StringRef,
    /// The name of the entry-point function
    entry_name: []const u8,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Linker {
        return .{ .allocator = allocator };
    }

    /// Write a complete ELF64 executable to `output_path`.
    pub fn link(self: *Linker, io: std.Io, input: LinkerInput, output_path: []const u8) !void {
        const buf = try self.buildElf(input);
        defer self.allocator.free(buf);

        const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, output_path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, buf);
        try std.Io.File.setPermissions(file, io, std.Io.File.Permissions.fromMode(0o755));
    }

    /// Build the complete ELF binary in memory.
    pub fn buildElf(self: *Linker, input: LinkerInput) ![]u8 {
        // Inject built-in runtime stubs (writeln, write, maia_*) at the start of .text
        var rt_result = try buildRuntime(self.allocator);
        const rt = rt_result.buf;
        defer self.allocator.free(rt);
        defer rt_result.stubs.deinit();

        // Compute the adjusted text: runtime stubs prepended
        const rt_size: u32 = @intCast(rt.len);

        // Verify the user code contains the expected entry symbol
        if (input.symbols.get(input.entry_name) == null and
            !std.mem.eql(u8, input.entry_name, "main") and
            !std.mem.eql(u8, input.entry_name, "_start"))
            return error.EntryNotFound;

        // The ELF entry point is always _start (inside the runtime stub)
        const entry_off: u32 = rt_result.start_off;

        // Section sizes
        const text_size: u64 = rt_size + input.text.len;
        const rodata_size: u64 = input.rodata.len;

        // File layout:
        //   0x00      ELF header (64 bytes)
        //   0x40      Program header table (2 entries × 56 bytes = 112 bytes)
        //   0xB0      .text
        //   0xB0+text .rodata
        //   (padding to page)
        //   Section header table
        //   .shstrtab

        const eh_size: u64 = 64;
        const phdr_size: u64 = 2 * 56; // two PT_LOAD segments
        const headers_size: u64 = eh_size + phdr_size;

        // Virtual addresses
        const text_vaddr: u64 = LOAD_ADDR + headers_size;
        const rodata_vaddr: u64 = text_vaddr + text_size;

        // Entry virtual address
        const entry_vaddr: u64 = text_vaddr + entry_off;

        // Section header string table
        const shstrtab = "\x00.text\x00.rodata\x00.shstrtab\x00";
        const shstrtab_offset: u64 = headers_size + text_size + rodata_size;
        const shstrtab_size: u64 = shstrtab.len;

        // Section header table (4 entries: null, .text, .rodata, .shstrtab)
        const shdr_count: u64 = 4;
        const shdr_size: u64 = 64;
        const shdr_offset: u64 = shstrtab_offset + shstrtab_size;

        const total_size: u64 = shdr_offset + shdr_count * shdr_size;

        var buf = try self.allocator.alloc(u8, @intCast(total_size));
        @memset(buf, 0);

        // ── ELF header ─────────────────────────────────────────────────────────
        var off: usize = 0;
        writeU32LE(buf, off, ELF_MAGIC); off += 4;
        buf[off] = ELFCLASS64; off += 1;  // EI_CLASS
        buf[off] = ELFDATA2LSB; off += 1; // EI_DATA
        buf[off] = 1; off += 1;           // EI_VERSION = 1
        buf[off] = 0; off += 1;           // EI_OSABI = ELFOSABI_NONE
        off += 8;                          // EI_ABIVERSION + padding
        writeU16LE(buf, off, ET_EXEC); off += 2;   // e_type
        writeU16LE(buf, off, EM_X86_64); off += 2; // e_machine
        writeU32LE(buf, off, 1); off += 4;          // e_version
        writeU64LE(buf, off, entry_vaddr); off += 8;// e_entry
        writeU64LE(buf, off, eh_size); off += 8;    // e_phoff
        writeU64LE(buf, off, shdr_offset); off += 8;// e_shoff
        writeU32LE(buf, off, 0); off += 4;           // e_flags
        writeU16LE(buf, off, 64); off += 2;          // e_ehsize
        writeU16LE(buf, off, 56); off += 2;          // e_phentsize
        writeU16LE(buf, off, 2); off += 2;            // e_phnum
        writeU16LE(buf, off, 64); off += 2;           // e_shentsize
        writeU16LE(buf, off, @intCast(shdr_count)); off += 2; // e_shnum
        writeU16LE(buf, off, 3); off += 2;            // e_shstrndx (index of .shstrtab)

        // ── Program header: PT_LOAD (text, read+exec) ─────────────────────────
        // phdr 0: covers headers + text + rodata
        const seg0_filesz: u64 = headers_size + text_size + rodata_size;
        writeU32LE(buf, off, PT_LOAD); off += 4;
        writeU32LE(buf, off, PF_R | PF_X); off += 4;       // p_flags
        writeU64LE(buf, off, 0); off += 8;                  // p_offset
        writeU64LE(buf, off, LOAD_ADDR); off += 8;          // p_vaddr
        writeU64LE(buf, off, LOAD_ADDR); off += 8;          // p_paddr
        writeU64LE(buf, off, seg0_filesz); off += 8;        // p_filesz
        writeU64LE(buf, off, seg0_filesz); off += 8;        // p_memsz
        writeU64LE(buf, off, PAGE_SIZE); off += 8;          // p_align

        // phdr 1: placeholder read-write (data/bss — empty for bootstrap)
        writeU32LE(buf, off, PT_LOAD); off += 4;
        writeU32LE(buf, off, PF_R | PF_W); off += 4;
        writeU64LE(buf, off, 0); off += 8;
        writeU64LE(buf, off, LOAD_ADDR + seg0_filesz); off += 8;
        writeU64LE(buf, off, LOAD_ADDR + seg0_filesz); off += 8;
        writeU64LE(buf, off, 0); off += 8; // filesz = 0
        writeU64LE(buf, off, 0); off += 8; // memsz  = 0
        writeU64LE(buf, off, PAGE_SIZE); off += 8;

        std.debug.assert(off == @as(usize, @intCast(headers_size)));

        // ── .text section: runtime stubs + user code ──────────────────────────
        // Patch relocations: string pointers and extern function addresses.
        const patched_text = try self.allocator.dupe(u8, input.text);
        defer self.allocator.free(patched_text);
        // Patch string pointer loads (imm32 ← rodata_vaddr + string_entry.offset)
        for (input.string_refs) |ref| {
            const addr: u32 = @intCast(rodata_vaddr + input.strings[ref.string_idx].offset);
            writeU32LE(patched_text, ref.imm_offset, addr);
        }
        // Patch extern call address loads (imm32 ← absolute vaddr of runtime stub)
        for (input.extern_calls) |site| {
            const stub_off: u32 = rt_result.stubs.get(site.name) orelse 0;
            const fn_vaddr: u32 = @intCast(text_vaddr + stub_off);
            writeU32LE(patched_text, site.imm_offset, fn_vaddr);
        }

        // Re-patch the `call main` displacement inside the runtime now that we
        // know the actual offset of `main` in the user code section.
        // The runtime was originally patched assuming main is at rt_size+0,
        // but main might not be the first user function.
        {
            const rt_size2: u32 = @intCast(rt.len);
            const main_user_off: u32 = input.symbols.get(input.entry_name) orelse 0;
            // call_off: position of E8 inside rt (scan backwards)
            var call_off_rt: u32 = 0;
            var scan_i: u32 = rt_size2;
            while (scan_i > 0) {
                scan_i -= 1;
                if (rt[scan_i] == 0xE8) { call_off_rt = scan_i; break; }
            }
            const call_end_rt: u32 = call_off_rt + 5;
            const main_abs: u32 = rt_size2 + main_user_off;
            const disp_fixed: i32 = @intCast(@as(i64, @intCast(main_abs)) - @as(i64, @intCast(call_end_rt)));
            const db = std.mem.asBytes(&disp_fixed);
            // Patch via a mutable copy of the runtime bytes
            var rt_mut = try self.allocator.dupe(u8, rt);
            defer self.allocator.free(rt_mut);
            rt_mut[call_off_rt + 1] = db[0];
            rt_mut[call_off_rt + 2] = db[1];
            rt_mut[call_off_rt + 3] = db[2];
            rt_mut[call_off_rt + 4] = db[3];
            @memcpy(buf[off..off + rt_mut.len], rt_mut); off += rt_mut.len;
        }
        @memcpy(buf[off..off + patched_text.len], patched_text); off += patched_text.len;

        // ── .rodata section ───────────────────────────────────────────────────
        if (input.rodata.len > 0) {
            @memcpy(buf[off..off + input.rodata.len], input.rodata);
            off += input.rodata.len;
        }

        // ── .shstrtab ─────────────────────────────────────────────────────────
        std.debug.assert(off == @as(usize, @intCast(shstrtab_offset)));
        @memcpy(buf[off..off + shstrtab.len], shstrtab);
        off += shstrtab.len;

        // ── Section headers ───────────────────────────────────────────────────
        std.debug.assert(off == @as(usize, @intCast(shdr_offset)));

        // SHT_NULL (index 0)
        off += @intCast(shdr_size); // all zeros

        // .text (index 1)
        writeU32LE(buf, off, 1); off += 4;            // sh_name (offset 1 in shstrtab)
        writeU32LE(buf, off, SHT_PROGBITS); off += 4;
        writeU64LE(buf, off, SHF_ALLOC | SHF_EXECINSTR); off += 8;
        writeU64LE(buf, off, text_vaddr); off += 8;   // sh_addr
        writeU64LE(buf, off, headers_size); off += 8; // sh_offset
        writeU64LE(buf, off, text_size); off += 8;    // sh_size
        writeU32LE(buf, off, 0); off += 4;             // sh_link
        writeU32LE(buf, off, 0); off += 4;             // sh_info
        writeU64LE(buf, off, 16); off += 8;            // sh_addralign
        writeU64LE(buf, off, 0); off += 8;             // sh_entsize

        // .rodata (index 2)
        writeU32LE(buf, off, 7); off += 4;            // sh_name (.rodata at offset 7)
        writeU32LE(buf, off, SHT_PROGBITS); off += 4;
        writeU64LE(buf, off, SHF_ALLOC); off += 8;
        writeU64LE(buf, off, rodata_vaddr); off += 8;
        writeU64LE(buf, off, headers_size + text_size); off += 8;
        writeU64LE(buf, off, rodata_size); off += 8;
        writeU32LE(buf, off, 0); off += 4;
        writeU32LE(buf, off, 0); off += 4;
        writeU64LE(buf, off, 1); off += 8;
        writeU64LE(buf, off, 0); off += 8;

        // .shstrtab (index 3)
        writeU32LE(buf, off, 15); off += 4;           // sh_name (.shstrtab at offset 15)
        writeU32LE(buf, off, SHT_STRTAB); off += 4;
        writeU64LE(buf, off, 0); off += 8;            // no SHF_ALLOC
        writeU64LE(buf, off, 0); off += 8;
        writeU64LE(buf, off, shstrtab_offset); off += 8;
        writeU64LE(buf, off, shstrtab_size); off += 8;
        writeU32LE(buf, off, 0); off += 4;
        writeU32LE(buf, off, 0); off += 4;
        writeU64LE(buf, off, 1); off += 8;
        writeU64LE(buf, off, 0); off += 8;

        return buf;
    }
};

// ── Runtime stubs ─────────────────────────────────────────────────────────────
/// Build a small blob of x86_64 machine code that provides:
///   writeln(ptr: *u8, len: usize)  — write ptr[0..len] + '\n' to stdout
///   _start  — calls main() then calls exit(0) via syscall
///
/// The stubs use Linux syscalls directly (no libc).
fn buildRuntime(allocator: std.mem.Allocator) !RuntimeResult {
    // We emit raw machine code bytes for the runtime stubs.
    // Layout (approximate — actual bytes listed below):
    //
    // _writeln:          ; writeln(str_ptr: rdi, str_len: rsi)
    //   push rbp
    //   mov rbp, rsp
    //   ; write(1, str_ptr, str_len)
    //   mov rax, 1       ; syscall number: write
    //   mov rdi, rdi     ; fd = 1 (stdout)  [already in rdi]
    //   ; rsi already has len
    //   syscall
    //   ; write newline '\n'
    //   sub rsp, 8
    //   mov byte [rsp], 0x0A
    //   mov rax, 1
    //   mov rdi, 1
    //   lea rsi, [rsp]
    //   mov rdx, 1
    //   syscall
    //   add rsp, 8
    //   pop rbp
    //   ret
    //
    // _start:
    //   xor rbp, rbp
    //   call main
    //   ; exit(rax)
    //   mov rdi, rax
    //   mov rax, 60      ; syscall: exit
    //   syscall
    //   ud2

    const code = [_]u8{
        // _writeln(rdi = null-terminated string ptr)
        // Computes strlen internally, then write(1, ptr, len) + '\n'.
        0x55,                   // push rbp                  [0]
        0x48, 0x89, 0xE5,       // mov rbp, rsp              [1]
        0x48, 0x31, 0xC0,       // xor rax, rax              [4]  ; length = 0
        // strlen_loop (offset 7):
        0x80, 0x3C, 0x07, 0x00, // cmp byte [rdi+rax], 0     [7]
        0x74, 0x05,             // je +5  (→ offset 18)      [11]
        0x48, 0xFF, 0xC0,       // inc rax                   [13]
        0xEB, 0xF5,             // jmp -11 (→ offset 7)      [16]
        // strlen_done (offset 18):
        0x48, 0x89, 0xC2,       // mov rdx, rax              [18] ; len
        0x48, 0x89, 0xFE,       // mov rsi, rdi              [21] ; ptr
        0x48, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00, // mov rdi, 1  [24] ; stdout
        0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00, // mov rax, 1  [31] ; write
        0x0F, 0x05,             // syscall                   [38]
        // Write newline
        0x48, 0x83, 0xEC, 0x08, // sub rsp, 8                [40]
        0xC6, 0x04, 0x24, 0x0A, // mov byte [rsp], '\n'      [44]
        0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00, // mov rax, 1  [48]
        0x48, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00, // mov rdi, 1  [55]
        0x48, 0x8D, 0x34, 0x24, // lea rsi, [rsp]            [62]
        0x48, 0xC7, 0xC2, 0x01, 0x00, 0x00, 0x00, // mov rdx, 1  [66]
        0x0F, 0x05,             // syscall                   [73]
        0x48, 0x83, 0xC4, 0x08, // add rsp, 8                [75]
        0x5D,                   // pop rbp                   [79]
        0xC3,                   // ret                       [80]

        // _start entry (offset 81)
        // On Linux x86_64, at process entry:
        //   [rsp]   = argc (integer)
        //   [rsp+8] = argv[0]  (char** array)
        // We load them into rdi/rsi before calling main so that main(argc, argv)
        // receives the correct values via the SysV AMD64 ABI.
        0x48, 0x31, 0xED,       // xor rbp, rbp              [81]
        0x48, 0x8B, 0x3C, 0x24, // mov rdi, [rsp]  ; argc    [84]
        0x48, 0x8D, 0x74, 0x24, 0x08, // lea rsi, [rsp+8] ; argv [88]
        0xE8, 0x00, 0x00, 0x00, 0x00, // call main             [93] (patched)
        // exit(rax)
        0x48, 0x89, 0xC7,       // mov rdi, rax  ; exit code  [98]
        0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, // mov rax, 60    [101]
        0x0F, 0x05,             // syscall                    [108]
        0x0F, 0x0B,             // ud2                        [110]
    };

    var buf = try allocator.dupe(u8, &code);

    // Find the `call main` E8 opcode (scan backwards through the core stub).
    var call_off: u32 = 0;
    {
        var i: u32 = @intCast(buf.len);
        while (i > 0) {
            i -= 1;
            if (buf[i] == 0xE8) { call_off = i; break; }
        }
    }

    // _start begins 12 bytes before the call instruction:
    //   xor rbp, rbp (3) + mov rdi,[rsp] (4) + lea rsi,[rsp+8] (5) = 12 bytes
    const start_off: u32 = call_off - 12;

    // NOTE: we patch the call displacement AFTER appending ext stubs below,
    // because main follows the entire runtime (core + ext stubs) in the text section.

    // ── Additional syscall stubs appended after the core runtime ─────────────
    //
    // Each stub begins immediately after the previous one.
    // Naming convention used by extern call resolution:
    //
    //   maia_mmap(len: rdi) → rax
    //     mmap(NULL, len, PROT_RW, MAP_PRIVATE|ANON, -1, 0)
    //
    //   maia_open(path: rdi) → rax  [fd or -1]
    //     open(path, O_RDONLY, 0)
    //
    //   maia_read(fd: rdi, buf: rsi, count: rdx) → rax  [bytes read]
    //     read(fd, buf, count)
    //
    //   maia_write(fd: rdi, buf: rsi, count: rdx) → rax  [bytes written]
    //     write(fd, buf, count)
    //
    //   maia_close(fd: rdi)
    //     close(fd)
    //
    //   maia_exit(code: rdi)  [noreturn]
    //     exit(code)
    //
    //   maia_fsize(fd: rdi) → rax  [file size in bytes]
    //     lseek(fd, 0, SEEK_END); lseek(fd, 0, SEEK_SET); return size
    //
    const ext_stubs = [_]u8{
        // ── maia_mmap ─────────────────────────────────────────────────────────
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0x89, 0xFE,                   // mov rsi, rdi    ; length
        0x48, 0x31, 0xFF,                   // xor rdi, rdi    ; addr = 0
        0x48, 0xC7, 0xC2, 0x03, 0x00, 0x00, 0x00, // mov rdx, 3  ; PROT_READ|WRITE
        0x49, 0xC7, 0xC2, 0x22, 0x00, 0x00, 0x00, // mov r10, 0x22 ; PRIVATE|ANON
        0x49, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF, // mov r8, -1  ; fd (anon)
        0x4D, 0x31, 0xC9,                   // xor r9, r9      ; offset = 0
        0x48, 0xC7, 0xC0, 0x09, 0x00, 0x00, 0x00, // mov rax, 9  ; mmap
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── maia_open ─────────────────────────────────────────────────────────
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0x31, 0xF6,                   // xor rsi, rsi    ; O_RDONLY = 0
        0x48, 0x31, 0xD2,                   // xor rdx, rdx    ; mode = 0
        0x48, 0xC7, 0xC0, 0x02, 0x00, 0x00, 0x00, // mov rax, 2  ; open
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── maia_read ─────────────────────────────────────────────────────────
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0x31, 0xC0,                   // xor rax, rax    ; read = 0
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── maia_write ────────────────────────────────────────────────────────
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00, // mov rax, 1  ; write
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── maia_close ────────────────────────────────────────────────────────
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0xC7, 0xC0, 0x03, 0x00, 0x00, 0x00, // mov rax, 3  ; close
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── maia_exit ─────────────────────────────────────────────────────────
        0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, // mov rax, 60 ; exit
        0x0F, 0x05,                         // syscall
        0x0F, 0x0B,                         // ud2

        // ── maia_fsize ────────────────────────────────────────────────────────
        // Save fd, lseek(fd,0,SEEK_END), save size, lseek(fd,0,SEEK_SET),
        // restore size as return value.
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0x83, 0xEC, 0x10,             // sub rsp, 16
        0x48, 0x89, 0x7D, 0xF8,             // mov [rbp-8], rdi   ; save fd
        0x48, 0x31, 0xF6,                   // xor rsi, rsi        ; offset = 0
        0x48, 0xC7, 0xC2, 0x02, 0x00, 0x00, 0x00, // mov rdx, 2   ; SEEK_END
        0x48, 0xC7, 0xC0, 0x08, 0x00, 0x00, 0x00, // mov rax, 8   ; lseek
        0x0F, 0x05,                         // syscall
        0x48, 0x89, 0x45, 0xF0,             // mov [rbp-16], rax  ; save size
        0x48, 0x8B, 0x7D, 0xF8,             // mov rdi, [rbp-8]   ; restore fd
        0x48, 0x31, 0xF6,                   // xor rsi, rsi        ; offset = 0
        0x48, 0x31, 0xD2,                   // xor rdx, rdx        ; SEEK_SET = 0
        0x48, 0xC7, 0xC0, 0x08, 0x00, 0x00, 0x00, // mov rax, 8   ; lseek
        0x0F, 0x05,                         // syscall
        0x48, 0x8B, 0x45, 0xF0,             // mov rax, [rbp-16]  ; return size
        0x48, 0x89, 0xEC,                   // mov rsp, rbp
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // ── Memory primitive stubs ───────────────────────────────────────────
        // These implement the low-level memory access operations declared as
        // extern functions in the self-hosted compiler source.

        // load_byte(addr: rdi) → rax  [6 bytes]
        0x48, 0x31, 0xC0,   // xor rax, rax
        0x8A, 0x07,         // mov al, byte [rdi]
        0xC3,               // ret

        // store_byte(addr: rdi, val: rsi)  [4 bytes]
        0x40, 0x88, 0x37,   // mov byte [rdi], sil   (REX needed for sil)
        0xC3,               // ret

        // load32(addr: rdi) → rax (zero-extended)  [3 bytes]
        0x8B, 0x07,         // mov eax, [rdi]
        0xC3,               // ret

        // store32(addr: rdi, val: rsi)  [3 bytes]
        0x89, 0x37,         // mov dword [rdi], esi
        0xC3,               // ret

        // load64(addr: rdi) → rax  [4 bytes]
        0x48, 0x8B, 0x07,   // mov rax, [rdi]
        0xC3,               // ret

        // store64(addr: rdi, val: rsi)  [4 bytes]
        0x48, 0x89, 0x37,   // mov [rdi], rsi
        0xC3,               // ret

        // maia_create(path: rdi, mode: rsi) → rax  [25 bytes]
        // open(path, O_WRONLY|O_CREAT|O_TRUNC=0x241, mode)
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0x89, 0xF2,                   // mov rdx, rsi   ; mode
        0x48, 0xC7, 0xC6, 0x41, 0x02, 0x00, 0x00, // mov rsi, 0x241 ; flags
        0x48, 0xC7, 0xC0, 0x02, 0x00, 0x00, 0x00, // mov rax, 2     ; open
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // maia_chmod(fd: rdi, mode: rsi) → rax  [17 bytes]
        // fchmod(fd, mode): syscall 91
        0x55,                               // push rbp
        0x48, 0x89, 0xE5,                   // mov rbp, rsp
        0x48, 0xC7, 0xC0, 0x5B, 0x00, 0x00, 0x00, // mov rax, 91 ; fchmod
        0x0F, 0x05,                         // syscall
        0x5D,                               // pop rbp
        0xC3,                               // ret

        // maia_close_fd(fd: rdi)  [10 bytes]
        // close(fd): syscall 3
        0x48, 0xC7, 0xC0, 0x03, 0x00, 0x00, 0x00, // mov rax, 3  ; close
        0x0F, 0x05,                         // syscall
        0xC3,                               // ret
    };

    const base_len: u32 = @intCast(buf.len);
    const new_buf = try allocator.realloc(buf, buf.len + ext_stubs.len);
    buf = new_buf;
    @memcpy(buf[base_len..], &ext_stubs);

    // ── Compute stub offsets for extern call resolution ───────────────────────
    var stubs = std.StringHashMap(u32).init(allocator);
    // writeln is always at offset 0
    try stubs.put("writeln", 0);
    try stubs.put("write",   0);

    // Measure each stub's offset by counting bytes in ext_stubs up to its start.
    // maia_mmap starts immediately at base_len.
    const mmap_off:       u32 = base_len;
    const open_off:       u32 = mmap_off       + 45;
    const read_off:       u32 = open_off        + 21;
    const write_off:      u32 = read_off        + 11;
    const close_off:      u32 = write_off       + 15;
    const exit_off:       u32 = close_off       + 15;
    const fsize_off:      u32 = exit_off        + 11;
    const load_byte_off:  u32 = fsize_off       + 63;
    const store_byte_off: u32 = load_byte_off   + 6;
    const load32_off:     u32 = store_byte_off  + 4;
    const store32_off:    u32 = load32_off      + 3;
    const load64_off:     u32 = store32_off     + 3;
    const store64_off:    u32 = load64_off      + 4;
    const create_off:     u32 = store64_off     + 4;
    const chmod_off:      u32 = create_off      + 25;
    const closefd_off:    u32 = chmod_off       + 17;

    try stubs.put("maia_mmap",    mmap_off);
    try stubs.put("maia_open",    open_off);
    try stubs.put("maia_read",    read_off);
    try stubs.put("maia_write",   write_off);
    try stubs.put("maia_close",   close_off);
    try stubs.put("maia_exit",    exit_off);
    try stubs.put("maia_fsize",   fsize_off);
    try stubs.put("load_byte",    load_byte_off);
    try stubs.put("store_byte",   store_byte_off);
    try stubs.put("load32",       load32_off);
    try stubs.put("store32",      store32_off);
    try stubs.put("load64",       load64_off);
    try stubs.put("store64",      store64_off);
    try stubs.put("maia_create",  create_off);
    try stubs.put("maia_chmod",   chmod_off);
    try stubs.put("maia_close_fd",closefd_off);

    // Now patch the `call main` displacement with the full runtime size.
    // main (user code) follows all of the runtime stubs in the text section.
    const rt_size_total: u32 = @intCast(buf.len);
    const call_end: u32 = call_off + 5;
    const disp: i32 = @intCast(@as(i64, @intCast(rt_size_total)) - @as(i64, @intCast(call_end)));
    const disp_bytes = std.mem.asBytes(&disp);
    buf[call_off + 1] = disp_bytes[0];
    buf[call_off + 2] = disp_bytes[1];
    buf[call_off + 3] = disp_bytes[2];
    buf[call_off + 4] = disp_bytes[3];

    return .{ .buf = buf, .start_off = start_off, .stubs = stubs };
}

const RuntimeResult = struct {
    buf: []u8,
    start_off: u32,
    /// Offsets within buf for each named stub.
    /// Used by the linker to patch extern call sites.
    stubs: std.StringHashMap(u32),
};

// ── Write helpers ─────────────────────────────────────────────────────────────

fn writeU16LE(buf: []u8, off: usize, v: u16) void {
    buf[off]     = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

fn writeU32LE(buf: []u8, off: usize, v: u32) void {
    buf[off]     = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

fn writeU64LE(buf: []u8, off: usize, v: u64) void {
    writeU32LE(buf, off,     @truncate(v));
    writeU32LE(buf, off + 4, @truncate(v >> 32));
}
