const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log.scoped(.gesture);

const posix = @import("posix");
const config = @import("config");

const binding = @import("binding.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const Udev = opaque {};
const Libinput = opaque {};
const Event = opaque {};
const GestureEvent = opaque {};

extern fn udev_new() ?*Udev;
extern fn udev_unref(*Udev) ?*Udev;
extern fn libinput_udev_create_context(*const Interface, ?*anyopaque, *Udev) ?*Libinput;
extern fn libinput_udev_assign_seat(*Libinput, [*:0]const u8) c_int;
extern fn libinput_unref(*Libinput) ?*Libinput;
extern fn libinput_get_fd(*Libinput) c_int;
extern fn libinput_dispatch(*Libinput) c_int;
extern fn libinput_get_event(*Libinput) ?*Event;
extern fn libinput_event_get_type(*Event) c_int;
extern fn libinput_event_destroy(*Event) void;
extern fn libinput_event_get_gesture_event(*Event) *GestureEvent;
extern fn libinput_event_gesture_get_finger_count(*GestureEvent) c_int;
extern fn libinput_event_gesture_get_dx_unaccelerated(*GestureEvent) f64;
extern fn libinput_event_gesture_get_dy_unaccelerated(*GestureEvent) f64;
extern fn libinput_event_gesture_get_cancelled(*GestureEvent) c_int;
extern fn libinput_event_gesture_get_time_usec(*GestureEvent) u64;

const Interface = extern struct {
    open_restricted: *const fn ([*:0]const u8, c_int, ?*anyopaque) callconv(.c) c_int,
    close_restricted: *const fn (c_int, ?*anyopaque) callconv(.c) void,
};

const interface: Interface = .{
    .open_restricted = open_restricted,
    .close_restricted = close_restricted,
};

// enum libinput_event_type in libinput.h
const SWIPE_BEGIN = 800;
const SWIPE_UPDATE = 801;
const SWIPE_END = 802;


// distance before the swipe axis is locked
const axis_lock_distance = 16;

// interval between animation frames
const frame_ms = 8;
// movement within this window before release decides the fling velocity
const velocity_window_us = 100 * std.time.us_per_ms;

const Axis = enum { undecided, horizontal, vertical };

// whether an animation tick is already scheduled
var ticking = false;


li: *Libinput,
fd: posix.fd_t,
dx: f64 = 0,
dy: f64 = 0,
axis: Axis = .undecided,
// output whose scroller follows the fingers, null if not tracking
tracking: ?*Output = null,
// output whose tags follow the fingers vertically, null if not tracking
tracking_y: ?*Output = null,
// recent updates, used to compute the velocity at release
samples: [16]Sample = undefined,
sample_count: usize = 0,

const Sample = struct { time_us: u64, dx: f64, dy: f64 };


pub fn init(self: *Self) !void {
    const udev = udev_new() orelse return error.UdevNewFailed;
    // libinput holds its own reference
    defer _ = udev_unref(udev);

    const li = libinput_udev_create_context(&interface, null, udev) orelse return error.LibinputCreateFailed;
    errdefer _ = libinput_unref(li);

    if (libinput_udev_assign_seat(li, "seat0") != 0) return error.LibinputAssignSeatFailed;

    self.* = .{ .li = li, .fd = libinput_get_fd(li) };
}


pub fn deinit(self: *Self) void {
    _ = libinput_unref(self.li);
}


pub fn dispatch(self: *Self) void {
    _ = libinput_dispatch(self.li);
    while (libinput_get_event(self.li)) |event| {
        defer libinput_event_destroy(event);
        self.handle_event(event);
    }
}


fn handle_event(self: *Self, event: *Event) void {
    const event_type = libinput_event_get_type(event);
    switch (event_type) {
        SWIPE_BEGIN, SWIPE_UPDATE, SWIPE_END => {},
        else => return,
    }
    const g = libinput_event_get_gesture_event(event);
    if (libinput_event_gesture_get_finger_count(g) != ctx.cfg.gesture.fingers) return;

    // libinput is read directly, so the lock screen has to be respected here
    if (!ctx.cfg.gesture.enabled or mem.eql(u8, ctx.mode, config.lock_mode)) {
        self.abort();
        return;
    }
    // the tracked output may have been unplugged since the last event
    if (self.tracking) |output| if (!alive(output)) {
        self.tracking = null;
    };
    if (self.tracking_y) |output| if (!alive(output)) {
        self.tracking_y = null;
    };

    switch (event_type) {
        SWIPE_BEGIN => {
            self.dx = 0;
            self.dy = 0;
            self.axis = .undecided;
            self.tracking = null;
            self.tracking_y = null;
            self.sample_count = 0;
        },
        SWIPE_UPDATE => {
            const dx = libinput_event_gesture_get_dx_unaccelerated(g);
            const dy = libinput_event_gesture_get_dy_unaccelerated(g);
            self.dx += dx;
            self.dy += dy;
            self.samples[self.sample_count % self.samples.len] = .{
                .time_us = libinput_event_gesture_get_time_usec(g),
                .dx = dx,
                .dy = dy,
            };
            self.sample_count += 1;

            if (self.axis == .undecided and @abs(self.dx) + @abs(self.dy) >= axis_lock_distance) {
                self.axis = if (@abs(self.dx) >= @abs(self.dy)) .horizontal else .vertical;
                if (self.axis == .horizontal) {
                    if (scroller_output()) |output| {
                        // grab the view where it is, even if it is still settling
                        output.gesture_anim_start_ms = null;
                        output.gesture_anchor = null;
                        output.gesture_base = output.gesture_offset_x;
                        self.tracking = output;
                    }
                } else if (tag_output()) |output| {
                    // grab the tags where they are, even if they are still settling
                    output.gesture_anim_y_start_ms = null;
                    output.gesture_base = output.gesture_offset_y;
                    self.tracking_y = output;
                }
            }

            if (self.tracking_y) |output| {
                const offset = output.gesture_base + @as(i32, @intFromFloat(@round(self.dy * ctx.cfg.gesture.tag_scroll_factor)));
                set_peek(output, offset);
                // nothing to reveal: resist instead of moving freely
                output.gesture_offset_y = if (output.gesture_peek_tag == 0) rubber(offset, 0) else offset;
                ctx.rwm.manageDirty();
            }

            if (self.tracking) |output| {
                const offset = output.gesture_base + @as(i32, @intFromFloat(@round(self.dx * ctx.cfg.gesture.scroll_factor)));
                fill_edge(output, offset);
                output.gesture_offset_x = damp_x(output, offset);
                ctx.rwm.manageDirty();
            }
        },
        SWIPE_END => {
            const cancelled = libinput_event_gesture_get_cancelled(g) != 0;
            // where the fingers would have ended up had they kept their release speed
            const vx, const vy = self.velocity(libinput_event_gesture_get_time_usec(g));
            const px = self.dx + vx * ctx.cfg.gesture.fling;
            const py = self.dy + vy * ctx.cfg.gesture.fling;
            log.debug("swipe end dx={d:.2} dy={d:.2} projected=({d:.2}, {d:.2}) cancelled={}", .{ self.dx, self.dy, px, py, cancelled });

            if (self.tracking) |output| {
                defer self.tracking = null;
                if (!cancelled) {
                    // a fling may go further than the drag, make sure there is something to land on
                    fill_edge(output, output.gesture_base + @as(i32, @intFromFloat(@round(px * ctx.cfg.gesture.scroll_factor))));
                }
                const steps = if (cancelled) 0 else scroll_steps(output, px);
                // remember where the current window is on screen, the next arrange
                // turns the jump to the new resting position into an animation
                if (ctx.focus_top_in(output, true)) |window| {
                    output.gesture_anchor = .{ .window = window, .x = window.x };
                }
                output.gesture_offset_x = 0;
                for (0..steps) |_| trigger(.{ .focus_iter = .{ .direction = if (px < 0) .forward else .reverse } });
                ctx.rwm.manageDirty();
                return;
            }

            if (self.tracking_y) |output| {
                defer self.tracking_y = null;
                const offset = output.gesture_offset_y;
                // the fling has to point the same way as the revealed tag
                const towards_peek = (py < 0) == (offset < 0);
                if (!cancelled and @abs(py) >= ctx.cfg.gesture.threshold and towards_peek and output.gesture_peek_tag != 0) {
                    // switch to the revealed tag, it keeps its on-screen position and
                    // slides in while the old tag becomes the one sliding out
                    const old_tag = output.tag;
                    const side = output.gesture_peek_side;
                    // step instead of jumping to the tag, so dynamic tags can wrap around
                    trigger(.{ .set_output_tag = .{ .tag = .{ .direction = if (side == 1) .forward else .reverse } } });
                    // the switch is animated here, the next arrange must not animate it again
                    output.gesture_prev_tag = output.gesture_peek_tag;
                    output.gesture_peek_tag = old_tag;
                    output.gesture_peek_side = -side;
                    start_settle_y(output, offset + side * output.exclusive_height());
                } else if (!cancelled and @abs(py) >= ctx.cfg.gesture.threshold and output.gesture_peek_tag == 0 and peek_exists(output, py)) {
                    // nothing to preview (floating tag), switch without the slide
                    output.gesture_offset_y = 0;
                    trigger(.{ .set_output_tag = .{ .tag = .{ .direction = if (py < 0) .forward else .reverse } } });
                } else {
                    start_settle_y(output, offset);
                }
                ctx.rwm.manageDirty();
                return;
            }

            if (cancelled) return;
            if (self.resolve_action()) |action| trigger(action);
        },
        else => unreachable,
    }
}


// drop the gesture in progress and put everything back in place
fn abort(self: *Self) void {
    if (self.tracking) |output| if (alive(output)) start_settle(output, output.gesture_offset_x);
    if (self.tracking_y) |output| if (alive(output)) start_settle_y(output, output.gesture_offset_y);
    self.tracking = null;
    self.tracking_y = null;
    self.axis = .undecided;
}


// compare by address only, `output` may already be destroyed
fn alive(output: *Output) bool {
    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o == output) return true;
    }
    return false;
}


// average velocity (units per second) of the updates within `velocity_window_us` before `end_us`
fn velocity(self: *const Self, end_us: u64) struct { f64, f64 } {
    const count = @min(self.sample_count, self.samples.len);
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var oldest: u64 = end_us;
    for (0..count) |i| {
        const sample = self.samples[(self.sample_count - 1 - i) % self.samples.len];
        if (sample.time_us + velocity_window_us < end_us) break;
        sum_x += sample.dx;
        sum_y += sample.dy;
        oldest = sample.time_us;
    }
    // the oldest sample's movement happened before its timestamp, count one more frame
    const span_us = end_us - oldest + 10 * std.time.us_per_ms;
    const span_s = @as(f64, @floatFromInt(span_us)) / std.time.us_per_s;
    return .{ sum_x / span_s, sum_y / span_s };
}


// past `limit`, movement is damped and approaches `limit + rubber_band`
fn rubber(offset: i32, limit: i32) i32 {
    const magnitude: i32 = @intCast(@abs(offset));
    if (magnitude <= limit) return offset;
    const over: f64 = @floatFromInt(magnitude - limit);
    const band: f64 = @floatFromInt(ctx.cfg.gesture.rubber_band);
    const stretched = limit + @as(i32, @intFromFloat(@round(band * over / (over + band))));
    return if (offset < 0) -stretched else stretched;
}


// horizontal offset limited to the columns that actually exist in that direction
fn damp_x(output: *Output, offset: i32) i32 {
    if (offset == 0) return 0;
    const focus_top = ctx.focus_top_in(output, true) orelse return offset;
    const column = focus_top.width + output.scroller().inner_gap;
    const beyond: i32 = @intCast(windows_beyond(output, focus_top, offset < 0));
    return rubber(offset, beyond * column);
}


// whether there is a tag to switch to in the direction of `dy`, even one that cannot be previewed
fn peek_exists(output: *Output, dy: f64) bool {
    const tag: binding.Tag = .{ .direction = if (dy < 0) .forward else .reverse };
    const peek = tag.of(.{ .output = output });
    return peek != 0 and peek != output.tag;
}


// start animating `output`'s offset from `from` back to 0
pub fn start_settle(output: *Output, from: i32) void {
    output.gesture_offset_x = from;
    if (from == 0) {
        output.gesture_anim_start_ms = null;
        return;
    }
    output.gesture_anim_from = @floatFromInt(from);
    output.gesture_anim_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


// start animating `output`'s vertical offset from `from` back to 0, the peek tag goes away at the end
pub fn start_settle_y(output: *Output, from: i32) void {
    output.gesture_offset_y = from;
    if (from == 0) {
        output.gesture_anim_y_start_ms = null;
        output.gesture_peek_tag = 0;
        return;
    }
    output.gesture_anim_y_from = @floatFromInt(from);
    output.gesture_anim_y_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


fn tick(_: *Context) void {
    const now = now_ms();
    var active = false;

    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.gesture_anim_start_ms) |start| {
            if (ease(now, start, output.gesture_anim_from)) |offset| {
                output.gesture_offset_x = offset;
                active = true;
            } else {
                output.gesture_offset_x = 0;
                output.gesture_anim_start_ms = null;
            }
        }
        if (output.gesture_anim_y_start_ms) |start| {
            if (ease(now, start, output.gesture_anim_y_from)) |offset| {
                output.gesture_offset_y = offset;
                active = true;
            } else {
                output.gesture_offset_y = 0;
                output.gesture_anim_y_start_ms = null;
                output.gesture_peek_tag = 0;
            }
        }
    }

    ctx.rwm.manageDirty();
    if (active) ctx.run_later(.fromMilliseconds(frame_ms), tick) else ticking = false;
}


// offset at `now` of an animation from `from` to 0, null once finished
fn ease(now: i64, start: i64, from: f64) ?i32 {
    const t = @as(f64, @floatFromInt(now - start)) / @as(f64, @floatFromInt(ctx.cfg.gesture.settle_ms));
    if (t >= 1) return null;
    // ease-out cubic: fast at first, slows down near the resting position
    return @intFromFloat(@round(from * std.math.pow(f64, 1 - t, 3)));
}


fn now_ms() i64 {
    return Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
}


// When the fingers drag past the last window in some direction, move the window
// from the opposite end over, so there is always something to scroll to.
fn fill_edge(output: *Output, offset: i32) void {
    if (ctx.cfg.disable_wrap_around_for_scroller or offset == 0) return;

    const focus_top = ctx.focus_top_in(output, true) orelse return;
    const gap = output.scroller().inner_gap;
    const column = focus_top.width + gap;
    if (column <= 0) return;
    // columns that have to exist beyond the focused window to cover the drag
    const need: usize = @intCast(@divFloor(@as(i32, @intCast(@abs(offset))) + column - 1, column));

    var buffer: [64]*Window = undefined;
    var windows: std.ArrayList(*Window) = .initBuffer(&buffer);
    var focus_index: usize = 0;
    {
        var it = ctx.windows.iterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(output) or window.floating) continue;
            if (window == focus_top) focus_index = windows.items.len;
            windows.appendBounded(window) catch return;
        }
    }
    const n = windows.items.len;
    // with two windows or less, reordering only flips them back and forth
    if (n <= 2) return;

    // offset < 0: content moves left, the windows after the focused one come into view
    const forward = offset < 0;
    const beyond = if (forward) n - 1 - focus_index else focus_index;
    if (beyond >= need) return;
    const moves = @min(need - beyond, n - 1 - beyond);
    if (moves == 0) return;

    // remember where the focused window rests before its neighbours change
    if (output.gesture_rebase == null) {
        if (focus_top.scroller_x) |scroller_x| switch (scroller_x) {
            .x => |x| output.gesture_rebase = .{ .window = focus_top, .rest_x = x },
            .center => {},
        };
    }

    for (0..moves) |i| {
        if (forward) {
            // first window goes after the last one
            const window = windows.items[i];
            const tail = if (i == 0) windows.items[n - 1] else windows.items[i - 1];
            window.link.remove();
            tail.link.insert(&window.link);
            log.debug("move {*} to the end", .{ window });
        } else {
            // last window goes before the first one
            const window = windows.items[n - 1 - i];
            const head = if (i == 0) windows.items[0] else windows.items[n - i];
            const head_rest = if (head.scroller_x) |scroller_x| switch (scroller_x) {
                .x => |x| x,
                .center => head.x - output.gesture_offset_x,
            } else head.x - output.gesture_offset_x;
            window.link.remove();
            head.link.prev.?.insert(&window.link);
            // the window right before the focused one decides where the focused one rests
            window.scroller_x = .{ .x = head_rest - gap - window.width };
            log.debug("move {*} to the front", .{ window });
        }
    }
}


// the current output if its tags can follow the fingers vertically
fn tag_output() ?*Output {
    if (ctx.overview.active) return null;
    const output = ctx.current_output orelse return null;
    if (output.fullscreen_window() != null) return null;
    return output;
}


// pick the tag revealed by a vertical `offset`: dragging up shows the next tag below
fn set_peek(output: *Output, offset: i32) void {
    if (offset == 0) {
        output.gesture_peek_tag = 0;
        return;
    }
    const forward = offset < 0;
    const tag: binding.Tag = .{ .direction = if (forward) .forward else .reverse };
    const peek = tag.of(.{ .output = output });
    if (peek == 0 or peek == output.tag) {
        output.gesture_peek_tag = 0;
        return;
    }
    output.gesture_peek_tag = peek;
    output.gesture_peek_side = if (forward) 1 else -1;
}


// the current output, its scroller can follow the fingers
fn scroller_output() ?*Output {
    if (ctx.overview.active) return null;
    return ctx.current_output;
}


// how many columns to move after a horizontal swipe on the scroller
fn scroll_steps(output: *Output, dx: f64) usize {
    if (@abs(dx) < ctx.cfg.gesture.threshold) return 0;
    const focus_top = ctx.focus_top_in(output, true) orelse return 0;
    const column: f64 = @floatFromInt(focus_top.width + output.scroller().inner_gap);
    const offset = @abs(dx * ctx.cfg.gesture.scroll_factor);
    // a short flick past the threshold still moves one column
    const steps = @max(1, @as(usize, @intFromFloat(@round(offset / column))));
    // never go past the end, wrapping around would jump across the whole strip
    return @min(steps, windows_beyond(output, focus_top, dx < 0));
}


// number of tiled windows after (`forward`) or before the focused one
fn windows_beyond(output: *Output, focus_top: *Window, forward: bool) usize {
    var count: usize = 0;
    var seen_focus = false;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible_in(output) or window.floating) continue;
        if (window == focus_top) {
            seen_focus = true;
            if (!forward) return count;
            continue;
        }
        if (seen_focus) count += 1 else if (!forward) count += 1;
    }
    return count;
}


fn resolve_action(self: *const Self) ?binding.Action {
    // like niri: fingers move left -> content moves left -> go to the next one
    if (@abs(self.dx) >= @abs(self.dy)) {
        if (@abs(self.dx) < ctx.cfg.gesture.threshold) return null;
        return .{ .focus_iter = .{ .direction = if (self.dx < 0) .forward else .reverse } };
    } else {
        if (@abs(self.dy) < ctx.cfg.gesture.threshold) return null;
        return .{ .set_output_tag = .{ .tag = .{ .direction = if (self.dy < 0) .forward else .reverse } } };
    }
}


fn trigger(action: binding.Action) void {
    const seat = ctx.current_seat orelse return;
    seat.append_action(action);
    ctx.rwm.manageDirty();
}


fn open_restricted(path: [*:0]const u8, flags: c_int, _: ?*anyopaque) callconv(.c) c_int {
    const fd = std.c.open(path, @bitCast(@as(u32, @intCast(flags))));
    return if (fd < 0) -@as(c_int, @intCast(@intFromEnum(std.c.errno(fd)))) else fd;
}


fn close_restricted(fd: c_int, _: ?*anyopaque) callconv(.c) void {
    _ = std.c.close(fd);
}
