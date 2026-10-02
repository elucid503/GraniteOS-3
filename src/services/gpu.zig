const std = @import("std");

const svga = @import("svga.zig");

const api = @import("api");
const gui = @import("gui");

// SVGA3D commands, numbered as in VMware's svga3d_cmd.h; "memory objects" are its MOBs.
const set_z_range = 1048;
const set_render_state = 1049;
const set_render_target = 1050;
const set_texture_state = 1051;
const set_viewport = 1055;
const clear = 1057;
const set_shader = 1061;
const draw = 1063;
const destroy_object = 1094;
const define_surface = 1097;
const destroy_surface = 1098;
const bind_surface = 1099;
const update_image = 1101;
const readback_image = 1103;
const define_context = 1107;
const bind_context = 1109;
const define_shader = 1112;
const bind_shader = 1114;
const set_table = 1115;
const define_target = 1124;
const bind_target = 1126;
const update_target = 1127;
const define_object = 1135;

// Surface formats and flags.
const x8r8g8b8 = 1;
const buffer = 37;
const vertex_hint = 1 << 4;
const texture_hint = 1 << 5;
const target_hint = 1 << 6;
const scanout = 1 << 16;

// Page table depths for 64-bit page numbers: the data page itself, one level of tables, or two.
const flat = 4;
const one_level = 5;
const two_levels = 6;

const color0 = 2;
const clear_color = 1;
const vertex_shader = 1;
const pixel_shader = 2;
const float2 = 1;
const position = 0;
const texcoord = 5;
const triangle_list = 1;
const no_id = 0xffffffff;
const primary = 1;

// Render states and their values.
const z_enable = 1;
const z_write = 2;
const alpha_test = 3;
const blend = 5;
const fog = 6;
const stencil = 8;
const lighting = 9;
const shade_mode = 30;
const smooth = 2;
const cull_mode = 35;
const cull_none = 1;

// Texture states and their values.
const bind_texture = 1;
const address_u = 8;
const address_v = 9;
const mip_filter = 10;
const mag_filter = 11;
const min_filter = 12;
const clamp = 3;
const nearest = 1;

// vs_2_0: dcl_position v0; dcl_texcoord v1; mov oPos, v0; mov oT0.xy, v1
const passthrough = [_]u32{ 0xfffe0200, 0x0200001f, 0x80000000, 0x900f0000, 0x0200001f, 0x80000005, 0x900f0001, 0x02000001, 0xc00f0000, 0x90e40000, 0x02000001, 0xe0030000, 0x90e40001, 0x0000ffff };

// ps_2_0: dcl t0.xy; dcl_2d s0; texld r0, t0, s0; mov oC0, r0
const sample = [_]u32{ 0xffff0200, 0x0200001f, 0x80000000, 0xb0030000, 0x0200001f, 0x90000000, 0xa00f0800, 0x03000042, 0x800f0000, 0xb0e40000, 0xa0e40800, 0x02000001, 0x800f0800, 0x80e40000, 0x0000ffff };

// Object ids; every surface keeps its pixels in the memory object of the same id.
const frame = 0;
const vertices = 1;
const probe = 2;
const result = 3;
const code = 4;
const state = 5;
const textures = 6;

// One page holds each object table: memory objects, surfaces, contexts, shaders, and screen targets.
const tables = 5;

const context = 0;
const quad_bytes = 6 * 4 * @sizeOf(f32);

// A legacy context saves 16 KiB of state.
const state_pages = 4;

/// Most surfaces one frame can draw.
pub const layers = 16;

/// A client surface as it sits on screen.
pub const Layer = struct {

    index: u32,
    area: gui.Rect,

};

/// Composes client surfaces on the SVGA3D device: each is a texture, drawn as a quad into a frame a screen target shows.
pub const Gpu = struct {

    device: *svga.Device,
    width: u32,
    height: u32,

    /// CPU views of the vertex staging page, the self-test texture, and what the self-test reads back.
    staging: api.Page,
    texels: api.Page,
    readback: api.Page,

    /// Page tables per memory object, kept so a later surface in the same slot reuses them.
    paging: [textures + layers]Paging = [_]Paging{.{}} ** (textures + layers),

    /// How far pixel centres sit from each pixel's top-left corner; the self-test settles it.
    shift: f32 = 0.5,

    /// Draws into a `width` by `height` frame and shows it; null, leaving the screen alone, unless a test pattern draws exactly.
    pub fn init(device: *svga.Device, width: u32, height: u32) ?Gpu {

        if (!device.accelerated) return null;

        return setup(device, width, height) catch null;

    }

    fn setup(device: *svga.Device, width: u32, height: u32) !?Gpu {

        // Tables from an earlier display are dropped along with every object they held.
        for (0..tables) |kind| {

            const page = try api.dma();

            device.submit(set_table, &.{ @intCast(kind), @truncate(page.physical >> 12), @intCast(page.physical >> 44), 4096, 0, flat });

        }

        var gpu = Gpu{

            .device = device,
            .width = width,
            .height = height,

            .staging = undefined,
            .texels = undefined,
            .readback = undefined,

        };

        // The device may write context state and rendered frames back at any time, so those pages outlive us.
        _ = try gpu.reserve(state, state_pages);
        _ = try gpu.reserve(frame, (width * height * 4 + 4095) / 4096);

        const program = try gpu.reserve(code, 1);

        gpu.staging = try gpu.reserve(vertices, 1);
        gpu.texels = try gpu.reserve(probe, 1);
        gpu.readback = try gpu.reserve(result, 1);

        @memcpy(program.bytes[0..@sizeOf(@TypeOf(passthrough))], std.mem.asBytes(&passthrough));
        @memcpy(program.bytes[256..][0..@sizeOf(@TypeOf(sample))], std.mem.asBytes(&sample));

        gpu.surface(frame, texture_hint | target_hint | scanout, x8r8g8b8, width, height);
        gpu.surface(vertices, vertex_hint, buffer, layers * quad_bytes, 1);
        gpu.surface(probe, texture_hint, x8r8g8b8, 2, 2);
        gpu.surface(result, target_hint, x8r8g8b8, 4, 4);

        device.submit(define_context, &.{context});
        device.submit(bind_context, &.{ context, state, 0 });
        device.submit(define_shader, &.{ 0, vertex_shader, @sizeOf(@TypeOf(passthrough)) });
        device.submit(bind_shader, &.{ 0, code, 0 });
        device.submit(define_shader, &.{ 1, pixel_shader, @sizeOf(@TypeOf(sample)) });
        device.submit(bind_shader, &.{ 1, code, 256 });
        device.submit(set_z_range, &.{ context, @bitCast(@as(f32, 0)), @bitCast(@as(f32, 1)) });

        // Flat shading takes a slow path on some hosts; nothing here is depth-tested, lit, fogged, culled, or blended.
        device.submit(set_render_state, &.{

            context,
            shade_mode, smooth,
            z_enable, 0,
            z_write, 0,
            alpha_test, 0,
            blend, 0,
            fog, 0,
            stencil, 0,
            lighting, 0,
            cull_mode, cull_none,

        });

        // Point sampling at texel centres copies client pixels exactly.
        device.submit(set_texture_state, &.{

            context,
            0, min_filter, nearest,
            0, mag_filter, nearest,
            0, mip_filter, 0,
            0, address_u, clamp,
            0, address_v, clamp,

        });

        device.submit(set_shader, &.{ context, vertex_shader, 0 });
        device.submit(set_shader, &.{ context, pixel_shader, 1 });

        // Hosts disagree on where pixel centres fall, so take whichever convention draws the pattern exactly.
        const settled = for ([_]f32{ 0.5, 0 }) |shift| {

            gpu.shift = shift;
            if (gpu.check()) break true;

        } else false;

        if (!settled) return null;

        device.submit(set_render_target, &.{ context, color0, frame, 0, 0 });
        device.submit(set_viewport, &.{ context, 0, 0, width, height });

        device.retire();
        device.submit(define_target, &.{ 0, width, height, 0, 0, primary, 0 });
        device.submit(bind_target, &.{ 0, frame, 0, 0 });

        return gpu;

    }

    /// Makes client surface `index` drawable from `memory`, a `width` by `height` image; false when it does not fit.
    pub fn adopt(self: *Gpu, index: u32, memory: []align(4096) const u8, width: u32, height: u32) bool {

        const id = textures + index;
        const paging = &self.paging[id];

        for (0..memory.len / 4096) |page| {

            const physical = api.physical(@intFromPtr(memory.ptr) + page * 4096) catch return false;

            paging.set(page, physical) catch return false;

        }

        self.describe(id, memory.len / 4096) catch return false;
        self.surface(id, texture_hint, x8r8g8b8, width, height);
        self.upload(index, .{

            .width = @intCast(width),
            .height = @intCast(height),

        });

        return true;

    }

    /// Copies `area` of client surface `index` into its texture.
    pub fn upload(self: *Gpu, index: u32, area: gui.Rect) void {

        self.update(textures + index, @intCast(area.x), @intCast(area.y), @intCast(area.width), @intCast(area.height));

    }

    /// Drops client surface `index`; once this returns the device no longer touches its memory.
    pub fn release(self: *Gpu, index: u32) void {

        self.device.submit(destroy_surface, &.{textures + index});
        self.device.submit(destroy_object, &.{textures + index});
        self.device.idle();

    }

    /// Redraws the frame from `stack`, bottom first, and shows `area` of it.
    pub fn compose(self: *Gpu, area: gui.Rect, stack: []const Layer) void {

        self.device.submit(clear, &.{ context, clear_color, gui.theme.background, @bitCast(@as(f32, 1)), 0, 0, 0, self.width, self.height });
        for (stack, 0..) |layer, slot| self.quad(@intCast(slot), textures + layer.index, layer.area, self.width, self.height);

        self.device.submit(update_target, &.{ 0, @intCast(area.x), @intCast(area.y), @intCast(area.width), @intCast(area.height) });

        // Clients redraw as soon as we reply, so their pixels must already be copied.
        self.device.idle();

    }

    /// Draws a two-by-two texture one pixel in from the corner of a four-by-four target; true when every pixel lands exactly.
    fn check(self: *Gpu) bool {

        const texels = [4]u32{ 0xff0000, 0x00ff00, 0x0000ff, 0xffffff };
        const border = 0x808080;

        @memcpy(self.texels.bytes[0..16], std.mem.asBytes(&texels));
        self.update(probe, 0, 0, 2, 2);

        self.device.submit(set_render_target, &.{ context, color0, result, 0, 0 });
        self.device.submit(set_viewport, &.{ context, 0, 0, 4, 4 });
        self.device.submit(clear, &.{ context, clear_color, border, @bitCast(@as(f32, 1)), 0, 0, 0, 4, 4 });
        self.quad(0, probe, .{

            .x = 1,
            .y = 1,
            .width = 2,
            .height = 2,

        }, 4, 4);

        self.device.submit(readback_image, &.{ result, 0, 0 });
        self.device.idle();

        const pixels: *const volatile [16]u32 = @ptrCast(self.readback.bytes);

        for (0..4) |y| {

            for (0..4) |x| {

                const inside = (x == 1 or x == 2) and (y == 1 or y == 2);
                const expected: u32 = if (inside) texels[(y - 1) * 2 + x - 1] else border;
                const actual = pixels[y * 4 + x] & 0xffffff;

                if (actual == expected) continue;

                var line: [80]u8 = undefined;

                api.log(std.fmt.bufPrint(&line, "display: 3D self-test read {x} at ({d}, {d}), shift {d}\n", .{ actual, x, y, self.shift }) catch unreachable);

                return false;

            }

        }

        return true;

    }

    /// Draws texture `sid` over `area` of a `columns` by `rows` target, staging its corners in vertex slot `slot`.
    fn quad(self: *Gpu, slot: u32, sid: u32, area: gui.Rect, columns: u32, rows: u32) void {

        const offset = slot * quad_bytes;
        const corners = place(area.x, area.y, area.width, area.height, columns, rows, self.shift);

        @memcpy(self.staging.bytes[offset..][0..quad_bytes], std.mem.asBytes(&corners));
        self.update(vertices, offset, 0, quad_bytes, 1);
        self.device.submit(set_texture_state, &.{ context, 0, bind_texture, sid });

        // Two arrays read the interleaved position and texture coordinate, then one unindexed range of two triangles.
        self.device.submit(draw, &.{

            context, 2, 1,
            float2, 0, position, 0, vertices, offset, 16, 0, 0,
            float2, 0, texcoord, 0, vertices, offset + 8, 16, 0, 0,
            triangle_list, 2, no_id, 0, 0, 0, 0,

        });

    }

    /// Copies a box of surface `sid` from its memory object to the device's copy.
    fn update(self: *Gpu, sid: u32, x: u32, y: u32, width: u32, height: u32) void {

        self.device.submit(update_image, &.{ sid, 0, 0, x, y, 0, width, height, 1 });

    }

    /// Defines surface `id` and binds it to the memory object of the same id.
    fn surface(self: *Gpu, id: u32, flags: u32, format: u32, width: u32, height: u32) void {

        // One mipmap level, no multisampling, no automatic mipmap filter.
        self.device.submit(define_surface, &.{ id, flags, format, 1, 0, 0, width, height, 1 });
        self.device.submit(bind_surface, &.{ id, id });

    }

    /// Makes memory object `id` from `count` fresh pages, which stay ours even after we exit; returns the first.
    fn reserve(self: *Gpu, id: u32, count: usize) !api.Page {

        var first: api.Page = undefined;

        for (0..count) |index| {

            const page = try api.dma();

            if (index == 0) first = page;
            try self.paging[id].set(index, page.physical);

        }

        try self.describe(id, count);

        return first;

    }

    /// Defines memory object `id` over the `count` pages its page tables list.
    fn describe(self: *Gpu, id: u32, count: usize) !void {

        const paging = &self.paging[id];
        var depth: u32 = one_level;
        var root = paging.pages[1].?.physical;

        if (count > 512) {

            if (paging.pages[0] == null) paging.pages[0] = try api.dma();

            const directory: *[512]u64 = @ptrCast(paging.pages[0].?.bytes);

            for (0..(count + 511) / 512) |leaf| directory[leaf] = paging.pages[1 + leaf].?.physical >> 12;

            depth = two_levels;
            root = paging.pages[0].?.physical;

        }

        self.device.submit(define_object, &.{ id, depth, @truncate(root >> 12), @intCast(root >> 44), @intCast(count * 4096) });

    }

};

/// Page tables listing up to 2048 pages (8 MiB): a directory, then up to four leaves of 512 page numbers each.
const Paging = struct {

    pages: [5]?api.Page = [_]?api.Page{null} ** 5,

    fn set(self: *Paging, index: usize, physical: u64) !void {

        if (index >= 4 * 512) return error.TooLarge;

        const leaf = &self.pages[1 + index / 512];

        if (leaf.* == null) leaf.* = try api.dma();

        const entries: *[512]u64 = @ptrCast(leaf.*.?.bytes);

        entries[index % 512] = physical >> 12;

    }

};

/// Clip-space corners and texture coordinates of two triangles covering an area of a `columns` by `rows` frame.
pub fn place(x: i32, y: i32, width: i32, height: i32, columns: u32, rows: u32, shift: f32) [24]f32 {

    const left = clip(x, columns, shift);
    const right = clip(x + width, columns, shift);
    const top = -clip(y, rows, shift);
    const bottom = -clip(y + height, rows, shift);

    return .{

        left, top, 0, 0,
        right, top, 1, 0,
        right, bottom, 1, 1,
        left, top, 0, 0,
        right, bottom, 1, 1,
        left, bottom, 0, 1,

    };

}

fn clip(edge: i32, span: u32, shift: f32) f32 {

    return (@as(f32, @floatFromInt(edge)) - shift) * 2 / @as(f32, @floatFromInt(span)) - 1;

}
