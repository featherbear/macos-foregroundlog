const std = @import("std");
const ChildProcess = std.process.Child;
const processUtil = @import("./processUtil.zig");

const LogStream = struct { eventMessage: []const u8, subsystem: []const u8, processID: c_int, timestamp: []const u8 };

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var allocatorBacking = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = allocatorBacking.allocator();

    const filter = "subsystem == 'com.apple.processmanager' AND eventMessage BEGINSWITH 'SETFRONT: pid='";

    var proc = ChildProcess.init(&[_][]const u8{ "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", filter }, allocator);
    proc.stdout_behavior = ChildProcess.StdIo.Pipe;
    proc.stderr_behavior = ChildProcess.StdIo.Ignore;
    try proc.spawn();

    // The max I've seen is around 5400 bytes
    var buffer: [8192]u8 = undefined;

    const reader = proc.stdout.?.reader();

    // Skip the first line: "Filtering the log data using ..."
    _ = try reader.readUntilDelimiter(&buffer, '\n');

    try stderr.print("Observing events...\n", .{});

    while (true) {
        const bytesRead = (try reader.readUntilDelimiter(&buffer, '\n')).len;
        const parsed = try std.json.parseFromSlice(LogStream, allocator, buffer[0..bytesRead], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const isForeground = std.mem.indexOf(u8, parsed.value.eventMessage, "foreground=1") != null;

        const prefix = "SETFRONT: pid=";
        const startIdx = std.mem.indexOf(u8, parsed.value.eventMessage, prefix).? + prefix.len;
        const endIdx = std.mem.indexOfPos(u8, parsed.value.eventMessage, startIdx, " ").?;

        const pidStr = parsed.value.eventMessage[startIdx..endIdx];
        const pid = try std.fmt.parseInt(u22, pidStr, 10);
        if (pid == 0) continue;

        // Strip macOS package path from image path
        const imagePath_volatile = processUtil.image_path_of_pid(pid);
        const imagePath = try allocator.alloc(u8, imagePath_volatile.len);
        defer allocator.free(imagePath);
        std.mem.copyForwards(u8, imagePath, imagePath_volatile);

        const lastIdx = std.mem.lastIndexOf(u8, imagePath, "/Contents/MacOS/") orelse imagePath.len;

        try stdout.print("{s},{s},{s}\n", .{
            if (isForeground) "application" else "popup",
            parsed.value.timestamp,
            imagePath[0..lastIdx],
        });
    }
}
