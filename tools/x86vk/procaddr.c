/* Walk the Vulkan entry points the way a loader-heavy consumer does.
 *
 * DXVK reaches essentially every Vulkan function through vkGetInstanceProcAddr
 * and vkGetDeviceProcAddr rather than by linking them. If the wrapping layer
 * (box64 wrapping the host libvulkan here) fails to forward any of them, the
 * consumer receives NULL and dereferences it — which is exactly the class of
 * crash that is hard to attribute later.
 *
 * This prints the names that come back NULL, so a gap is identified by name
 * before any Windows code is involved.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static const char *inst_names[] = {
    "vkCreateInstance", "vkDestroyInstance", "vkEnumerateInstanceExtensionProperties",
    "vkEnumerateInstanceLayerProperties", "vkEnumeratePhysicalDevices",
    "vkGetPhysicalDeviceProperties", "vkGetPhysicalDeviceFeatures",
    "vkGetPhysicalDeviceQueueFamilyProperties", "vkGetPhysicalDeviceMemoryProperties",
    "vkGetPhysicalDeviceFormatProperties", "vkCreateDevice", "vkGetDeviceProcAddr",
    "vkGetInstanceProcAddr", "vkEnumerateDeviceExtensionProperties",
    "vkEnumerateDeviceLayerProperties", "vkGetPhysicalDeviceImageFormatProperties",
    "vkCreateWaylandSurfaceKHR", "vkDestroySurfaceKHR",
    "vkGetPhysicalDeviceSurfaceSupportKHR", "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
    "vkGetPhysicalDeviceSurfaceFormatsKHR", "vkGetPhysicalDeviceSurfacePresentModesKHR",
    NULL
};

static const char *dev_names[] = {
    "vkDestroyDevice", "vkGetDeviceQueue", "vkQueueSubmit", "vkQueueWaitIdle",
    "vkDeviceWaitIdle", "vkAllocateMemory", "vkFreeMemory", "vkMapMemory",
    "vkUnmapMemory", "vkFlushMappedMemoryRanges", "vkInvalidateMappedMemoryRanges",
    "vkGetDeviceMemoryCommitment", "vkBindBufferMemory", "vkBindImageMemory",
    "vkGetBufferMemoryRequirements", "vkGetImageMemoryRequirements",
    "vkCreateFence", "vkDestroyFence", "vkResetFences", "vkGetFenceStatus",
    "vkWaitForFences", "vkCreateSemaphore", "vkDestroySemaphore",
    "vkCreateEvent", "vkDestroyEvent", "vkCreateQueryPool", "vkDestroyQueryPool",
    "vkCreateBuffer", "vkDestroyBuffer", "vkCreateBufferView", "vkDestroyBufferView",
    "vkCreateImage", "vkDestroyImage", "vkGetImageSubresourceLayout",
    "vkCreateImageView", "vkDestroyImageView",
    "vkCreateShaderModule", "vkDestroyShaderModule",
    "vkCreatePipelineCache", "vkDestroyPipelineCache",
    "vkCreatePipelineLayout", "vkDestroyPipelineLayout",
    "vkCreateComputePipelines", "vkDestroyPipeline",
    "vkCreateSampler", "vkDestroySampler",
    "vkCreateDescriptorSetLayout", "vkDestroyDescriptorSetLayout",
    "vkCreateDescriptorPool", "vkDestroyDescriptorPool", "vkResetDescriptorPool",
    "vkAllocateDescriptorSets", "vkFreeDescriptorSets", "vkUpdateDescriptorSets",
    "vkCreateFramebuffer", "vkDestroyFramebuffer", "vkCreateRenderPass",
    "vkDestroyRenderPass", "vkGetRenderAreaGranularity",
    "vkCreateCommandPool", "vkDestroyCommandPool", "vkResetCommandPool",
    "vkAllocateCommandBuffers", "vkFreeCommandBuffers", "vkBeginCommandBuffer",
    "vkEndCommandBuffer", "vkResetCommandBuffer",
    "vkCmdBindPipeline", "vkCmdSetViewport", "vkCmdSetScissor", "vkCmdBindDescriptorSets",
    "vkCmdBindVertexBuffers", "vkCmdBindIndexBuffer", "vkCmdDraw", "vkCmdDrawIndexed",
    "vkCmdDispatch", "vkCmdCopyBuffer", "vkCmdCopyImage", "vkCmdBlitImage",
    "vkCmdCopyBufferToImage", "vkCmdCopyImageToBuffer", "vkCmdUpdateBuffer",
    "vkCmdFillBuffer", "vkCmdPipelineBarrier", "vkCmdBeginRenderPass",
    "vkCmdNextSubpass", "vkCmdEndRenderPass", "vkCmdExecuteCommands",
    "vkCmdPushConstants", "vkCmdClearColorImage", "vkCmdClearDepthStencilImage",
    "vkCreateSwapchainKHR", "vkDestroySwapchainKHR", "vkGetSwapchainImagesKHR",
    "vkAcquireNextImageKHR", "vkQueuePresentKHR",
    NULL
};

int main(void)
{
    VkApplicationInfo app;
    memset(&app, 0, sizeof(app));
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.apiVersion = VK_API_VERSION_1_1;

    /* Surface entries only resolve when the instance extension is requested;
     * without this the NULLs below are correct behaviour, not a wrapper gap. */
    static const char *inst_ext[] = { "VK_KHR_surface", "VK_KHR_wayland_surface", NULL };

    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = inst_ext;

    VkInstance inst;
    VkResult r = vkCreateInstance(&ici, NULL, &inst);
    if (r != VK_SUCCESS) {
        printf("FAIL vkCreateInstance %d\n", (int)r);
        return 1;
    }

    int inst_missing = 0, inst_total = 0;
    for (int i = 0; inst_names[i]; i++) {
        inst_total++;
        if (vkGetInstanceProcAddr(inst, inst_names[i]) == NULL) {
            printf("instance NULL %s\n", inst_names[i]);
            inst_missing++;
        }
    }

    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst, &n, NULL);
    if (n == 0) {
        printf("FAIL no device\n");
        return 1;
    }
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);

    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("device %s\n", props.deviceName);

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, NULL);
    VkQueueFamilyProperties *qfs = malloc(sizeof(*qfs) * qn);
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, qfs);
    int qi = -1;
    for (uint32_t i = 0; i < qn; i++)
        if (qfs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qi = (int)i; break; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci;
    memset(&qci, 0, sizeof(qci));
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = (uint32_t)qi;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    /* Same reasoning for the swapchain entries. */
    static const char *dev_ext[] = { "VK_KHR_swapchain", NULL };

    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof(dci));
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = dev_ext;

    VkDevice dev;
    r = vkCreateDevice(pd, &dci, NULL, &dev);
    if (r != VK_SUCCESS) {
        printf("FAIL vkCreateDevice %d\n", (int)r);
        return 1;
    }

    int dev_missing = 0, dev_total = 0;
    for (int i = 0; dev_names[i]; i++) {
        dev_total++;
        if (vkGetDeviceProcAddr(dev, dev_names[i]) == NULL) {
            printf("device NULL %s\n", dev_names[i]);
            dev_missing++;
        }
    }

    printf("summary instance %d/%d device %d/%d\n",
           inst_total - inst_missing, inst_total,
           dev_total - dev_missing, dev_total);
    return (inst_missing || dev_missing) ? 2 : 0;
}
