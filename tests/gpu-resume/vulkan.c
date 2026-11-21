/* Offscreen graphics-queue and transfer readback. No surface or swapchain. */
#include <vulkan/vulkan.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_CALL(expr) do { VkResult r_ = (expr); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "VULKAN_FAIL %s result=%d\n", #expr, (int)r_); exit(1); } } while (0)
enum { WIDTH = 64, HEIGHT = 32, FRAMES = 4 };

static void fail(const char *why)
{
    fprintf(stderr, "VULKAN_FAIL %s\n", why);
    exit(1);
}

static VkDeviceMemory allocate(VkDevice device, const VkPhysicalDeviceMemoryProperties *types,
                               VkMemoryRequirements req, VkMemoryPropertyFlags flags)
{
    for (uint32_t i = 0; i < types->memoryTypeCount; i++) {
        if (!(req.memoryTypeBits & (1u << i)) || (types->memoryTypes[i].propertyFlags & flags) != flags)
            continue;
        VkMemoryAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size, .memoryTypeIndex = i };
        VkDeviceMemory memory;
        VK_CALL(vkAllocateMemory(device, &info, NULL, &memory));
        return memory;
    }
    fail("no suitable memory type");
    return VK_NULL_HANDLE;
}

static VkPhysicalDevice select_gpu(VkInstance instance, bool software)
{
    VkPhysicalDevice devices[32];
    uint32_t count = sizeof(devices) / sizeof(devices[0]);
    VK_CALL(vkEnumeratePhysicalDevices(instance, &count, devices));
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceDriverProperties driver = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
        VkPhysicalDeviceProperties2 props = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &driver };
        vkGetPhysicalDeviceProperties2(devices[i], &props);
        const VkPhysicalDeviceProperties *p = &props.properties;
        printf("VULKAN_DEVICE name=%s driver=%s driverID=%u type=%u\n",
               p->deviceName, driver.driverName, (unsigned)driver.driverID, (unsigned)p->deviceType);
        if (p->apiVersion < VK_API_VERSION_1_2)
            continue;
        if (software && driver.driverID == VK_DRIVER_ID_MESA_LLVMPIPE && p->deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU)
            return devices[i];
        if (!software && driver.driverID == VK_DRIVER_ID_MESA_TURNIP && p->deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
            && strcmp(p->deviceName, "Turnip Adreno (TM) 730") == 0)
            return devices[i];
    }
    fail(software ? "no lavapipe CPU device" : "no Turnip Adreno 730 hardware device");
    return VK_NULL_HANDLE;
}

int main(int argc, char **argv)
{
    bool software = argc == 2 && strcmp(argv[1], "--software-control") == 0;
    if (argc != 1 && !software)
        fail("usage: vulkan-offscreen [--software-control]");
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Y700 readback",
        .apiVersion = VK_API_VERSION_1_2 };
    VkInstanceCreateInfo instance_info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    VK_CALL(vkCreateInstance(&instance_info, NULL, &instance));
    VkPhysicalDevice gpu = select_gpu(instance, software);
    VkQueueFamilyProperties queues[32];
    uint32_t families = sizeof(queues) / sizeof(queues[0]), family = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &families, queues);
    while (family < families && !(queues[family].queueFlags & VK_QUEUE_GRAPHICS_BIT))
        family++;
    if (family == families)
        fail("no graphics queue");
    float priority = 1.f;
    VkDeviceQueueCreateInfo queue_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo device_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info };
    VkDevice device;
    VK_CALL(vkCreateDevice(gpu, &device_info, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);

    VkPhysicalDeviceMemoryProperties types;
    vkGetPhysicalDeviceMemoryProperties(gpu, &types);
    const VkFormat format = VK_FORMAT_R8G8B8A8_UINT;
    const VkExtent3D extent = {WIDTH, HEIGHT, 1};
    VkImageCreateInfo image_info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = extent, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
    VkImage image;
    VK_CALL(vkCreateImage(device, &image_info, NULL, &image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, image, &req);
    VkDeviceMemory image_memory = allocate(device, &types, req, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VK_CALL(vkBindImageMemory(device, image, image_memory, 0));
    VkImageViewCreateInfo view_info = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
        .subresourceRange = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 } };
    VkImageView view;
    VK_CALL(vkCreateImageView(device, &view_info, NULL, &view));
    VkBufferCreateInfo buffer_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = WIDTH * HEIGHT * 4,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buffer;
    VK_CALL(vkCreateBuffer(device, &buffer_info, NULL, &buffer));
    vkGetBufferMemoryRequirements(device, buffer, &req);
    VkDeviceMemory host_memory = allocate(device, &types, req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    VK_CALL(vkBindBufferMemory(device, buffer, host_memory, 0));
    void *mapped;
    VK_CALL(vkMapMemory(device, host_memory, 0, VK_WHOLE_SIZE, 0, &mapped));

    VkAttachmentDescription attachment = { .format = format, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
    VkAttachmentReference color = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &color };
    VkSubpassDependency copy_dep = { .srcSubpass = 0, .dstSubpass = VK_SUBPASS_EXTERNAL,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT };
    VkRenderPassCreateInfo pass_info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass,
        .dependencyCount = 1, .pDependencies = &copy_dep };
    VkRenderPass pass;
    VK_CALL(vkCreateRenderPass(device, &pass_info, NULL, &pass));
    VkFramebufferCreateInfo fb_info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
        .attachmentCount = 1, .pAttachments = &view, .width = WIDTH, .height = HEIGHT, .layers = 1 };
    VkFramebuffer fb;
    VK_CALL(vkCreateFramebuffer(device, &fb_info, NULL, &fb));
    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool pool;
    VK_CALL(vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo cmd_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    VK_CALL(vkAllocateCommandBuffers(device, &cmd_info, &cmd));
    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    VK_CALL(vkCreateFence(device, &fence_info, NULL, &fence));
    for (int frame = 0; frame < FRAMES; frame++) {
        VkClearValue background = { .color.uint32 = { 9u + frame, 63, 171, 255 } };
        VkClearAttachment foreground = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .clearValue.color.uint32 = { 222, 11u + frame, 45, 170 } };
        VkClearRect rect = { .rect = { .offset = { 4 + 6 * frame, 3 + frame }, .extent = { 19, 13 } }, .layerCount = 1 };
        VkRenderPassBeginInfo begin_pass = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = pass, .framebuffer = fb, .renderArea.extent = { WIDTH, HEIGHT },
            .clearValueCount = 1, .pClearValues = &background };
        VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        VK_CALL(vkResetCommandPool(device, pool, 0));
        VK_CALL(vkBeginCommandBuffer(cmd, &begin));
        vkCmdBeginRenderPass(cmd, &begin_pass, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdClearAttachments(cmd, 1, &foreground, 1, &rect);
        vkCmdEndRenderPass(cmd);
        VkBufferImageCopy copy = { .imageSubresource = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = 1 },
            .imageExtent = extent };
        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
        VkMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
        VK_CALL(vkEndCommandBuffer(cmd));
        VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
        VK_CALL(vkResetFences(device, 1, &fence));
        VK_CALL(vkQueueSubmit(queue, 1, &submit, fence));
        VK_CALL(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_C(3000000000)));
        VkMappedMemoryRange range = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = host_memory, .size = VK_WHOLE_SIZE };
        VK_CALL(vkInvalidateMappedMemoryRanges(device, 1, &range));
        const uint8_t *pixels = mapped;
        for (int y = 0; y < HEIGHT; y++) {
            for (int x = 0; x < WIDTH; x++) {
                int dx = x - rect.rect.offset.x, dy = y - rect.rect.offset.y;
                bool inside = dx >= 0 && dx < (int)rect.rect.extent.width && dy >= 0 && dy < (int)rect.rect.extent.height;
                const uint32_t *expected = inside ? foreground.clearValue.color.uint32 : background.color.uint32;
                for (int c = 0; c < 4; c++)
                    if (pixels[(y * WIDTH + x) * 4 + c] != expected[c]) {
                        fprintf(stderr, "VULKAN_FAIL pixel frame=%d x=%d y=%d channel=%d\n", frame, x, y, c);
                        return 1;
                    }
            }
        }
    }
    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyFramebuffer(device, fb, NULL);
    vkDestroyRenderPass(device, pass, NULL);
    vkDestroyImageView(device, view, NULL);
    vkDestroyImage(device, image, NULL);
    vkFreeMemory(device, image_memory, NULL);
    vkUnmapMemory(device, host_memory);
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, host_memory, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    printf("VULKAN_%s_PASS queue_family=%u render_passes=%d transfers=%d pixels=%d bytes=%d\n",
           software ? "SOFTWARE_CONTROL" : "TURNIP", family, FRAMES, FRAMES, WIDTH * HEIGHT * FRAMES, WIDTH * HEIGHT * FRAMES * 4);
    return 0;
}
