/*
 * libslsk: a Soulseek client protocol library.
 *
 * This header is written by hand. Keep it in sync with src/c_api.zig.
 */
#ifndef SLSK_H
#define SLSK_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Returns the library version as a static NUL-terminated string,
 * for example "0.1.0". The caller must not free the string.
 */
const char *slsk_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SLSK_H */
