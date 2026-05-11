const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Source modules ────────────────────────────────────────────────────────
    const mod_lexer = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target, .optimize = optimize,
    });
    const mod_ast = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target, .optimize = optimize,
    });
    mod_ast.addImport("lexer", mod_lexer);

    const mod_parser = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target, .optimize = optimize,
    });
    mod_parser.addImport("lexer", mod_lexer);
    mod_parser.addImport("ast",   mod_ast);

    const mod_sema = b.createModule(.{
        .root_source_file = b.path("src/sema.zig"),
        .target = target, .optimize = optimize,
    });
    mod_sema.addImport("ast", mod_ast);

    const mod_ir = b.createModule(.{
        .root_source_file = b.path("src/ir.zig"),
        .target = target, .optimize = optimize,
    });
    mod_ir.addImport("ast",  mod_ast);
    mod_ir.addImport("sema", mod_sema);

    const mod_assembler = b.createModule(.{
        .root_source_file = b.path("src/assembler.zig"),
        .target = target, .optimize = optimize,
    });

    const mod_cg_arm64 = b.createModule(.{
        .root_source_file = b.path("src/codegen/arm64.zig"),
        .target = target, .optimize = optimize,
    });
    mod_cg_arm64.addImport("ir", mod_ir);

    const mod_cg_riscv64 = b.createModule(.{
        .root_source_file = b.path("src/codegen/riscv64.zig"),
        .target = target, .optimize = optimize,
    });
    mod_cg_riscv64.addImport("ir", mod_ir);

    const mod_cg_wasm32 = b.createModule(.{
        .root_source_file = b.path("src/codegen/wasm32.zig"),
        .target = target, .optimize = optimize,
    });
    mod_cg_wasm32.addImport("ir", mod_ir);

    const mod_cg_x86 = b.createModule(.{
        .root_source_file = b.path("src/codegen/x86_64.zig"),
        .target = target, .optimize = optimize,
    });
    mod_cg_x86.addImport("ir",        mod_ir);
    mod_cg_x86.addImport("assembler", mod_assembler);
    mod_cg_x86.addImport("sema",      mod_sema);

    const mod_linker = b.createModule(.{
        .root_source_file = b.path("src/linker.zig"),
        .target = target, .optimize = optimize,
    });
    mod_linker.addImport("codegen/x86_64", mod_cg_x86);

    // ── Main executable ───────────────────────────────────────────────────────
    const mod_main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target, .optimize = optimize,
    });
    mod_main.addImport("lexer",          mod_lexer);
    mod_main.addImport("parser",         mod_parser);
    mod_main.addImport("sema",           mod_sema);
    mod_main.addImport("ir",             mod_ir);
    mod_main.addImport("codegen/x86_64", mod_cg_x86);
    mod_main.addImport("codegen/wasm32", mod_cg_wasm32);
    mod_main.addImport("linker",         mod_linker);

    const exe = b.addExecutable(.{
        .name = "maia",
        .root_module = mod_main,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Maia compiler");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (chained sequentially to avoid saturating the machine) ──────────
    const test_step = b.step("test", "Run all tests");
    var prev_step: *std.Build.Step = test_step;

    // lexer tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/lexer_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/lexer.zig", mod_lexer);
        const t = b.addTest(.{ .name = "lexer", .root_module = mod });
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // parser tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/parser_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/lexer.zig",  mod_lexer);
        mod.addImport("../src/parser.zig", mod_parser);
        mod.addImport("../src/ast.zig",    mod_ast);
        const t = b.addTest(.{ .name = "parser", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // sema tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/sema_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/lexer.zig",  mod_lexer);
        mod.addImport("../src/parser.zig", mod_parser);
        mod.addImport("../src/sema.zig",   mod_sema);
        const t = b.addTest(.{ .name = "sema", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // ir tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/ir_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/lexer.zig",  mod_lexer);
        mod.addImport("../src/parser.zig", mod_parser);
        mod.addImport("../src/sema.zig",   mod_sema);
        mod.addImport("../src/ir.zig",     mod_ir);
        const t = b.addTest(.{ .name = "ir", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // assembler tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/assembler_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/assembler.zig", mod_assembler);
        const t = b.addTest(.{ .name = "assembler", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // codegen tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/codegen_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/lexer.zig",            mod_lexer);
        mod.addImport("../src/parser.zig",           mod_parser);
        mod.addImport("../src/sema.zig",             mod_sema);
        mod.addImport("../src/ir.zig",               mod_ir);
        mod.addImport("../src/codegen/x86_64.zig",   mod_cg_x86);
        mod.addImport("../src/codegen/arm64.zig",    mod_cg_arm64);
        mod.addImport("../src/codegen/riscv64.zig",  mod_cg_riscv64);
        mod.addImport("../src/codegen/wasm32.zig",   mod_cg_wasm32);
        const t = b.addTest(.{ .name = "codegen", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    // linker tests
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/linker_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("../src/linker.zig",          mod_linker);
        mod.addImport("../src/codegen/x86_64.zig",  mod_cg_x86);
        const t = b.addTest(.{ .name = "linker", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
    }
}
