const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const math = std.math;
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config");

const utils = @import("utils.zig");
const Layout = @import("layout.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const Gesture = @import("gesture.zig");
const types = @import("types.zig");

pub const State = struct {
    layouts: [32]Layout,

    tag: u32 = 1,
    main_tag: u32 = 1,
    prev_tag: u32 = 1,
    prev_main_tag: u32 = 1,
};

const ctx = Context.get();

link: wl.list.Link = undefined,

wl_output: ?*wl.Output = null,
rwm_output: *river.OutputV1,
rwm_layer_shell_output: ?*river.LayerShellOutputV1,

layouts: [32]Layout,

tag: u32 = 1,
main_tag: u32 = 1,
prev_tag: u32 = 1,
prev_main_tag: u32 = 1,
// horizontal offset applied by scroller layout while a touchpad swipe is in progress
gesture_offset_x: i32 = 0,
// offset when the current swipe started, the finger movement is added on top of it
gesture_base: i32 = 0,
// window to keep at its on-screen x on the next arrange, so the release does not jump
gesture_anchor: ?struct { window: *Window, x: i32 } = null,
// resting x of the focused window before the window list was reordered during a swipe,
// the next arrange shifts the offset by the change so the view does not move
gesture_rebase: ?struct { window: *Window, rest_x: i32 } = null,
// settle animation of gesture_offset_x back to 0
gesture_anim_from: f64 = 0,
gesture_anim_start_ms: ?i64 = null,
// vertical offset of the tiled windows during a vertical swipe
gesture_offset_y: i32 = 0,
// adjacent tag shown next to the current one during a vertical swipe, 0 if none
gesture_peek_tag: u32 = 0,
// 1: the peek tag is below the current one, -1: above
gesture_peek_side: i32 = 1,
// settle animation of gesture_offset_y back to 0
gesture_anim_y_from: f64 = 0,
gesture_anim_y_start_ms: ?i64 = null,
// tag shown by the last arrange, to animate tag switches; 0 if unknown
gesture_prev_tag: u32 = 0,
// direction of the last step_tag (1: next, -1: previous, 0: none), so a wrap-around
// still slides in from the direction of travel
tag_step_direction: i32 = 0,
// focused window of the last scroller arrange, to animate focus changes
scroller_prev_focus: ?*Window = null,

name: ?[]const u8 = null,
x: i32 = undefined,
y: i32 = undefined,
width: i32 = undefined,
height: i32 = undefined,

background: if (build_options.background_enabled) @import("background.zig") else void = undefined,
bar: if (build_options.bar_enabled) @import("bar.zig") else void = undefined,

pub fn create(
    rwm_output: *river.OutputV1,
    rwm_layer_shell_output: ?*river.LayerShellOutputV1,
) !*Self {
    const output = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(output);

    defer log.debug("<{*}> created", .{output});

    output.* = .{
        .rwm_output = rwm_output,
        .rwm_layer_shell_output = rwm_layer_shell_output,
        .layouts = .{ctx.cfg.layout} ** 32,
    };
    output.link.init();

    if (comptime build_options.background_enabled) {
        try output.background.init(output);
    }

    if (comptime build_options.bar_enabled) {
        try output.bar.init(output);
    }

    rwm_output.setListener(*Self, rwm_output_listener, output);

    if (rwm_layer_shell_output) |layer_shell_output| {
        layer_shell_output.setListener(*Self, rwm_layer_shell_output_listener, output);
    }

    return output;
}

pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{self});

    {
        var it = ctx.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .output => |output| if (self == output) {
                    seat.previous_focused = .none;
                },
                else => {},
            }
        }
    }

    self.set_name(null);

    self.link.remove();
    self.rwm_output.destroy();
    if (self.wl_output) |wl_output| wl_output.destroy();

    if (self.rwm_layer_shell_output) |rwm_layer_shell_output| {
        rwm_layer_shell_output.destroy();
    }

    if (comptime build_options.background_enabled) self.background.deinit();

    if (comptime build_options.bar_enabled) self.bar.deinit();

    ctx.gpa.destroy(self);
}

pub fn get_state(self: *const Self) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(state, field.name) = @field(self, field.name);
    }
    return state;
}

pub fn sync_state(self: *Self, state: *const State) void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(self, field.name) = @field(state, field.name);
    }
}

pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{self});

    for (ctx.cfg.output_rules) |rule| {
        if (rule.match(self.name)) {
            self.apply_rule(&rule);
            break;
        }
    }
}

pub inline fn exclusive_x(self: *Self) i32 {
    return self.x;
}

pub inline fn exclusive_y(self: *Self) i32 {
    return if (comptime build_options.bar_enabled)
        if (ctx.cfg.bar.position == .bottom or self.bar.hidden) self.y else self.y + self.bar.height(true)
    else
        self.y;
}

pub inline fn exclusive_width(self: *Self) i32 {
    return self.width;
}

pub inline fn exclusive_height(self: *Self) i32 {
    return if (comptime build_options.bar_enabled)
        if (self.bar.hidden) self.height else self.height - self.bar.height(true)
    else
        self.height;
}

pub fn fullscreen_window(self: *Self) ?*Window {
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(self)) continue;

            switch (window.fullscreen) {
                .output => |output| {
                    if (output == self) {
                        return window;
                    }
                },
                else => {},
            }
        }
    }

    return null;
}

pub fn set_presentation(self: *Self, mode: river.OutputV1.PresentationMode) void {
    log.debug("<{*}> set presentation mode to {s}", .{ self, @tagName(mode) });

    self.rwm_output.setPresentationMode(mode);
}

pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0 or self.tag == tag) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.prev_tag = self.tag;
    self.prev_main_tag = self.main_tag;

    self.tag = tag;
    if (self.main_tag & tag == 0) {
        // use the lowest bit 1 as new main tag
        self.main_tag = tag ^ (tag & (tag - 1));

        log.debug("<{*}> update main tag to {b}", .{ self, self.main_tag });
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

pub fn switch_to_previous_tag(self: *Self) void {
    const prev_main_tag = self.prev_main_tag;

    self.set_tag(self.prev_tag);
    log.debug("<{*}> switch to previous tag", .{self});

    self.main_tag = prev_main_tag;
    log.debug("<{*}> switch to previous main tag", .{self});
}

pub fn occupied_tags(self: *const Self) u32 {
    var mask: u32 = 0;
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.output == self and window.swallowed_by == null) mask |= window.tag;
        }
    }
    return mask;
}

pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: (tag: {b}, mask: {b})", .{ self, self.tag, mask });

    self.tag ^= mask;
    // if there is only one bit 1, set it as new main tag
    if (self.tag & (self.tag - 1) == 0) {
        log.debug("<{*}> update main tag to {b}", .{ self, self.tag });

        self.main_tag = self.tag;
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

pub fn scroller(self: *Self) *Layout.Scroller {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag - 1) == 0);

    return &self.layouts[@ctz(self.main_tag)].scroller;
}

pub inline fn scroller_mfact(self: *const Self) f32 {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag - 1) == 0);

    const i = @ctz(self.main_tag);
    return self.layouts[i].scroller.mfact;
}

pub fn manage(self: *Self) void {
    if (ctx.overview.active) {
        self.scroller_prev_focus = null;
        ctx.overview.arrange(self);
        return;
    }

    self.normalize_tags();
    self.animate_tag_change();
    if (self.gesture_peek_tag != 0) self.arrange_peek();

    self.scroller().arrange(self) catch |err| {
        log.err("<{*}> arrange windows failed: {}", .{ self, err });
        return;
    };

    self.shift_tiled(self.gesture_offset_y);

    log.debug("<{*}> managed", .{self});
}

pub fn dynamic_tags() bool {
    return ctx.cfg.dynamic_tags and !ctx.cfg.single_tagset;
}

fn tag_limit() usize {
    return if (ctx.cfg.bar.tags) |area| area.tags.len else 32;
}

// tags holding windows of this output; sticky windows are on every tag and do not count
fn dynamic_occupied(self: *const Self) u32 {
    var mask: u32 = 0;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output == self and window.swallowed_by == null and !window.sticky) mask |= window.tag;
    }
    return mask;
}

// number of workspaces with dynamic tags: the occupied ones (packed to the front by
// normalize_tags), the current one even if empty, and one empty tag after them
pub fn workspace_count(self: *const Self) usize {
    const occupied = self.dynamic_occupied();
    const kept = occupied | self.tag;
    if (kept == 0) return 1;
    const last: u5 = @intCast(31 - @clz(kept));
    const trailing_empty: usize = if (occupied & (@as(u32, 1) << last) != 0) 1 else 0;
    return @min(@as(usize, last) + 1 + trailing_empty, tag_limit());
}

// next/previous workspace of `base`, wrapping around at both ends
pub fn ring_neighbor(self: *const Self, base: u32, direction: types.Direction) u32 {
    if (base == 0) return 0;
    const n = self.workspace_count();
    const current = @ctz(base);
    const next: usize = switch (direction) {
        .forward => if (current + 1 < n) current + 1 else 0,
        .reverse => if (current > 0) current - 1 else n - 1,
    };
    return @as(u32, 1) << @intCast(next);
}

// switch to the next/previous workspace, wrapping around at both ends
pub fn step_tag(self: *Self, direction: types.Direction) void {
    // windows may have been closed since the last arrange
    self.normalize_tags();
    if (self.workspace_count() < 2) return;
    self.tag_step_direction = switch (direction) {
        .forward => 1,
        .reverse => -1,
    };
    self.set_tag(self.ring_neighbor(self.main_tag, direction));
}

// drop empty tags (except the shown ones) and pack the rest to the front, keeping their order
fn normalize_tags(self: *Self) void {
    if (!dynamic_tags()) return;

    const kept = self.dynamic_occupied() | self.tag;
    var perm: Permutation = undefined;
    var next: u6 = 0;
    for (0..32) |i| {
        if (kept & (@as(u32, 1) << @intCast(i)) != 0) {
            perm[i] = @intCast(next);
            next += 1;
        }
    }
    for (0..32) |i| {
        if (kept & (@as(u32, 1) << @intCast(i)) == 0) {
            perm[i] = @intCast(next);
            next += 1;
        }
    }
    if (std.mem.eql(u5, &perm, &identity)) return;
    self.permute_tags(&perm);
}

// old tag index -> new tag index
const Permutation = [32]u5;

const identity: Permutation = blk: {
    var perm: Permutation = undefined;
    for (0..32) |i| perm[i] = i;
    break :blk perm;
};

fn apply_permutation(perm: *const Permutation, mask: u32) u32 {
    var result: u32 = 0;
    for (0..32) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) result |= @as(u32, 1) << perm[i];
    }
    return result;
}

// renumber the tags of this output and everything that refers to them
fn permute_tags(self: *Self, perm: *const Permutation) void {
    if (std.mem.eql(u5, perm, &identity)) return;
    log.debug("<{*}> renumber tags", .{self});

    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output == self) window.tag = apply_permutation(perm, window.tag);
    }

    inline for (.{ "tag", "main_tag", "prev_tag", "prev_main_tag", "gesture_peek_tag", "gesture_prev_tag" }) |name| {
        @field(self, name) = apply_permutation(perm, @field(self, name));
    }

    const layouts = self.layouts;
    for (0..32) |i| self.layouts[perm[i]] = layouts[i];

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

// slide between tags when the tag was switched by other means than a swipe
fn animate_tag_change(self: *Self) void {
    const prev = self.gesture_prev_tag;
    self.gesture_prev_tag = self.tag;
    const step_direction = self.tag_step_direction;
    self.tag_step_direction = 0;
    if (prev == 0 or (prev & self.tag) != 0) return;
    const prev_main = prev ^ (prev & (prev - 1));
    if (!ctx.cfg.gesture.animate_bindings) {
        self.gesture_offset_y = 0;
        self.gesture_anim_y_start_ms = null;
        self.gesture_peek_tag = 0;
        return;
    }

    // the next tag comes in from below, the previous one from above, also when wrapping;
    // for direct jumps compare the positions
    const from_below = if (step_direction != 0) step_direction > 0 else @ctz(self.main_tag) > @ctz(prev_main);
    const side: i32 = if (from_below) -1 else 1;
    // the previous tag stays where it is now (still moving if a switch was animating),
    // the new one starts right next to it
    const offset = self.gesture_offset_y - side * self.exclusive_height();
    self.gesture_peek_tag = prev;
    self.gesture_peek_side = side;
    Gesture.start_settle_y(self, offset);
}

// arrange the tag revealed by a vertical swipe with its own settings, one screen away
fn arrange_peek(self: *Self) void {
    const tag = self.tag;
    const main_tag = self.main_tag;
    defer {
        self.tag = tag;
        self.main_tag = main_tag;
    }
    self.tag = self.gesture_peek_tag;
    self.main_tag = self.tag ^ (self.tag & (self.tag - 1));

    self.scroller().arrange(self) catch |err| {
        log.err("<{*}> arrange peek tag failed: {}", .{ self, err });
        return;
    };
    self.shift_tiled(self.gesture_offset_y + self.gesture_peek_side * self.exclusive_height());
}

// move the tiled windows of the current tag vertically, they are re-arranged every manage
fn shift_tiled(self: *Self, dy: i32) void {
    if (dy == 0) return;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible_in(self) or window.floating) continue;
        window.unbound_move(null, window.y + dy);
    }
}

fn apply_rule(self: *Self, rule: *const config.OutputRule) void {
    if (rule.presentation_mode) |mode| self.set_presentation(mode);
    if (rule.layout) |layout| for (&self.layouts) |*l| {
        l.* = config.meta.override(l.*, layout);
    };
}

fn set_name(self: *Self, name: ?[]const u8) void {
    if (self.name) |name_| {
        ctx.gpa.free(name_);
        self.name = null;
    }

    if (name) |name_| {
        self.name = ctx.gpa.dupe(u8, name_) catch null;
    }
}

fn rwm_output_listener(rwm_output: *river.OutputV1, event: river.OutputV1.Event, output: *Self) void {
    std.debug.assert(rwm_output == output.rwm_output);

    switch (event) {
        .dimensions => |data| {
            log.debug("<{*}> new dimensions: (width: {}, height: {})", .{ output, data.width, data.height });

            output.width = data.width;
            output.height = data.height;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .position => |data| {
            log.debug("<{*}> new position: (x: {}, y: {})", .{ output, data.x, data.y });

            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .removed => {
            log.debug("<{*}> removed, name: {s}", .{ output, output.name orelse "" });

            ctx.prepare_remove_output(output);

            output.destroy();
        },
        .wl_output => |data| {
            log.debug("<{*}> wl_output: {}", .{ output, data.name });

            const wl_output = ctx.wl_registry.bind(data.name, wl.Output, 4) catch return;
            output.wl_output = wl_output;
            wl_output.setListener(*Self, wl_output_listener, output);
        },
    }
}

fn rwm_layer_shell_output_listener(
    rwm_layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Self,
) void {
    std.debug.assert(rwm_layer_shell_output == output.rwm_layer_shell_output.?);

    switch (event) {
        .non_exclusive_area => |data| {
            log.debug(
                "<{*}> non exclusive area: (width: {}, height: {}, x: {}, y: {})",
                .{ output, data.width, data.height, data.x, data.y },
            );

            output.width = data.width;
            output.height = data.height;
            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.bar_enabled) {
                output.bar.damage(.all);
            }
        },
    }
}

fn wl_output_listener(wl_output: *wl.Output, event: wl.Output.Event, output: *Self) void {
    std.debug.assert(wl_output == output.wl_output.?);

    switch (event) {
        .geometry => |data| {
            log.debug(
                "<{*}> geometry: (x: {}, y: {}, physical_width: {}, physical_height: {}, subpixel: {s}, make: {s}, model: {s}, transform: {s})",
                .{ output, data.x, data.y, data.physical_width, data.physical_height, @tagName(data.subpixel), data.make, data.model, @tagName(data.transform) },
            );
        },
        .mode => |data| {
            log.debug(
                "<{*}> mode: (flags: (current: {}, preferred: {}), width: {}, height: {}, refresh: {})",
                .{ output, data.flags.current, data.flags.preferred, data.width, data.height, data.refresh },
            );
        },
        .scale => |data| {
            log.debug("<{*}> scale: {}", .{ output, data.factor });
        },
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ output, data.name });

            const name = mem.span(data.name);
            output.set_name(name);

            if (ctx.output_states.fetchRemove(name)) |kv| {
                log.debug("<{*}> restore state: {any}", .{ output, kv.value });
                output.sync_state(kv.value);
                ctx.gpa.free(kv.key);
                ctx.gpa.destroy(kv.value);

                ctx.rwm.manageDirty();
            }

            {
                var it = ctx.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.former_output) |former| {
                        if (mem.eql(u8, former, name)) {
                            log.debug("{*} former output match `{s}`", .{ window, name });
                            window.set_output(output, true);
                        }
                    }
                }
            }
        },
        .description => |data| {
            log.debug("<{*}> description: {s}", .{ output, data.description });
        },
        .done => {
            log.debug("<{*}> done", .{output});

            output.apply_rules();
        },
    }
}
