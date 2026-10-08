/* SPDX-License-Identifier: MIT */

#include <stddef.h>

extern size_t ZSTD_compress(void *dst,
                            size_t dst_capacity,
                            const void *src,
                            size_t src_size,
                            int compression_level);
extern size_t ZSTD_decompress(void *dst,
                              size_t dst_capacity,
                              const void *src,
                              size_t compressed_size);

#ifdef ENABLE_SHADER_CACHE
__attribute__((used, visibility("default")))
const char pf_zink_shader_cache_witness[] =
   "zink: Failed to create disk cache queue";
#endif

__attribute__((visibility("default")))
size_t
pf_gallium_cache_fixture(void *dst,
                         size_t dst_capacity,
                         const void *src,
                         size_t src_size)
{
   size_t result = 0;

#ifndef OMIT_ZSTD_CALLS
   result += ZSTD_compress(dst, dst_capacity, src, src_size, 1);
   result += ZSTD_decompress(dst, dst_capacity, src, src_size);
#endif

#ifdef ENABLE_SHADER_CACHE
   result += (unsigned char)pf_zink_shader_cache_witness[0];
#endif

   return result;
}
