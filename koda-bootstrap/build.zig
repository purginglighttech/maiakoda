const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Source modules
    const mod_value = b.createModule(.{
        .root_source_file = b.path("src/value.zig"),
        .target = target, .optimize = optimize,
    });
    const mod_bytecode = b.createModule(.{
        .root_source_file = b.path("src/bytecode.zig"),
        .target = target, .optimize = optimize,
    });
    const mod_lexer = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target, .optimize = optimize,
    });
    const mod_ast = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target, .optimize = optimize,
    });
    const mod_parser = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target, .optimize = optimize,
    });
    mod_parser.addImport("lexer", mod_lexer);
    mod_parser.addImport("ast", mod_ast);

    const mod_compiler = b.createModule(.{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target, .optimize = optimize,
    });
    mod_compiler.addImport("ast", mod_ast);
    mod_compiler.addImport("value", mod_value);
    mod_compiler.addImport("bytecode", mod_bytecode);

    // Lib modules
    const mod_lib_core = b.createModule(.{
        .root_source_file = b.path("src/lib/core.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_core.addImport("value", mod_value);

    const mod_lib_string = b.createModule(.{
        .root_source_file = b.path("src/lib/string.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_string.addImport("value", mod_value);

    const mod_lib_array = b.createModule(.{
        .root_source_file = b.path("src/lib/array.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_array.addImport("value", mod_value);

    const mod_lib_table = b.createModule(.{
        .root_source_file = b.path("src/lib/table.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_table.addImport("value", mod_value);

    const mod_lib_math = b.createModule(.{
        .root_source_file = b.path("src/lib/math.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_math.addImport("value", mod_value);

    const mod_lib_io = b.createModule(.{
        .root_source_file = b.path("src/lib/io.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_io.addImport("value", mod_value);

    const mod_lib_async = b.createModule(.{
        .root_source_file = b.path("src/lib/async.zig"),
        .target = target, .optimize = optimize,
    });
    mod_lib_async.addImport("value", mod_value);

    const mod_runtime = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target, .optimize = optimize,
    });
    mod_runtime.addImport("value", mod_value);
    mod_runtime.addImport("lib_core",   mod_lib_core);
    mod_runtime.addImport("lib_string", mod_lib_string);
    mod_runtime.addImport("lib_array",  mod_lib_array);
    mod_runtime.addImport("lib_table",  mod_lib_table);
    mod_runtime.addImport("lib_math",   mod_lib_math);
    mod_runtime.addImport("lib_io",     mod_lib_io);
    mod_runtime.addImport("lib_async",  mod_lib_async);

    const mod_vm = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target, .optimize = optimize,
    });
    mod_vm.addImport("value", mod_value);
    mod_vm.addImport("bytecode", mod_bytecode);
    mod_vm.addImport("runtime", mod_runtime);

    const mod_repl = b.createModule(.{
        .root_source_file = b.path("src/repl.zig"),
        .target = target, .optimize = optimize,
    });
    mod_repl.addImport("lexer", mod_lexer);
    mod_repl.addImport("parser", mod_parser);
    mod_repl.addImport("compiler", mod_compiler);
    mod_repl.addImport("vm", mod_vm);
    mod_repl.addImport("value", mod_value);

    const mod_main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target, .optimize = optimize,
    });
    mod_main.addImport("lexer", mod_lexer);
    mod_main.addImport("parser", mod_parser);
    mod_main.addImport("compiler", mod_compiler);
    mod_main.addImport("vm", mod_vm);
    mod_main.addImport("repl", mod_repl);

    // Executable
    const exe = b.addExecutable(.{
        .name = "koda",
        .root_module = mod_main,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the koda interpreter");
    run_step.dependOn(&run_cmd.step);

    // Tests — chained sequentially to avoid saturating the machine with
    // parallel Zig compilations.  Each run step depends on the previous one.
    const test_step = b.step("test", "Run all tests");
    var prev_step: *std.Build.Step = test_step;

    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/lexer_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer", mod_lexer);
        const t = b.addTest(.{ .name = "lexer", .root_module = mod });
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/parser_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer", mod_lexer);
        mod.addImport("parser", mod_parser);
        mod.addImport("ast", mod_ast);
        const t = b.addTest(.{ .name = "parser", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/compiler_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer", mod_lexer);
        mod.addImport("parser", mod_parser);
        mod.addImport("compiler", mod_compiler);
        mod.addImport("value", mod_value);
        mod.addImport("bytecode", mod_bytecode);
        mod.addImport("ast", mod_ast);
        const t = b.addTest(.{ .name = "compiler", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/vm_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer", mod_lexer);
        mod.addImport("parser", mod_parser);
        mod.addImport("compiler", mod_compiler);
        mod.addImport("vm", mod_vm);
        mod.addImport("value", mod_value);
        const t = b.addTest(.{ .name = "vm", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/runtime_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer", mod_lexer);
        mod.addImport("parser", mod_parser);
        mod.addImport("compiler", mod_compiler);
        mod.addImport("vm", mod_vm);
        mod.addImport("value", mod_value);
        const t = b.addTest(.{ .name = "runtime", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/lib_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer",    mod_lexer);
        mod.addImport("parser",   mod_parser);
        mod.addImport("compiler", mod_compiler);
        mod.addImport("vm",       mod_vm);
        mod.addImport("value",    mod_value);
        const t = b.addTest(.{ .name = "lib", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
        prev_step = &run.step;
    }
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/repl_tests.zig"),
            .target = target, .optimize = optimize,
        });
        mod.addImport("lexer",    mod_lexer);
        mod.addImport("parser",   mod_parser);
        mod.addImport("compiler", mod_compiler);
        mod.addImport("vm",       mod_vm);
        mod.addImport("value",    mod_value);
        mod.addImport("repl",     mod_repl);
        const t = b.addTest(.{ .name = "repl", .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(prev_step);
        test_step.dependOn(&run.step);
    }
}
