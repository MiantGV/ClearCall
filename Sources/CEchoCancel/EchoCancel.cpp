#include "CEchoCancel.h"

#include <memory>
#include <vector>

#include "modules/audio_processing/include/audio_processing.h"

struct ECHandle {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    int sample_rate;
    std::vector<float> scratch;
};

extern "C" ECHandle *ec_create(int sample_rate, int noise_suppression) {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
    if (!apm) return nullptr;

    webrtc::AudioProcessing::Config config;
    config.pipeline.maximum_internal_processing_rate = 48000;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    config.noise_suppression.enabled = noise_suppression != 0;
    config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kLow;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    apm->ApplyConfig(config);
    apm->Initialize();

    auto *handle = new ECHandle();
    handle->apm = apm;
    handle->sample_rate = sample_rate;
    handle->scratch.resize(sample_rate / 100);
    return handle;
}

extern "C" void ec_destroy(ECHandle *handle) {
    delete handle;
}

extern "C" int ec_process(ECHandle *handle, const float *reference, const float *mic, float *out,
                          int frames, int delay_ms) {
    if (!handle || frames != handle->sample_rate / 100) return -1;
    webrtc::StreamConfig config(handle->sample_rate, 1);

    // Far end: what the speakers played.
    const float *ref_channels[1] = {reference};
    float *ref_out[1] = {handle->scratch.data()};
    int err = handle->apm->ProcessReverseStream(ref_channels, config, config, ref_out);
    if (err != 0) return err;

    // Near end: the microphone.
    handle->apm->set_stream_delay_ms(delay_ms);
    const float *mic_channels[1] = {mic};
    float *mic_out[1] = {out};
    return handle->apm->ProcessStream(mic_channels, config, config, mic_out);
}
