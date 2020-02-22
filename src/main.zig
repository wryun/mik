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
    name: std.Buffer,
    help: std.Buffer,
    args: std.Buffer,

    fn init(allocator: *std.mem.Allocator) !Command {
        return Command{
            .allocator = allocator,
            .name = try std.Buffer.initSize(allocator, 0),
            .help = try std.Buffer.initSize(allocator, 0),
            .args = try std.Buffer.initSize(allocator, 0),
        };
    }

    fn clone(self: *Command) !Command {
        return Command{
            .allocator = self.allocator,
            .name = try std.Buffer.init(self.allocator, self.name.toSliceConst()),
            .help = try std.Buffer.init(self.allocator, self.help.toSliceConst()),
            .args = try std.Buffer.init(self.allocator, self.args.toSliceConst()),
        };
    }

    fn reset(self: *Command) !void {
        try self.name.resize(0);
        try self.help.resize(0);
        try self.args.resize(0);
    }

    fn _setField(self: *Command, buf: *std.Buffer, value: []const u8) !void {
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
            std.debug.warn("{}\n", key);
            return CommandError.NoSuchField;
        }
    }

    fn showHelp(self: *const Command) void {
        std.debug.warn("  {s10}  {}\n", self.name.toSliceConst(), self.help.toSliceConst());
    }

    fn showFullHelp(self: *const Command) void {
        std.debug.warn("mik {} {}", self.name.toSliceConst(), self.args.toSliceConst());
        std.debug.warn("{}\n", self.help.toSliceConst());
    }

    fn parseArgString(self: *const Command) !std.hash_map.AutoHashMap([]const u8, Argument) {
        const args = std.hash_map.AutoHashMap([]const u8, []const []const u8).init(self.allocator);
        const positionals = 
        var it = mem.tokenize(self.args, " \t\r\n");
        while (it.next()) |token| {
            if (mem.startsWith(u8, token, "-")) {
            } else if (mem.startsWith(u8, token, "<") and mem.endsWith(u8, token, ">")) {
                token[1..-1]
            }
        }

    }

    fn exec(self: *const Command, tmp_file: []const u8) !void {
        const argsMap = self.parseArgString();
        var env = try processArgs(self.allocator, self, &std.process.args());
        // TODO pass remaining std.process.args
        try std.os.execve(self.allocator, [_][]const u8{ "bash", tmp_file }, &env);
    }
};

fn processFile(allocator: *std.mem.Allocator, input: *std.io.InStream(std.os.ReadError), output: *std.io.OutStream(std.os.WriteError), command_name: []const u8) !?Command {
    const help_mode = std.mem.eql(u8, command_name, "help");
    var buf = try std.Buffer.initSize(allocator, 1000);
    var current_command = try Command.init(allocator);

    // for amusement's sake (and to use a stupidly small amount of memory), we
    // don't build a hashmap of all the commands but instead return only
    // that referenced by command_name.
    var final_command: ?Command = null;
    // TODO smaller static buffer, only read start of line?
    while (std.io.readLineFrom(input, &buf)) |line| {
        try output.write(line);
        try output.write("\n");

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
                    std.debug.warn("{} multiply defined as {}", field, value);
                    return err;
                };
            }
        }

        try buf.resize(0);
    } else |err| {}

    if (final_command) |command| {
        try output.write("mik_");
        try output.write(command.name.toSliceConst());
        try output.write(" \"$@\"\n");
    } else if (!help_mode) {
        std.debug.warn("missing '{}' - try mik help\n", command_name);
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
    const file = std.fs.File.openWriteNoClobber(MIKFILE, std.fs.File.default_mode) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => {
            std.debug.warn("Cowardly refusing to overwrite existing {}\n", MIKFILE);
            return;
        },
        else => return err,
    };
    defer file.close();
    try file.write(MIKFILE_SCAFFOLD);
}

pub fn main() anyerror!void {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    // using an arena allocator means we don't have to worry about deinit as we go.
    // tbh, it's all kinda a waste of time anyway, as the arena.deinit
    // will never run on a correct execution (since we're exec-ing ...).
    var arena = std.heap.ArenaAllocator.init(&direct_allocator.allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    // TODO generate name randomly... or at least process id suffix
    const tmp_file = "/tmp/Mikfile.bash";
    var output = try std.fs.File.openWrite(tmp_file);
    try output.write("rm " ++ tmp_file ++ "\n");
    errdefer std.fs.deleteFile(tmp_file) catch {};
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

    var input = try std.fs.File.openRead(MIKFILE);
    defer input.close();

    var command = try processFile(allocator, &input.inStream().stream, &output.outStream().stream, command_name);

    if (command) |command_val| {
        if (command_help) {
            command_val.showFullHelp();
        } else {
            try command_val.exec(tmp_file);
        }
    }
}
