#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>

int main(int argc, char **argv)
{
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    const AVCodecHWConfig *config;
    AVBufferRef *device = NULL;
    int expect_request = argc == 2 && strcmp(argv[1], "green") == 0;
    int found = 0;
    int i;
    int rc;

    if (!codec) {
        fputs("h264 software decoder missing\n", stderr);
        return 10;
    }
    for (i = 0; (config = avcodec_get_hw_config(codec, i)); i++) {
        if (config->pix_fmt == AV_PIX_FMT_DRM_PRIME &&
            config->device_type == AV_HWDEVICE_TYPE_DRM &&
            (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
            found = 1;
            break;
        }
    }
    rc = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_DRM, NULL, NULL, 0);
    if (expect_request) {
        if (!found || rc < 0 || !device) {
            fprintf(stderr, "GREEN failed: request=%d drm-null=%d device=%p\n",
                    found, rc, (void *)device);
            return 11;
        }
    } else if (found || rc >= 0 || device) {
        fprintf(stderr, "RED failed: request=%d drm-null=%d device=%p\n",
                found, rc, (void *)device);
        return 12;
    }
    av_buffer_unref(&device);
    printf("%s request=%d drm-null=%d avcodec=%u avutil=%u\n",
           expect_request ? "GREEN" : "RED", found, rc,
           avcodec_version(), avutil_version());
    return 0;
}
