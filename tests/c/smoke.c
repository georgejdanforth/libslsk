/*
 * C smoke test: link libslsk and call slsk_version().
 *
 * Usage: c-smoke <expected-version>
 */
#include <stdio.h>
#include <string.h>

#include "slsk.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <expected-version>\n", argv[0]);
        return 2;
    }

    const char *version = slsk_version();
    if (version == NULL) {
        fprintf(stderr, "slsk_version() returned NULL\n");
        return 1;
    }
    if (strcmp(version, argv[1]) != 0) {
        fprintf(stderr, "slsk_version() returned \"%s\", expected \"%s\"\n", version, argv[1]);
        return 1;
    }
    return 0;
}
