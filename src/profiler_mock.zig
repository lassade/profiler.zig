const std = @import("std");
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Instant = std.time.Instant;
const Thread = std.Thread;

const ZoneScope = struct {
    pub fn end(_: @This()) void {}
};

const InitOptions = struct {
    allocator: Allocator = std.heap.page_allocator,
};

pub fn init(_: InitOptions) void {}

pub fn deinit() void {}

pub fn frameMark() void {}

pub fn begin(_: SourceLocation, _: [:0]const u8) ZoneScope {
    return .{};
}

pub fn dump(_: []const u8) !void {
    return error.Mock;
}
