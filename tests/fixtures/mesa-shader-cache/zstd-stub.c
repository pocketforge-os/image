/* SPDX-License-Identifier: MIT */

#include <stddef.h>

size_t
ZSTD_compress(void *dst,
              size_t dst_capacity,
              const void *src,
              size_t src_size,
              int compression_level)
{
   (void)dst;
   (void)dst_capacity;
   (void)src;
   (void)src_size;
   (void)compression_level;
   return 0;
}

size_t
ZSTD_decompress(void *dst,
                size_t dst_capacity,
                const void *src,
                size_t compressed_size)
{
   (void)dst;
   (void)dst_capacity;
   (void)src;
   (void)compressed_size;
   return 0;
}
