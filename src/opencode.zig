const std = @import("std");

/// OpenCode's inline config is JSONC. Add our plugin in that final config layer
/// so global/project config, custom paths, and existing plugins keep their origin.
pub fn withPlugin(alloc: std.mem.Allocator, input: []const u8, plugin: []const u8) ![]const u8 {
    const source = if (std.mem.trim(u8, input, " \t\r\n").len == 0) "{}" else input;
    const json = try stripJsonc(alloc, source);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    const parse_alloc = parsed.arena.allocator();
    var config = parsed.value;
    if (config != .object) return error.InvalidConfig;
    if (!config.object.contains("plugin")) try config.object.put(parse_alloc, "plugin", .{ .array = std.array_list.Managed(std.json.Value).init(parse_alloc) });
    const plugins = config.object.getPtr("plugin").?;
    if (plugins.* != .array) return error.InvalidPlugins;
    for (plugins.array.items) |item| {
        const spec = if (item == .array and item.array.items.len > 0) item.array.items[0] else item;
        if (spec == .string and std.mem.eql(u8, spec.string, plugin))
            return std.json.Stringify.valueAlloc(alloc, config, .{});
    }
    try plugins.array.append(.{ .string = plugin });
    return std.json.Stringify.valueAlloc(alloc, config, .{});
}

fn stripJsonc(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, source);
    errdefer alloc.free(out);
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == '"') {
            i = stringEnd(out, i);
        } else if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '*') {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) out[i] = ' ';
            if (i + 1 >= out.len) return error.UnterminatedComment;
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
        } else i += 1;
    }
    i = 0;
    while (i < out.len) {
        if (out[i] == '"') {
            i = stringEnd(out, i);
        } else {
            if (out[i] == ',') {
                var next = i + 1;
                while (next < out.len and std.ascii.isWhitespace(out[next])) : (next += 1) {}
                var previous = i;
                while (previous > 0 and std.ascii.isWhitespace(out[previous - 1])) : (previous -= 1) {}
                const has_value = previous > 0 and std.mem.indexOfScalar(u8, "[{,:", out[previous - 1]) == null;
                if (has_value and next < out.len and (out[next] == '}' or out[next] == ']')) out[i] = ' ';
            }
            i += 1;
        }
    }
    return out;
}

fn stringEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return i + 1;
        if (text[i] == '\\' and i + 1 < text.len) i += 1;
    }
    return i;
}

test "inline config retains plugins, options, comments in strings and runtime variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try withPlugin(alloc,
        \\{ // custom config
        \\  "model": "openrouter/z-ai/glm-5.3-flash",
        \\  "plugin": ["./user.js", ["user-plugin", {"url": "https://x/*keep*/",}],],
        \\  "provider": {"custom": {"options": {"apiKey": "{env:KEY}"}}}, /* end */
        \\}
    , "/opt/a 'quote'/plugin.mjs");
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    const config = parsed.value.object;
    try std.testing.expectEqualStrings("openrouter/z-ai/glm-5.3-flash", config.get("model").?.string);
    const plugins = config.get("plugin").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), plugins.len);
    try std.testing.expectEqualStrings("./user.js", plugins[0].string);
    try std.testing.expectEqualStrings("https://x/*keep*/", plugins[1].array.items[1].object.get("url").?.string);
    try std.testing.expectEqualStrings("/opt/a 'quote'/plugin.mjs", plugins[2].string);
    try std.testing.expectEqualStrings("{env:KEY}", config.get("provider").?.object.get("custom").?.object.get("options").?.object.get("apiKey").?.string);
}

test "invalid inline config fails without replacing user settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(error.InvalidConfig, withPlugin(alloc, "[]", "/plugin.mjs"));
    try std.testing.expectError(error.InvalidPlugins, withPlugin(alloc, "{\"plugin\":null}", "/plugin.mjs"));
    try std.testing.expectError(error.UnterminatedComment, withPlugin(alloc, "{/* unfinished", "/plugin.mjs"));
    try std.testing.expectError(error.SyntaxError, withPlugin(alloc, "{\"plugin\":[,]}", "/plugin.mjs"));
}

test "plugin injection is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const once = try withPlugin(alloc, "", "/plugin.mjs");
    try std.testing.expectEqualStrings(once, try withPlugin(alloc, once, "/plugin.mjs"));
}
