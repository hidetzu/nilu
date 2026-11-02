const std = @import("std");

pub fn build(builder: *std.Build) void {
    const optimize = builder.standardOptimizeOption(.{});
    const filter = builder.option([]const u8, "test-filter", "Run compiled Zig tests whose names contain this text");
    // The code layout every build has (tools/README.md, "Code layout"); a
    // measurement varies it to tell a change from where the code landed.
    const layout: Layout = .{
        .arm_slot = builder.option(u32, "arm-slot", "Code layout: each VM instruction arm aligned to this many bytes, a power of two (default 128)") orelse Layout.default.arm_slot,
        .arm_shift = builder.option(u32, "arm-shift", "Code layout, for measuring: the running code starts this many bytes past a 4096-byte boundary (default 2048; ELF only)") orelse Layout.default.arm_shift,
        .group_gap = builder.option(u32, "group-gap", "Code layout, for measuring: bytes left between the groups of the running code (default 448; ELF only)") orelse Layout.default.group_gap,
        .group_page = builder.option(bool, "group-page", "Code layout, for measuring: start each group of the running code on a 4096-byte boundary, plus the gap (default true; ELF only)") orelse Layout.default.group_page,
    };
    if (layout.arm_slot != 0 and !std.math.isPowerOfTwo(layout.arm_slot)) @panic("-Darm-slot must be a power of two");
    poison_registers = builder.option(bool, "poison-registers", "For checking the compiler: registers the VM regrows hold a poison number instead of what they held, so a read before a write changes an answer (default false)") orelse false;

    const format = builder.addFmt(.{
        .paths = &.{builder.path(".")},
        .exclude_paths = &.{ builder.path(".zig-cache"), builder.path("zig-out") },
    });
    builder.step("fmt", "Format Zig source").dependOn(&format.step);
    const format_check = builder.addFmt(.{
        .paths = &.{builder.path(".")},
        .exclude_paths = &.{ builder.path(".zig-cache"), builder.path("zig-out") },
        .check = true,
    });
    builder.step("fmt-check", "Check Zig formatting").dependOn(&format_check.step);

    const documents = nodeStep(builder, "docs-check", "Check carried references and document links", "tools/docs-check.mjs");
    const document_tests = nodeStep(builder, "docs-check-test", "Exercise the document checker against fixtures", "tools/docs-check-test.mjs");
    const build_tests = nodeStep(builder, "build-check-test", "Exercise build entry points against temporary projects", "tools/build-check-test.mjs");
    build_tests.addArgs(&.{ "--zig", builder.graph.zig_exe });

    const naming = nodeStep(builder, "naming-check", "Check Zig file, declaration and directory names", "tools/zig-naming.mjs");
    const naming_tests = nodeStep(builder, "naming-check-test", "Exercise the naming checker against fixtures", "tools/zig-naming-test.mjs");
    const tooling = builder.step("tool-test", "Run all tooling fixture suites");
    tooling.dependOn(&document_tests.step);
    tooling.dependOn(&build_tests.step);
    tooling.dependOn(&naming_tests.step);

    const stage = builder.step("stage-check", "A faster subset of check while developing; it does not replace check");
    stage.dependOn(&format_check.step);
    stage.dependOn(&documents.step);
    stage.dependOn(&naming.step);
    stage.dependOn(tooling);

    const source_module = builder.createModule(.{
        .root_source_file = builder.path("src/root.zig"),
        .target = builder.graph.host,
        .optimize = optimize,
    });
    source_module.addAnonymousImport("lua55-numerals", .{ .root_source_file = builder.path("test/fixtures/lua55-numerals.txt") });
    source_module.addAnonymousImport("lua55-numeral-parsing", .{ .root_source_file = builder.path("test/fixtures/lua55-numeral-parsing.txt") });
    source_module.addAnonymousImport("lua55-format", .{ .root_source_file = builder.path("test/fixtures/lua55-format.txt") });
    source_module.addAnonymousImport("lua55-expressions", .{ .root_source_file = builder.path("test/fixtures/lua55-expressions.txt") });
    source_module.addAnonymousImport("lua55-statements", .{ .root_source_file = builder.path("test/fixtures/lua55-statements.txt") });
    source_module.addAnonymousImport("lua55-varargs", .{ .root_source_file = builder.path("test/fixtures/lua55-varargs.txt") });
    source_module.addAnonymousImport("lua55-calls", .{ .root_source_file = builder.path("test/fixtures/lua55-calls.txt") });
    source_module.addAnonymousImport("lua55-functions", .{ .root_source_file = builder.path("test/fixtures/lua55-functions.txt") });
    source_module.addAnonymousImport("lua55-generic-for", .{ .root_source_file = builder.path("test/fixtures/lua55-generic-for.txt") });
    source_module.addAnonymousImport("lua55-index-chains", .{ .root_source_file = builder.path("test/fixtures/lua55-index-chains.txt") });
    source_module.addAnonymousImport("lua55-newindex-chains", .{ .root_source_file = builder.path("test/fixtures/lua55-newindex-chains.txt") });
    source_module.addAnonymousImport("lua55-index-handlers", .{ .root_source_file = builder.path("test/fixtures/lua55-index-handlers.txt") });
    source_module.addAnonymousImport("lua55-operator-handlers", .{ .root_source_file = builder.path("test/fixtures/lua55-operator-handlers.txt") });
    source_module.addAnonymousImport("lua55-order-handlers", .{ .root_source_file = builder.path("test/fixtures/lua55-order-handlers.txt") });
    source_module.addAnonymousImport("lua55-call-chains", .{ .root_source_file = builder.path("test/fixtures/lua55-call-chains.txt") });
    source_module.addAnonymousImport("lua55-reserved-word-keys", .{ .root_source_file = builder.path("test/fixtures/lua55-reserved-word-keys.txt") });
    source_module.addAnonymousImport("c-api-header", .{ .root_source_file = builder.path("include/nilu.h") });
    source_module.addAnonymousImport("manual-library", .{ .root_source_file = builder.path("doc/en/10-library.md") });
    source_module.addAnonymousImport("manual-failure", .{ .root_source_file = builder.path("doc/en/08-failure.md") });
    source_module.addAnonymousImport("manual-01", .{ .root_source_file = builder.path("doc/en/01-getting-started.md") });
    source_module.addAnonymousImport("manual-02", .{ .root_source_file = builder.path("doc/en/02-values.md") });
    source_module.addAnonymousImport("manual-03", .{ .root_source_file = builder.path("doc/en/03-variables.md") });
    source_module.addAnonymousImport("manual-04", .{ .root_source_file = builder.path("doc/en/04-statements.md") });
    source_module.addAnonymousImport("manual-05", .{ .root_source_file = builder.path("doc/en/05-expressions.md") });
    source_module.addAnonymousImport("manual-06", .{ .root_source_file = builder.path("doc/en/06-functions.md") });
    source_module.addAnonymousImport("manual-07", .{ .root_source_file = builder.path("doc/en/07-metatables.md") });
    source_module.addAnonymousImport("manual-09", .{ .root_source_file = builder.path("doc/en/09-gc.md") });
    source_module.addIncludePath(builder.path("include"));
    // The header as a C compiler reads it; c_api_abi_test compares the
    // exported functions with these declarations.
    const header = builder.addTranslateC(.{ .root_source_file = builder.path("include/nilu.h"), .target = builder.graph.host, .optimize = optimize });
    source_module.addImport("nilu-header", header.createModule());
    source_module.addImport("layout", layoutModule(builder, Layout.default));
    source_module.addCSourceFile(.{ .file = builder.path("test/c_api/callbacks.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    const unit_tests = builder.addTest(.{
        .root_module = source_module,
        // The frame loop's arms jump to each other by tail call, which only
        // the LLVM backend makes; the default Debug backend refuses it.
        .use_llvm = true,
        .filters = if (filter) |text| &.{text} else &.{},
    });
    const run_tests = builder.addSystemCommand(&.{ "node", "tools/run-zig-tests.mjs" });
    run_tests.addArtifactArg(unit_tests);
    run_tests.addArg(filter orelse "");
    run_tests.addPassthruArgs();
    run_tests.has_side_effects = true;
    stage.dependOn(&run_tests.step);
    builder.step("test", "Run native Zig tests; missing source, zero tests and skips fail").dependOn(&run_tests.step);

    // An explicitly partial C boundary; full c-test/install remain pending.
    const c_library = builder.addLibrary(.{
        .name = "nilu-stack-foundation",
        .use_llvm = true,
        .linkage = .static,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("src/c_api_test_bridge.zig"),
            .pic = true,
            .target = builder.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "layout", .module = layoutModule(builder, Layout.default) }},
        }),
    });
    // An LLVM Debug build probes large frames through compiler_rt, which a
    // C host linking the archive does not have.
    c_library.bundle_compiler_rt = true;
    const c_host = builder.addExecutable(.{
        .name = "c-stack-foundation",
        .root_module = builder.createModule(.{ .target = builder.graph.host, .optimize = optimize, .link_libc = true }),
    });
    c_host.root_module.addCSourceFile(.{ .file = builder.path("test/c_api/stack_foundation.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    c_host.root_module.addIncludePath(builder.path("include"));
    c_host.root_module.linkLibrary(c_library);
    const c_run = builder.addSystemCommand(&.{ "node", "tools/run-c-stack-foundation.mjs" });
    c_run.addArtifactArg(c_host);
    c_run.addFileArg(builder.path("test/c_api/stack_foundation.c"));
    c_run.addDirectoryArg(builder.path("include"));
    c_run.addArtifactArg(c_library);
    c_run.has_side_effects = true;
    stage.dependOn(&c_run.step);
    builder.step("c-stack-foundation", "Run the partial C state/value-stack boundary and abort checks").dependOn(&c_run.step);

    // The library a host links: every nilu_* export with the standard library
    // inside, and the header beside it. The command is one host of it.
    const host_artifacts = artifacts(builder, builder.graph.host, optimize, false, layout);
    const library = host_artifacts.library;
    const command = host_artifacts.command;
    builder.installArtifact(library);
    builder.getInstallStep().dependOn(&builder.addInstallHeaderFile(builder.path("include/nilu.h"), "nilu.h").step);
    builder.installArtifact(command);

    // The whole carried C suite against the library, under both compilers.
    const smoke = builder.addExecutable(.{
        .name = "c-smoke",
        .root_module = builder.createModule(.{ .target = builder.graph.host, .optimize = optimize, .link_libc = true }),
    });
    smoke.root_module.addCSourceFile(.{ .file = builder.path("test/c/smoke.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    smoke.root_module.addIncludePath(builder.path("include"));
    smoke.root_module.linkLibrary(library);
    const smoke_run = builder.addSystemCommand(&.{ "node", "tools/run-c-smoke.mjs" });
    smoke_run.addArtifactArg(smoke);
    smoke_run.addFileArg(builder.path("test/c/smoke.c"));
    smoke_run.addDirectoryArg(builder.path("include"));
    smoke_run.addArtifactArg(library);
    smoke_run.addPassthruArgs();
    smoke_run.has_side_effects = true;
    builder.step("c-test", "Run the whole carried C smoke suite against the library").dependOn(&smoke_run.step);

    // The carried command cases drive the nilu program through pipes (POSIX).
    const cli_cases = builder.addExecutable(.{
        .name = "cli-cases",
        .root_module = builder.createModule(.{ .target = builder.graph.host, .optimize = optimize, .link_libc = true }),
    });
    cli_cases.root_module.addCSourceFile(.{ .file = builder.path("test/c/cli.c"), .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    cli_cases.root_module.addIncludePath(builder.path("include"));
    const cli_run = builder.addSystemCommand(&.{ "node", "tools/run-cli-cases.mjs" });
    cli_run.addArtifactArg(cli_cases);
    cli_run.addArtifactArg(command);
    inline for (.{ "hello", "bad", "args", "fails", "shebang", "shebang-fails", "hash", "only-shebang" }) |fixture| {
        cli_run.addFileArg(builder.path("test/cli/" ++ fixture ++ ".nilu"));
    }
    cli_run.addPassthruArgs();
    cli_run.has_side_effects = true;
    builder.step("cli-test", "Run the carried command cases against the nilu program").dependOn(&cli_run.step);
    // The command's reader for require, dofile and loadfile (ADR 0003), over
    // files the runner writes into a fresh directory.
    const module_run = builder.addSystemCommand(&.{ "node", "tools/module-cases.mjs" });
    module_run.addArtifactArg(command);
    module_run.addPassthruArgs();
    module_run.has_side_effects = true;
    builder.step("module-test", "Run the nilu command's module reader against written files").dependOn(&module_run.step);

    // Every example of both manuals, through the program a reader would use.
    const manual = builder.addSystemCommand(&.{ "node", "tools/manual-check.mjs", "--nilu" });
    manual.addArtifactArg(command);
    manual.addArgs(&.{ "--zig", builder.graph.zig_exe, "--include" });
    manual.addDirectoryArg(builder.path("include"));
    manual.addArg("--library");
    manual.addArtifactArg(library);
    manual.addPassthruArgs();
    manual.has_side_effects = true;
    builder.step("manual-check", "Run the examples of both manuals and compare their output").dependOn(&manual.step);
    const manual_tests = builder.addSystemCommand(&.{ "node", "tools/manual-check-test.mjs", "--nilu" });
    manual_tests.addArtifactArg(command);
    manual_tests.addPassthruArgs();
    manual_tests.has_side_effects = true;
    builder.step("manual-check-test", "Exercise the manual checker against small manuals").dependOn(&manual_tests.step);

    // The consumer's path: the installed header and library with a plain C driver.
    const example = builder.addSystemCommand(&.{ "node", "tools/run-example.mjs", "--zig" });
    example.addFileArg(.zig_exe);
    example.addArg("--include");
    example.addDirectoryArg(.{ .relative = .{ .base = .install_include } });
    example.addArg("--library");
    example.addFileArg(.{ .relative = .{ .base = .install_lib, .sub_path = "libnilu.a" } });
    for ([_][]const u8{ "test/install/stack.c", "examples/hello.c", "examples/host_function.c", "examples/coroutine.c", "examples/rules.c" }) |source| {
        example.addArg("--source");
        example.addFileArg(builder.path(source));
    }
    example.step.dependOn(builder.getInstallStep());
    example.has_side_effects = true;
    builder.step("example", "Compile and run the C hosts in examples/ and test/install/ against the installed artifacts").dependOn(&example.step);

    const check = builder.step("check", "Full verification gate; fails while any required stage is missing");
    check.dependOn(stage);
    check.dependOn(&run_tests.step);
    check.dependOn(&smoke_run.step);
    check.dependOn(&cli_run.step);
    check.dependOn(&module_run.step);
    check.dependOn(&manual.step);
    check.dependOn(&manual_tests.step);
    check.dependOn(&example.step);

    // The release (ADR 0011): the command, the library, the header and the
    // licence for five targets under zig-out/dist/nilu-<version>-<target>/,
    // and SHA256SUMS over all of them. The version is the header's. Only the
    // host's binary can be run here; the checker says which one it ran.
    const dist = builder.step("dist", "Build the release artifacts for the five targets and write SHA256SUMS");
    if (headerVersion(builder)) |version| {
        const dist_check = builder.addSystemCommand(&.{ "node", "tools/dist-check.mjs", "--dist" });
        dist_check.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "dist" } });
        dist_check.addArgs(&.{ "--version", version, "--targets", comptime joinTargets(), "--host", builder.fmt("{s}-{s}", .{ @tagName(builder.graph.host.result.cpu.arch), @tagName(builder.graph.host.result.os.tag) }) });
        dist_check.has_side_effects = true;
        for (release_targets) |triple| {
            const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("a release target does not parse");
            const release = artifacts(builder, builder.resolveTargetQuery(query), .ReleaseSafe, true, Layout.default);
            const directory: std.Build.InstallDir = .{ .custom = builder.fmt("dist/nilu-{s}-{s}", .{ version, triple }) };
            dist_check.step.dependOn(&builder.addInstallArtifact(release.command, .{ .dest_dir = .{ .override = directory } }).step);
            dist_check.step.dependOn(&builder.addInstallArtifact(release.library, .{ .dest_dir = .{ .override = directory } }).step);
            dist_check.step.dependOn(&builder.addInstallFileWithDir(builder.path("include/nilu.h"), directory, "nilu.h").step);
            dist_check.step.dependOn(&builder.addInstallFileWithDir(builder.path("LICENSE"), directory, "LICENSE").step);
        }
        dist.dependOn(&dist_check.step);
    } else {
        dist.dependOn(&builder.addFail("NOT-VERIFIED: include/nilu.h does not define NILU_VERSION; no release can be named").step);
    }
}

/// The five targets a release carries (ADR 0011; the owner's choice of
/// 2026-10-31): Linux against glibc, not musl, because musl's stdio leaves
/// errno unset when a stream is used against its direction and the command
/// then says `No error information` where the carried cases and Lua say `Bad
/// file descriptor`; both macOS architectures; and x86_64 Windows.
const release_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu" };

fn joinTargets() []const u8 {
    var joined: []const u8 = "";
    for (release_targets, 0..) |triple, index| joined = joined ++ (if (index == 0) "" else ",") ++ triple;
    return joined;
}

const Artifacts = struct { library: *std.Build.Step.Compile, command: *std.Build.Step.Compile };

/// See `-Darm-slot`, `-Darm-shift` and `-Dgroup-gap`. A release always has
/// the default.
const Layout = struct {
    arm_slot: u32,
    arm_shift: u32,
    group_gap: u32,
    /// Each group starts `group_gap` bytes past a 4096-byte boundary instead
    /// of `group_gap` bytes past the group before it, so that a group's size
    /// does not move the groups after it within a page.
    group_page: bool,

    /// What the command and a release are built with: of sixteen layouts
    /// measured in ReleaseSafe, the one with the lowest geometric mean over
    /// bench/, the smaller worst case breaking a tie. Shift and
    /// gap apply to ELF only.
    const default: Layout = .{ .arm_slot = 128, .arm_shift = 2048, .group_gap = 448, .group_page = true };
};

/// What src/vm.zig reads as `@import("layout")`.
/// `-Dpoison-registers`, read once in `build`.
var poison_registers = false;

fn layoutModule(builder: *std.Build, layout: Layout) *std.Build.Module {
    const options = builder.addOptions();
    options.addOption(u32, "arm_slot", layout.arm_slot);
    options.addOption(bool, "poison_registers", poison_registers);
    return options.createModule();
}

/// The linker script that places the command's running code as `layout`
/// asks: in a section after .text, from a 4096-byte boundary plus the shift,
/// each group in name order, so that a change to the code left in .text (the
/// compiler, the parser, I/O) moves none of it, and a change to one group
/// moves only what comes after it. The standard library's hot parts come
/// first, since our changes do not alter them; then the arms (one section,
/// src/vm.zig), then the rest of the VM and the runtime. The gap goes between the groups: a shift moves
/// the whole section and keeps where its functions are against each other,
/// which can matter as much. LLVM puts what it judges cold in
/// .text.unlikely, which stays where it is.
fn layoutScript(builder: *std.Build, layout: Layout) std.Build.LazyPath {
    // Each name is a function's section without its `.text.` prefix; a
    // stripped build names an internal function `.L<name>`, so both forms
    // are listed. The C API's exported functions keep their export names.
    const groups = [_][]const []const u8{
        &.{ "hash.wyhash.*", "heap.SmpAllocator.*" },
        &.{"nilu_arms"},
        &.{"vm.*"},
        &.{ "HashPart.*", "runtime.*", "execution_context.*" },
        &.{ "native.*", "c_api.*", "nilu_*", "api_*", "stdlib*" },
    };
    var text: std.ArrayList(u8) = .empty;
    text.print(builder.allocator, "SECTIONS {{ .text.nilu_running : ALIGN(4096) {{ . = . + {d};\n", .{layout.arm_shift}) catch @panic("OOM");
    for (groups, 0..) |group, index| {
        if (index != 0) {
            if (layout.group_page) text.appendSlice(builder.allocator, "  . = ALIGN(4096);\n") catch @panic("OOM");
            text.print(builder.allocator, "  . = . + {d};\n", .{layout.group_gap}) catch @panic("OOM");
        }
        for (group) |name| text.print(builder.allocator, "  *(SORT_BY_NAME(.text.{s} .text..L{s}))\n", .{ name, name }) catch @panic("OOM");
    }
    text.appendSlice(builder.allocator, "} } INSERT AFTER .text;\n") catch @panic("OOM");
    return builder.addWriteFiles().add("layout.ld", text.items);
}

/// The library and the command for one target: the same two definitions
/// whether they are installed for the host or built for a release. A release
/// is stripped: a handed-out binary carries no debug information, and so no
/// separate .pdb on Windows.
fn artifacts(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, layout: Layout) Artifacts {
    const library = builder.addLibrary(.{
        .name = "nilu",
        .use_llvm = true,
        .linkage = .static,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("src/c_api.zig"),
            .pic = true,
            .target = target,
            .optimize = optimize,
            .strip = strip,
            // Every instruction's arm would save and restore it: three of its
            // dozen-odd machine instructions. Debug keeps it.
            .omit_frame_pointer = optimize != .debug,
            .imports = &.{.{ .name = "layout", .module = layoutModule(builder, layout) }},
        }),
    });
    library.bundle_compiler_rt = true;
    const command = builder.addExecutable(.{
        .name = "nilu",
        .root_module = builder.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .strip = strip }),
    });
    command.root_module.addCSourceFile(.{ .file = builder.path("cli/nilu.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    command.root_module.addIncludePath(builder.path("include"));
    command.root_module.linkLibrary(library);
    // The arms have a section of their own on every target (src/vm.zig);
    // only an ELF linker takes a script, which places the rest of the
    // running code too.
    library.link_function_sections = true;
    if (target.result.ofmt == .elf) {
        command.link_function_sections = true;
        command.setLinkerScript(layoutScript(builder, layout));
    }
    return .{ .library = library, .command = command };
}

/// NILU_VERSION as the header defines it, or null when the header or the
/// definition is missing; the release directories are named after it.
fn headerVersion(builder: *std.Build) ?[]const u8 {
    // Read while configuring, so the configure step is repeated when the header changes.
    builder.dependOnFileContents(builder.path("include/nilu.h"));
    const header = builder.root.join(builder.allocator, "include/nilu.h") catch @panic("OOM");
    const text = header.root_dir.handle.readFileAlloc(builder.graph.io, header.sub_path, builder.allocator, .limited(1 << 20)) catch return null;
    const marker = "#define NILU_VERSION \"";
    const start = (std.mem.indexOf(u8, text, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    if (end == start) return null;
    return text[start..end];
}

fn nodeStep(builder: *std.Build, name: []const u8, description: []const u8, script: []const u8) *std.Build.Step.Run {
    const command = builder.addSystemCommand(&.{ "node", script });
    command.has_side_effects = true;
    command.addPassthruArgs();
    builder.step(name, description).dependOn(&command.step);
    return command;
}
