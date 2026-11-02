//! The header and the exports are one promise (ADR 0011): every `nilu_*`
//! function the header declares is exported from `c_api.zig` with the C
//! calling convention, and every such export is declared. Comments, string
//! literals and preprocessor lines (the `nilu_tostring` macro among them) are
//! not declarations. The C compiler's view of the types is `c_api_abi`'s job.
const std = @import("std");
const api = @import("c_api.zig");
const header = @embedFile("c-api-header");

/// The header with every comment, string literal and preprocessor line
/// blanked to spaces, so that only code can declare a name. Lengths are kept.
fn codeOnly(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, source);
    errdefer allocator.free(out);
    var i: usize = 0;
    var line_start = true;
    while (i < out.len) {
        if (line_start) {
            var j = i;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t')) j += 1;
            if (j < out.len and out[j] == '#') {
                // A directive runs to the end of its line, or past a backslash continuation.
                while (i < out.len) : (i += 1) {
                    if (out[i] == '\n') {
                        if (i > 0 and out[i - 1] == '\\') continue;
                        break;
                    }
                    out[i] = ' ';
                }
                if (i < out.len) i += 1;
                continue;
            }
            line_start = false;
        }
        if (std.mem.startsWith(u8, out[i..], "//")) {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (std.mem.startsWith(u8, out[i..], "/*")) {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            var closed = false;
            while (i < out.len) : (i += 1) {
                if (std.mem.startsWith(u8, out[i..], "*/")) {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                    closed = true;
                    break;
                }
                if (out[i] != '\n') out[i] = ' ';
            }
            if (!closed) return error.UnterminatedComment;
        } else if (out[i] == '"' or out[i] == '\'') {
            const quote = out[i];
            out[i] = ' ';
            i += 1;
            var closed = false;
            while (i < out.len) : (i += 1) {
                const c = out[i];
                if (c != '\n') out[i] = ' ';
                if (c == '\\' and i + 1 < out.len) {
                    i += 1;
                    if (out[i] != '\n') out[i] = ' ';
                } else if (c == quote) {
                    closed = true;
                    i += 1;
                    break;
                }
            }
            if (!closed) return error.UnterminatedLiteral;
        } else {
            if (out[i] == '\n') line_start = true;
            i += 1;
        }
    }
    return out;
}

fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Every `nilu_<name>(` in the code outside braces: a function declaration at
/// file scope. An `extern "C" {` block is file scope; a struct or enum body is
/// not, and a typedef of a function pointer names no export.
fn declaredNames(allocator: std.mem.Allocator, code: []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    errdefer names.deinit(allocator);
    // One flag per open brace: whether it hides declarations.
    var blocks: [64]bool = undefined;
    var depth: usize = 0;
    var hidden: usize = 0;
    var statement_start: usize = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        switch (code[i]) {
            '{' => {
                if (depth == blocks.len) return error.UnbalancedBraces;
                const before = std.mem.trimEnd(u8, code[statement_start..i], " \t\n");
                const linkage = std.mem.endsWith(u8, before, "extern");
                blocks[depth] = !linkage;
                if (!linkage) hidden += 1;
                depth += 1;
                statement_start = i + 1;
            },
            '}' => {
                if (depth == 0) return error.UnbalancedBraces;
                depth -= 1;
                if (blocks[depth]) hidden -= 1;
                statement_start = i + 1;
            },
            ';' => {
                if (hidden == 0) {
                    const statement = code[statement_start..i];
                    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, statement, " \t\n"), "typedef")) {
                        if (std.mem.indexOf(u8, statement, "nilu_")) |at| {
                            if (at == 0 or !isIdentifier(statement[at - 1])) {
                                var end = at;
                                while (end < statement.len and isIdentifier(statement[end])) end += 1;
                                var after = end;
                                while (after < statement.len and (statement[after] == ' ' or statement[after] == '\n')) after += 1;
                                if (after < statement.len and statement[after] == '(') {
                                    const entry = try names.getOrPut(allocator, statement[at..end]);
                                    if (entry.found_existing) return error.DuplicateDeclaration;
                                }
                            }
                        }
                    }
                }
                statement_start = i + 1;
            },
            else => {},
        }
    }
    if (depth != 0) return error.UnbalancedBraces;
    return names;
}

/// The `nilu_*` declarations of `c_api.zig` that are functions with the C
/// calling convention: what the library exports.
fn exportedNames() []const []const u8 {
    comptime {
        // One comparison per declaration; the C API has grown past the default.
        @setEvalBranchQuota(20000);
        var found: []const []const u8 = &.{};
        for (@typeInfo(api).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, "nilu_")) continue;
            const T = @TypeOf(@field(api, name));
            if (@typeInfo(T) != .@"fn") continue;
            if (@typeInfo(T).@"fn".attrs.@"callconv".eql(.c)) found = found ++ .{name};
        }
        return found;
    }
}

test "c_api_contract every exported nilu_ function is declared in the header and every declaration is exported" {
    const allocator = std.testing.allocator;
    const code = try codeOnly(allocator, header);
    defer allocator.free(code);
    var declared = try declaredNames(allocator, code);
    defer declared.deinit(allocator);
    const exported = comptime exportedNames();
    try std.testing.expect(exported.len > 0);
    var problems: usize = 0;
    for (exported) |name| {
        if (!declared.contains(name)) {
            std.debug.print("exported without a declaration: {s}\n", .{name});
            problems += 1;
        }
    }
    for (declared.keys()) |name| {
        var found = false;
        for (exported) |candidate| found = found or std.mem.eql(u8, candidate, name);
        if (!found) {
            std.debug.print("declared without an export: {s}\n", .{name});
            problems += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), problems);
    try std.testing.expectEqual(exported.len, declared.count());
}

test "c_api_contract the header scanner ignores comments literals macros and brace bodies" {
    const allocator = std.testing.allocator;
    const sample =
        \\/* nilu_in_comment(int) */
        \\#define nilu_in_macro(N, i) nilu_real(N, i, NULL)
        \\// nilu_in_line_comment();
        \\typedef int (*nilu_callback)(struct S *);
        \\typedef struct { int nilu_in_struct; } T;
        \\extern const char *nilu_text; /* "nilu_in_string(" */
        \\extern "C" {
        \\int nilu_real(struct S *N, int i, const char *s);
        \\void
        \\nilu_split (void);
        \\}
    ;
    const code = try codeOnly(allocator, sample);
    defer allocator.free(code);
    try std.testing.expectEqual(sample.len, code.len);
    var declared = try declaredNames(allocator, code);
    defer declared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), declared.count());
    try std.testing.expect(declared.contains("nilu_real"));
    try std.testing.expect(declared.contains("nilu_split"));
    try std.testing.expectError(error.UnterminatedComment, codeOnly(allocator, "int a; /* open"));
    try std.testing.expectError(error.UnterminatedLiteral, codeOnly(allocator, "char *s = \"open;"));
    const twice = try codeOnly(allocator, "int nilu_a(void); int nilu_a(int);");
    defer allocator.free(twice);
    try std.testing.expectError(error.DuplicateDeclaration, declaredNames(allocator, twice));
}
