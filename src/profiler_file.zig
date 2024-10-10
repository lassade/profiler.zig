const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const SourceLocation = std.builtin.SourceLocation;
const Instant = std.time.Instant;
const Thread = std.Thread;

pub const enabled = true;

pub const max_threads = 8;

fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

const Zone = struct {
    // src: SourceLocation,
    name: [:0]const u8,
    depth: u64,
    t_begin: Instant,
    t_end: Instant,
};

const ThreadFrame = struct {
    depth: u16 = 0,
    zones: std.MultiArrayList(Zone) = .{},
};

const Frame = struct {
    // t_begin: Instant,
    // t_end: Instant,
    threads: std.MultiArrayList(struct { tid: u64, tf: ThreadFrame }),

    fn find(self: *@This(), tid: u64) *ThreadFrame {
        const s = self.threads.slice();
        const tids = s.items(.tid);
        const tfs = s.items(.tf);
        return &tfs.ptr[
            std.mem.indexOfScalar(u64, tids, tid) orelse blk: {
                assert(self.threads.len < self.threads.capacity);
                const i = self.threads.len;
                self.threads.len += 1;
                tids.ptr[i] = tid;
                tfs.ptr[i] = .{};
                break :blk i;
            }
        ];
    }
};

var allocator: Allocator = undefined;
pub var t_startup: Instant = undefined;
pub var frame_index: u64 = undefined;
pub var frame: Frame = undefined;
var file: File = undefined;
var file_writer: File.Writer = undefined;

const ZoneScope = struct {
    depth: u64,
    tid: u64,
    // src: SourceLocation,
    name: [:0]const u8,
    t_begin: Instant,

    pub fn end(z: @This()) void {
        const t_end = Instant.now() catch unreachable;
        assert(z.tid == Thread.getCurrentId()); // ended in the same thread it started
        const t = frame.find(z.tid);
        assert(z.depth + 1 == t.depth); // sane begin/end
        t.depth -= 1;
        t.zones.append(
            allocator,
            Zone{
                .depth = z.depth,
                // .src = z.src,
                .name = z.name,
                .t_begin = z.t_begin,
                .t_end = t_end,
            },
        ) catch unreachable;
    }
};

const InitOptions = struct {
    allocator: Allocator = std.heap.page_allocator,
    file_name: []const u8 = "profile.json",
};

pub fn init(opt: InitOptions) void {
    allocator = opt.allocator;
    t_startup = Instant.now() catch unreachable;

    // frame.t_begin = t_startup;
    // frame.t_end = t_startup;
    frame.threads = .{};
    frame.threads.ensureTotalCapacity(allocator, max_threads) catch unreachable;
    frame_index = 0;

    file = std.fs.cwd().createFile(opt.file_name, .{}) catch unreachable;
    file_writer = file.writer();
    file_writer.writeAll(
        \\[
        \\  { "name": "init", "ph": "i", "pid": 0, "tid": 1, "ts": 0 },
        \\
    ) catch unreachable;
}

pub fn deinit() void {
    const t_now = Instant.now() catch unreachable;

    file_writer.print(
        \\  {{ "name": "deinit", "ph": "i", "pid": 0, "tid": 1, "ts": {} }}
        \\]
        \\
    , .{
        @as(f64, @floatFromInt(t_now.since(t_startup))) / 1000.0,
    }) catch unreachable;
    file.close();

    for (frame.threads.items(.tf)) |*tf| tf.zones.deinit(allocator);
    frame.threads.deinit(allocator);
}

pub fn frameMark() void {
    frame_index +%= 1;

    const t_now = Instant.now() catch unreachable;

    file_writer.print(
        \\  {{ "name": "frameMark", "ph": "i", "pid": 0, "tid": 1, "ts": {} }},
        \\
    , .{
        @as(f64, @floatFromInt(t_now.since(t_startup))) / 1000.0,
    }) catch unreachable;

    for (frame.threads.items(.tf), 1..) |*tf, tid| {
        const s = tf.zones.slice();

        var i = s.len -% 1;
        while (i < s.len) : (i -%= 1) {
            const t_begin = s.items(.t_begin).ptr[i];
            const t_end = s.items(.t_end).ptr[i];

            file_writer.print(
                \\  {{ "name": "{s}", "ph": "X", "pid": 0, "tid": {}, "ts": {}, "dur": {} }},
                \\
            , .{
                s.items(.name).ptr[i],
                tid,
                @as(f64, @floatFromInt(t_begin.since(t_startup))) / 1000.0,
                @as(f64, @floatFromInt(t_end.since(t_begin))) / 1000.0,
            }) catch unreachable;
        }

        // clear zones in all threads but kee
        tf.zones.len = 0;
    }

    const t_end = Instant.now() catch unreachable;
    file_writer.print(
        \\  {{ "name": "dump", "ph": "X", "pid": 0, "tid": 1, "ts": {}, "dur": {} }},
        \\
    , .{
        @as(f64, @floatFromInt(t_now.since(t_startup))) / 1000.0,
        @as(f64, @floatFromInt(t_end.since(t_now))) / 1000.0,
    }) catch unreachable;
}

pub fn begin(_: SourceLocation, name: [:0]const u8) ZoneScope {
    const tid = Thread.getCurrentId();
    const tf = frame.find(tid);
    const depth = tf.depth;
    tf.depth += 1;
    return ZoneScope{
        .depth = depth,
        .tid = tid,
        // .src = src,
        .name = name,
        .t_begin = Instant.now() catch unreachable,
    };
}
