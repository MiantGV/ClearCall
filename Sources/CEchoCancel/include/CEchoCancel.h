#ifndef CECHOCANCEL_H
#define CECHOCANCEL_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a WebRTC audio processing instance (AEC3 + high-pass filter + light noise suppression).
typedef struct ECHandle ECHandle;

/// Creates a canceller for mono audio at `sample_rate` (48000) processed in 10 ms frames.
/// Returns NULL on failure.
ECHandle *ec_create(int sample_rate, int noise_suppression);

void ec_destroy(ECHandle *handle);

/// Processes one 10 ms frame. `reference` is what the speakers played (the call audio),
/// `mic` is the raw microphone. The echo-reduced microphone is written to `out`
/// (may be the same buffer as `mic`). `delay_ms` is a hint for the speaker-to-mic delay.
/// Returns 0 on success.
int ec_process(ECHandle *handle, const float *reference, const float *mic, float *out, int frames, int delay_ms);

#ifdef __cplusplus
}
#endif

#endif
