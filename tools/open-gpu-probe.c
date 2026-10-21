/* POSIX 2008 for readlink, setenv and O_CLOEXEC under -std=c11. */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/ioctl.h>

#include <vulkan/vulkan.h>

#include <libdrm/virtgpu_drm.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

/*
 * Strict-virtual constants. The kernel UAPI (include/uapi/drm/virtgpu_drm.h)
 * names them since Linux 6.0 / libdrm 2.4.116; the guards keep the probe
 * building against older headers while the ioctl itself fails closed on
 * kernels that do not implement VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs.
 */
#ifndef VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs
#define VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs 7
#endif
#ifndef VIRTGPU_DRM_CAPSET_VENUS
#define VIRTGPU_DRM_CAPSET_VENUS 4
#endif

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
#ifndef EGL_CONTEXT_MAJOR_VERSION_KHR
#define EGL_CONTEXT_MAJOR_VERSION_KHR 0x3098
#endif
#ifndef EGL_CONTEXT_MINOR_VERSION_KHR
#define EGL_CONTEXT_MINOR_VERSION_KHR 0x30FB
#endif

#define VENUS_READBACK_PATTERN 0x5046564eu /* 'PFVN' */

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

/* ------------------------------------------------------------------ */
/* Physical branch: unchanged GE8300 probe.                           */
/* ------------------------------------------------------------------ */

static int probe_physical(void)
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
    if (physical_count == 0) {
        fprintf(stderr,
                "open-gpu-probe: no Vulkan physical device (VkResult=%d) "
                "hint=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=%s\n",
                result,
                getenv("PVR_I_WANT_A_BROKEN_VULKAN_DRIVER") != NULL ? "set" : "unset");
        exit(1);
    }
    if (result != VK_SUCCESS)
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

/* ------------------------------------------------------------------ */
/* Strict virtual branch helpers.                                     */
/* ------------------------------------------------------------------ */

static int virtual_fail(const char *message)
{
    fprintf(stderr, "open-gpu-probe: %s (%s)\n", message, strerror(errno));
    return 1;
}

static int link_targets_driver(const char *link, const char *wanted)
{
    char resolved[256];
    ssize_t length = readlink(link, resolved, sizeof(resolved) - 1);
    const char *base;

    if (length < 0)
        return 0;
    resolved[length] = '\0';
    base = strrchr(resolved, '/');
    base = base != NULL ? base + 1 : resolved;
    return strcmp(base, wanted) == 0;
}

/* The A133 DRM device is a virtio-mmio platform child. */
static int device_has_virtgpu_driver(const char *device_dir)
{
    char driver_link[256];
    DIR *children;
    struct dirent *entry;
    int found = 0;

    if (snprintf(driver_link, sizeof(driver_link), "%s/driver", device_dir)
            >= (int)sizeof(driver_link))
        return 0;
    if (link_targets_driver(driver_link, "virtio_gpu"))
        return 1;
    if (!link_targets_driver(driver_link, "virtio-mmio"))
        return 0;

    children = opendir(device_dir);
    if (children == NULL)
        return 0;
    while ((entry = readdir(children)) != NULL) {
        if (strncmp(entry->d_name, "virtio", 6) != 0)
            continue;
        if (snprintf(driver_link, sizeof(driver_link), "%s/%s/driver",
                     device_dir, entry->d_name) >= (int)sizeof(driver_link))
            continue;
        if (link_targets_driver(driver_link, "virtio_gpu")) {
            found = 1;
            break;
        }
    }
    closedir(children);
    return found;
}

/* Lowest-numbered render node whose bound kernel driver is virtio_gpu. */
static int find_virtgpu_render_node(char *path, size_t path_size)
{
    static const char class_dir[] = "/sys/class/drm";
    DIR *dir = opendir(class_dir);
    struct dirent *entry;
    unsigned long best = ULONG_MAX;

    if (dir == NULL)
        return virtual_fail("cannot open /sys/class/drm");
    while ((entry = readdir(dir)) != NULL) {
        char device_dir[256];
        unsigned long number;

        if (strncmp(entry->d_name, "renderD", 7) != 0)
            continue;
        errno = 0;
        number = strtoul(entry->d_name + 7, NULL, 10);
        if (errno != 0 || number >= best)
            continue;
        if (snprintf(device_dir, sizeof(device_dir), "%s/%s/device",
                     class_dir, entry->d_name) >= (int)sizeof(device_dir))
            continue;
        if (!device_has_virtgpu_driver(device_dir))
            continue;
        if (snprintf(path, path_size, "/dev/dri/%s", entry->d_name)
                >= (int)path_size)
            continue;
        best = number;
    }
    closedir(dir);
    if (best == ULONG_MAX) {
        errno = ENODEV;
        return virtual_fail("no render node is bound to the virtio_gpu driver");
    }
    return 0;
}

/* Installed Venus ICD manifest; pins VK_DRIVER_FILES so a direct guest
 * software ICD (lavapipe/llvmpipe) can never satisfy the virtual branch. */
static int find_venus_icd(char *path, size_t path_size)
{
    static const char icd_dir[] = "/usr/share/vulkan/icd.d";
    DIR *dir = opendir(icd_dir);
    struct dirent *entry;
    int found = 0;

    if (dir == NULL)
        return virtual_fail("cannot open /usr/share/vulkan/icd.d");
    while ((entry = readdir(dir)) != NULL) {
        size_t length = strlen(entry->d_name);

        if (strncmp(entry->d_name, "virtio_icd.", 11) != 0 ||
            length < 6 || strcmp(entry->d_name + length - 5, ".json") != 0)
            continue;
        if (!found || strcmp(entry->d_name, strrchr(path, '/') + 1) < 0)
            snprintf(path, path_size, "%s/%s", icd_dir, entry->d_name);
        found = 1;
    }
    closedir(dir);
    if (!found) {
        errno = ENOENT;
        return virtual_fail("no Venus ICD manifest (virtio_icd.*.json) is installed");
    }
    if (access(path, R_OK) != 0)
        return virtual_fail("Venus ICD manifest is not readable");
    return 0;
}

/*
 * Minimal SPIR-V compute module: one workgroup, one invocation, stores the
 * fixed 32-bit pattern 'PFVN' (0x5046564e) into the storage buffer at
 * (set = 0, binding = 0). Generated from the following source with
 * glslangValidator -V --target-env vulkan1.1 and validated with spirv-val; the words below are the
 * exact generator output (tests/test-open-gpu-probe-spirv.sh re-decodes
 * them):
 *
 *   #version 450
 *   layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
 *   layout(set = 0, binding = 0) buffer OutBuf { uint data; } out_buf;
 *   void main() { out_buf.data = 0x5046564eu; }
 */
static const uint32_t venus_writeback_spv[] = {
    0x07230203, 0x00010300, 0x0008000b, 0x00000012, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0005000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x00060010, 0x00000004, 0x00000011,
    0x00000001, 0x00000001, 0x00000001, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004,
    0x6e69616d, 0x00000000, 0x00040005, 0x00000007, 0x4274754f, 0x00006675, 0x00050006, 0x00000007,
    0x00000000, 0x61746164, 0x00000000, 0x00040005, 0x00000009, 0x5f74756f, 0x00667562, 0x00030047,
    0x00000007, 0x00000002, 0x00050048, 0x00000007, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
    0x00000009, 0x00000021, 0x00000000, 0x00040047, 0x00000009, 0x00000022, 0x00000000, 0x00040047,
    0x00000011, 0x0000000b, 0x00000019, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00040015, 0x00000006, 0x00000020, 0x00000000, 0x0003001e, 0x00000007, 0x00000006, 0x00040020,
    0x00000008, 0x0000000c, 0x00000007, 0x0004003b, 0x00000008, 0x00000009, 0x0000000c, 0x00040015,
    0x0000000a, 0x00000020, 0x00000001, 0x0004002b, 0x0000000a, 0x0000000b, 0x00000000, 0x0004002b,
    0x00000006, 0x0000000c, 0x5046564e, 0x00040020, 0x0000000d, 0x0000000c, 0x00000006, 0x00040017,
    0x0000000f, 0x00000006, 0x00000003, 0x0004002b, 0x00000006, 0x00000010, 0x00000001, 0x0006002c,
    0x0000000f, 0x00000011, 0x00000010, 0x00000010, 0x00000010, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x0000000d, 0x0000000e, 0x00000009,
    0x0000000b, 0x0003003e, 0x0000000e, 0x0000000c, 0x000100fd, 0x00010038
};

/* ------------------------------------------------------------------ */
/* --venus-readback: Venus capset + compute host readback.            */
/* ------------------------------------------------------------------ */

static int probe_venus_readback(void)
{
    char node[256], icd[256];
    int drm_fd;
    uint64_t capset_mask = 0;
    struct drm_virtgpu_getparam getparam;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice *physical_devices = NULL;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceDriverProperties driver_properties;
    VkQueueFamilyProperties *queue_families = NULL;
    uint32_t physical_count = 0, queue_count = 0, queue_family = UINT32_MAX;
    const float priority = 1.0f;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkResult result;
    uint32_t i, pattern = 0;
    void *mapped = NULL;
    int status = 1;

    if (find_virtgpu_render_node(node, sizeof(node)) != 0)
        return 1;
    if (find_venus_icd(icd, sizeof(icd)) != 0)
        return 1;

    drm_fd = open(node, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
        return virtual_fail("cannot open the virtio_gpu render node");
    memset(&getparam, 0, sizeof(getparam));
    getparam.param = VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs;
    getparam.value = (uint64_t)(uintptr_t)&capset_mask;
    if (ioctl(drm_fd, DRM_IOCTL_VIRTGPU_GETPARAM, &getparam) != 0) {
        close(drm_fd);
        return virtual_fail("VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs query failed");
    }
    close(drm_fd);
    if ((capset_mask & (1ULL << VIRTGPU_DRM_CAPSET_VENUS)) == 0) {
        fprintf(stderr,
                "open-gpu-probe: host does not advertise the Venus capset "
                "(supported mask=0x%llx)\n", (unsigned long long)capset_mask);
        return 1;
    }

    /* Only the Venus ICD is visible to the loader for this probe. */
    if (setenv("VK_DRIVER_FILES", icd, 1) != 0)
        return virtual_fail("cannot pin VK_DRIVER_FILES");

    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "PocketForge open GPU virtual probe",
        .apiVersion = VK_API_VERSION_1_1,
    };
    const VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS)
        fail("vkCreateInstance failed", result);
    result = vkEnumeratePhysicalDevices(instance, &physical_count, NULL);
    if (result != VK_SUCCESS || physical_count == 0) {
        fprintf(stderr, "open-gpu-probe: no Vulkan device behind the Venus ICD\n");
        return 1;
    }
    physical_devices = calloc(physical_count, sizeof(*physical_devices));
    if (physical_devices == NULL)
        fail("physical-device allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    result = vkEnumeratePhysicalDevices(instance, &physical_count, physical_devices);
    if (result != VK_SUCCESS)
        fail("physical-device enumeration failed", result);

    /*
     * The device must be the Venus guest driver. The host behind Venus may
     * legitimately report a CPU/software device (pinned host Lavapipe), so
     * deviceType and device name are not filters here; driverName == "venus"
     * is the strict requirement (design pass 2 on tsp-mc9m.41.984.54.18).
     */
    for (i = 0; i < physical_count; ++i) {
        VkPhysicalDeviceProperties2 properties2 = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver_properties,
        };
        memset(&driver_properties, 0, sizeof(driver_properties));
        driver_properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
        vkGetPhysicalDeviceProperties2(physical_devices[i], &properties2);
        if (strcmp(driver_properties.driverName, "venus") == 0) {
            physical = physical_devices[i];
            properties = properties2.properties;
            break;
        }
    }
    if (physical == VK_NULL_HANDLE) {
        fprintf(stderr, "open-gpu-probe: no Vulkan device reports driver=venus\n");
        return 1;
    }

    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, NULL);
    queue_families = calloc(queue_count, sizeof(*queue_families));
    if (queue_families == NULL)
        fail("queue-family allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, queue_families);
    for (i = 0; i < queue_count; ++i) {
        if (queue_families[i].queueCount > 0 &&
            (queue_families[i].queueFlags &
             (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))) {
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

    const VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = sizeof(pattern),
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
    };
    result = vkCreateBuffer(device, &buffer_info, NULL, &buffer);
    if (result != VK_SUCCESS)
        fail("readback buffer creation failed", result);
    VkMemoryRequirements memory_requirements;
    vkGetBufferMemoryRequirements(device, buffer, &memory_requirements);
    VkPhysicalDeviceMemoryProperties memory_properties;
    vkGetPhysicalDeviceMemoryProperties(physical, &memory_properties);
    uint32_t memory_type = UINT32_MAX;
    for (i = 0; i < memory_properties.memoryTypeCount; ++i) {
        const VkFlags required =
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((memory_requirements.memoryTypeBits & (1u << i)) != 0 &&
            (memory_properties.memoryTypes[i].propertyFlags & required) == required) {
            memory_type = i;
            break;
        }
    }
    if (memory_type == UINT32_MAX)
        fail("no host-visible coherent memory type", VK_ERROR_FORMAT_NOT_SUPPORTED);
    const VkMemoryAllocateInfo allocation_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memory_requirements.size,
        .memoryTypeIndex = memory_type,
    };
    result = vkAllocateMemory(device, &allocation_info, NULL, &memory);
    if (result != VK_SUCCESS)
        fail("readback memory allocation failed", result);
    result = vkBindBufferMemory(device, buffer, memory, 0);
    if (result != VK_SUCCESS)
        fail("readback buffer binding failed", result);

    const VkShaderModuleCreateInfo shader_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(venus_writeback_spv),
        .pCode = venus_writeback_spv,
    };
    result = vkCreateShaderModule(device, &shader_info, NULL, &shader);
    if (result != VK_SUCCESS)
        fail("SPIR-V shader module creation failed", result);
    const VkDescriptorSetLayoutBinding binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
    };
    const VkDescriptorSetLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    result = vkCreateDescriptorSetLayout(device, &layout_info, NULL, &set_layout);
    if (result != VK_SUCCESS)
        fail("descriptor set layout creation failed", result);
    const VkPipelineLayoutCreateInfo pipeline_layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
    };
    result = vkCreatePipelineLayout(device, &pipeline_layout_info, NULL, &pipeline_layout);
    if (result != VK_SUCCESS)
        fail("pipeline layout creation failed", result);
    const VkComputePipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = "main",
        },
        .layout = pipeline_layout,
    };
    result = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info,
                                      NULL, &pipeline);
    if (result != VK_SUCCESS)
        fail("compute pipeline creation failed", result);
    const VkDescriptorPoolSize pool_size = {
        .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
    };
    const VkDescriptorPoolCreateInfo pool_create_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    result = vkCreateDescriptorPool(device, &pool_create_info, NULL, &descriptor_pool);
    if (result != VK_SUCCESS)
        fail("descriptor pool creation failed", result);
    const VkDescriptorSetAllocateInfo set_allocate_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &set_layout,
    };
    result = vkAllocateDescriptorSets(device, &set_allocate_info, &descriptor_set);
    if (result != VK_SUCCESS)
        fail("descriptor set allocation failed", result);
    const VkDescriptorBufferInfo buffer_descriptor = {
        .buffer = buffer,
        .offset = 0,
        .range = sizeof(pattern),
    };
    const VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = descriptor_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &buffer_descriptor,
    };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);

    const VkCommandPoolCreateInfo command_pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family,
    };
    result = vkCreateCommandPool(device, &command_pool_info, NULL, &pool);
    if (result != VK_SUCCESS)
        fail("vkCreateCommandPool failed", result);
    const VkCommandBufferAllocateInfo command_allocate_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    result = vkAllocateCommandBuffers(device, &command_allocate_info, &command);
    if (result != VK_SUCCESS)
        fail("vkAllocateCommandBuffers failed", result);
    const VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    result = vkBeginCommandBuffer(command, &begin_info);
    if (result != VK_SUCCESS)
        fail("command-buffer begin failed", result);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout,
                            0, 1, &descriptor_set, 0, NULL);
    vkCmdDispatch(command, 1, 1, 1);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS)
        fail("command-buffer recording failed", result);
    const VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    result = vkCreateFence(device, &fence_info, NULL, &fence);
    if (result != VK_SUCCESS)
        fail("vkCreateFence failed", result);
    const VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };
    result = vkQueueSubmit(queue, 1, &submit_info, fence);
    if (result != VK_SUCCESS)
        fail("vkQueueSubmit failed", result);
    result = vkWaitForFences(device, 1, &fence, VK_TRUE, 10ULL * 1000 * 1000 * 1000);
    if (result != VK_SUCCESS)
        fail("submitted work did not complete within 10 seconds", result);

    result = vkMapMemory(device, memory, 0, sizeof(pattern), 0, &mapped);
    if (result != VK_SUCCESS)
        fail("readback mapping failed", result);
    memcpy(&pattern, mapped, sizeof(pattern));
    vkUnmapMemory(device, memory);
    if (pattern != VENUS_READBACK_PATTERN) {
        fprintf(stderr, "open-gpu-probe: Venus readback mismatch: 0x%08x != 0x%08x\n",
                pattern, VENUS_READBACK_PATTERN);
        status = 1;
    } else {
        printf("renderer=%s driver=%s/%u submit=ok capset=venus readback=0x%08x\n",
               properties.deviceName, driver_properties.driverName,
               properties.driverVersion, pattern);
        status = 0;
    }

    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyDescriptorPool(device, descriptor_pool, NULL);
    vkDestroyPipeline(device, pipeline, NULL);
    vkDestroyPipelineLayout(device, pipeline_layout, NULL);
    vkDestroyDescriptorSetLayout(device, set_layout, NULL);
    vkDestroyShaderModule(device, shader, NULL);
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, memory, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    free(queue_families);
    free(physical_devices);
    return status;
}

/* ------------------------------------------------------------------ */
/* --gles32-zink-readback: GLES 3.2 through Zink on Venus.            */
/* ------------------------------------------------------------------ */

static unsigned compile_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    GLint compiled = GL_FALSE;
    char log[1024];

    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "open-gpu-probe: shader compile failed: %s\n", log);
        exit(1);
    }
    return shader;
}

static void print_venus_vulkan_features(const char *icd)
{
    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "PocketForge open GPU GLES diagnostic",
        .apiVersion = VK_API_VERSION_1_1,
    };
    const VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice *devices = NULL;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties2 properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
    };
    VkPhysicalDeviceDriverProperties driver = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
    };
    VkPhysicalDeviceFeatures2 features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
    };
    VkPhysicalDeviceRobustness2FeaturesEXT robustness2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
    };
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
    };
    VkExtensionProperties *extensions = NULL;
    uint32_t count = 0;
    uint32_t extension_count = 0;
    int has_robustness2 = 0;
    int has_timeline = 0;
    VkResult result;

    if (setenv("VK_DRIVER_FILES", icd, 1) != 0)
        return;
    result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS)
        return;
    result = vkEnumeratePhysicalDevices(instance, &count, NULL);
    if (result != VK_SUCCESS || count == 0)
        goto cleanup;
    devices = calloc(count, sizeof(*devices));
    if (devices == NULL)
        goto cleanup;
    result = vkEnumeratePhysicalDevices(instance, &count, devices);
    if (result != VK_SUCCESS)
        goto cleanup;
    for (uint32_t i = 0; i < count; ++i) {
        memset(&properties, 0, sizeof(properties));
        memset(&driver, 0, sizeof(driver));
        properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        properties.pNext = &driver;
        driver.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
        vkGetPhysicalDeviceProperties2(devices[i], &properties);
        if (strcmp(driver.driverName, "venus") == 0) {
            physical = devices[i];
            break;
        }
    }
    if (physical == VK_NULL_HANDLE)
        goto cleanup;
    result = vkEnumerateDeviceExtensionProperties(physical, NULL,
                                                  &extension_count, NULL);
    if (result != VK_SUCCESS)
        goto cleanup;
    extensions = calloc(extension_count, sizeof(*extensions));
    if (extensions == NULL)
        goto cleanup;
    result = vkEnumerateDeviceExtensionProperties(physical, NULL,
                                                  &extension_count, extensions);
    if (result != VK_SUCCESS)
        goto cleanup;
    for (uint32_t i = 0; i < extension_count; ++i) {
        if (strcmp(extensions[i].extensionName,
                   VK_EXT_ROBUSTNESS_2_EXTENSION_NAME) == 0)
            has_robustness2 = 1;
        if (strcmp(extensions[i].extensionName,
                   VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME) == 0)
            has_timeline = 1;
    }
    vkGetPhysicalDeviceFeatures2(physical, &features);
    if (has_robustness2) {
        features.pNext = &robustness2;
        vkGetPhysicalDeviceFeatures2(physical, &features);
    }
    if (has_timeline ||
        properties.properties.apiVersion >= VK_API_VERSION_1_2) {
        features.pNext = &timeline;
        vkGetPhysicalDeviceFeatures2(physical, &features);
    }
    fprintf(stderr,
            "open-gpu-probe: venus_vulkan_features="
            "api=%u.%u.%u driver=%s device=%s "
            "compute=core geometry=%u tessellation=%u sample_rate=%u "
            "robust_buffer=%u fragment_stores=%u shader_storage_read=%u "
            "shader_storage_write=%u null_descriptor=%u "
            "timeline_semaphore=%u\n",
            VK_VERSION_MAJOR(properties.properties.apiVersion),
            VK_VERSION_MINOR(properties.properties.apiVersion),
            VK_VERSION_PATCH(properties.properties.apiVersion),
            driver.driverName, properties.properties.deviceName,
            features.features.geometryShader,
            features.features.tessellationShader,
            features.features.sampleRateShading,
            features.features.robustBufferAccess,
            features.features.fragmentStoresAndAtomics,
            features.features.shaderStorageImageReadWithoutFormat,
            features.features.shaderStorageImageWriteWithoutFormat,
            has_robustness2 ? robustness2.nullDescriptor : 0,
            (has_timeline || properties.properties.apiVersion >= VK_API_VERSION_1_2) ?
                timeline.timelineSemaphore : 0);

cleanup:
    free(extensions);
    free(devices);
    if (instance != VK_NULL_HANDLE)
        vkDestroyInstance(instance, NULL);
}

static void print_egl_config_diagnostics(EGLDisplay display, EGLConfig config)
{
    EGLint id = 0, surface_type = 0, renderable_type = 0;
    EGLint red = 0, green = 0, blue = 0, alpha = 0;
    if (eglGetConfigAttrib(display, config, EGL_CONFIG_ID, &id) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_SURFACE_TYPE, &surface_type) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_RENDERABLE_TYPE, &renderable_type) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_RED_SIZE, &red) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_GREEN_SIZE, &green) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_BLUE_SIZE, &blue) != EGL_TRUE ||
        eglGetConfigAttrib(display, config, EGL_ALPHA_SIZE, &alpha) != EGL_TRUE) {
        fprintf(stderr, "open-gpu-probe: egl_config=unavailable error=0x%x\n",
                eglGetError());
        return;
    }
    fprintf(stderr,
            "open-gpu-probe: egl_config=id=%d surface=0x%x renderable=0x%x "
            "rgba=%d,%d,%d,%d\n",
            id, surface_type, renderable_type, red, green, blue, alpha);
}

static void print_zink_gles_version(EGLDisplay display, EGLConfig config,
                                    const EGLint *surface_attributes)
{
    const EGLint fallback_context_attributes[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 1,
        EGL_NONE,
    };
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    const char *version;
    const char *renderer;

    context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                               fallback_context_attributes);
    if (context == EGL_NO_CONTEXT) {
        fprintf(stderr,
                "open-gpu-probe: zink_gles_version=unavailable "
                "fallback=3.1 error=0x%x\n", eglGetError());
        return;
    }
    surface = eglCreatePbufferSurface(display, config, surface_attributes);
    if (surface == EGL_NO_SURFACE ||
        eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        fprintf(stderr,
                "open-gpu-probe: zink_gles_version=unavailable "
                "fallback=3.1 error=0x%x\n", eglGetError());
        if (surface != EGL_NO_SURFACE)
            eglDestroySurface(display, surface);
        eglDestroyContext(display, context);
        return;
    }
    version = (const char *)glGetString(GL_VERSION);
    renderer = (const char *)glGetString(GL_RENDERER);
    if (version == NULL || renderer == NULL)
        fprintf(stderr, "open-gpu-probe: zink_gles_version=unavailable fallback=3.1\n");
    else
        fprintf(stderr, "open-gpu-probe: zink_gles_version=%s renderer=%s\n",
                version, renderer);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, surface);
    eglDestroyContext(display, context);
}

static int probe_gles32_zink_readback(void)
{
    static const char *const vertex_source =
        "#version 320 es\n"
        "void main() {\n"
        "    vec2 positions[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));\n"
        "    gl_Position = vec4(positions[gl_VertexID], 0.0, 1.0);\n"
        "}\n";
    static const char *const fragment_source =
        "#version 320 es\n"
        "precision mediump float;\n"
        "layout(location = 0) out vec4 color;\n"
        "void main() { color = vec4(1.0, 0.0, 0.0, 1.0); }\n";
    char node[256], icd[256];
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLint config_count = 0, major = 0, minor = 0;
    GLuint program = 0, vertex_shader = 0, fragment_shader = 0;
    GLuint framebuffer = 0, texture = 0;
    GLint linked = GL_FALSE;
    const char *version, *renderer;
    unsigned char pixel[4] = { 0, 0, 0, 0 };
    int status = 1;

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    const EGLint context_attributes[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
        EGL_CONTEXT_MINOR_VERSION_KHR, 2,
        EGL_NONE,
    };
    const EGLint surface_attributes[] = {
        EGL_WIDTH, 16,
        EGL_HEIGHT, 16,
        EGL_NONE,
    };

    if (find_virtgpu_render_node(node, sizeof(node)) != 0)
        return 1;
    if (find_venus_icd(icd, sizeof(icd)) != 0)
        return 1;
    print_venus_vulkan_features(icd);
    if (setenv("VK_DRIVER_FILES", icd, 1) != 0)
        return virtual_fail("cannot pin VK_DRIVER_FILES");
    if (setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1) != 0)
        return virtual_fail("cannot pin the zink loader override");
    /*
     * Mesa's Venus Zink path needs its private RGB32 texture-buffer
     * lowering to expose the GLES 3.2 texture-buffer extension.  Keep this
     * scoped to the render-only probe; it is not a global image setting.
     */
    if (setenv("ZINK_DEBUG", "tbo_rgb32", 1) != 0)
        return virtual_fail("cannot enable Zink RGB32 texture-buffer lowering");
    /*
     * The render-only Venus device has no DRM identity that Mesa's Zink
     * surfaceless DRM path can match to a Vulkan physical device.  Force
     * Mesa's software surfaceless path, which passes fd=-1 to Zink and lets
     * the pinned Venus ICD select its llvmpipe-backed render server device.
     * The renderer check below still rejects a fallback to llvmpipe GL.
     */
    if (setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1) != 0)
        return virtual_fail("cannot force software surfaceless Zink");

    /*
     * The QEMU Venus device is intentionally render-only: KMS is disabled
     * and max_outputs=0.  Use Mesa's public surfaceless platform with a
     * pbuffer so Zink never needs a GBM window or scanout-capable device.
     */
    display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                    EGL_DEFAULT_DISPLAY, NULL);
    if (display == EGL_NO_DISPLAY ||
        eglInitialize(display, &major, &minor) != EGL_TRUE) {
        fprintf(stderr, "open-gpu-probe: EGL initialize failed (0x%x)\n", eglGetError());
        display = EGL_NO_DISPLAY;
        goto cleanup;
    }
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        fprintf(stderr, "open-gpu-probe: eglBindAPI failed (0x%x)\n", eglGetError());
        goto cleanup;
    }
    if (eglChooseConfig(display, config_attributes, &config, 1, &config_count) != EGL_TRUE ||
        config_count < 1) {
        fprintf(stderr, "open-gpu-probe: no ES3 pbuffer config (0x%x)\n", eglGetError());
        goto cleanup;
    }
    print_egl_config_diagnostics(display, config);
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (context == EGL_NO_CONTEXT) {
        fprintf(stderr, "open-gpu-probe: ES 3.2 context creation failed (0x%x)\n",
                eglGetError());
        print_zink_gles_version(display, config, surface_attributes);
        goto cleanup;
    }
    surface = eglCreatePbufferSurface(display, config, surface_attributes);
    if (surface == NULL) {
        fprintf(stderr, "open-gpu-probe: eglCreatePbufferSurface failed (0x%x)\n",
                eglGetError());
        goto cleanup;
    }
    if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        fprintf(stderr, "open-gpu-probe: eglMakeCurrent failed (0x%x)\n", eglGetError());
        goto cleanup;
    }

    version = (const char *)glGetString(GL_VERSION);
    renderer = (const char *)glGetString(GL_RENDERER);
    if (version == NULL || renderer == NULL) {
        fprintf(stderr, "open-gpu-probe: glGetString returned NULL\n");
        goto cleanup;
    }
    if (strstr(version, "OpenGL ES 3.2") == NULL) {
        fprintf(stderr, "open-gpu-probe: GL_VERSION lacks OpenGL ES 3.2: %s\n", version);
        goto cleanup;
    }
    if (strncmp(renderer, "zink", 4) != 0) {
        fprintf(stderr, "open-gpu-probe: GL_RENDERER is not zink: %s\n", renderer);
        goto cleanup;
    }

    vertex_shader = compile_shader(GL_VERTEX_SHADER, vertex_source);
    fragment_shader = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    program = glCreateProgram();
    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        char log[1024];
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "open-gpu-probe: program link failed: %s\n", log);
        goto cleanup;
    }

    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "open-gpu-probe: framebuffer incomplete\n");
        goto cleanup;
    }

    glViewport(0, 0, 16, 16);
    glUseProgram(program);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    if (pixel[0] != 255 || pixel[1] != 0 || pixel[2] != 0 || pixel[3] != 255) {
        fprintf(stderr,
                "open-gpu-probe: GLES draw readback mismatch: %u,%u,%u,%u != 255,0,0,255\n",
                pixel[0], pixel[1], pixel[2], pixel[3]);
        goto cleanup;
    }

    printf("gles_version=3.2 renderer=%s draw=readback-ok label=virtual\n", renderer);
    status = 0;

cleanup:
    if (display != EGL_NO_DISPLAY)
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context != EGL_NO_CONTEXT && display != EGL_NO_DISPLAY)
        eglDestroyContext(display, context);
    if (surface != EGL_NO_SURFACE && display != EGL_NO_DISPLAY)
        eglDestroySurface(display, surface);
    if (display != EGL_NO_DISPLAY)
        eglTerminate(display);
    return status;
}

int main(int argc, char **argv)
{
    if (argc == 1)
        return probe_physical();
    if (argc == 2 && strcmp(argv[1], "--venus-readback") == 0)
        return probe_venus_readback();
    if (argc == 2 && strcmp(argv[1], "--gles32-zink-readback") == 0)
        return probe_gles32_zink_readback();
    fprintf(stderr,
            "usage: open-gpu-probe [--venus-readback | --gles32-zink-readback]\n");
    return 2;
}
