const std = @import("std");
const zzz = @import("zzz");

pub const Config = struct {
    allocator: *std.mem.Allocator,
    raw: []u8,
    vhosts: std.StringHashMap(VHost),

    pub const VHost = struct {
        root: []const u8,

        fn init(node: *const zzz.ZNode) !VHost {
            var root: ?[]const u8 = null;

            var maybe_child = node.nextChild(null);
            while (maybe_child) |child| : (maybe_child = node.nextChild(child)) {
                if (child.value != .String) return error.BadConfigUnknownVHostNodeType;
                if (std.mem.eql(u8, child.value.String, "root")) {
                    root = try extractSingleChildString(child);
                } else {
                    return error.BadConfigUnknownVHostChild;
                }
            }

            return VHost{
                .root = root orelse return error.BadConfigVHostMissingRoot,
            };
        }

        fn extractSingleChildString(node: *const zzz.ZNode) ![]const u8 {
            var child = node.nextChild(null) orelse return error.BadConfigMissingChild;
            if (child.value != .String) return error.BadConfigUnknownChildType;
            if (node.nextChild(child) != null) return error.BadConfigMultipleChildren;
            return child.value.String;
        }
    };

    // Takes ownership of `raw'; will free it with `allocator' unless this returns an error.
    // Further uses `allocator' internally.
    pub fn init(allocator: *std.mem.Allocator, raw: []u8) !Config {
        var vhosts = std.StringHashMap(VHost).init(allocator);
        errdefer vhosts.deinit();

        var tree = zzz.ZTree(1, 100){};
        var root = try tree.appendText(raw);

        var maybe_node = root.nextChild(null);
        while (maybe_node) |node| : (maybe_node = root.nextChild(node)) {
            switch (node.value) {
                .String => |vhost| try vhosts.put(vhost, try VHost.init(node)),
                else => return error.BadConfigUnknownNodeType,
            }
        }

        return Config{
            .allocator = allocator,
            .raw = raw,
            .vhosts = vhosts,
        };
    }

    pub fn deinit(self: *Config) void {
        self.vhosts.deinit();
        self.allocator.free(self.raw);
    }
};
