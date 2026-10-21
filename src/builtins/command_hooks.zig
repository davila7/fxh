//! Modified for fxh (fork of vercel-labs/fx): new file.
//!
//! Command hooks: external programs that run on PreToolUse and PostToolUse.
//! They are read from the `hooks` key of the user settings file
//! (`~/.fx/settings.json`) in the Claude Code hook settings shape:
//!
//!     { "hooks": { "PreToolUse": [ { "matcher": "shell|read_file",
//!         "hooks": [ { "type": "command", "command": "...", "timeout": 30 } ] } ] } }
//!
//! Each command gets the event as JSON on stdin and answers on stdout and
//! with its exit code. A command that fails, times out, or prints something
//! that is not JSON leaves the call as it was.

const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("../core/hooks/hooks.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

const max_settings_bytes = 4 * 1024 * 1024;
const max_command_output_bytes = hooks.Limits.output_bytes + 64 * 1024;
const default_timeout_seconds: u64 = 60;
const default_deny_reason = "Tool call was not allowed";
// Commands need a child process and a stdin writer thread; WASM builds have neither.
const supported = !builtin.single_threaded and builtin.os.tag != .wasi;

pub const pre_tool_use_handler_name = "fx.command_hooks.pre_tool_use";
pub const post_tool_use_handler_name = "fx.command_hooks.post_tool_use";

const Command = struct {
    command: []const u8,
    timeout_seconds: u64,
};

const Group = struct {
    /// Null matches every tool. Otherwise exact tool names separated by `|`.
    matcher: ?[]const u8,
    commands: []const Command,

    fn matches(self: Group, tool_name: []const u8) bool {
        const matcher = self.matcher orelse return true;
        var names = std.mem.splitScalar(u8, matcher, '|');
        while (names.next()) |name| {
            if (std.mem.eql(u8, std.mem.trim(u8, name, " "), tool_name)) return true;
        }
        return false;
    }
};

pub const CommandHooks = struct {
    arena: std.heap.ArenaAllocator,
    pre_tool_use: []const Group = &.{},
    post_tool_use: []const Group = &.{},

    pub fn deinit(self: *CommandHooks) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isEmpty(self: *const CommandHooks) bool {
        return self.pre_tool_use.len == 0 and self.post_tool_use.len == 0;
    }

    /// Must run before the lifecycle runtime is frozen. `self` must outlive it.
    pub fn register(self: *CommandHooks, runtime: *hooks.Runtime) !void {
        if (self.pre_tool_use.len > 0) {
            try runtime.registerPreToolUse(.{
                .name = pre_tool_use_handler_name,
                .ctx = self,
                .run = runPreToolUse,
            });
        }
        if (self.post_tool_use.len > 0) {
            try runtime.registerPostToolUse(.{
                .name = post_tool_use_handler_name,
                .ctx = self,
                .run = runPostToolUse,
            });
        }
    }
};

/// Loads the user's command hooks and registers them on `runtime`, which must
/// not be frozen yet. Returns the owned hooks, or null when none are set; the
/// caller frees them with `destroy` after the runtime is gone.
pub fn loadAndRegister(alloc: Allocator, runtime: *hooks.Runtime) !?*CommandHooks {
    if (comptime !supported) return null;
    var loaded = (try loadUserCommandHooks(alloc)) orelse return null;
    if (loaded.isEmpty()) {
        loaded.deinit();
        return null;
    }
    const owned = alloc.create(CommandHooks) catch |err| {
        loaded.deinit();
        return err;
    };
    owned.* = loaded;
    errdefer destroy(alloc, owned);
    try owned.register(runtime);
    debug_trace.logf("hooks", "command hooks: registered pre={d} post={d}", .{ owned.pre_tool_use.len, owned.post_tool_use.len });
    return owned;
}

pub fn destroy(alloc: Allocator, command_hooks: *CommandHooks) void {
    command_hooks.deinit();
    alloc.destroy(command_hooks);
}

/// Reads command hooks from the user settings file. Returns null when the
/// file or the `hooks` key is absent. A malformed `hooks` value is logged and
/// ignored rather than stopping fx.
pub fn loadUserCommandHooks(alloc: Allocator) !?CommandHooks {
    const home = io_mod.getenv("HOME") orelse return null;
    const path = try profile_paths.settingsPath(alloc, home);
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_settings_bytes) catch |err| {
        debug_trace.logf("hooks", "command hooks: settings read failed err={s}", .{@errorName(err)});
        return null;
    };
    defer alloc.free(bytes);
    return parseCommandHooks(alloc, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("hooks", "command hooks: ignored invalid hooks setting err={s}", .{@errorName(err)});
        return null;
    };
}

pub fn parseCommandHooks(alloc: Allocator, settings_json: []const u8) !?CommandHooks {
    var result = CommandHooks{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, settings_json, .{});
    const root_object = switch (root) {
        .object => |object| object,
        else => return error.InvalidHooksSetting,
    };
    const hooks_value = root_object.get("hooks") orelse {
        result.arena.deinit();
        return null;
    };
    const hooks_object = switch (hooks_value) {
        .object => |object| object,
        else => return error.InvalidHooksSetting,
    };
    if (hooks_object.get("PreToolUse")) |value| result.pre_tool_use = try parseGroups(arena, value);
    if (hooks_object.get("PostToolUse")) |value| result.post_tool_use = try parseGroups(arena, value);
    return result;
}

fn parseGroups(arena: Allocator, value: std.json.Value) ![]const Group {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidHooksSetting,
    };
    var groups: std.ArrayList(Group) = .empty;
    for (items) |item| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidHooksSetting,
        };
        const matcher: ?[]const u8 = if (object.get("matcher")) |matcher_value| switch (matcher_value) {
            .string => |text| if (text.len == 0 or std.mem.eql(u8, text, "*")) null else text,
            .null => null,
            else => return error.InvalidHooksSetting,
        } else null;
        const handlers = switch (object.get("hooks") orelse return error.InvalidHooksSetting) {
            .array => |array| array.items,
            else => return error.InvalidHooksSetting,
        };
        var commands: std.ArrayList(Command) = .empty;
        for (handlers) |handler| {
            const handler_object = switch (handler) {
                .object => |handler_object| handler_object,
                else => return error.InvalidHooksSetting,
            };
            const kind = switch (handler_object.get("type") orelse return error.InvalidHooksSetting) {
                .string => |text| text,
                else => return error.InvalidHooksSetting,
            };
            // Only command hooks are implemented; other types are skipped so a
            // settings file shared with other agents still loads.
            if (!std.mem.eql(u8, kind, "command")) continue;
            const command = switch (handler_object.get("command") orelse return error.InvalidHooksSetting) {
                .string => |text| text,
                else => return error.InvalidHooksSetting,
            };
            const timeout_seconds: u64 = if (handler_object.get("timeout")) |timeout| switch (timeout) {
                .integer => |seconds| if (seconds > 0) @intCast(seconds) else return error.InvalidHooksSetting,
                else => return error.InvalidHooksSetting,
            } else default_timeout_seconds;
            try commands.append(arena, .{ .command = command, .timeout_seconds = timeout_seconds });
        }
        if (commands.items.len == 0) continue;
        try groups.append(arena, .{ .matcher = matcher, .commands = commands.items });
    }
    return groups.items;
}

// Handlers return borrowed slices that the hook runtime copies before the
// next call on the same thread; calls in a parallel group run on separate
// threads, so the storage is per thread.
threadlocal var pre_result_storage: std.ArrayList(u8) = .empty;
threadlocal var post_result_storage: std.ArrayList(u8) = .empty;

fn storeResult(storage: *std.ArrayList(u8), text: []const u8) ![]const u8 {
    storage.clearRetainingCapacity();
    try storage.appendSlice(std.heap.c_allocator, text);
    return storage.items;
}

fn runPreToolUse(raw: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
    const self: *CommandHooks = @ptrCast(@alignCast(raw));
    return preToolUse(self, input) catch |err| {
        debug_trace.logf("hooks", "command hooks: PreToolUse failed open err={s}", .{@errorName(err)});
        return .continue_;
    };
}

fn preToolUse(self: *CommandHooks, input: hooks.PreToolUseInput) !hooks.PreToolUseAction {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var arguments_json = input.arguments_json;
    var rewritten = false;
    for (self.pre_tool_use) |group| {
        if (!group.matches(input.tool_name)) continue;
        for (group.commands) |command| {
            const payload = try eventJson(arena, "PreToolUse", input.invocation, input.call_id, input.tool_name, arguments_json, null, false);
            const result = runCommand(arena, command, input.invocation.scope.workspace_root, payload) orelse continue;
            switch (try parsePreToolUseResult(arena, result)) {
                .none => {},
                .deny => |reason| return .{ .fail = try storeResult(&pre_result_storage, reason) },
                .rewrite => |updated| {
                    arguments_json = updated;
                    rewritten = true;
                },
            }
        }
    }
    if (rewritten) return .{ .rewrite_arguments = try storeResult(&pre_result_storage, arguments_json) };
    return .continue_;
}

fn runPostToolUse(raw: *anyopaque, input: hooks.PostToolUseInput) hooks.HandlerError!hooks.PostToolUseAction {
    const self: *CommandHooks = @ptrCast(@alignCast(raw));
    return postToolUse(self, input) catch |err| {
        debug_trace.logf("hooks", "command hooks: PostToolUse failed open err={s}", .{@errorName(err)});
        return .continue_;
    };
}

fn postToolUse(self: *CommandHooks, input: hooks.PostToolUseInput) !hooks.PostToolUseAction {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var output = input.output;
    var replaced = false;
    for (self.post_tool_use) |group| {
        if (!group.matches(input.tool_name)) continue;
        for (group.commands) |command| {
            const payload = try eventJson(arena, "PostToolUse", input.invocation, input.call_id, input.tool_name, input.arguments_json, output, input.tool_failed);
            const result = runCommand(arena, command, input.invocation.scope.workspace_root, payload) orelse continue;
            switch (try parsePostToolUseResult(arena, result)) {
                .none => {},
                .replace => |replacement| {
                    if (replacement.failed) {
                        return .{ .replace_output = .{
                            .output = try storeResult(&post_result_storage, replacement.output),
                            .failed = true,
                        } };
                    }
                    output = replacement.output;
                    replaced = true;
                },
            }
        }
    }
    if (replaced) return .{ .replace_output = .{ .output = try storeResult(&post_result_storage, output) } };
    return .continue_;
}

fn eventJson(
    arena: Allocator,
    event: []const u8,
    invocation: hooks.Invocation,
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    tool_response: ?[]const u8,
    tool_failed: bool,
) ![]const u8 {
    const tool_input = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch
        std.json.Value{ .object = .empty };
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("hook_event_name");
    try stringify.write(event);
    try stringify.objectField("session_id");
    try stringify.write(invocation.scope.session_id);
    try stringify.objectField("cwd");
    try stringify.write(invocation.scope.workspace_root);
    try stringify.objectField("tool_name");
    try stringify.write(tool_name);
    try stringify.objectField("tool_input");
    try stringify.write(tool_input);
    try stringify.objectField("tool_use_id");
    try stringify.write(call_id);
    if (invocation.scope.subagent_id) |id| {
        try stringify.objectField("agent_id");
        try stringify.print("\"{d}\"", .{id});
    }
    if (tool_response) |text| {
        try stringify.objectField("tool_response");
        try stringify.write(text);
        try stringify.objectField("tool_failed");
        try stringify.write(tool_failed);
    }
    try stringify.endObject();
    return out.written();
}

const CommandResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const StdinWriter = struct {
    file: std.Io.File,
    bytes: []const u8,

    fn run(self: *StdinWriter) void {
        self.file.writeStreamingAll(io_mod.getIo(), self.bytes) catch {};
        self.file.close(io_mod.getIo());
    }
};

/// Runs `/bin/sh -c <command>` in the workspace. Returns null when the
/// command could not start, timed out, or was killed by a signal.
fn runCommand(arena: Allocator, command: Command, cwd: []const u8, payload: []const u8) ?CommandResult {
    if (comptime !supported) return null else return runChild(arena, command, cwd, payload);
}

fn runChild(arena: Allocator, command: Command, cwd: []const u8, payload: []const u8) ?CommandResult {
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command.command },
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        debug_trace.logf("hooks", "command hooks: spawn failed err={s}", .{@errorName(err)});
        return null;
    };
    var waited = false;
    defer if (!waited) child.kill(io);

    // Written from another thread so a command that prints before reading
    // all of stdin cannot block fx on a full pipe.
    var stdin_writer = StdinWriter{ .file = child.stdin.?, .bytes = payload };
    child.stdin = null;
    const writer_thread = std.Thread.spawn(.{}, StdinWriter.run, .{&stdin_writer}) catch {
        stdin_writer.run();
        return collect(arena, &child, command, &waited);
    };
    defer writer_thread.join();
    return collect(arena, &child, command, &waited);
}

fn collect(arena: Allocator, child: *std.process.Child, command: Command, waited: *bool) ?CommandResult {
    const io = io_mod.getIo();
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(@intCast(command.timeout_seconds)),
    } };
    const deadline = timeout.toDeadline(io);
    while (multi_reader.fill(4096, deadline)) |_| {
        if (multi_reader.reader(0).buffered().len > max_command_output_bytes or
            multi_reader.reader(1).buffered().len > max_command_output_bytes)
        {
            debug_trace.logf("hooks", "command hooks: output limit exceeded", .{});
            return null;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            debug_trace.logf("hooks", "command hooks: command did not finish err={s}", .{@errorName(err)});
            return null;
        },
    }
    multi_reader.checkAnyError() catch return null;
    const term = child.wait(io) catch return null;
    waited.* = true;
    const exit_code = switch (term) {
        .exited => |code| code,
        else => return null,
    };
    return .{
        .exit_code = exit_code,
        .stdout = multi_reader.toOwnedSlice(0) catch return null,
        .stderr = multi_reader.toOwnedSlice(1) catch return null,
    };
}

const PreToolUseResult = union(enum) {
    none,
    deny: []const u8,
    rewrite: []const u8,
};

fn parsePreToolUseResult(arena: Allocator, result: CommandResult) !PreToolUseResult {
    if (result.exit_code == 2) {
        const reason = std.mem.trim(u8, result.stderr, " \t\r\n");
        return .{ .deny = if (reason.len > 0) reason else default_deny_reason };
    }
    if (result.exit_code != 0) return .none;
    const specific = hookSpecificOutput(arena, result.stdout, "PreToolUse") orelse return .none;
    if (specific.get("permissionDecision")) |decision| {
        if (decision == .string and std.mem.eql(u8, decision.string, "deny")) {
            const reason = if (specific.get("permissionDecisionReason")) |value| switch (value) {
                .string => |text| text,
                else => default_deny_reason,
            } else default_deny_reason;
            return .{ .deny = if (reason.len > 0) reason else default_deny_reason };
        }
    }
    if (specific.get("updatedInput")) |updated| {
        if (updated == .object) {
            return .{ .rewrite = try std.json.Stringify.valueAlloc(arena, updated, .{}) };
        }
    }
    return .none;
}

const PostToolUseResult = union(enum) {
    none,
    replace: struct {
        output: []const u8,
        failed: bool,
    },
};

fn parsePostToolUseResult(arena: Allocator, result: CommandResult) !PostToolUseResult {
    if (result.exit_code != 0) return .none;
    const specific = hookSpecificOutput(arena, result.stdout, "PostToolUse") orelse return .none;
    const updated = specific.get("updatedToolOutput") orelse return .none;
    const output = switch (updated) {
        .string => |text| text,
        .null => return .none,
        else => try std.json.Stringify.valueAlloc(arena, updated, .{}),
    };
    // fxh extension: Claude Code's schema has no way to mark a replaced
    // output as a failed call.
    const failed = if (specific.get("updatedToolOutputIsError")) |flag| flag == .bool and flag.bool else false;
    return .{ .replace = .{ .output = output, .failed = failed } };
}

fn hookSpecificOutput(arena: Allocator, stdout: []const u8, event: []const u8) ?std.json.ObjectMap {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return null;
    if (root != .object) return null;
    const specific = root.object.get("hookSpecificOutput") orelse return null;
    if (specific != .object) return null;
    if (specific.object.get("hookEventName")) |name| {
        if (name != .string or !std.mem.eql(u8, name.string, event)) return null;
    }
    return specific.object;
}

test "parse reads Claude Code shaped groups and skips other handler types" {
    const alloc = std.testing.allocator;
    var parsed = (try parseCommandHooks(alloc,
        \\{"model":"x","hooks":{
        \\  "PreToolUse":[{"matcher":"shell|read_file","hooks":[{"type":"command","command":"pre","timeout":5},{"type":"prompt","prompt":"p"}]}],
        \\  "PostToolUse":[{"hooks":[{"type":"command","command":"post"}]},{"matcher":"x","hooks":[{"type":"http","url":"u"}]}]
        \\}}
    )).?;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.pre_tool_use.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.pre_tool_use[0].commands.len);
    try std.testing.expectEqual(@as(u64, 5), parsed.pre_tool_use[0].commands[0].timeout_seconds);
    try std.testing.expect(parsed.pre_tool_use[0].matches("shell"));
    try std.testing.expect(parsed.pre_tool_use[0].matches("read_file"));
    try std.testing.expect(!parsed.pre_tool_use[0].matches("write_file"));
    try std.testing.expectEqual(@as(usize, 1), parsed.post_tool_use.len);
    try std.testing.expect(parsed.post_tool_use[0].matches("anything"));
    try std.testing.expectEqual(default_timeout_seconds, parsed.post_tool_use[0].commands[0].timeout_seconds);
}

test "parse returns null without a hooks key and rejects malformed hooks" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try parseCommandHooks(alloc, "{\"model\":\"x\"}")) == null);
    try std.testing.expectError(error.InvalidHooksSetting, parseCommandHooks(alloc, "{\"hooks\":[]}"));
    try std.testing.expectError(error.InvalidHooksSetting, parseCommandHooks(alloc,
        \\{"hooks":{"PreToolUse":[{"hooks":[{"type":"command"}]}]}}
    ));
}

test "PreToolUse results map deny, exit code 2, and updatedInput" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deny = try parsePreToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"EACCES: permission denied"}}
    });
    try std.testing.expectEqualStrings("EACCES: permission denied", deny.deny);
    const exit_two = try parsePreToolUseResult(arena, .{ .exit_code = 2, .stdout = "", .stderr = "busy\n" });
    try std.testing.expectEqualStrings("busy", exit_two.deny);
    const rewrite = try parsePreToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"path":"b"}}}
    });
    try std.testing.expectEqualStrings("{\"path\":\"b\"}", rewrite.rewrite);
    try std.testing.expect((try parsePreToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout = "not json" })) == .none);
    try std.testing.expect((try parsePreToolUseResult(arena, .{ .exit_code = 1, .stderr = "x", .stdout = "" })) == .none);
}

test "PostToolUse results map updatedToolOutput and the failure extension" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replaced = try parsePostToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout =
        \\{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"new"}}
    });
    try std.testing.expectEqualStrings("new", replaced.replace.output);
    try std.testing.expect(!replaced.replace.failed);
    const failed = try parsePostToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout =
        \\{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"Error: reset","updatedToolOutputIsError":true}}
    });
    try std.testing.expect(failed.replace.failed);
    const wrong_event = try parsePostToolUseResult(arena, .{ .exit_code = 0, .stderr = "", .stdout =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedToolOutput":"x"}}
    });
    try std.testing.expect(wrong_event == .none);
}

test "commands receive the event on stdin and answer on stdout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io_mod.getIo(), &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const settings = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"hooks":{{
        \\  "PreToolUse":[{{"matcher":"shell","hooks":[{{"type":"command","command":"grep -q '\"tool_name\":\"shell\"' && echo deny-reason >&2 && exit 2"}}]}}],
        \\  "PostToolUse":[{{"hooks":[{{"type":"command","command":"cat > seen.json; printf '%s' '{{\"hookSpecificOutput\":{{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":\"replaced\"}}}}'"}}]}}]
        \\}}}}
    , .{});
    defer std.testing.allocator.free(settings);
    var command_hooks = (try parseCommandHooks(std.testing.allocator, settings)).?;
    defer command_hooks.deinit();

    const invocation: hooks.Invocation = .{ .scope = .{ .kind = .ask, .workspace_root = cwd, .session_id = "s" }, .turn_id = 1 };
    const pre = try preToolUse(&command_hooks, .{
        .invocation = invocation,
        .step_index = 0,
        .call_id = "c1",
        .tool_name = "shell",
        .arguments_json = "{\"command\":\"ls\"}",
    });
    try std.testing.expectEqualStrings("deny-reason", pre.fail);
    const not_matched = try preToolUse(&command_hooks, .{
        .invocation = invocation,
        .step_index = 0,
        .call_id = "c2",
        .tool_name = "read_file",
        .arguments_json = "{}",
    });
    try std.testing.expect(not_matched == .continue_);

    const post = try postToolUse(&command_hooks, .{
        .invocation = invocation,
        .step_index = 0,
        .call_id = "c3",
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
        .output = "1\thello",
        .tool_failed = true,
    });
    try std.testing.expectEqualStrings("replaced", post.replace_output.output);
    var seen_file = try tmp.dir.openFile(io_mod.getIo(), "seen.json", .{});
    defer seen_file.close(io_mod.getIo());
    const seen = try io_mod.readFileToEnd(std.testing.allocator, &seen_file, 1 << 20);
    defer std.testing.allocator.free(seen);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, seen, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("PostToolUse", parsed.value.object.get("hook_event_name").?.string);
    try std.testing.expectEqualStrings("c3", parsed.value.object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("1\thello", parsed.value.object.get("tool_response").?.string);
    try std.testing.expect(parsed.value.object.get("tool_failed").?.bool);
    try std.testing.expectEqualStrings("a.txt", parsed.value.object.get("tool_input").?.object.get("path").?.string);
}
