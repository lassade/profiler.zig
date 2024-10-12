// note: it kinda works, but isn't the source of the problem
// File.writeAll and File.sync are the the bigest output bottle-neck
//
// at the very least this will give smaller traces

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Timer = std.time.Timer;
const Thread = std.Thread;
const Id = Thread.Id;

var time_scale: f64 = 1.0;

fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

const Zone = struct {
    // src: SourceLocation,
    name: [:0]const u8,
    depth: u32,
    time_begin: u64,
    time_end: u64,
};

const WireType = enum(u3) {
    varint,
    i64,
    len,
    sgroup, // DEPRECATED
    egroup, // DEPRECATED
    i32,
};
const VarInt = struct {
    fn len(v: u64) usize {
        if (v == 0) return 1;
        var x = v;
        var c: usize = 0;
        while (x != 0) : (c += 1) x >>= 7;
        return c;
    }
    fn encode(w: anytype, v: u64) !void {
        if (v == 0) {
            try w.writeByte(0);
            return;
        }
        var x = v;
        while (x != 0) {
            const part: u8 = @as(u7, @truncate(x));
            x >>= 7;
            const next: u8 = @intFromBool(x != 0);
            try w.writeByte(next << 7 | part);
        }
    }
};
fn tag(comptime field_num: u61, comptime wire_type: WireType) u64 {
    const wire = @intFromEnum(wire_type);
    return @as(u64, wire) | @as(u64, field_num) << 3;
}
fn varint(comptime v: u64) [VarInt.len(v)]u8 {
    return comptime blk: {
        var b = std.BoundedArray(u8, VarInt.len(v)){};
        VarInt.encode(b.writer(), v);
        assert(b.len == b.buffer.len);
        const out = b.buffer;
        break :blk out;
    };
}
// const ChromeTraceEvent = struct {
//     fn len(z: *const Zone) usize {
//         return (1 + VarInt.len(z.name.len) + z.name.len) + (1 + 8) + (0) + (1 + 4) + (1 + 8);
//     }
//     fn encode(writer: anytype, z: *const Zone) !void {
//         try Tag.encode(writer, 1, .len); // name +1
//         try VarInt.encode(writer, z.name.len);
//         try writer.writeAll(z.name);

//         try Tag.encode(writer, 2, .i64); // timestamp +1
//         try writer.writeAll(std.mem.asBytes(&z.time_begin)); // +8

//         // try Tag.encode(writer, 3, .varint); // phase +1
//         // try writer.writeByte('X'); // +1
//         // try Tag.encode(writer, 3, .i32); // phase +1
//         // const phase: u32 = 'X';
//         // try writer.writeAll(std.mem.asBytes(&phase)); // +4

//         try Tag.encode(writer, 4, .i32); // thread_id +1
//         const tid: u32 = 1;
//         try writer.writeAll(std.mem.asBytes(&tid)); // +4

//         try Tag.encode(writer, 5, .i64); // duration +1
//         const dur = z.time_end - z.time_begin;
//         try writer.writeAll(std.mem.asBytes(&dur)); // +8
//     }
// };

// test {
//     // assmume little endian
//     comptime if (builtin.cpu.arch.endian() != .little) unreachable;

//     const pb = try std.fs.cwd().createFile("profile.pb", .{});
//     defer pb.close();

//     var b = std.ArrayList(u8).init(std.testing.allocator);
//     const writer = b.writer();
//     defer b.deinit();

//     var z = Zone{
//         .depth = 0,
//         .name = "",
//         .time_begin = 0,
//         .time_end = 0,
//     };

//     for (&[_][:0]const u8{ "begin", "middle", "end" }) |name| {
//         z.name = name;
//         defer z.time_begin += 100;
//         z.time_end += 100;

//         // count
//         const cte = ChromeTraceEvent.len(&z);
//         const ceb = 1 + VarInt.len(cte) + cte;
//         const tp = 1 + VarInt.len(ceb) + ceb;

//         try Tag.encode(writer, 1, .len); // TracePacket
//         try VarInt.encode(writer, tp);

//         try Tag.encode(writer, 5, .len); // ChromeEventBundle +1
//         try VarInt.encode(writer, ceb); // +VarInt.len(ceb)

//         try Tag.encode(writer, 1, .len); // ChromeTraceEvent +1
//         try VarInt.encode(writer, cte); // +VarInt.len(cte)
//         try ChromeTraceEvent.encode(writer, &z); // +cte

//     }
//     try pb.writeAll(b.items);
// }

test {
    // assmume little endian
    comptime if (builtin.cpu.arch.endian() != .little) unreachable;

    const pb = try std.fs.cwd().createFile("profile.pb", .{});
    defer pb.close();

    var b = std.ArrayList(u8).init(std.testing.allocator);
    const writer = b.writer();
    defer b.deinit();

    // (VarInt.len(tag(1, .varint)) + 1) + // uuid
    // (VarInt.len(tag(2, .len)) + VarInt.len(name.len) + name.len) // name

    var z = Zone{
        .depth = 0,
        .name = "",
        .time_begin = 0,
        .time_end = 0,
    };
    time_scale = 1.0;

    // todo: TrackDescriptor isn't working at all, so you will see weird names
    // try TracePacket.TrackDescriptor.encode(writer, "mainThread", 1, 0);

    for (&[_][:0]const u8{ "begin", "middle", "end" }, 0..) |name, id| {
        z.name = name;
        defer z.time_begin += 100;
        z.time_end += 100;

        try TracePacket.TrackEvent.encode(writer, @intCast(id), 1, z.name, z.time_begin, .slice_begin);
        try TracePacket.TrackEvent.encode(writer, @intCast(id), 1, z.name, z.time_end, .slice_end);
    }
    try pb.writeAll(b.items);
}

const TracePacket = struct {
    const TrackDescriptor = struct {
        fn encode(writer: anytype, name: []const u8, tid: u7, pid: u7) !void {
            const pd = // ProcessDescriptor
                (VarInt.len(tag(1, .varint)) + 1) + // pid
                (VarInt.len(tag(6, .len)) + VarInt.len(name.len) + name.len) // process_name
            ;
            // const thd = // ProcessDescriptor
            //     (VarInt.len(tag(1, .varint)) + 1) + // pid
            //     (VarInt.len(tag(2, .varint)) + 1) + // tid
            //     (VarInt.len(tag(5, .len)) + VarInt.len(name.len) + name.len) // process_name
            // ;
            const te = // TrackEvent size
                (VarInt.len(tag(1, .varint)) + 1) + // uuid
                (VarInt.len(tag(2, .len)) + VarInt.len(name.len) + name.len) + // name
                (VarInt.len(tag(3, .len)) + VarInt.len(pd) + pd) // process (ProcessDescriptor)
            // (VarInt.len(tag(4, .len)) + VarInt.len(thd) + thd) // thread (ThreadDescriptor)
            ;
            const tp = // TracePacket size
                (VarInt.len(tag(11, .len)) + VarInt.len(te) + te) // TrackDescriptor
            ;

            try VarInt.encode(writer, tag(1, .len)); // TracePacket
            try VarInt.encode(writer, tp);
            {
                try VarInt.encode(writer, tag(11, .len)); // TrackDescriptor
                try VarInt.encode(writer, te); // +VarInt.len(ceb)
                {
                    try VarInt.encode(writer, tag(1, .varint)); // uuid
                    try writer.writeByte(tid);
                    try VarInt.encode(writer, tag(2, .len)); // name
                    try VarInt.encode(writer, name.len);
                    try writer.writeAll(name);
                    try VarInt.encode(writer, tag(3, .len)); // process (ProcessDescriptor)
                    try VarInt.encode(writer, pd);
                    {
                        try VarInt.encode(writer, tag(1, .varint)); // pid
                        try writer.writeByte(pid);
                        try VarInt.encode(writer, tag(6, .len)); // process_name
                        try VarInt.encode(writer, name.len);
                        try writer.writeAll(name);
                    }
                    // try VarInt.encode(writer, tag(4, .len)); // thread (ThreadDescriptor)
                    // try VarInt.encode(writer, thd);
                    // {
                    //     try VarInt.encode(writer, tag(1, .varint)); // pid
                    //     try writer.writeByte(pid);
                    //     try VarInt.encode(writer, tag(2, .varint)); // tid
                    //     try writer.writeByte(tid);
                    //     try VarInt.encode(writer, tag(5, .len)); // thread_name
                    //     try VarInt.encode(writer, name.len);
                    //     try writer.writeAll(name);
                    // }
                }
            }
        }
    };
    const TrackEvent = struct {
        const Type = enum(u7) {
            unspecified = 0,
            slice_begin = 1,
            slice_end = 2,
            instant = 3,
            counter = 4,
        };
        fn encode(writer: anytype, seq: u32, tid: u7, name: []const u8, ts: u64, ty: Type) !void {
            const te = // TrackEvent size
                (VarInt.len(tag(23, .len)) + VarInt.len(name.len) + name.len) + // name
                (VarInt.len(tag(9, .len)) + 1) + // type
                (VarInt.len(tag(11, .varint)) + 1) // track_uuid
            ;
            const tp = // TracePacket size
                (VarInt.len(tag(8, .len)) + @sizeOf(u64)) + // timestamp
                (VarInt.len(tag(10, .i32)) + @sizeOf(u32)) + // trusted_packet_sequence_id
                (VarInt.len(tag(11, .len)) + VarInt.len(te) + te) // TrackEvent
            ;

            try VarInt.encode(writer, tag(1, .len)); // TracePacket
            try VarInt.encode(writer, tp);

            try VarInt.encode(writer, tag(8, .i64)); // timestamp
            // try writer.writeInt(u64, ts, .little);
            try writer.writeInt(u64, @intFromFloat(@as(f64, @floatFromInt(ts)) * time_scale), .little);

            try VarInt.encode(writer, tag(10, .i32)); // trusted_packet_sequence_id
            try writer.writeInt(u32, seq, .little);

            try VarInt.encode(writer, tag(11, .len)); // TrackEvent
            try VarInt.encode(writer, te); // +VarInt.len(ceb)

            try VarInt.encode(writer, tag(23, .len)); // name
            try VarInt.encode(writer, name.len);
            try writer.writeAll(name);

            try VarInt.encode(writer, tag(9, .varint)); // type
            try writer.writeByte(@intFromEnum(ty));

            try VarInt.encode(writer, tag(11, .varint)); // track_uuid
            try writer.writeByte(tid);
        }
    };
};
