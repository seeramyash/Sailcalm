#pragma once

// StressTrack / NeuroSense CNN runtime for Seeed XIAO ESP32C3.
// This file deliberately uses direct includes instead of __has_include checks:
// missing dependencies must produce a clear compiler error, not silently
// compile a firmware image with the CNN disabled.

#include <Arduino.h>
#include <math.h>
#include <stdint.h>

#include <Chirale_TensorFlowLite.h>
#include "tflite_model_data.h"
#include <tensorflow/lite/micro/micro_interpreter.h>
#include <tensorflow/lite/micro/micro_mutable_op_resolver.h>
#include <tensorflow/lite/schema/schema_generated.h>

#define STRESSTRACK_CNN_AVAILABLE 1

#ifndef STRESSTRACK_TFLM_ARENA_BYTES
#define STRESSTRACK_TFLM_ARENA_BYTES (64 * 1024)
#endif

namespace StressTrackCNN {

static uint8_t tensorArena[STRESSTRACK_TFLM_ARENA_BYTES]
    __attribute__((aligned(16)));

// The exported model's resolver audit specifies these 12 builtin operators.
static tflite::MicroMutableOpResolver<12> resolver;
static bool resolverConfigured = false;

inline bool configureResolver() {
    if (resolverConfigured) return true;

    if (resolver.AddAdd() != kTfLiteOk) return false;
    if (resolver.AddAveragePool2D() != kTfLiteOk) return false;
    if (resolver.AddBatchToSpaceNd() != kTfLiteOk) return false;
    if (resolver.AddConcatenation() != kTfLiteOk) return false;
    if (resolver.AddConv2D() != kTfLiteOk) return false;
    if (resolver.AddExpandDims() != kTfLiteOk) return false;
    if (resolver.AddFullyConnected() != kTfLiteOk) return false;
    if (resolver.AddMean() != kTfLiteOk) return false;
    if (resolver.AddMul() != kTfLiteOk) return false;
    if (resolver.AddReshape() != kTfLiteOk) return false;
    if (resolver.AddSoftmax() != kTfLiteOk) return false;
    if (resolver.AddSpaceToBatchNd() != kTfLiteOk) return false;

    resolverConfigured = true;
    return true;
}

static tflite::MicroInterpreter interpreter(
    tflite::GetModel(g_tremor_cnn_model),
    resolver,
    tensorArena,
    sizeof(tensorArena));

static bool ready = false;
static TfLiteTensor *inputTensor = nullptr;
static TfLiteTensor *outputTensor = nullptr;
static int modelChannels = 0;

inline bool init() {
    if (ready) return true;

    Serial.println(F("[TFLM] Configuring minimal operator resolver"));
    if (!configureResolver()) {
        Serial.println(F("[TFLM] ERROR: operator registration failed"));
        return false;
    }

    const tflite::Model *model = tflite::GetModel(g_tremor_cnn_model);
    if (model == nullptr) {
        Serial.println(F("[TFLM] ERROR: model pointer is null"));
        return false;
    }

    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println(F("[TFLM] ERROR: model schema version mismatch"));
        return false;
    }

    Serial.println(F("[TFLM] Allocating tensors (64 KB arena)"));
    if (interpreter.AllocateTensors() != kTfLiteOk) {
        Serial.println(F("[TFLM] ERROR: AllocateTensors failed; check arena size and model operators"));
        return false;
    }

    inputTensor = interpreter.input(0);
    outputTensor = interpreter.output(0);
    if (inputTensor == nullptr || outputTensor == nullptr) {
        Serial.println(F("[TFLM] ERROR: input/output tensor missing"));
        return false;
    }

    if (inputTensor->type != kTfLiteInt8 || outputTensor->type != kTfLiteInt8) {
        Serial.println(F("[TFLM] ERROR: model input/output must both be INT8"));
        return false;
    }

    if (inputTensor->dims == nullptr || inputTensor->dims->size != 3 ||
        inputTensor->dims->data[0] != 1 || inputTensor->dims->data[1] != 128) {
        Serial.println(F("[TFLM] ERROR: expected input shape 1x128xC"));
        return false;
    }

    modelChannels = inputTensor->dims->data[2];
    if (modelChannels != 3 && modelChannels != 6) {
        Serial.println(F("[TFLM] ERROR: expected 3 or 6 input channels"));
        return false;
    }

    if (g_tremor_cnn_channel_count != static_cast<unsigned int>(modelChannels)) {
        Serial.println(F("[TFLM] ERROR: model channel metadata mismatch"));
        return false;
    }

    if (inputTensor->bytes != 128 * modelChannels || outputTensor->bytes != 4) {
        Serial.println(F("[TFLM] ERROR: unexpected input/output tensor byte count"));
        return false;
    }

    if (outputTensor->dims == nullptr || outputTensor->dims->size < 2 ||
        outputTensor->dims->data[outputTensor->dims->size - 1] != 4) {
        Serial.println(F("[TFLM] ERROR: expected four output classes"));
        return false;
    }

    if (inputTensor->params.scale <= 0.0f || outputTensor->params.scale <= 0.0f) {
        Serial.println(F("[TFLM] ERROR: invalid INT8 quantization scale"));
        return false;
    }

    for (int c = 0; c < modelChannels; ++c) {
        if (!isfinite(g_tremor_cnn_channel_mean[c]) ||
            !isfinite(g_tremor_cnn_channel_std[c]) ||
            g_tremor_cnn_channel_std[c] < 1e-4f) {
            Serial.println(F("[TFLM] ERROR: invalid channel normalization metadata"));
            return false;
        }
    }

    ready = true;
    Serial.print(F("[TFLM] MODEL READY; channels="));
    Serial.println(modelChannels);
    return true;
}

// window6 contains 128 rows of ax, ay, az, gx, gy, gz.
// The supplied model is 3-axis, so it consumes ax, ay, az.
inline int predict(const float *window6, float *probabilities) {
    if (!ready || window6 == nullptr || probabilities == nullptr ||
        inputTensor == nullptr || outputTensor == nullptr) {
        return -1;
    }

    const float scale = inputTensor->params.scale;
    const int zeroPoint = inputTensor->params.zero_point;

    float windowMean[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    for (int t = 0; t < 128; ++t) {
        for (int c = 0; c < modelChannels; ++c) {
            const float value = window6[t * 6 + c];
            if (!isfinite(value)) return -1;
            windowMean[c] += value;
        }
    }
    for (int c = 0; c < modelChannels; ++c) {
        windowMean[c] /= 128.0f;
    }

    int dst = 0;
    for (int t = 0; t < 128; ++t) {
        for (int c = 0; c < modelChannels; ++c) {
            const float centered = window6[t * 6 + c] - windowMean[c];
            const float normalized =
                (centered - g_tremor_cnn_channel_mean[c]) /
                g_tremor_cnn_channel_std[c];
            const float qf = normalized / scale + static_cast<float>(zeroPoint);
            long q = lroundf(qf);
            if (q < -128) q = -128;
            if (q > 127) q = 127;
            inputTensor->data.int8[dst++] = static_cast<int8_t>(q);
        }
    }

    if (interpreter.Invoke() != kTfLiteOk) {
        return -1;
    }

    const float outScale = outputTensor->params.scale;
    const int outZero = outputTensor->params.zero_point;
    float sum = 0.0f;
    int best = 0;

    for (int c = 0; c < 4; ++c) {
        float p = (static_cast<float>(outputTensor->data.int8[c]) - outZero) * outScale;
        if (!isfinite(p) || p < 0.0f) p = 0.0f;
        probabilities[c] = p;
        sum += p;
    }

    if (!isfinite(sum) || sum <= 0.0f) return -1;

    for (int c = 0; c < 4; ++c) {
        probabilities[c] /= sum;
        if (probabilities[c] > probabilities[best]) best = c;
    }

    return best;
}

inline bool isReady() {
    return ready;
}

inline int channels() {
    return ready ? modelChannels : 0;
}

} // namespace StressTrackCNN

inline bool cnn_tflm_init() {
    return StressTrackCNN::init();
}

inline int cnn_tflm_predict(const float *window6, float *probabilities) {
    return StressTrackCNN::predict(window6, probabilities);
}

inline bool cnn_tflm_is_ready() {
    return StressTrackCNN::isReady();
}

inline int cnn_tflm_channels() {
    return StressTrackCNN::channels();
}
