const std = @import("std");

const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The package version in build.zig.zon is the only source of the library version.
    const version = std.SemanticVersion.parse(zon.version) catch |err| {
        std.debug.panic("invalid version '{s}' in build.zig.zon: {t}", .{ zon.version, err });
    };
    const options = b.addOptions();
    options.addOption([:0]const u8, "version", zon.version);

    const slsk = b.addModule("slsk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    slsk.addOptions("build_options", options);

    const lib_static = addCLibrary(b, .{
        .slsk = slsk,
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .version = version,
    });
    const lib_shared = addCLibrary(b, .{
        .slsk = slsk,
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic,
        .version = version,
    });
    b.installArtifact(lib_static);
    b.installArtifact(lib_shared);

    const test_step = b.step("test", "Run unit tests and C tests");

    const slsk_tests = b.addTest(.{ .root_module = slsk });
    test_step.dependOn(&b.addRunArtifact(slsk_tests).step);

    const c_api_tests = b.addTest(.{ .root_module = lib_static.root_module });
    test_step.dependOn(&b.addRunArtifact(c_api_tests).step);

    // Link the smoke test to each library, so that both export the C symbols.
    const c_smoke_libraries = [_]struct { name: []const u8, library: *std.Build.Step.Compile }{
        .{ .name = "c-smoke-static", .library = lib_static },
        .{ .name = "c-smoke-shared", .library = lib_shared },
    };
    for (c_smoke_libraries) |entry| {
        const c_smoke = addCTest(b, .{
            .name = entry.name,
            .source = b.path("tests/c/smoke.c"),
            .library = entry.library,
            .target = target,
            .optimize = optimize,
        });
        const c_smoke_run = b.addRunArtifact(c_smoke);
        c_smoke_run.addArg(zon.version);
        c_smoke_run.expectExitCode(0);
        test_step.dependOn(&c_smoke_run.step);
    }

    const fmt_step = b.step("fmt", "Check the formatting of Zig source files");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = b.pathList(&.{ "build.zig", "build.zig.zon", "src" }),
        .check = true,
    }).step);
}

const CLibraryOptions = struct {
    slsk: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    version: std.SemanticVersion,
};

fn addCLibrary(b: *std.Build, options: CLibraryOptions) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = "slsk",
        .linkage = options.linkage,
        .version = options.version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "slsk", .module = options.slsk },
            },
        }),
    });
    library.installHeader(b.path("include/slsk.h"), "slsk.h");
    return library;
}

const CTestOptions = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
};

fn addCTest(b: *std.Build, options: CTestOptions) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{
        .file = options.source,
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    module.addIncludePath(b.path("include"));
    module.linkLibrary(options.library);
    return b.addExecutable(.{ .name = options.name, .root_module = module });
}
