const std = @import("std");

const Entry = struct {
    mime_type: []const u8,
    extensions: []const []const u8,
};

const entries: []const Entry = comptime blk: {
    @setEvalBranchQuota(100000);
    var es: []const Entry = &[_]Entry{};

    const data = @embedFile("mimes");
    var it = std.mem.tokenize(data, "\n");
    while (it.next()) |line| {
        var lit = std.mem.tokenize(line, " \t");

        const mime_type = lit.next() orelse continue;
        var exts: []const []const u8 = &[_][]const u8{};
        while (lit.next()) |ext| {
            exts = exts ++ &[_][]const u8{ext};
        }

        es = es ++ &[_]Entry{.{
            .mime_type = mime_type,
            .extensions = exts,
        }};
    }

    break :blk es;
};

pub fn lookup(extension: []const u8) ?[]const u8 {
    for (entries) |entry| {
        for (entry.extensions) |ext| {
            if (std.ascii.eqlIgnoreCase(extension, ext)) {
                return entry.mime_type;
            }
        }
    }
    return null;
}
