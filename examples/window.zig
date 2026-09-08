// SPDX-License-Identifier: BSL-1.0

//! A window for a device to draw into, and the device itself.
//!
//! The same file `fluxion-rhi`'s own examples have, because the job is the
//! same: a window from `fluxion-platform`, and the two seams a device needs
//! from one - a `GlHooks` for the OpenGL backend, an `HWND` for Direct3D.
//! Nothing here is part of this library, which emits text and stops.
//!
//! ```zig
//! var window = try Window.open(.{ .backend = .gl });
//! defer window.close();
//! var device = try window.openDevice(gpa, .{});
//! defer device.deinit();
//! const surface = try window.createSurface(&device);
//! ```
//!
//! `fluxion_platform` is a lazy dependency of the examples alone; the library
//! never opens a window.

const std = @import("std");
const builtin = @import("builtin");

const rhi = @import("fluxion_rhi");
const platform = @import("fluxion_platform");

/// The backend a machine most likely has: Direct3D on Windows, OpenGL
/// elsewhere.
pub fn defaultBackend() rhi.Backend {
    return if (builtin.os.tag == .windows) .d3d11 else .gl;
}

pub fn parseBackend(text: []const u8) ?rhi.Backend {
    return std.meta.stringToEnum(rhi.Backend, text);
}

pub const Window = struct {
    inner: *Inner,
    backend: rhi.Backend,
    /// The framebuffer, in pixels.
    width: u32,
    height: u32,
    resized: bool = false,

    /// Boxed, because a `platform.Window` points at its context and the
    /// hooks point at this - neither may move.
    const Inner = struct {
        ctx: platform.Context,
        win: platform.Window,
    };

    pub const Error = platform.Error;

    pub const Options = struct {
        /// Decides whether the window comes with an OpenGL context. Has to be
        /// known here: no platform lets a window change its mind afterwards.
        backend: rhi.Backend,
        title: []const u8 = "Fluxion RHI",
        width: u32 = 960,
        height: u32 = 540,
        visible: bool = true,
    };

    pub fn open(options: Options) Error!Window {
        const gpa = std.heap.smp_allocator;

        const inner = try gpa.create(Inner);
        errdefer gpa.destroy(inner);
        inner.ctx = try platform.Context.init(gpa, .{});
        errdefer inner.ctx.deinit();

        inner.win = try inner.ctx.createWindow(.{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .visible = options.visible,
            .gl = if (options.backend == .gl) .{ .major = 3, .minor = 3, .profile = .core } else null,
        });
        errdefer inner.win.destroy();

        if (options.backend == .gl) {
            try inner.win.makeContextCurrent();
            inner.win.setSwapInterval(.vsync) catch {};
        }

        const size = inner.win.framebufferSize();
        return .{ .inner = inner, .backend = options.backend, .width = size[0], .height = size[1] };
    }

    /// Is this error the machine's answer rather than the program's fault?
    pub fn isAbsent(err: Error) bool {
        return switch (err) {
            error.Unsupported, error.NoDisplay, error.ConnectionFailed, error.WindowCreationFailed, error.Unavailable => true,
            error.OutOfMemory => false,
        };
    }

    /// What the OpenGL backend needs: the context, as four callbacks.
    pub fn hooks(self: Window) rhi.GlHooks {
        return .{
            .context = self.inner,
            .get_proc_address = getProcAddress,
            .swap_buffers = swapBuffers,
            .framebuffer_size = framebufferSize,
        };
    }

    fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.GlProc {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.getProcAddress(name);
    }

    fn swapBuffers(context: *anyopaque) void {
        const inner: *Inner = @ptrCast(@alignCast(context));
        inner.win.swapBuffers() catch {};
    }

    fn framebufferSize(context: *anyopaque) [2]u32 {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.framebufferSize();
    }

    /// The platform's own handle: an `HWND` on Windows.
    pub fn nativeHandle(self: Window) usize {
        return self.inner.win.native();
    }

    pub const DeviceOptions = struct {
        debug: bool = false,
        software: bool = false,
    };

    /// A device on this window's backend.
    pub fn openDevice(self: Window, gpa: std.mem.Allocator, options: DeviceOptions) rhi.Error!rhi.Device {
        return rhi.Device.init(gpa, .{
            .backend = switch (self.backend) {
                .gl => .gl,
                .d3d11 => .d3d11,
                .none => .none,
            },
            .gl = if (self.backend == .gl) self.hooks() else null,
            .debug = options.debug,
            .software = options.software,
        });
    }

    /// The device's surface for this window.
    pub fn createSurface(self: Window, device: *rhi.Device) rhi.Error!rhi.Surface {
        return device.createSurface(.{
            .native_window = self.nativeHandle(),
            .width = self.width,
            .height = self.height,
        });
    }

    /// Drain the events and answer whether the window is still there.
    pub fn pump(self: *Window) bool {
        self.inner.ctx.pump() catch return false;
        while (self.inner.ctx.poll()) |ev| switch (ev) {
            .close => self.inner.win.setShouldClose(true),
            .key => |k| if (k.key == .escape and k.action == .press) self.inner.win.setShouldClose(true),
            .framebuffer_resize => |r| {
                self.width = r.width;
                self.height = r.height;
                self.resized = true;
            },
            else => {},
        };
        return !self.inner.win.shouldClose();
    }

    /// Whether the window changed size since this was last asked.
    pub fn takeResize(self: *Window) bool {
        defer self.resized = false;
        return self.resized;
    }

    pub fn minimised(self: Window) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn close(self: *Window) void {
        self.inner.win.destroy();
        self.inner.ctx.deinit();
        std.heap.smp_allocator.destroy(self.inner);
        self.* = undefined;
    }
};

/// A hidden window with a context for the tests, or a skip where there is
/// no display.
pub fn openForTest(backend: rhi.Backend) !Window {
    return Window.open(.{ .backend = backend, .width = 64, .height = 64, .visible = false }) catch |err|
        if (Window.isAbsent(err)) error.SkipZigTest else err;
}

/// A device for the tests: GL on a hidden window, Direct3D on WARP.
pub const TestDevice = struct {
    window: ?Window,
    device: rhi.Device,

    pub fn open(backend: rhi.Backend) !TestDevice {
        switch (backend) {
            .gl => {
                var window = try openForTest(.gl);
                errdefer window.close();
                const device = window.openDevice(std.testing.allocator, .{ .debug = true }) catch |err| switch (err) {
                    error.NoDevice, error.Unsupported => return error.SkipZigTest,
                    else => return err,
                };
                return .{ .window = window, .device = device };
            },
            .d3d11 => {
                const device = rhi.Device.init(std.testing.allocator, .{ .backend = .d3d11, .software = true }) catch |err| switch (err) {
                    error.NoDevice, error.Unsupported => return error.SkipZigTest,
                    else => return err,
                };
                return .{ .window = null, .device = device };
            },
            .none => return .{ .window = null, .device = try rhi.Device.init(std.testing.allocator, .{ .backend = .none }) },
        }
    }

    pub fn close(self: *TestDevice) void {
        self.device.deinit();
        if (self.window) |*w| w.close();
        self.* = undefined;
    }
};
