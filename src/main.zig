const std = @import("std");
const ChildProcess = std.process.Child;
const processUtil = @import("./processUtil.zig");

const LogStream = struct { eventMessage: []const u8, subsystem: []const u8, processID: c_int, timestamp: []const u8 };

const AppEvent = struct { isForeground: bool, timeString: []const u8, path: []const u8, bundleId: ?[]const u8 };
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

fn emitCsv(event: AppEvent) !void {
    // if (!event.isForeground) return;

    if (!event.isForeground and std.mem.eql(u8, event.path, "/System/Library/CoreServices/loginwindow.app")) {
        try stdout.print("{s},{s}\n", .{ event.timeString, "screen lock" });
        return;
    }

    try stdout.print("{s},{s},\"{s}\",{s}\n", .{ event.timeString, if (event.isForeground) "application" else "popup", event.path, if (event.bundleId) |bundleId| bundleId else "(null)" });
}

fn emitJson(event: AppEvent) !void {
    var jsonWriter = std.json.writeStream(stdout, .{});
    // if (!event.isForeground) return;

    if (!event.isForeground and std.mem.eql(u8, event.path, "/System/Library/CoreServices/loginwindow.app")) {
        try jsonWriter.write(.{ .time = event.timeString, .event = "screen lock" });
        try stdout.writeByte('\n');

        return;
    }

    try jsonWriter.write(.{ .time = event.timeString, .event = if (event.isForeground) "application" else "popup", .path = event.path, .bundleId = if (event.bundleId) |bundleId| bundleId else null });
    try stdout.writeByte('\n');
}

var shouldEmitAsJson = false;
fn emit(event: AppEvent) !void {
    if (shouldEmitAsJson) {
        try emitJson(event);
    } else {
        try emitCsv(event);
    }
}

pub fn main() !void {
    var allocatorBacking = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = allocatorBacking.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            shouldEmitAsJson = true;
        }
    }

    const filter = "subsystem == 'com.apple.processmanager' AND eventMessage BEGINSWITH 'SETFRONT: pid='";

    var proc = ChildProcess.init(&[_][]const u8{ "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", filter }, allocator);
    proc.stdout_behavior = ChildProcess.StdIo.Pipe;
    proc.stderr_behavior = ChildProcess.StdIo.Ignore;
    try proc.spawn();

    const bundleIdMap_maxItems = 10;
    var bundleIdMap = std.StringArrayHashMap([]const u8).init(allocator);
    try bundleIdMap.ensureTotalCapacity(bundleIdMap_maxItems);

    defer bundleIdMap.deinit();

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

        var evtObject = AppEvent{ .isForeground = std.mem.indexOf(u8, parsed.value.eventMessage, "foreground=1") != null, .timeString = parsed.value.timestamp, .path = undefined, .bundleId = null };

        const prefix = "SETFRONT: pid=";
        const startIdx = std.mem.indexOf(u8, parsed.value.eventMessage, prefix).? + prefix.len;
        const endIdx = std.mem.indexOfPos(u8, parsed.value.eventMessage, startIdx, " ").?;

        const pidStr = parsed.value.eventMessage[startIdx..endIdx];
        const pid = try std.fmt.parseInt(u22, pidStr, 10);

        if (pid == 0) continue;

        // Strip macOS package path from image path
        const imagePath = try processUtil.image_path_of_pid(allocator, pid);
        defer allocator.free(imagePath);

        if (std.mem.lastIndexOf(u8, imagePath, "/Contents/MacOS/")) |idx| {
            evtObject.path = imagePath[0..idx];

            if (bundleIdMap.get(imagePath)) |bundleId| {
                // std.debug.print("Got cache for {s} -> {s}\n", .{ imagePath, bundleId });

                evtObject.bundleId = bundleId;
            } else {
                if (bundleIdMap.count() == bundleIdMap_maxItems) {
                    // std.debug.print("Reached capacity for cached bundle ids\n", .{});
                    var iterator = bundleIdMap.iterator();
                    while (iterator.next()) |entry| {
                        // std.debug.print("Freeing: {s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                        allocator.free(entry.key_ptr.*);
                        allocator.free(entry.value_ptr.*);
                    }
                    bundleIdMap.clearRetainingCapacity();
                }

                const plistPath = try std.fmt.allocPrint(allocator, "{s}/Contents/Info.plist", .{imagePath[0..idx]});
                defer allocator.free(plistPath);

                if (ChildProcess.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "/usr/bin/defaults", "read", plistPath, "CFBundleIdentifier" },
                    // .argv = &[_][]const u8{ "/usr/bin/mdls", "-name", "kMDItemCFBundleIdentifier", "-r", imagePath[0..idx] },
                })) |mdlsResult| {
                    defer allocator.free(mdlsResult.stdout);
                    defer allocator.free(mdlsResult.stderr);

                    if (mdlsResult.stderr.len == 0) {
                        const key = try allocator.dupe(u8, imagePath);
                        const value = try allocator.dupe(u8, std.mem.trimRight(u8, mdlsResult.stdout, "\n"));

                        evtObject.bundleId = value;
                        try bundleIdMap.put(key, value);
                    }
                } else |_| {}
            }
        } else {
            evtObject.path = imagePath;
        }

        try emit(evtObject);
    }
}
