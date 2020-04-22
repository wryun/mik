const std = @import("std");

const MIKFILE = "Mikfile.bash";
const MIKFILE_SCAFFOLD = @embedFile("../Mikfile.bash.scaffold");

const CommandError = error{
    NoSuchField,
    FieldDefinedTwice,
    ExtraArgs,
};

const Command = struct {
    allocator: *std.mem.Allocator,
    name: std.ArrayListSentineled(u8, 0),
    help: std.ArrayListSentineled(u8, 0),
    args: std.ArrayListSentineled(u8, 0),

    fn init(allocator: *std.mem.Allocator) !Command {
        return Command{
            .allocator = allocator,
            .name = try std.ArrayListSentineled(u8, 0).initSize(allocator, 0),
            .help = try std.ArrayListSentineled(u8, 0).initSize(allocator, 0),
            .args = try std.ArrayListSentineled(u8, 0).initSize(allocator, 0),
        };
    }

    fn clone(self: *Command) !Command {
        return Command{
            .allocator = self.allocator,
            .name = try std.ArrayListSentineled(u8, 0).init(self.allocator, self.name.list.items),
            .help = try std.ArrayListSentineled(u8, 0).init(self.allocator, self.help.list.items),
            .args = try std.ArrayListSentineled(u8, 0).init(self.allocator, self.args.list.items),
        };
    }

    fn reset(self: *Command) !void {
        try self.name.resize(0);
        try self.help.resize(0);
        try self.args.resize(0);
    }

    fn _setField(self: *Command, buf: *std.ArrayListSentineled(u8, 0), value: []const u8) !void {
        if (buf.len() != 0) {
            return CommandError.FieldDefinedTwice;
        }
        try buf.replaceContents(value);
    }

    fn setField(self: *Command, key: []const u8, value: []const u8) !void {
        // Is there a tricky way to do this? comptime something something?
        if (std.mem.eql(u8, key, "help")) {
            try self._setField(&self.help, value);
        } else if (std.mem.eql(u8, key, "args")) {
            try self._setField(&self.args, value);
        } else {
            std.debug.warn("{}\n", .{key});
            return CommandError.NoSuchField;
        }
    }

    fn showHelp(self: *const Command) void {
        //std.debug.warn("  {s10}  {}\n", .{self.name.list.items, self.help.list.items});
    }

    fn showFullHelp(self: *const Command) void {
        std.debug.warn("mik {} {}", .{ self.name.list.items, self.args.list.items });
        std.debug.warn("{}\n", .{self.help.list.items});
    }

    //fn parseArgString(self: *const Command) !std.hash_map.AutoHashMap([]const u8, Argument) {
    fn parseArgString(self: *const Command) std.hash_map.StringHashMap([]const []const u8) {
        //const args = std.hash_map.AutoHashMap([]const u8, []const []const u8).init(self.allocator);
        const args = std.hash_map.StringHashMap([]const []const u8).init(self.allocator);
        //const positionals =
        var it = std.mem.tokenize(self.args.list.items, " \t\r\n");
        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, "-")) {} else if (std.mem.startsWith(u8, token, "<") and std.mem.endsWith(u8, token, ">")) {
                //token[1..-1]
            }
        }

        return args;
    }

    fn exec(self: *const Command, tmp_file: []const u8) !void {
        const argsMap = self.parseArgString();
        var env = try processArgs(self.allocator, self, &std.process.args());
        // TODO pass remaining std.process.args
        //try std.os.execveZ(self.allocator, [_][]const u8{ "bash", tmp_file }, &env);
        //try std.os.execveZ("bash", .{ try std.mem.allocSentinel(self.allocator, u8, tmp_file.len, null) }, &env);
        return std.os.execvpe(self.allocator, &[_][]const u8{ "bash", tmp_file }, &env);
    }
};

fn processFile(allocator: *std.mem.Allocator, input: std.fs.File.InStream, output: std.fs.File.OutStream, command_name: []const u8) !?Command {
    const help_mode = std.mem.eql(u8, command_name, "help");
    var current_command = try Command.init(allocator);

    // for amusement's sake (and to use a stupidly small amount of memory), we
    // don't build a hashmap of all the commands but instead return only
    // that referenced by command_name.
    var final_command: ?Command = null;

    // Consider buffering situation.
    const in_stream = std.io.bufferedInStream(input).inStream();
    const out_stream = std.io.bufferedOutStream(output).outStream();
    var line_buf: [512]u8 = undefined;
    while (in_stream.readUntilDelimiterOrEof(&line_buf, '\n')) |l| {
        const line = l.?;
        _ = try output.write(line);
        _ = try output.write("\n");

        if (std.mem.startsWith(u8, line, "mik_") and std.mem.endsWith(u8, line, "() {")) {
            try current_command.name.replaceContents(line[4..std.mem.indexOfScalar(u8, line, '(').?]);
            if (help_mode) {
                current_command.showHelp();
            } else if (current_command.name.eql(command_name)) {
                final_command = try current_command.clone();
            }

            try current_command.reset();
        } else if (std.mem.startsWith(u8, line, "# mik_")) {
            const colonIndex = std.mem.indexOfScalar(u8, line, ':').?;
            const field = line[6..colonIndex];
            const value = line[colonIndex + 1 ..];
            if (!std.mem.startsWith(u8, field, "global_")) {
                current_command.setField(field, value) catch |err| {
                    std.debug.warn("{} multiply defined as {}", .{ field, value });
                    return err;
                };
            }
        }
    } else |err| {}

    if (final_command) |command| {
        _ = try output.write("mik_");
        _ = try output.write(command.name.list.items);
        _ = try output.write(" \"$@\"\n");
    } else if (!help_mode) {
        std.debug.warn("missing '{}' - try mik help\n", .{command_name});
    }

    return final_command;
}

fn processArgs(allocator: *std.mem.Allocator, command: *const Command, args_it: *std.process.ArgIterator) !std.BufMap {
    var envMap = try std.process.getEnvMap(allocator);

    while (args_it.nextPosix()) |arg| {
        // TODO
        // NB if ... at the end, leave remainder for execve
    }

    return envMap;
}

fn generate_scaffold() !void {
    const file = std.fs.cwd().createFile(MIKFILE, .{ .exclusive = true }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => {
            std.debug.warn("Cowardly refusing to overwrite existing {}\n", .{MIKFILE});
            return;
        },
        else => return err,
    };
    defer file.close();
    _ = try file.write(MIKFILE_SCAFFOLD);
}

pub fn main() anyerror!void {
    // using an arena allocator means we don't have to worry about deinit as we go.
    // tbh, it's all kinda a waste of time anyway, as the arena.deinit
    // will never run on a correct execution (since we're exec-ing ...).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    // TODO generate name randomly... or at least process id suffix
    const tmp_file = "/tmp/Mikfile.sh";
    var output = try std.fs.cwd().createFile(tmp_file, .{ .exclusive = true });
    _ = try output.write("rm " ++ tmp_file ++ "\n");
    errdefer std.fs.cwd().deleteFile(tmp_file) catch {};
    defer output.close();

    var args_it = std.process.args();
    _ = args_it.skip();

    var command_name = args_it.nextPosix() orelse "help";
    var command_help = false;
    if (std.mem.eql(u8, command_name, "scaffold")) {
        if (args_it.skip()) {
            return CommandError.ExtraArgs;
        }
        try generate_scaffold();
    } else if (std.mem.eql(u8, command_name, "help")) {
        if (args_it.nextPosix()) |arg| {
            command_help = true;
            command_name = arg;
        }
        if (args_it.skip()) {
            return CommandError.ExtraArgs;
        }
    }

    var input = try std.fs.cwd().openFile(MIKFILE, .{});
    defer input.close();

    var command = try processFile(allocator, input.inStream(), output.outStream(), command_name);

    if (command) |command_val| {
        if (command_help) {
            command_val.showFullHelp();
        } else {
            try command_val.exec(tmp_file);
        }
    }
}
