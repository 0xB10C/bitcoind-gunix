/* Minimal `gzip -6` via zlib's high-level gzFile API.
 *
 * gzopen(path, "wb6") -> deflateInit2(level=6, Z_DEFLATED, MAX_WBITS+16,
 * DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY) -- i.e. zlib's defaults for a gzip-
 * wrapped stream at level 6. This is exactly what `git archive
 * --output=*.tar.gz` does internally, and its output is sensitive to the
 * zlib version (GNU gzip's own bundled deflate and zlib-ng both produce
 * different bytes for the same input). */
#include <zlib.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <in> <out.gz>\n", argv[0]);
        return 1;
    }
    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror(argv[1]); return 1; }
    gzFile out = gzopen(argv[2], "wb6");
    if (!out) { perror(argv[2]); return 1; }

    char buf[1 << 16];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (gzwrite(out, buf, (unsigned)n) == 0) {
            fprintf(stderr, "gzwrite failed\n");
            return 1;
        }
    }
    if (ferror(in)) { perror(argv[1]); return 1; }
    fclose(in);

    if (gzclose(out) != Z_OK) {
        fprintf(stderr, "gzclose failed\n");
        return 1;
    }
    return 0;
}
