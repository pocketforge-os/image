#include <stddef.h>
#include <libavcodec/avcodec.h>

_Static_assert(offsetof(AVCodecContext, get_format) == 152,
               "AVCodecContext.get_format offset drift");
_Static_assert(offsetof(AVCodecContext, hw_device_ctx) == 872,
               "AVCodecContext.hw_device_ctx offset drift");

int main(void) { return 0; }
