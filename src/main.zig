const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    @cDefine("RGFW_VULKAN", "");
    @cInclude("vulkan/vulkan.h");
    @cInclude("RGFW.h");
    @cInclude("cglm/call.h");
});

const WIDTH: u32 = 1200;
const HEIGHT: u32 = 800;

const validationLayers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const deviceExtensions = [_][*c]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

const enableValidationLayers = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: ?*c.RGFW_window,
    instance: c.VkInstance,
    debugMessenger: c.VkDebugUtilsMessengerEXT,
    physicalDevice: c.VkPhysicalDevice = null,
    device: c.VkDevice,
    graphicsQueue: c.VkQueue,
    surface: c.VkSurfaceKHR,
    presentQueue: c.VkQueue,
    swapChain: c.VkSwapchainKHR,
    swapChainImages: []c.VkImage,
    swapChainImageFormat: c.VkFormat,
    swapChainExtent: c.VkExtent2D,

    pub fn init(self: *App) !void {
        self.*.allocator = std.heap.page_allocator;

        try self.initWindow();
        try self.initVulkan();
        self.mainLoop();
    }

    pub fn deinit(self: *App) void {
        c.vkDestroySwapchainKHR(self.*.device, self.*.swapChain, null);
        c.vkDestroyDevice(self.*.device, null);
        if (enableValidationLayers) {
            destroyDebugUtilMessengerEXT(self.instance, self.debugMessenger, null);
        }
        c.vkDestroySurfaceKHR(self.*.instance, self.*.surface, null);
        c.vkDestroyInstance(self.*.instance, null);
        c.RGFW_window_close(self.*.window);
    }

    fn initWindow(self: *App) !void {
        const window = c.RGFW_createWindow("Vulkan", 0, 0, WIDTH, HEIGHT, 0);
        if (window == null) return error.WindowCreationFailed;
        _ = c.RGFW_setWindowResizedCallback(onWindowResize);

        self.*.window = window;
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapChain();
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
        if (enableValidationLayers and !checkValidationLayerSupport()) return error.RequestedValidationLayersUnavailable;
        var instance: c.VkInstance = undefined;
        const appInfo = c.VkApplicationInfo{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Hello Triangle", .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0), .pEngineName = "No Engine", .engineVersion = c.VK_MAKE_VERSION(1, 0, 0), .apiVersion = c.VK_API_VERSION_1_0 };
        var createInfo = c.VkInstanceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &appInfo };

        const extensions = try getRequiredExtensions(self.*.allocator);
        defer self.allocator.free(extensions);

        createInfo.enabledExtensionCount = @as(u32, @intCast(extensions.len));
        createInfo.ppEnabledExtensionNames = extensions.ptr;
        createInfo.enabledLayerCount = 0;

        var debugCreateInfo = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
        if (enableValidationLayers) {
            createInfo.enabledLayerCount = @as(u32, @intCast(validationLayers.len));
            createInfo.ppEnabledLayerNames = &validationLayers;
            populateDebugMessengerCreateInfo(&debugCreateInfo);
            createInfo.pNext = @ptrCast(&debugCreateInfo);
        } else {
            createInfo.enabledLayerCount = 0;
            createInfo.pNext = null;
        }

        const result = c.vkCreateInstance(&createInfo, null, &instance);

        if (result != c.VK_SUCCESS) return error.VkInstanceError else self.*.instance = instance;
    }

    fn createDebugUtilsMessengerEXT(instance: c.VkInstance, pCreateInfo: *const c.VkDebugUtilsMessengerCreateInfoEXT, pAllocator: ?*const c.VkAllocationCallbacks, pDebugMessenger: *c.VkDebugUtilsMessengerEXT) c.VkResult {
        const raw_func = c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");

        const func = @as(c.PFN_vkCreateDebugUtilsMessengerEXT, @ptrCast(raw_func));

        if (func) |f| {
            return f(instance, pCreateInfo, pAllocator, pDebugMessenger);
        } else {
            return c.VK_ERROR_EXTENSION_NOT_PRESENT;
        }
    }

    fn destroyDebugUtilMessengerEXT(instance: c.VkInstance, debugMessenger: c.VkDebugUtilsMessengerEXT, pAllocator: ?*const c.VkAllocationCallbacks) void {
        const raw_func = c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
        const func = @as(c.PFN_vkDestroyDebugUtilsMessengerEXT, @ptrCast(raw_func));

        if (func) |f| {
            return f(instance, debugMessenger, pAllocator);
        }
    }

    fn setupDebugMessenger(self: *App) !void {
        if (!enableValidationLayers) return;

        var createInfo = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
        populateDebugMessengerCreateInfo(&createInfo);

        if (createDebugUtilsMessengerEXT(self.instance, &createInfo, null, &self.debugMessenger) != c.VK_SUCCESS) {
            return error.DebugMessengerSetup;
        }
    }

    fn populateDebugMessengerCreateInfo(createInfo: *c.VkDebugUtilsMessengerCreateInfoEXT) void {
        createInfo.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        createInfo.messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        createInfo.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        createInfo.pfnUserCallback = debugCallback;
        createInfo.pUserData = null;
    }

    fn checkValidationLayerSupport() bool {
        var layerCount: u32 = undefined;
        _ = c.vkEnumerateInstanceLayerProperties(&layerCount, null);
        var availableLayers: [6]c.VkLayerProperties = undefined;
        _ = c.vkEnumerateInstanceLayerProperties(&layerCount, &availableLayers);

        for (validationLayers) |layerName| {
            var layerFound = false;
            for (availableLayers) |layerProperties| {
                // 1. Convert your requested layer name (from your validationLayers array) to a Zig slice
                const requested_name = std.mem.span(layerName);

                // 2. Convert the Vulkan property's fixed C-array to a Zig slice
                const available_name = std.mem.span(@as([*c]const u8, @ptrCast(&layerProperties.layerName)));
                if (std.mem.eql(u8, requested_name, available_name)) {
                    layerFound = true;
                    break;
                }
            }
            if (!layerFound) return false;
        }
        return true;
    }

    fn getRequiredExtensions(allocator: std.mem.Allocator) ![]const [*c]const u8 {
        var rgfwExtensionCount: usize = 0;
        var rgfwExtensions: [*c][*c]const u8 = undefined;

        rgfwExtensions = c.RGFW_getRequiredInstanceExtensions_Vulkan(&rgfwExtensionCount);

        var extensions = std.ArrayList([*c]const u8){};
        errdefer extensions.deinit(allocator);

        var i: usize = 0;
        while (i < rgfwExtensionCount) : (i += 1) {
            try extensions.append(allocator, rgfwExtensions[i]);
        }

        if (enableValidationLayers) try extensions.append(allocator, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

        return extensions.toOwnedSlice(allocator);
    }

    fn debugCallback(messageSeverity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, messageType: c.VkDebugUtilsMessageTypeFlagsEXT, pCallbackData: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, pUserData: ?*anyopaque) callconv(.c) c.VkBool32 {
        _ = messageSeverity;
        _ = messageType;
        _ = pUserData;

        std.debug.print("validation layer: {s}\n", .{pCallbackData.*.pMessage});

        return c.VK_FALSE;
    }

    fn pickPhysicalDevice(self: *App) !void {
        var deviceCount: u32 = undefined;
        _ = c.vkEnumeratePhysicalDevices(self.*.instance, &deviceCount, null);
        if (deviceCount == 0) return error.NoVulkanEnabledGPUsAvailable;

        const devices = try self.*.allocator.alloc(c.VkPhysicalDevice, deviceCount);
        defer self.*.allocator.free(devices);

        _ = c.vkEnumeratePhysicalDevices(self.*.instance, &deviceCount, devices.ptr);

        for (devices) |device| {
            if (try isDeviceSuitable(self, device)) {
                self.*.physicalDevice = device;
                break;
            }
        }

        if (self.*.physicalDevice == null) return error.NoSuitableGPUAvailable;
    }

    fn isDeviceSuitable(self: *App, device: c.VkPhysicalDevice) !bool {
        //var deviceProperties: c.VkPhysicalDeviceProperties = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        //var deviceFeatures: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        //_ = c.vkGetPhysicalDeviceProperties(device, &deviceProperties);
        //_ = c.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);

        //return deviceProperties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and deviceFeatures.geometryShader == 1;
        const indices: QueueFamilyIndices = try findQueueFamilies(self, device);
        const extensionsSupported = try self.checkDeviceExtensionSupport(device);

        var swapChainAdequate = false;
        if (extensionsSupported) {
            var swapChainSupport = try querySwapChainSupport(self, device);
            defer swapChainSupport.deinit();
            swapChainAdequate = (swapChainSupport.formats.items.len != 0) and (swapChainSupport.presentModes.items.len != 0);
        }

        return indices.isComplete() and extensionsSupported and swapChainAdequate;
    }

    const QueueFamilyIndices = struct {
        graphicsFamily: ?u32 = null,
        presentFamily: ?u32 = null,

        pub fn isComplete(self: QueueFamilyIndices) bool {
            return (self.graphicsFamily != null) and (self.presentFamily != null);
        }
    };

    fn findQueueFamilies(self: *App, device: c.VkPhysicalDevice) !QueueFamilyIndices {
        var indices = QueueFamilyIndices{ .graphicsFamily = null };

        var queueFamilyCount: u32 = undefined;
        _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, null);

        const queueFamilies = try self.allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
        defer self.*.allocator.free(queueFamilies);

        _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, queueFamilies.ptr);

        var i: u32 = 0;
        for (queueFamilies) |queueFamily| {
            if (queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                indices.graphicsFamily = i;
                var presentSupport = c.VK_FALSE;
                _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, i, self.*.surface, &presentSupport);
                if (presentSupport == c.VK_TRUE) indices.presentFamily = i;
            }

            if (indices.isComplete()) break;
            i += 1;
        }

        return indices;
    }

    fn checkDeviceExtensionSupport(self: *App, device: c.VkPhysicalDevice) !bool {
        var extensionCount: u32 = 0;
        _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extensionCount, null);

        const availableExtensions = try self.allocator.alloc(c.VkExtensionProperties, extensionCount);
        defer self.allocator.free(availableExtensions);

        _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extensionCount, availableExtensions.ptr);

        var requiredExtensionsFound: usize = 0;

        for (deviceExtensions) |requiredExt| {
            // Convert the required C-string pointer to a Zig slice
            const required_name = std.mem.span(requiredExt);
            var found = false;

            for (availableExtensions) |availableExt| {
                // Convert the Vulkan array to a C-pointer, then to a Zig slice
                const available_name = std.mem.span(@as([*c]const u8, @ptrCast(&availableExt.extensionName)));
                if (std.mem.eql(u8, required_name, available_name)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                requiredExtensionsFound += 1;
            }
        }

        return requiredExtensionsFound == deviceExtensions.len;
    }

    fn createLogicalDevice(self: *App) !void {
        const indices = try findQueueFamilies(self, self.*.physicalDevice);

        var queueCreateInfos = std.ArrayList(c.VkDeviceQueueCreateInfo){};
        defer queueCreateInfos.deinit(self.*.allocator);

        var uniqueFamilyQueues = std.AutoHashMap(u32, void).init(self.*.allocator);
        defer uniqueFamilyQueues.deinit();

        try uniqueFamilyQueues.put(indices.graphicsFamily.?, {});
        try uniqueFamilyQueues.put(indices.presentFamily.?, {});

        var queuePriority: f32 = 1.0;
        var it = uniqueFamilyQueues.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;

            const queueCreateInfo = c.VkDeviceQueueCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = key, .queueCount = 1, .pQueuePriorities = &queuePriority };
            try queueCreateInfos.append(self.*.allocator, queueCreateInfo);
        }
        var deviceFeatures = c.VkPhysicalDeviceFeatures{};

        var createInfo = c.VkDeviceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pQueueCreateInfos = queueCreateInfos.items.ptr, .queueCreateInfoCount = 1, .pEnabledFeatures = &deviceFeatures, .enabledExtensionCount = @as(u32, @intCast(deviceExtensions.len)), .ppEnabledExtensionNames = &deviceExtensions };

        if (enableValidationLayers) {
            createInfo.enabledLayerCount = @as(u32, @intCast(validationLayers.len));
            createInfo.ppEnabledLayerNames = &validationLayers;
        } else {
            createInfo.enabledLayerCount = 0;
        }

        if (c.vkCreateDevice(self.*.physicalDevice, &createInfo, null, &self.*.device) != c.VK_SUCCESS) {
            return error.LogicalDeviceCreationFailure;
        }

        c.vkGetDeviceQueue(self.*.device, indices.graphicsFamily.?, 0, &self.*.graphicsQueue);
        c.vkGetDeviceQueue(self.*.device, indices.presentFamily.?, 0, &self.*.presentQueue);
    }

    fn createSwapChain(self: *App) !void {
        var swapChainSupport = try querySwapChainSupport(self, self.*.physicalDevice);
        defer swapChainSupport.deinit();

        const surfaceFormat = chooseSwapSurfaceFormat(swapChainSupport.formats.items);
        const presentMode = chooseSwapPresentMode(swapChainSupport.presentModes.items);
        const extent = chooseSwapExtent(self, swapChainSupport.capabilities);

        var imageCount: u32 = swapChainSupport.capabilities.minImageCount + 1;
        if (swapChainSupport.capabilities.maxImageCount > 0 and imageCount > swapChainSupport.capabilities.maxImageCount) {
            imageCount = swapChainSupport.capabilities.maxImageCount;
        }

        //var createInfo = c.VkSwapchainCreateInfoKHR{ .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = self.surface, .minImageCount = imageCount, .imageFormat = surfaceFormat.format, .imageColorSpace = surfaceFormat.colorSpace, .imageExtent = extent, .imageArrayLayers = 1, .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
        var createInfo = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = imageCount,
            .imageFormat = surfaceFormat.format,
            .imageColorSpace = surfaceFormat.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .preTransform = swapChainSupport.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = presentMode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,

            // These will be overridden below if sharing mode is concurrent
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .pNext = null,
            .flags = 0,
        };

        const indices = try self.findQueueFamilies(self.physicalDevice);

        const queueFamilyIndices = [_]u32{ indices.graphicsFamily.?, indices.presentFamily.? };

        if (indices.graphicsFamily.? != indices.presentFamily.?) {
            createInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            createInfo.queueFamilyIndexCount = 2;
            // Pass the memory address of the fixed array we just created
            createInfo.pQueueFamilyIndices = &queueFamilyIndices;
        }

        if (c.vkCreateSwapchainKHR(self.device, &createInfo, null, &self.swapChain) != c.VK_SUCCESS) {
            return error.SwapchainCreationFailure;
        }

        var actualImageCount: u32 = 0;
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapChain, &actualImageCount, null);

        self.swapChainImages = try self.allocator.alloc(c.VkImage, actualImageCount);

        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapChain, &actualImageCount, self.swapChainImages.ptr);

        self.swapChainImageFormat = surfaceFormat.format;
        self.swapChainExtent = extent;
    }

    fn createSurface(self: *App) !void {
        if (c.RGFW_window_createSurface_Vulkan(self.window, self.instance, &self.surface) != c.VK_SUCCESS) {
            return error.SurfaceCreationFailure;
        }
    }

    const SwapChainSupportDetails = struct {
        allocator: std.mem.Allocator,
        capabilities: c.VkSurfaceCapabilitiesKHR,
        formats: std.ArrayList(c.VkSurfaceFormatKHR),
        presentModes: std.ArrayList(c.VkPresentModeKHR),

        pub fn deinit(self: *SwapChainSupportDetails) void {
            self.formats.deinit(self.allocator);
            self.presentModes.deinit(self.allocator);
        }
    };

    fn querySwapChainSupport(self: *App, device: c.VkPhysicalDevice) !SwapChainSupportDetails {
        var details = SwapChainSupportDetails{
            .allocator = self.*.allocator,
            .capabilities = .{},
            .formats = std.ArrayList(c.VkSurfaceFormatKHR){},
            .presentModes = std.ArrayList(c.VkPresentModeKHR){},
        };

        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.*.surface, &details.capabilities);

        var formatCount: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.*.surface, &formatCount, null);

        if (formatCount != 0) {
            try details.formats.resize(self.*.allocator, formatCount);
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.*.surface, &formatCount, details.formats.items.ptr);
        }

        var presentModeCount: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.*.surface, &presentModeCount, null);

        if (presentModeCount != 0) {
            try details.presentModes.resize(self.*.allocator, presentModeCount);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.*.surface, &presentModeCount, details.presentModes.items.ptr);
        }

        return details;
    }

    fn chooseSwapSurfaceFormat(availableForms: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
        for (availableForms) |availableForm| {
            if (availableForm.format == c.VK_FORMAT_B8G8R8A8_SRGB and availableForm.colorSpace == c.VK_COLORSPACE_SRGB_NONLINEAR_KHR) {
                return availableForm;
            }
        }
        return availableForms[0];
    }

    fn chooseSwapPresentMode(availablePresentModes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
        for (availablePresentModes) |availablePresentMode| {
            if (availablePresentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return availablePresentMode;
            }
        }
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn chooseSwapExtent(self: *App, capabilities: c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        } else {
            var height: i32 = 0;
            var width: i32 = 0;
            _ = c.RGFW_window_getSize(self.*.window.?, &width, &height);

            var actualExtent = c.VkExtent2D{
                .height = @intCast(height),
                .width = @intCast(width),
            };

            actualExtent.width = std.math.clamp(actualExtent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);

            actualExtent.height = std.math.clamp(actualExtent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);

            return actualExtent;
        }
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
