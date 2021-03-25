const std = @import("std");
const zzz = @import("zzz");

pub const Config = struct {
    allocator: *std.mem.Allocator,
    raw: []u8,

    bind: []const u8,
    port: u16,
    vhosts: std.StringHashMap(VHost),

    pub const VHost = struct {
        root: []const u8,
        index: []const u8,

        fn init(node: *const zzz.ZNode) !VHost {
            var root: ?[]const u8 = null;
            var index: ?[]const u8 = null;

            var maybe_child = node.nextChild(null);
            while (maybe_child) |child| : (maybe_child = node.nextChild(child)) {
                if (child.value != .String) return error.BadConfigUnknownVHostNodeType;
                if (std.mem.eql(u8, child.value.String, "root")) {
                    root = try extractSingleChildString(child);
                } else if (std.mem.eql(u8, child.value.String, "index")) {
                    index = try extractSingleChildString(child);
                } else {
                    return error.BadConfigUnknownVHostChild;
                }
            }

            return VHost{
                .root = root orelse return error.BadConfigVHostMissingRoot,
                .index = index orelse "index.gmi",
            };
        }
    };

    // Takes ownership of `raw'; will free it with `allocator' unless this returns an error.
    // Further uses `allocator' internally.
    pub fn init(allocator: *std.mem.Allocator, raw: []u8) !Config {
        var vhosts = std.StringHashMap(VHost).init(allocator);
        errdefer vhosts.deinit();

        var bind: ?[]const u8 = null;
        var port: ?u16 = null;

        var tree = zzz.ZTree(1, 100){};
        var root = try tree.appendText(raw);

        var maybe_node = root.nextChild(null);
        while (maybe_node) |node| : (maybe_node = root.nextChild(node)) {
            switch (node.value) {
                .String => |key| {
                    if (std.mem.eql(u8, key, "bind")) {
                        bind = try extractSingleChildString(node);
                    } else if (std.mem.eql(u8, key, "port")) {
                        port = try std.fmt.parseUnsigned(u16, try extractSingleChildString(node), 10);
                    } else {
                        try vhosts.put(key, try VHost.init(node));
                    }
                },
                else => return error.BadConfigUnknownNodeType,
            }
        }

        return Config{
            .allocator = allocator,
            .raw = raw,

            .bind = bind orelse "127.0.0.1",
            .port = port orelse 4003,
            .vhosts = vhosts,
        };
    }

    pub fn deinit(self: *Config) void {
        self.vhosts.deinit();
        self.allocator.free(self.raw);
    }
};

fn extractSingleChildString(node: *const zzz.ZNode) ![]const u8 {
    var child = node.nextChild(null) orelse return error.BadConfigMissingChild;
    if (child.value != .String) return error.BadConfigUnknownChildType;
    if (node.nextChild(child) != null) return error.BadConfigMultipleChildren;
    return child.value.String;
}
