#ifndef POCKETFORGE_GLX_RENDERER_POLICY_H
#define POCKETFORGE_GLX_RENDERER_POLICY_H

#include <stddef.h>

static int pf_ascii_contains_folded(const char *text, const char *needle)
{
    size_t i, j;

    if (text == NULL || needle == NULL || needle[0] == '\0')
        return 0;
    for (i = 0; text[i] != '\0'; ++i) {
        for (j = 0; needle[j] != '\0'; ++j) {
            unsigned char left = (unsigned char)text[i + j];
            unsigned char right = (unsigned char)needle[j];

            if (left == '\0')
                break;
            if (left >= 'A' && left <= 'Z')
                left = (unsigned char)(left - 'A' + 'a');
            if (right >= 'A' && right <= 'Z')
                right = (unsigned char)(right - 'A' + 'a');
            if (left != right)
                break;
        }
        if (needle[j] == '\0')
            return 1;
    }
    return 0;
}

static int pf_glx_renderer_is_owned(const char *renderer)
{
    static const char *const rejected[] = {
        "llvmpipe", "softpipe", "swrast", "lavapipe", "software", NULL,
    };
    size_t i;

    if (!pf_ascii_contains_folded(renderer, "zink"))
        return 0;
    if (!pf_ascii_contains_folded(renderer, "powervr") &&
        !pf_ascii_contains_folded(renderer, "ge8300"))
        return 0;
    for (i = 0; rejected[i] != NULL; ++i) {
        if (pf_ascii_contains_folded(renderer, rejected[i]))
            return 0;
    }
    return 1;
}

#endif
