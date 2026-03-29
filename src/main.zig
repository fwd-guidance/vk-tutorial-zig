const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    @cDefine("RGFW_VULKAN", "");
    @cInclude("vulkan/vulkan.h");
    @cInclude("RGFW.h");
    @cInclude("cglm/call.h");
});

const shaders = @import("shaders");

const WIDTH: u32 = 1200;
const HEIGHT: u32 = 800;

const validationLayers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const deviceExtensions = [_][*c]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
const MAX_FRAMES_IN_FLIGHT = 2;
var currentFrame: u32 = 0;

const enableValidationLayers = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

const vertices = [_]Vertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1.0, 1.0, 1.0 } },
};

const INDICES = [_]u16{ 0, 1, 2, 2, 3, 0 };

pub const UniformBufferObject = extern struct {
    model: c.mat4 align(16),
    view: c.mat4 align(16),
    proj: c.mat4 align(16),
};

pub const Vertex = extern struct {
    pos: c.vec2,
    color: c.vec3,

    pub fn init(pos_x: f32, pos_y: f32, r: f32, g: f32, b: f32) Vertex {
        return .{
            .pos = .{ pos_x, pos_y },
            .color = .{ r, g, b },
        };
    }

    pub fn getBindingDescription() c.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn getAttributeDescriptions() [2]c.VkVertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    startTime: i64,
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
    swapChainImageViews: []c.VkImageView,
    renderPass: c.VkRenderPass,
    descriptorSetLayout: c.VkDescriptorSetLayout,
    pipelineLayout: c.VkPipelineLayout,
    graphicsPipeline: c.VkPipeline,
    swapChainFramebuffers: []c.VkFramebuffer,
    commandPool: c.VkCommandPool,
    commandBuffers: [MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,

    imageAvailableSemaphores: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    renderFinishedSemaphores: []c.VkSemaphore,
    inFlightFences: [MAX_FRAMES_IN_FLIGHT]c.VkFence,
    framebufferResized: bool = false,

    vertexBuffer: c.VkBuffer,
    vertexBufferMemory: c.VkDeviceMemory,
    indexBuffer: c.VkBuffer,
    indexBufferMemory: c.VkDeviceMemory,
    uniformBuffers: [MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    uniformBuffersMemory: [MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    uniformBuffersMapped: [MAX_FRAMES_IN_FLIGHT]?*anyopaque,
    descriptorPool: c.VkDescriptorPool,
    descriptorSets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,

    pub fn init(self: *App) !void {
        //self.*.allocator = std.heap.page_allocator;
        self.startTime = std.time.milliTimestamp();

        try self.initWindow();
        try self.initVulkan();
        try self.mainLoop();
    }

    pub fn deinit(self: *App) void {
        self.cleanupSwapChain();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            c.vkDestroyBuffer(self.device, self.uniformBuffers[i], null);
            c.vkFreeMemory(self.device, self.uniformBuffersMemory[i], null);
        }

        c.vkDestroyDescriptorPool(self.device, self.descriptorPool, null);

        c.vkDestroyDescriptorSetLayout(self.device, self.descriptorSetLayout, null);

        c.vkDestroyBuffer(self.device, self.indexBuffer, null);
        c.vkFreeMemory(self.device, self.indexBufferMemory, null);

        c.vkDestroyBuffer(self.device, self.vertexBuffer, null);
        c.vkFreeMemory(self.device, self.vertexBufferMemory, null);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            c.vkDestroySemaphore(self.*.device, self.imageAvailableSemaphores[i], null);
            c.vkDestroyFence(self.*.device, self.inFlightFences[i], null);
        }

        for (self.renderFinishedSemaphores) |semaphore| {
            c.vkDestroySemaphore(self.*.device, semaphore, null);
        }
        self.allocator.free(self.renderFinishedSemaphores);

        c.vkDestroyCommandPool(self.*.device, self.*.commandPool, null);

        c.vkDestroyPipeline(self.*.device, self.*.graphicsPipeline, null);
        c.vkDestroyPipelineLayout(self.*.device, self.*.pipelineLayout, null);
        c.vkDestroyRenderPass(self.*.device, self.*.renderPass, null);
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

        c.RGFW_window_setUserPtr(window, self);
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
        try self.createImageViews();
        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipeline();
        try self.createFramebuffers();
        try self.createCommandPool();
        try self.createVertexBuffer();
        try self.createIndexBuffer();
        try self.createUniformBuffers();
        try self.createDescriptorPool();
        try self.createDescriptorSets();
        try self.createCommandBuffer();
        try self.createSyncObjects();
    }

    fn mainLoop(self: *App) !void {
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
            try self.drawFrame();
        }
        _ = c.vkDeviceWaitIdle(self.*.device);
    }

    fn drawFrame(self: *App) !void {
        _ = c.vkWaitForFences(self.*.device, 1, &self.inFlightFences[currentFrame], c.VK_TRUE, std.math.maxInt(u64));

        var imageIndex: u32 = 0;
        var res = c.vkAcquireNextImageKHR(self.*.device, self.swapChain, std.math.maxInt(u64), self.imageAvailableSemaphores[currentFrame], null, &imageIndex);

        if (res == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapChain();
            return;
        } else if (res != c.VK_SUCCESS and res != c.VK_SUBOPTIMAL_KHR) {
            return error.SwapChainImageAcquisition;
        }

        self.updateUniformBuffer(currentFrame);

        _ = c.vkResetFences(self.*.device, 1, &self.inFlightFences[currentFrame]);
        _ = c.vkResetCommandBuffer(self.commandBuffers[currentFrame], 0);
        try self.recordCommandBuffer(self.commandBuffers[currentFrame], imageIndex);

        const waitSemaphores = [_]c.VkSemaphore{self.imageAvailableSemaphores[currentFrame]};
        const waitStages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signalSemaphores = [_]c.VkSemaphore{self.renderFinishedSemaphores[imageIndex]};
        const submitInfo = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &waitSemaphores,
            .pWaitDstStageMask = &waitStages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.commandBuffers[currentFrame],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signalSemaphores,
        };

        if (c.vkQueueSubmit(self.*.graphicsQueue, 1, &submitInfo, self.inFlightFences[currentFrame]) != c.VK_SUCCESS) {
            return error.DrawCommandBufferSubmission;
        }

        const swapChains = [_]c.VkSwapchainKHR{self.swapChain};
        const presentInfo = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signalSemaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapChains,
            .pImageIndices = &imageIndex,
            .pResults = null,
        };

        res = c.vkQueuePresentKHR(self.presentQueue, &presentInfo);
        if (res == c.VK_ERROR_OUT_OF_DATE_KHR or res == c.VK_SUBOPTIMAL_KHR or self.framebufferResized) {
            self.framebufferResized = true;
            try self.recreateSwapChain();
        } else if (res != c.VK_SUCCESS) {
            return error.SwapChainImagePresentation;
        }

        currentFrame = (currentFrame + 1) % MAX_FRAMES_IN_FLIGHT;
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

    fn recreateSwapChain(self: *App) !void {
        var height: i32 = 0;
        var width: i32 = 0;
        _ = c.RGFW_window_getSizeInPixels(self.window, &width, &height);

        while (width == 0 or height == 0) {
            _ = c.RGFW_waitForEvent(10);
            var event: c.RGFW_event = undefined;
            _ = c.RGFW_window_checkEvent(self.window, &event);

            _ = c.RGFW_window_getSizeInPixels(self.window, &width, &height);
        }

        _ = c.vkDeviceWaitIdle(self.device);

        self.cleanupSwapChain();

        try self.createSwapChain();
        try self.createImageViews();
        try self.createFramebuffers();
    }

    fn cleanupSwapChain(self: *App) void {
        for (self.swapChainFramebuffers) |fb| {
            c.vkDestroyFramebuffer(self.device, fb, null);
        }
        self.allocator.free(self.swapChainFramebuffers);

        for (self.swapChainImageViews) |iv| {
            c.vkDestroyImageView(self.device, iv, null);
        }
        self.allocator.free(self.swapChainImageViews);

        self.allocator.free(self.swapChainImages);

        c.vkDestroySwapchainKHR(self.device, self.swapChain, null);
    }

    fn createImageViews(self: *App) !void {
        self.swapChainImageViews = try self.allocator.alloc(c.VkImageView, self.swapChainImages.len);
        for (0..self.swapChainImages.len) |i| {
            var createInfo = c.VkImageViewCreateInfo{};
            createInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            createInfo.image = self.swapChainImages[i];
            createInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            createInfo.format = self.swapChainImageFormat;
            createInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            createInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            createInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            createInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            createInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            createInfo.subresourceRange.baseMipLevel = 0;
            createInfo.subresourceRange.levelCount = 1;
            createInfo.subresourceRange.baseArrayLayer = 0;
            createInfo.subresourceRange.layerCount = 1;

            if (c.vkCreateImageView(self.*.device, &createInfo, null, &self.swapChainImageViews[i]) != c.VK_SUCCESS) {
                return error.ImageViewCreationError;
            }
        }
    }

    fn createRenderPass(self: *App) !void {
        const colorAttachment = c.VkAttachmentDescription{
            .format = self.*.swapChainImageFormat,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const colorAttachmentRef = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &colorAttachmentRef,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        const renderPassInfo = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &colorAttachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        if (c.vkCreateRenderPass(self.*.device, &renderPassInfo, null, &self.renderPass) != c.VK_SUCCESS) {
            return error.RenderPassCreation;
        }
    }

    fn createDescriptorSetLayout(self: *App) !void {
        const uboLayoutBinding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        };

        var layoutInfo = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &uboLayoutBinding,
        };

        if (c.vkCreateDescriptorSetLayout(self.device, &layoutInfo, null, &self.descriptorSetLayout) != c.VK_SUCCESS) {
            return error.DescriptorSetLayoutCreation;
        }
    }

    fn createGraphicsPipeline(self: *App) !void {
        const vertShaderModule = try createShaderModule(self, &shaders.vert);
        defer c.vkDestroyShaderModule(self.device, vertShaderModule, null);

        const fragShaderModule = try createShaderModule(self, &shaders.frag);
        defer c.vkDestroyShaderModule(self.device, fragShaderModule, null);

        const vertShaderStageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vertShaderModule,
            .pName = "main",
        };
        const fragShaderStageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fragShaderModule,
            .pName = "main",
        };

        const shaderStages = [_]c.VkPipelineShaderStageCreateInfo{ vertShaderStageInfo, fragShaderStageInfo };

        const bindingDescription = Vertex.getBindingDescription();
        const attributeDescription = Vertex.getAttributeDescriptions();

        const vertexInputInfo = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &bindingDescription,
            .vertexAttributeDescriptionCount = @intCast(attributeDescription.len),
            .pVertexAttributeDescriptions = &attributeDescription,
        };

        const inputAssembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };

        const viewportState = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };

        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = c.VK_CULL_MODE_BACK_BIT,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
        };

        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = c.VK_FALSE,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        };

        const colorBlendAttachment = c.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = c.VK_FALSE,
        };

        const colorBlending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &colorBlendAttachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const dynamicStates = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamicState = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = @as(u32, @intCast(dynamicStates.len)),
            .pDynamicStates = &dynamicStates,
        };

        const pipelineLayoutInfo = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptorSetLayout,
            //.pushConstantRangeCount = 0,
        };

        if (c.vkCreatePipelineLayout(self.*.device, &pipelineLayoutInfo, null, &self.pipelineLayout) != c.VK_SUCCESS) {
            return error.PipelineLayoutCreation;
        }

        const pipelineInfo = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2,
            .pStages = &shaderStages,
            .pVertexInputState = &vertexInputInfo,
            .pInputAssemblyState = &inputAssembly,
            .pViewportState = &viewportState,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &colorBlending,
            .pDynamicState = &dynamicState,
            .layout = self.pipelineLayout,
            .renderPass = self.renderPass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        if (c.vkCreateGraphicsPipelines(self.*.device, null, 1, &pipelineInfo, null, &self.graphicsPipeline) != c.VK_SUCCESS) {
            return error.GraphicsPipelineCreation;
        }
    }

    fn createFramebuffers(self: *App) !void {
        self.swapChainFramebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapChainImageViews.len);

        for (0..self.swapChainImageViews.len) |i| {
            const attachments = [_]c.VkImageView{self.swapChainImageViews[i]};

            const framebufferInfo = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.renderPass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = self.swapChainExtent.width,
                .height = self.swapChainExtent.height,
                .layers = 1,
            };

            if (c.vkCreateFramebuffer(self.*.device, &framebufferInfo, null, &self.swapChainFramebuffers[i]) != c.VK_SUCCESS) {
                return error.FramebufferCreation;
            }
        }
        return;
    }

    fn createCommandPool(self: *App) !void {
        const queueFamilyIndices = try findQueueFamilies(self, self.*.physicalDevice);

        const poolInfo = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = queueFamilyIndices.graphicsFamily.?,
        };

        if (c.vkCreateCommandPool(self.*.device, &poolInfo, null, &self.commandPool) != c.VK_SUCCESS) {
            return error.CommandPoolCreation;
        }
    }

    fn createBuffer(self: *App, size: c.VkDeviceSize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags, buffer: *c.VkBuffer, bufferMemory: *c.VkDeviceMemory) !void {
        const bufferInfo = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };

        if (c.vkCreateBuffer(self.device, &bufferInfo, null, buffer) != c.VK_SUCCESS) {
            return error.BufferCreation;
        }

        var memRequirements: c.VkMemoryRequirements = .{};
        _ = c.vkGetBufferMemoryRequirements(self.device, buffer.*, &memRequirements);

        const allocInfo = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memRequirements.size,
            .memoryTypeIndex = try findMemoryType(self, memRequirements.memoryTypeBits, properties),
        };

        if (c.vkAllocateMemory(self.device, &allocInfo, null, bufferMemory) != c.VK_SUCCESS) {
            return error.BufferMalloc;
        }

        _ = c.vkBindBufferMemory(self.device, buffer.*, bufferMemory.*, 0);
    }

    fn copyBuffer(self: *App, srcBuffer: c.VkBuffer, dstBuffer: c.VkBuffer, size: c.VkDeviceSize) void {
        const allocInfo = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandPool = self.commandPool,
            .commandBufferCount = 1,
        };

        var commandBuffer: c.VkCommandBuffer = undefined;
        _ = c.vkAllocateCommandBuffers(self.device, &allocInfo, &commandBuffer);

        var beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };

        _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);

        var copyRegion = c.VkBufferCopy{
            .srcOffset = 0,
            .dstOffset = 0,
            .size = size,
        };

        _ = c.vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

        _ = c.vkEndCommandBuffer(commandBuffer);

        var submitInfo = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &commandBuffer,
        };

        _ = c.vkQueueSubmit(self.graphicsQueue, 1, &submitInfo, null);
        _ = c.vkQueueWaitIdle(self.graphicsQueue);

        _ = c.vkFreeCommandBuffers(self.device, self.commandPool, 1, &commandBuffer);
    }

    fn createVertexBuffer(self: *App) !void {
        const bufferSize: u32 = @sizeOf(@TypeOf(vertices));

        var stagingBuffer: c.VkBuffer = undefined;
        var stagingBufferMemory: c.VkDeviceMemory = undefined;
        try createBuffer(self, bufferSize, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &stagingBuffer, &stagingBufferMemory);

        var data: ?*anyopaque = null;

        if (c.vkMapMemory(self.device, stagingBufferMemory, 0, bufferSize, 0, &data) != c.VK_SUCCESS) {
            return error.mmapFailure;
        }

        const mapped_memory: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(mapped_memory[0..vertices.len], &vertices);
        c.vkUnmapMemory(self.device, stagingBufferMemory);

        try createBuffer(self, bufferSize, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.vertexBuffer, &self.vertexBufferMemory);

        copyBuffer(self, stagingBuffer, self.vertexBuffer, bufferSize);

        c.vkDestroyBuffer(self.device, stagingBuffer, null);
        c.vkFreeMemory(self.device, stagingBufferMemory, null);
    }

    fn createIndexBuffer(self: *App) !void {
        const bufferSize: u32 = @sizeOf(@TypeOf(INDICES));

        var stagingBuffer: c.VkBuffer = undefined;
        var stagingBufferMemory: c.VkDeviceMemory = undefined;
        try createBuffer(self, bufferSize, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &stagingBuffer, &stagingBufferMemory);

        var data: ?*anyopaque = null;

        if (c.vkMapMemory(self.device, stagingBufferMemory, 0, bufferSize, 0, &data) != c.VK_SUCCESS) {
            return error.mmapFailure;
        }

        const mapped_memory: [*]u16 = @ptrCast(@alignCast(data));
        @memcpy(mapped_memory[0..INDICES.len], &INDICES);
        c.vkUnmapMemory(self.device, stagingBufferMemory);

        try createBuffer(self, bufferSize, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.indexBuffer, &self.indexBufferMemory);

        copyBuffer(self, stagingBuffer, self.indexBuffer, bufferSize);

        c.vkDestroyBuffer(self.device, stagingBuffer, null);
        c.vkFreeMemory(self.device, stagingBufferMemory, null);
    }

    fn createUniformBuffers(self: *App) !void {
        const bufferSize = @sizeOf(UniformBufferObject);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            try createBuffer(self, bufferSize, c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &self.uniformBuffers[i], &self.uniformBuffersMemory[i]);

            _ = c.vkMapMemory(self.device, self.uniformBuffersMemory[i], 0, bufferSize, 0, &self.uniformBuffersMapped[i]);
        }
    }

    fn createDescriptorPool(self: *App) !void {
        const poolSize = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = MAX_FRAMES_IN_FLIGHT,
        };

        const poolInfo = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = 1,
            .pPoolSizes = &poolSize,
            .maxSets = MAX_FRAMES_IN_FLIGHT,
        };

        if (c.vkCreateDescriptorPool(self.device, &poolInfo, null, &self.descriptorPool) != c.VK_SUCCESS) {
            return error.DescriptorPoolCreation;
        }
    }

    fn createDescriptorSets(self: *App) !void {
        const layouts = [_]c.VkDescriptorSetLayout{self.descriptorSetLayout} ** MAX_FRAMES_IN_FLIGHT;

        const allocInfo = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.descriptorPool,
            .descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
            .pSetLayouts = &layouts,
        };

        if (c.vkAllocateDescriptorSets(self.device, &allocInfo, &self.descriptorSets[0]) != c.VK_SUCCESS) {
            return error.DescriptorSetAllocation;
        }

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const bufferInfo = c.VkDescriptorBufferInfo{
                .buffer = self.uniformBuffers[i],
                .offset = 0,
                .range = @sizeOf(UniformBufferObject),
            };

            const descriptorWrite = c.VkWriteDescriptorSet{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.descriptorSets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &bufferInfo,
            };

            c.vkUpdateDescriptorSets(self.device, 1, &descriptorWrite, 0, null);
        }
    }

    fn updateUniformBuffer(self: *App, currentImage: u32) void {
        //const startTime = std.time.milliTimestamp();
        const currentTime = std.time.milliTimestamp();

        const time = @as(f32, @floatFromInt(currentTime - self.startTime)) / 1000.0;

        var ubo: UniformBufferObject = undefined;
        c.glmc_mat4_identity(&ubo.model);
        var axis = c.vec3{ 0.0, 0.0, 1.0 };
        const angle = time * std.math.degreesToRadians(90.0);
        c.glmc_rotate(&ubo.model, angle, &axis);

        var eye = c.vec3{ 2.0, 2.0, 2.0 };
        var center = c.vec3{ 0.0, 0.0, 0.0 };
        var up = c.vec3{ 0.0, 0.0, 1.0 };
        c.glmc_lookat(&eye, &center, &up, &ubo.view);

        const aspect = @as(f32, @floatFromInt(self.swapChainExtent.width)) / @as(f32, @floatFromInt(self.swapChainExtent.height));
        c.glmc_perspective(std.math.degreesToRadians(45.0), aspect, 0.1, 10.0, &ubo.proj);

        ubo.proj[1][1] *= -1.0; // y-flip;

        const mapped_memory: [*]UniformBufferObject = @ptrCast(@alignCast(self.uniformBuffersMapped[currentImage]));
        mapped_memory[0] = ubo;
    }

    fn createCommandBuffer(self: *App) !void {
        //self.*.commandBuffers = try self.allocator.alloc(c.VkCommandBuffer, MAX_FRAMES_IN_FLIGHT);

        const allocInfo = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.commandPool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.*.commandBuffers.len),
        };

        if (c.vkAllocateCommandBuffers(self.*.device, &allocInfo, &self.commandBuffers) != c.VK_SUCCESS) {
            return error.CommandBufferAllocation;
        }
    }

    fn createSyncObjects(self: *App) !void {
        self.*.renderFinishedSemaphores = try self.allocator.alloc(c.VkSemaphore, self.swapChainImages.len);

        const semaphoreInfo = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fenceInfo = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (c.vkCreateSemaphore(self.*.device, &semaphoreInfo, null, &self.imageAvailableSemaphores[i]) != c.VK_SUCCESS or
                c.vkCreateFence(self.*.device, &fenceInfo, null, &self.inFlightFences[i]) != c.VK_SUCCESS)
            {
                return error.SyncObjectCreation;
            }
        }

        for (0..self.swapChainImages.len) |i| {
            if (c.vkCreateSemaphore(self.*.device, &semaphoreInfo, null, &self.renderFinishedSemaphores[i]) != c.VK_SUCCESS) {
                return error.SyncObjectCreation;
            }
        }
    }

    fn findMemoryType(self: *App, typeFilter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var memProperties: c.VkPhysicalDeviceMemoryProperties = .{};
        _ = c.vkGetPhysicalDeviceMemoryProperties(self.physicalDevice, &memProperties);

        for (0..memProperties.memoryTypeCount) |i| {
            const typeFilterBit = @as(u32, 1) << @as(u5, @intCast(i));
            if ((typeFilter & typeFilterBit) != 0 and (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return @intCast(i);
            }
        }
        return error.UnsuitableMemoryType;
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

    fn createShaderModule(self: *App, code: []align(4) const u8) !c.VkShaderModule {
        var createInfo = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,

            // Because we enforced align(4) in the build script,
            // this @ptrCast to a 32-bit pointer is completely safe!
            .pCode = @as([*c]const u32, @ptrCast(code.ptr)),
            .pNext = null,
            .flags = 0,
        };

        var shaderModule: c.VkShaderModule = undefined;
        if (c.vkCreateShaderModule(self.device, &createInfo, null, &shaderModule) != c.VK_SUCCESS) {
            return error.ShaderModuleCreationFailure;
        }

        return shaderModule;
    }

    fn recordCommandBuffer(self: *App, commandBuffer: c.VkCommandBuffer, imageIndex: u32) !void {
        const beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        if (c.vkBeginCommandBuffer(commandBuffer, &beginInfo) != c.VK_SUCCESS) {
            return error.CommandBufferRecording;
        }

        const clearColor = c.VkClearValue{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } };
        const renderPassInfo = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.*.renderPass,
            .framebuffer = self.swapChainFramebuffers[imageIndex],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapChainExtent,
            },
            .clearValueCount = 1,
            .pClearValues = &clearColor,
        };

        _ = c.vkCmdBeginRenderPass(commandBuffer, &renderPassInfo, c.VK_SUBPASS_CONTENTS_INLINE);
        _ = c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphicsPipeline);

        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.*.swapChainExtent.width),
            .height = @floatFromInt(self.*.swapChainExtent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        _ = c.vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapChainExtent,
        };
        _ = c.vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        const vertexBuffers = [_]c.VkBuffer{self.vertexBuffer};
        const offsets = [_]c.VkDeviceSize{0};
        _ = c.vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vertexBuffers, &offsets);
        _ = c.vkCmdBindIndexBuffer(commandBuffer, self.indexBuffer, 0, c.VK_INDEX_TYPE_UINT16);

        //_ = c.vkCmdDraw(commandBuffer, @intCast(vertices.len), 1, 0, 0);
        _ = c.vkCmdBindDescriptorSets(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipelineLayout, 0, 1, &self.descriptorSets[currentFrame], 0, null);

        _ = c.vkCmdDrawIndexed(commandBuffer, @as(u32, @intCast(INDICES.len)), 1, 0, 0, 0);

        _ = c.vkCmdEndRenderPass(commandBuffer);

        if (c.vkEndCommandBuffer(commandBuffer) != c.VK_SUCCESS) {
            return error.CommandBufferRecording;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("LEAK");
    }
    var app: App = undefined;
    app.allocator = gpa.allocator();
    try app.init();
    defer app.deinit();
}

fn onWindowResize(window: ?*c.RGFW_window, width: c_int, height: c_int) callconv(.c) void {
    if (width <= 0 or height <= 0) return;

    const ptr = c.RGFW_window_getUserPtr(window);
    if (ptr == null) return;
    const app: *App = @ptrCast(@alignCast(ptr));

    app.framebufferResized = true;
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
