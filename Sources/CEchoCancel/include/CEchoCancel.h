#ifndef CECHOCANCEL_H
#define CECHOCANCEL_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a WebRTC audio processing instance.
typedef struct ECHandle ECHandle;

/// Creates a processor for mono audio at `sample_rate` (48000) in 10 ms frames.
/// echo_cancel: AEC3 using the call audio as reference.
/// noise_suppression: light noise reduction.
/// auto_gain: raises a quiet microphone to a normal speech level (applied after echo removal).
/// Returns NULL on failure.
ECHandle *ec_create(int sample_rate, int echo_cancel, int noise_suppression, int auto_gain);

void ec_destroy(ECHandle *handle);

/// Processes one 10 ms frame. `reference` is what the speakers played (the call audio),
/// `mic` is the raw microphone. The processed microphone is written to `out`.
/// Returns 0 on success.
int ec_process(ECHandle *handle, const float *reference, const float *mic, float *out, int frames, int delay_ms);

#ifdef __cplusplus
}
#endif

#endif
