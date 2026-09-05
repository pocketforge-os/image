/* Headless H.264 decoder probe: FFmpeg parses, libvdpau-sunxi programs libcedrus/VE. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/vdpau.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>
#include <vdpau/vdpau.h>

typedef VdpStatus (*create_headless_fn)(VdpDevice *, VdpGetProcAddress **);

struct state {
    VdpDevice device;
    VdpGetProcAddress *get_proc;
};

static enum AVPixelFormat choose_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *formats)
{
    struct state *state = ctx->opaque;
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
        if (*p == AV_PIX_FMT_VDPAU) {
            if (av_vdpau_bind_context(ctx, state->device, state->get_proc, 0) < 0)
                return AV_PIX_FMT_NONE;
            return *p;
        }
    }
    return AV_PIX_FMT_NONE; /* Software fallback is forbidden. */
}

static void die(const char *message)
{
    fprintf(stderr, "cedar-headless-test: %s\n", message);
    exit(1);
}

int main(int argc, char **argv)
{
    if (argc != 2)
        die("usage: cedar-headless-test CLIP.h264");

    void *module = dlopen("libvdpau_sunxi.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!module)
        die(dlerror());
    create_headless_fn create_headless =
        (create_headless_fn)dlsym(module, "vdp_imp_device_create_headless");
    if (!create_headless)
        die("headless Cedar entry point is missing");

    struct state state = { .device = VDP_INVALID_HANDLE, .get_proc = NULL };
    if (create_headless(&state.device, &state.get_proc) != VDP_STATUS_OK)
        die("could not open libcedrus device");

    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, argv[1], NULL, NULL) < 0)
        die("could not open input");
    if (avformat_find_stream_info(format, NULL) < 0)
        die("could not parse input");
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (stream < 0)
        die("input has no video stream");

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, format->streams[stream]->codecpar) < 0)
        die("could not create decoder context");
    ctx->opaque = &state;
    ctx->get_format = choose_format;
    if (avcodec_open2(ctx, codec, NULL) < 0)
        die("could not open H.264 decoder");

    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!packet || !frame)
        die("allocation failure");
    unsigned long frames = 0;
    int rc;
    while ((rc = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index == stream) {
            if (avcodec_send_packet(ctx, packet) < 0)
                die("decoder rejected packet");
            while ((rc = avcodec_receive_frame(ctx, frame)) >= 0) {
                if (frame->format != AV_PIX_FMT_VDPAU)
                    die("software frame returned");
                ++frames;
                av_frame_unref(frame);
            }
            if (rc != AVERROR(EAGAIN) && rc != AVERROR_EOF)
                die("decoder failed");
        }
        av_packet_unref(packet);
    }
    if (rc != AVERROR_EOF)
        die("input read failed");
    if (avcodec_send_packet(ctx, NULL) < 0)
        die("decoder flush failed");
    while ((rc = avcodec_receive_frame(ctx, frame)) >= 0) {
        if (frame->format != AV_PIX_FMT_VDPAU)
            die("software frame returned during flush");
        ++frames;
        av_frame_unref(frame);
    }
    if (rc != AVERROR_EOF)
        die("decoder flush did not finish");

    printf("frames=%lu\n", frames);
    VdpDeviceDestroy *destroy = NULL;
    if (state.get_proc(state.device, VDP_FUNC_ID_DEVICE_DESTROY,
                       (void **)&destroy) == VDP_STATUS_OK && destroy)
        destroy(state.device);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&ctx);
    avformat_close_input(&format);
    dlclose(module);
    return frames ? 0 : 1;
}
