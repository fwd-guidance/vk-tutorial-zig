const std = @import("std");
const c = @cImport({
    @cDefine("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    @cDefine("RGFW_VULKAN", "");
    @cInclude("vulkan/vulkan.h");
    @cInclude("RGFW.h");
    @cInclude("cglm/call.h");
});

const WIDTH: u32 = 1200;
const HEIGHT: u32 = 800;

pub const App = struct {
    window: ?*c.RGFW_window,
    instance: c.VkInstance,

    pub fn init(self: *App) !void {
        try self.initWindow();
        try self.initVulkan();
        self.mainLoop();
    }

    pub fn deinit(self: *App) void {
        c.RGFW_window_close(self.window);
    }

    fn initWindow(self: *App) !void {
        const window = c.RGFW_createWindow("Vulkan", 0, 0, WIDTH, HEIGHT, 0);
        if (window == null) return error.WindowCreationFailed;
        _ = c.RGFW_setWindowResizedCallback(onWindowResize);

        self.*.window = window;
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
    }

    fn mainLoop(self: *App) void {
        var running = true;
        while (running) {
            var event: c.RGFW_event = undefined;
            while (c.RGFW_window_checkEvent(self.window, &event) != 0) {
                switch (event.type) {
                    c.RGFW_quit => {
                        running = false;
                    },
                    c.RGFW_keyPressed => {
                        if (event.key.value == c.RGFW_escape) {
                            running = false;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn createInstance(self: *App) !void {
        var instance: c.VkInstance = undefined;
        const appInfo = c.VkApplicationInfo{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Hello Triangle", .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0), .pEngineName = "No Engine", .engineVersion = c.VK_MAKE_VERSION(1, 0, 0), .apiVersion = c.VK_API_VERSION_1_0 };
        var createInfo = c.VkInstanceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &appInfo };
        var rgfwExtensionCount: usize = undefined;
        var rgfwExtensions: [*c][*c]const u8 = undefined;
        rgfwExtensions = c.RGFW_getRequiredInstanceExtensions_Vulkan(&rgfwExtensionCount);

        createInfo.enabledExtensionCount = @as(u32, @intCast(rgfwExtensionCount));
        createInfo.ppEnabledExtensionNames = rgfwExtensions;
        createInfo.enabledLayerCount = 0;

        std.debug.print("{any}, {any}", .{ rgfwExtensions, rgfwExtensionCount });

        const result = c.vkCreateInstance(&createInfo, null, &instance);

        if (result != c.VK_SUCCESS) return error.VkInstanceError else self.*.instance = instance;
    }
};

pub fn main() !void {
    var app: App = undefined;
    try app.init();
    defer app.deinit();
}

fn onWindowResize(window: ?*c.RGFW_window, width: c_int, height: c_int) callconv(.c) void {
    _ = window;
    _ = width;
    _ = height;
}

pub fn window_example() !void {
    const window = c.RGFW_createWindow("Vulkan window", 0, 0, 800, 600, 0);
    if (window == null) return error.WindowCreationFailed;

    defer c.RGFW_window_close(window);

    _ = c.RGFW_setWindowResizedCallback(onWindowResize);

    var extensionCount: u32 = 0;
    _ = c.vkEnumerateInstanceExtensionProperties(null, &extensionCount, null);
    std.debug.print("{d} extensions supported\n", .{extensionCount});

    var matrix: c.mat4 = undefined;
    c.glmc_mat4_identity(&matrix);

    var vec = c.vec4{ 1.0, 2.0, 3.0, 4.0 };
    var t: c.vec4 = undefined;

    // Execute matrix * vec
    c.glmc_mat4_mulv(&matrix, &vec, &t);
    std.debug.print("Vector multiplied: [{d}, {d}, {d}, {d}]\n", .{ t[0], t[1], t[2], t[3] });

    var running = true;
    while (running) {
        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(window, &event) != 0) {
            switch (event.type) {
                c.RGFW_quit => {
                    running = false;
                },
                c.RGFW_keyPressed => {
                    if (event.key.value == c.RGFW_escape) {
                        running = false;
                    }
                },
                else => {},
            }
        }
    }
}
