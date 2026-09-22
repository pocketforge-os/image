#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

static void fail(const char *message, VkResult result)
{
    fprintf(stderr, "open-gpu-probe: %s (VkResult=%d)\n", message, result);
    exit(1);
}

static int contains_software_name(const char *name)
{
    static const char *const rejected[] = {
        "llvmpipe", "softpipe", "swrast", "lavapipe", "software", NULL,
    };
    char lower[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
    size_t i;

    for (i = 0; i + 1 < sizeof(lower) && name[i] != '\0'; ++i)
        lower[i] = (char)tolower((unsigned char)name[i]);
    lower[i] = '\0';
    for (i = 0; rejected[i] != NULL; ++i) {
        if (strstr(lower, rejected[i]) != NULL)
            return 1;
    }
    return 0;
}

int main(void)
{
    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "PocketForge open GPU boot probe",
        .apiVersion = VK_API_VERSION_1_2,
    };
    const VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice *physical_devices = NULL;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceDriverProperties driver_properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
    };
    VkQueueFamilyProperties *queue_families = NULL;
    uint32_t physical_count = 0, queue_count = 0, queue_family = UINT32_MAX;
    const float priority = 1.0f;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkResult result;
    uint32_t i;

    result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS)
        fail("vkCreateInstance failed", result);
    result = vkEnumeratePhysicalDevices(instance, &physical_count, NULL);
    if (result != VK_SUCCESS || physical_count == 0)
        fail("no Vulkan physical device", result);
    physical_devices = calloc(physical_count, sizeof(*physical_devices));
    if (physical_devices == NULL)
        fail("physical-device allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    result = vkEnumeratePhysicalDevices(instance, &physical_count, physical_devices);
    if (result != VK_SUCCESS)
        fail("physical-device enumeration failed", result);
    for (i = 0; i < physical_count; ++i) {
        VkPhysicalDeviceProperties2 properties2 = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver_properties,
        };
        memset(&driver_properties, 0, sizeof(driver_properties));
        driver_properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
        vkGetPhysicalDeviceProperties2(physical_devices[i], &properties2);
        properties = properties2.properties;
        if (properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU &&
            !contains_software_name(properties.deviceName) &&
            !contains_software_name(driver_properties.driverName)) {
            physical = physical_devices[i];
            break;
        }
    }
    if (physical == VK_NULL_HANDLE)
        fail("only software/CPU Vulkan devices found", VK_ERROR_INITIALIZATION_FAILED);

    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, NULL);
    queue_families = calloc(queue_count, sizeof(*queue_families));
    if (queue_families == NULL)
        fail("queue-family allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, queue_families);
    for (i = 0; i < queue_count; ++i) {
        if (queue_families[i].queueCount > 0 &&
            (queue_families[i].queueFlags &
             (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT))) {
            queue_family = i;
            break;
        }
    }
    if (queue_family == UINT32_MAX)
        fail("no usable Vulkan queue family", VK_ERROR_INITIALIZATION_FAILED);

    const VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
    };
    result = vkCreateDevice(physical, &device_info, NULL, &device);
    if (result != VK_SUCCESS)
        fail("vkCreateDevice failed", result);
    vkGetDeviceQueue(device, queue_family, 0, &queue);

    const VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family,
    };
    result = vkCreateCommandPool(device, &pool_info, NULL, &pool);
    if (result != VK_SUCCESS)
        fail("vkCreateCommandPool failed", result);
    const VkCommandBufferAllocateInfo allocation_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    result = vkAllocateCommandBuffers(device, &allocation_info, &command);
    if (result != VK_SUCCESS)
        fail("vkAllocateCommandBuffers failed", result);
    const VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if ((result = vkBeginCommandBuffer(command, &begin_info)) != VK_SUCCESS ||
        (result = vkEndCommandBuffer(command)) != VK_SUCCESS)
        fail("empty command-buffer recording failed", result);
    const VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if ((result = vkCreateFence(device, &fence_info, NULL, &fence)) != VK_SUCCESS)
        fail("vkCreateFence failed", result);
    const VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };
    if ((result = vkQueueSubmit(queue, 1, &submit_info, fence)) != VK_SUCCESS)
        fail("vkQueueSubmit failed", result);
    result = vkWaitForFences(device, 1, &fence, VK_TRUE, 10ULL * 1000 * 1000 * 1000);
    if (result != VK_SUCCESS)
        fail("submitted work did not complete within 10 seconds", result);

    printf("renderer=%s driver=%s/%u submit=ok\n", properties.deviceName,
           driver_properties.driverName[0] != '\0' ? driver_properties.driverName : "unknown",
           properties.driverVersion);
    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    free(queue_families);
    free(physical_devices);
    return 0;
}
