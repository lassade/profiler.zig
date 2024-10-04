const std = @import("std");
const File = std.fs.File;
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Instant = std.time.Instant;
const Thread = std.Thread;

// todo: having to format, write to a file and lock is very slow

pub const enabled = true;

var t_startup: Instant = undefined;
var file: File = undefined;
var writer: File.Writer = undefined;
var mutex: Thread.Mutex = .{};

const InitOptions = struct {
    allocator: Allocator = undefined,
    file_name: []const u8 = "profile.json",
};

pub fn init(opt: InitOptions) void {
    t_startup = Instant.now() catch unreachable;
    file = std.fs.cwd().createFile(opt.file_name, .{}) catch unreachable;

    writer = file.writer();
    writer.writeAll(
        \\[
        \\  { "name": "init", "ph": "i", "pid": 0, "tid": 0, "ts": 0 },
        \\
    ) catch unreachable;
}

pub fn deinit() void {
    writer.writeAll(
        \\  { "name": "deinit", "ph": "i", "pid": 0, "tid": 0, "ts": 0 }
        \\]
        \\
    ) catch unreachable;
    file.close();

    file = undefined;
    writer = undefined;
}

pub fn frameMark() void {
    const tid = Thread.getCurrentId();
    const t_now = Instant.now() catch unreachable;
    writer.print(
        \\  {{ "name": "frameMark", "ph": "i", "pid": 0, "tid": {}, "ts": {} }},
        \\
    , .{
        tid,
        @as(f64, @floatFromInt(t_now.since(t_startup))) / 1000.0,
    }) catch unreachable;
}

const ZoneScope = struct {
    name: []const u8,
    tid: u64,
    t_begin: Instant,

    pub fn end(z: @This()) void {
        std.debug.assert(z.tid == Thread.getCurrentId()); // ended in the same thread it started
        const t_end = Instant.now() catch unreachable;
        mutex.lock();
        defer mutex.unlock();
        writer.print(
            \\  {{ "name": "{s}", "ph": "X", "pid": 0, "tid": {}, "ts": {}, "dur": {} }},
            \\
        , .{
            z.name,
            z.tid,
            @as(f64, @floatFromInt(z.t_begin.since(t_startup))) / 1000.0,
            @as(f64, @floatFromInt(t_end.since(z.t_begin))) / 1000.0,
        }) catch unreachable;
    }
};

pub fn begin(_: SourceLocation, name: [:0]const u8) ZoneScope {
    return ZoneScope{
        .name = name,
        .tid = Thread.getCurrentId(),
        .t_begin = Instant.now() catch unreachable,
    };
}

pub fn dump(_: []const u8) !void {
    try file.sync();
}
