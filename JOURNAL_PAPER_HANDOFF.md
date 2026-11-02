# Technical handoff for journal-paper preparation

**Project:** NeuroSense / StressTrack smart glove with SailmCalm application  
**Current deployed classifier:** `neurosense_cnn_v2_3axis`  
**Deployment target:** Seeed XIAO ESP32-C3 with TensorFlow Lite Micro  
**Purpose of this document:** Give the paper-writing collaborator a technically accurate account of the implementation, data, reported experiments, device evidence and unresolved limitations. This is a handoff, not a finished manuscript.

---

## 1. One-paragraph project description

NeuroSense is a wearable glove-oriented sensing prototype that combines an MPU6050 inertial measurement unit with GSR, pulse/heart-rate and skin-temperature sensing. A 3-axis accelerometer time-series classifier is deployed directly on a Seeed XIAO ESP32-C3 using a full-integer INT8 TensorFlow Lite Micro model. The device exposes current sensor telemetry and the CNN's class/probability outputs through a local HTTP JSON endpoint. The SailmCalm Flutter application reads that endpoint and presents live sensor readings and the CNN result alongside its existing profile, medication, daily-log, care and reporting features. The current classifier is an assistive research prototype; it has not been clinically validated and must not be presented as a Parkinson's diagnostic system.

## 2. Scope and terminology — important

Use the following descriptions consistently:

- **Deployed CNN:** `neurosense_cnn_v2_3axis`, INT8 TFLite Micro, running on the ESP32-C3.
- **CNN input:** MPU6050 accelerometer X, Y and Z only. The model input tensor is 1 × 128 × 3.
- **Not CNN inputs:** gyroscope XYZ, GSR, HRM2511E and DS18B20 readings. These remain device telemetry and context, but the training sources do not provide synchronized, independently labelled signals for them.
- **Separate legacy app model:** the Flutter project retains a Random Forest status-reproduction feature using `glove_status_random_forest.json`. It is shown in its own experimental section and is not the deployed tremor CNN. Do not conflate its output with the CNN.
- **Device class score:** softmax/top-output score for one inference. It is not accuracy, sensitivity, specificity or clinical confidence.
- **Rule-based tremor status:** a separate firmware signal heuristic; do not use this status as ground-truth labels for the CNN.

## 3. Hardware and system architecture

### 3.1 Hardware

| Component | Function | Firmware connection |
|---|---|---|
| Seeed XIAO ESP32-C3 | Main embedded processor and Wi-Fi server | MCU |
| MPU6050 | 3-axis accelerometer + 3-axis gyroscope | I²C SDA GPIO6, SCL GPIO7 |
| GSR sensor | Skin conductance telemetry | GPIO2 / A0 |
| HRM2511E | Pulse/heart-rate telemetry | GPIO4 / A2 |
| DS18B20 | Temperature telemetry | GPIO3 / one-wire |
| SH1106-compatible OLED | Device status, sensor pages and CNN result page | I²C address 0x3C |
| Physical button | OLED page switching | GPIO5 / D3, active-low |

The firmware uses a 400 kHz I²C bus, configures the MPU6050 sample-rate divisor for 50 Hz, and runs a dedicated IMU sampling task. Full-screen OLED refresh is limited to once per second to reduce I²C contention.

### 3.2 Data path

```text
MPU6050 accel XYZ @ nominal 50 Hz
        │
        ▼
Circular IMU buffer; 128 × 3 values used by current CNN
        │
        ▼
Window order / channel preprocessing
        │
        ▼
INT8 TFLite Micro interpreter on ESP32-C3
        │
        ├─ class index and label
        ├─ four class probabilities
        ├─ top output score
        └─ inference duration
        │
        ▼
GET /data → current.ml JSON object
        │
        ▼
Flutter LiveGlovePage parses current.ml
        │
        ▼
SailmCalm “ON-DEVICE CNN RESULT” card
```

GSR, HRM2511E, DS18B20 and gyroscope measurements are exposed separately in the same device JSON. They are not fused into the current classifier.

## 4. Data and preprocessing

### 4.1 Public window data (recorded training summary)

The saved training report from the project run records **24,060 windows** from four sources:

| Source | Windows |
|---|---:|
| IMU-Wild | 12,517 |
| PdAssist | 6,504 |
| TIM-Tremor | 3,092 |
| PD-BioStamp | 1,947 |
| **Total** | **24,060** |

The class counts recorded in the same report are:

| Label | Class | Windows |
|---:|---|---:|
| 0 | No tremor | 17,826 |
| 1 | Mild | 3,293 |
| 2 | Moderate | 2,185 |
| 3 | Severe | 756 |

This is an imbalanced dataset. Overall accuracy alone is not sufficient to characterize the model; report macro-F1, balanced accuracy and per-class precision/recall/F1.

**Source/unit cautions:** the project notes that the TIM-Tremor recordings were originally sampled at 1,000 Hz and standardized to 50 Hz by interpolation, while the other listed sources are described as 50 Hz. Do not assume that all source accelerations have identical physical units or orientations without checking each original dataset's metadata and the preparation audit. The source audit is not itself proof of unit equivalence.

The earlier spreadsheet of sparse glove telemetry was not used as supervised 50 Hz training data. It had a median adjacent timestamp gap of approximately 10.15 seconds and its tremor status came from firmware rules; it cannot provide valid 128 × 3 continuous windows or independent labels.

### 4.2 Windowing and model input

- Nominal sample rate: 50 Hz.
- Window length: 128 samples.
- Window duration: 128 / 50 = 2.56 seconds.
- Channel order: `ax_m_s2`, `ay_m_s2`, `az_m_s2`.
- Tensor shape: `[1, 128, 3]` for inference.

The embedded runtime applies the same preprocessing described by the training source:

1. Subtract each window's per-channel mean (remove the window DC component).
2. Subtract the per-channel mean fitted from training-fold centred windows.
3. Divide by the per-channel standard deviation fitted from training-fold centred windows.
4. Quantize normalized values to INT8 using the TFLite input tensor's quantization parameters.

The fitted channel normalization values are exported with the flatbuffer in `tflite_model_data.h`. The runtime and model header must be kept paired; replacing only one of them can invalidate inference.

## 5. CNN architecture and training method

The included `03_Model_Training/train_cnn_v2_50hz.py` contains the network definition and training/export pipeline for the model family. The architecture is a compact multi-scale, dilated residual 1D CNN:

1. Input `[128, 3]` (deployed 3-axis variant).
2. Stem Conv1D: 12 filters, kernel size 7, followed by batch normalization and ReLU.
3. Parallel temporal branches with 8 filters each and kernel sizes 3, 7 and 15.
4. Concatenate branches, then 1 × 1 Conv1D projection to 24 channels, batch normalization and ReLU.
5. Two 24-channel residual temporal blocks with dilation rates 1 and 2.
6. Average pooling by 2 and global average pooling.
7. Dense layer with 24 ReLU units, dropout 0.20, and 4-unit softmax output.

Recorded training settings in the script:

- Seed: 42.
- Optimizer: Adam, learning rate 8 × 10⁻⁴.
- Loss: class-weighted focal loss, gamma 1.5; alpha uses clipped inverse-square-root class frequency.
- Default maximum epochs: 70.
- Default batch size: 64.
- Early stopping: validation loss, patience 9, restore best weights.
- Learning-rate reduction: factor 0.5, patience 4, minimum learning rate 2 × 10⁻⁵.
- Augmentation: 3-D orientation rotations, scale perturbation (0.94–1.06) and low-level additive noise; training-only.
- Grouped validation: StratifiedGroupKFold; groups are intended to keep windows from a source segment together. The current report does **not** establish participant-independent splits because the public group IDs are segment/file identifiers, not verified participant IDs.
- Quantization: post-training full integer INT8 TFLite conversion, with representative windows sampled from the training data.

The current deployed artifact contains **3 input channels**. Although the trainer supports a 6-channel data shape, no 6-axis model should be claimed: the present public training set does not contain synchronized gyroscope channels. A future 6-axis model requires independently labelled continuous glove recordings and a separate evaluation.

## 6. Training evaluation results recorded for v2

The saved v2 run output reports these grouped cross-validation and held-out metrics:

| Metric | Float CNN | INT8 CNN |
|---|---:|---:|
| Held-out accuracy | 0.8325 | 0.8330 |
| Held-out balanced accuracy | 0.6457 | 0.6461 |
| Held-out macro precision | 0.6750 | 0.6786 |
| Held-out macro recall | 0.6457 | 0.6461 |
| Held-out macro-F1 | 0.6568 | 0.6592 |
| Held-out weighted F1 | 0.8281 | 0.8280 |

Grouped CV macro-F1: **0.6597 ± 0.0381** (reported mean ± standard deviation). The quantized model's macro-F1 difference relative to float was reported as +0.0023. The training script reports 9,088 float-model parameters and 33,640 bytes for the INT8 TFLite flatbuffer.

### INT8 per-class held-out results

| Class | Precision | Recall | F1 | Support |
|---|---:|---:|---:|---:|
| No tremor | 0.9119 | 0.9394 | 0.9254 | 3,581 |
| Mild | 0.5597 | 0.4394 | 0.4923 | 619 |
| Moderate | 0.5455 | 0.6055 | 0.5739 | 436 |
| Severe | 0.6972 | 0.6000 | 0.6450 | 165 |

**Interpretation:** the reported overall accuracy is strongly influenced by the large no-tremor class. Mild-class recall is comparatively low. The manuscript should disclose the class imbalance and per-class performance, and should avoid describing the model as highly accurate based only on 83.3% accuracy. These metrics are from a segment-grouped public-data evaluation, not an independent patient-level clinical study.

## 7. Embedded deployment details

- Runtime: TensorFlow Lite Micro, minimal `MicroMutableOpResolver` (capacity 12).
- Tensor arena: 64 KiB.
- Model artifact: INT8 TFLite flatbuffer byte array and preprocessing constants in `tflite_model_data.h`.
- Runtime wrapper: `cnn_tflm_runtime.h`.
- Inference cadence: the firmware fills a 128-sample ring buffer and runs another inference after 25 additional IMU samples.
- Output class index mapping: 0 no tremor, 1 mild, 2 moderate, 3 severe.
- Local inference remains operational independently of Wi-Fi; Wi-Fi is only for dashboard/app access and optional integrations.

### Actual device/API observation supplied by the team

One real `/data?compact=1` response from the physical XIAO reported:

| Item | Observed value |
|---|---:|
| Model available | true |
| Algorithm | `tflite_micro_cnn_int8` |
| Version | `neurosense_cnn_v2_3axis` |
| Input profile | `accel_xyz` |
| Prediction | No tremor (class 0) |
| Top output score | 0.9570 |
| Inference time | 73.439 ms |
| Measured sample rate | 49.2 Hz (target 50 Hz) |
| Average sample interval | 20.331 ms |
| Dropped samples | 2 |
| Missed deadlines | 26 |
| Successful samples | 2,743 |
| Device network | SSID `iotdata`, IP `172.20.10.2` |

This confirms model initialization/inference and live JSON delivery on the board at the time of capture. It is a snapshot, not a full-duration benchmark or clinical-performance result. Collect a sustained run with at least several hundred inferences and report sample interval median/p95/max, measured rate stability, missed deadlines, dropped reads, free heap and inference latency median/p95/max before presenting robust device performance claims.

## 8. Android application integration

The Flutter app calls the local XIAO `/data` endpoint. The CNN integration added a new `ON-DEVICE CNN RESULT` card in `lib/screens/live_glove_page.dart`. It parses `current.ml` and displays:

- class label;
- four class probabilities;
- top output score;
- inference time;
- model version and input profile;
- measured/target sampling frequency;
- dropped samples and missed deadlines.

The app retains its existing account/authentication, private records, medication, daily log, care, reports and export components. Do not claim that the phone runs the CNN: inference occurs on the ESP32, and the app is the display/client layer.

The checked-in source endpoint is `http://172.20.10.2/data`; it is specific to the demonstrated hotspot setup and should be configurable before broader distribution. The team's release build command succeeded with a 70.1 MB APK. The analyzer output had warnings/info notices, but no fatal build failure was reported. The APK binary still needs to be placed in the release folder for final handoff.

## 9. Recommended journal manuscript structure

1. **Title** — emphasize embedded, edge-based tremor classification using a wearable IMU; avoid a diagnostic title.
2. **Abstract** — problem, device/model method, dataset size/sources, grouped evaluation metrics, on-device latency/sample-rate evidence, and limitations.
3. **Introduction** — motivation for wearable tremor monitoring and edge inference; define the scope as research monitoring, not diagnosis.
4. **Related work** — wearable IMU tremor classification, time-series CNNs, quantized edge inference and embedded health-monitoring systems. Use primary sources and cite each public dataset correctly.
5. **System architecture** — glove sensors, MCU, display, Wi-Fi JSON endpoint and SailmCalm client. Include the block diagram from Section 3.
6. **Dataset and preprocessing** — exact dataset versions, labels, sampling rate, windowing, source unit harmonization, group construction, exclusions and class distribution.
7. **Model architecture and training** — CNN blocks, focal loss, augmentation, grouped validation, early stopping and INT8 conversion.
8. **Results** — float vs INT8 metrics, per-class metrics, confusion matrix, quantization comparison, model size and actual board timings.
9. **Discussion** — class imbalance, lower mild recall, domain shift between public datasets and a glove, orientation/unit matching, the difference between per-inference score and accuracy.
10. **Limitations and ethics** — segment-level rather than subject-independent validation, no clinician-confirmed prospective dataset, no clinical validation, no synchronized multimodal labels, privacy/consent/approval for future human recordings.
11. **Conclusion and future work** — additional participant-independent data, synchronized glove capture, 6-axis model only after data collection, longer hardware benchmark, external validation and usability evaluation.

## 10. Required additional work before a strong journal submission

- Recover and archive the exact dataset-preparation scripts, original public-data versions, checksums, metadata and unit-conversion decisions.
- Preserve the exact split/group IDs and export complete confusion matrices/classification reports from the run corresponding to the deployed header.
- Verify whether groups correspond to recordings/segments or actual subjects. Do not label segment-grouped validation as subject-independent.
- Check every source's axis orientation and acceleration units against the MPU6050 configuration. Document any resampling/interpolation.
- Run an ablation: no augmentation vs augmentation; ordinary cross-entropy vs focal loss; float vs INT8; perhaps compare an appropriate tree baseline using identical group splits.
- Capture labelled glove data with ethics/consent approval, independent labels, pseudonymous subject IDs, and subject-exclusive splits. Do not use the firmware rule-based status as the ground truth.
- Run a 5-minute or longer continuous hardware benchmark while the Wi-Fi dashboard and app are active. Report timing distribution, drop counts, missed deadlines, heap and latency percentiles.
- Test app connection and UI on the target tablet and archive screenshots/video, app version and APK hash.
- Have a domain expert review the clinical language. Describe this as a research tremor-monitoring prototype, not diagnosis or treatment guidance.

## 11. Claims the paper must not make

- Do not claim the model is clinically validated or diagnoses Parkinson's disease.
- Do not claim the CNN consumes six axes or fuses GSR/heart-rate/temperature; current deployed input is accelerometer XYZ only.
- Do not call a 95.7% single-window output score 95.7% accuracy.
- Do not use device OLED/API labels or the rule-based status as independent test labels.
- Do not imply the held-out split is patient-independent; current group identifiers are recording/segment groups.
- Do not report an on-device sample rate/inference snapshot as a sustained benchmark.
- Do not present the app's separate experimental Random Forest status estimate as the embedded CNN result.

## 12. Files to inspect first

- `01_Firmware/StressTrack_XIAO_50Hz_CNN/StressTrack_XIAO_50Hz_CNN.ino` — sensor scheduling, OLED, network server and `current.ml` JSON.
- `01_Firmware/StressTrack_XIAO_50Hz_CNN/cnn_tflm_runtime.h` — TFLite Micro inference, preprocessing and tensor validation.
- `01_Firmware/StressTrack_XIAO_50Hz_CNN/tflite_model_data.h` — deployed INT8 model bytes and fold-fitted preprocessing constants.
- `02_MobileApp/MobileApp/lib/screens/live_glove_page.dart` — app parsing and CNN result UI.
- `03_Model_Training/train_cnn_v2_50hz.py` — CNN architecture, augmentation, training, evaluation and export.

## 13. Evidence and provenance notes

The numeric training results in this handoff come from the team's recorded `cnn_v2_report.json` / `cnn_v2_metrics.csv` console output for `neurosense_cnn_v2_3axis`. The embedded runtime/device figures come from the team's physical XIAO `/data` JSON response. Re-run and archive the complete original artifacts before submission; the console transcript is not a substitute for the complete report, dataset audit, confusion matrix CSVs and split metadata.
