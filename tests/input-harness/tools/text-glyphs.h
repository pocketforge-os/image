#ifndef PF_INPUT_HARNESS_TEXT_GLYPHS_H
#define PF_INPUT_HARNESS_TEXT_GLYPHS_H

#include <stdint.h>

/* Tiny source-owned 5x7 glyphs for the harness phrases. Bit 4 is leftmost. */
static inline void pf_glyph_rows(char c, uint8_t rows[7])
{
	static const uint8_t blank[7] = {0, 0, 0, 0, 0, 0, 0};
	static const uint8_t a[7] = {14, 17, 17, 31, 17, 17, 17};
	static const uint8_t e[7] = {31, 16, 16, 30, 16, 16, 31};
	static const uint8_t h[7] = {17, 17, 17, 31, 17, 17, 17};
	static const uint8_t l[7] = {16, 16, 16, 16, 16, 16, 31};
	static const uint8_t n[7] = {17, 25, 21, 19, 17, 17, 17};
	static const uint8_t o[7] = {14, 17, 17, 17, 17, 17, 14};
	static const uint8_t r[7] = {30, 17, 17, 30, 20, 18, 17};
	static const uint8_t s[7] = {15, 16, 16, 14, 1, 1, 30};
	static const uint8_t digits[10][7] = {
		{14, 17, 19, 21, 25, 17, 14}, {4, 12, 4, 4, 4, 4, 14},
		{14, 17, 1, 2, 4, 8, 31}, {30, 1, 1, 14, 1, 1, 30},
		{2, 6, 10, 18, 31, 2, 2}, {31, 16, 16, 30, 1, 1, 30},
		{14, 16, 16, 30, 17, 17, 14}, {31, 1, 2, 4, 8, 8, 8},
		{14, 17, 17, 14, 17, 17, 14}, {14, 17, 17, 15, 1, 1, 14},
	};
	const uint8_t *src = blank;
	if (c >= '0' && c <= '9') src = digits[c - '0'];
	else if (c == 'a') src = a;
	else if (c == 'e') src = e;
	else if (c == 'h') src = h;
	else if (c == 'l') src = l;
	else if (c == 'n') src = n;
	else if (c == 'o') src = o;
	else if (c == 'r') src = r;
	else if (c == 's') src = s;
	for (int i = 0; i < 7; i++) rows[i] = src[i];
}

#endif
