const std = @import("std");
const build = std.build;

pub const cache = ".zigmod/deps";

pub fn addAllTo(exe: *build.LibExeObjStep) void {
    @setEvalBranchQuota(1_000_000);
    for (packages) |pkg| {
        exe.addPackage(pkg);
    }
    if (c_include_dirs.len > 0 or c_source_files.len > 0) {
        exe.linkLibC();
    }
    for (c_include_dirs) |dir| {
        exe.addIncludeDir(dir);
    }
    inline for (c_source_files) |fpath| {
        exe.addCSourceFile(fpath[1], @field(c_source_flags, fpath[0]));
    }
    for (system_libs) |lib| {
        exe.linkSystemLibrary(lib);
    }
}

fn get_flags(comptime index: usize) []const u8 {
    return @field(c_source_flags, _paths[index]);
}

pub const _ids = .{
    "2juqrn1feu1efgary5qdxq5claq8au5v8j31wpkynzfh82f8",
    "i1z0p8v0459f4paad9vphk5osu8cwvnnv1kesqencbpbl6u3",
};

pub const _paths = .{
    "",
    "/v/git/github.com/gruebite/zzz/commit-69b9cb9/",
};

pub const package_data = struct {
    pub const _i1z0p8v0459f4paad9vphk5osu8cwvnnv1kesqencbpbl6u3 = build.Pkg{ .name = "zzz", .path = cache ++ "/v/git/github.com/gruebite/zzz/commit-69b9cb9/src/main.zig", .dependencies = &[_]build.Pkg{ } };
};

pub const packages = &[_]build.Pkg{
    package_data._i1z0p8v0459f4paad9vphk5osu8cwvnnv1kesqencbpbl6u3,
};

pub const pkgs = struct {
    pub const zzz = packages[0];
};

pub const c_include_dirs = &[_][]const u8{
};

pub const c_source_flags = struct {
};

pub const c_source_files = &[_][2][]const u8{
};

pub const system_libs = &[_][]const u8{
};

