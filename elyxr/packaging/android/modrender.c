// Renders a tracker module (.xm/.mod/.s3m/.it) to a 16-bit stereo WAV, using
// libopenmpt — the same engine openmpt123 uses on desktop. Android can't shell
// out to a system openmpt123, so this ships inside the APK as a native lib
// (libmodrender.so) that the app execs from its nativeLibraryDir, exactly like
// the bundled lymnal. Output is a plain WAV, which both plays through
// audioplayers and feeds the app's own FFT for the spectrum visualizer.
//
//   libmodrender.so <input-module> <output.wav>
//
// Exit 0 on success; non-zero (with a short stderr note) otherwise, so the Dart
// side falls back to leaving the track silent rather than crashing.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <libopenmpt/libopenmpt.h>

#define SAMPLERATE 48000
#define CHANNELS 2
#define CHUNK 4096

static void write_u32(FILE *f, uint32_t v) {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    fwrite(b, 1, 4, f);
}
static void write_u16(FILE *f, uint16_t v) {
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    fwrite(b, 1, 2, f);
}

// A canonical 44-byte PCM WAV header. data_bytes is patched in after streaming.
static void write_wav_header(FILE *f, uint32_t data_bytes) {
    const uint32_t byte_rate = SAMPLERATE * CHANNELS * 2;
    fwrite("RIFF", 1, 4, f);
    write_u32(f, 36 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);
    write_u32(f, 16);              // PCM fmt chunk size
    write_u16(f, 1);               // PCM
    write_u16(f, CHANNELS);
    write_u32(f, SAMPLERATE);
    write_u32(f, byte_rate);
    write_u16(f, CHANNELS * 2);    // block align
    write_u16(f, 16);              // bits per sample
    fwrite("data", 1, 4, f);
    write_u32(f, data_bytes);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: modrender <in> <out.wav>\n");
        return 2;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        fprintf(stderr, "cannot open input\n");
        return 3;
    }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    if (size <= 0) {
        fclose(in);
        fprintf(stderr, "empty input\n");
        return 3;
    }
    void *data = malloc((size_t)size);
    if (!data) {
        fclose(in);
        return 4;
    }
    if (fread(data, 1, (size_t)size, in) != (size_t)size) {
        free(data);
        fclose(in);
        fprintf(stderr, "short read\n");
        return 3;
    }
    fclose(in);

    openmpt_module *mod = openmpt_module_create_from_memory2(
        data, (size_t)size, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    free(data);
    if (!mod) {
        fprintf(stderr, "not a module libopenmpt can read\n");
        return 5;
    }

    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        openmpt_module_destroy(mod);
        fprintf(stderr, "cannot open output\n");
        return 6;
    }
    write_wav_header(out, 0); // placeholder; patched below

    int16_t buffer[CHUNK * CHANNELS];
    uint32_t data_bytes = 0;
    size_t got;
    while ((got = openmpt_module_read_interleaved_stereo(
                mod, SAMPLERATE, CHUNK, buffer)) > 0) {
        fwrite(buffer, sizeof(int16_t), got * CHANNELS, out);
        data_bytes += (uint32_t)(got * CHANNELS * sizeof(int16_t));
    }

    // Patch the two size fields now that the total is known.
    fseek(out, 4, SEEK_SET);
    write_u32(out, 36 + data_bytes);
    fseek(out, 40, SEEK_SET);
    write_u32(out, data_bytes);

    fclose(out);
    openmpt_module_destroy(mod);
    return 0;
}
