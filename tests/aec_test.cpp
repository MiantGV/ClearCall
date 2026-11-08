// Runs ClearCall's echo canceller (Sources/CEchoCancel) over raw float32 48 kHz mono files.
// Usage: aec_test <reference.f32> <mic.f32> <out.f32> <echo_cancel 0|1> <auto_gain 0|1>
#include <cstdio>
#include <vector>

#include "CEchoCancel.h"

static std::vector<float> readAll(const char *path) {
    std::vector<float> v;
    FILE *f = fopen(path, "rb");
    if (!f) return v;
    float buf[4096];
    size_t n;
    while ((n = fread(buf, sizeof(float), 4096, f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    return v;
}

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage\n"); return 2; }
    std::vector<float> ref = readAll(argv[1]), mic = readAll(argv[2]);
    size_t n = std::min(ref.size(), mic.size());
    const int frame = 480;
    ECHandle *h = ec_create(48000, atoi(argv[4]), 1, atoi(argv[5]));
    if (!h) { fprintf(stderr, "ec_create failed\n"); return 1; }
    std::vector<float> out(n, 0.f);
    int failures = 0;
    for (size_t i = 0; i + frame <= n; i += frame) {
        if (ec_process(h, &ref[i], &mic[i], &out[i], frame, 0) != 0) failures++;
    }
    ec_destroy(h);
    FILE *f = fopen(argv[3], "wb");
    fwrite(out.data(), sizeof(float), n, f);
    fclose(f);
    printf("processed %zu samples, %d failed frames\n", n, failures);
    return failures ? 1 : 0;
}
