/*
  ╔══════════════════════════════════════════════════════════════════╗
  ║  StressTrack — Surgical Monitoring Suite   v8 FINAL             ║
  ║  Build:     July 11, 2026                                        ║
  ║  Developer: Dr. Raushan Singh                                    ║
  ║  Board:     Seeed XIAO ESP32C3                                   ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║  SENSORS                                                         ║
  ║   • GSR       — A0  (GPIO2)  stress / skin conductance          ║
  ║   • MPU6050   — D4/D5 (I2C) accel + gyro + die temp            ║
  ║   • HRM2511E  — A2  (GPIO4)  analog pulse / heart rate          ║
  ║   • DS18B20   — D1  (GPIO3)  OneWire body temperature           ║
  ║  BUTTON       — D3  (GPIO5) + GND  →  screen change            ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║  v8 CHANGES vs v7                                                ║
  ║   1. Tremor redesigned for SURGICAL GLOVE context:              ║
  ║      - IMU no longer used for screen switching (button only)    ║
  ║      - 4–8 Hz band (surgical/essential tremor range)            ║
  ║      - RMS amplitude, not peak-to-peak                          ║
  ║      - Requires 3 consecutive 2-second windows of consistent    ║
  ║        rhythmic signal before alerting (≥6s sustained tremor)  ║
  ║      - Normal surgical hand movements never trigger a false alarm║
  ║   2. Glossary updated with clinical reference values            ║
  ║   3. Google Sheets logging — step-by-step setup in dashboard    ║
  ║   4. Physical button on GPIO5/D3 changes OLED screen           ║
  ║      IMU data used exclusively for tremor analysis now          ║
  ║   5. Body temperature: separate °C and °F cards in HTML        ║
  ╚══════════════════════════════════════════════════════════════════╝

  WIRING — BUTTON (new):
    One leg → D3 (GPIO5) on XIAO ESP32C3
    Other leg → GND
    No resistor needed — internal pull-up is used.
    Press = LOW (active-low).

  REQUIRED LIBRARIES:
    Adafruit SH110X · Adafruit MPU6050 · Adafruit Unified Sensor
    OneWire · DallasTemperature
  (MAX30100lib no longer needed)
*/

// ═══════════════════════════════════════════════════════════════════
//  INCLUDES
// ═══════════════════════════════════════════════════════════════════
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SH110X.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <HTTPClient.h>
#include <time.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include "cnn_tflm_runtime.h"
#ifndef STRESSTRACK_CNN_MODEL_VERSION
#define STRESSTRACK_CNN_MODEL_VERSION "1.0.0"
#endif

// ═══════════════════════════════════════════════════════════════════
//  FORWARD DECLARATIONS
// ═══════════════════════════════════════════════════════════════════
void handleRoot(); void handleData(); void handleGraphs();
void handleProvisionRoot(); void handleProvisionScan(); void handleProvisionSave();
void syncTime();
bool tryConnect(const char*, const char*, int timeoutSecs = 12);
bool tryKnownNetworks();
bool connectWithSavedCredentials();
void startProvisioningMode();
void checkButton();
void pushToBuffer();
void sendToSheets();
void pushSpark();
void drawSparkline(float* arr, int x, int y, int w, int h);
void drawCombinedScreen();
void drawGsrScreen();
void drawMpuGraphScreen();
void drawHeartScreen();
void drawMLScreen();
void pushMLSample(float ax,float ay,float az,float gx,float gy,float gz);
void runMLIfReady();
void updateTremor();
void imuSamplingTask(void *parameter);
void flushDisplay();
int  hrmSmooth(int val);
void addRRInterval(float rr);
float rollingAvgBPM();
void computeHRV();
float getAccuracy();
const char* getHeartRateZone(float b);
void resetHRMSession();
float toF(float c);

// ═══════════════════════════════════════════════════════════════════
//  PINS & OBJECTS
// ═══════════════════════════════════════════════════════════════════
#define I2C_SDA      6
#define I2C_SCL      7
#define GSR_PIN      2
#define HRM_PIN      4
#define ONE_WIRE_PIN 3
#define BUTTON_PIN   5      // D3 on XIAO ESP32C3 → one leg to GND

// Google Sheets — paste your Apps Script web app URL below.
// Leave empty ("") to disable. See the dashboard's Sheets setup panel.
#define SHEETS_URL   ""
#define SHEETS_INTERVAL_MS 30000   // log every 30 seconds
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_ADDR     0x3C

SemaphoreHandle_t i2cMutex = nullptr;
Adafruit_SH1106G  display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
Adafruit_MPU6050  mpu;
OneWire           oneWire(ONE_WIRE_PIN);
DallasTemperature ds18b20(&oneWire);

// Mutex protects shared I2C use between OLED and the high-priority MPU task.
void flushDisplay(){
  if(i2cMutex){
    if(xSemaphoreTake(i2cMutex,pdMS_TO_TICKS(3))==pdTRUE){ display.display(); xSemaphoreGive(i2cMutex); }
  }else display.display();
}

// ═══════════════════════════════════════════════════════════════════
//  KNOWN WiFi NETWORKS
// ═══════════════════════════════════════════════════════════════════
struct KnownNet { const char* ssid; const char* pass; };
// Deployment credentials are intentionally redacted in the submission copy.
// Replace these placeholders locally before compiling, or use StressTrack-Setup
// provisioning to save credentials in ESP32 Preferences. Never commit real passwords.
KnownNet knownNets[] = {
  { "YOUR_HOTSPOT_SSID", "YOUR_HOTSPOT_PASSWORD" },
};
const int NUM_KNOWN = sizeof(knownNets) / sizeof(knownNets[0]);

// ═══════════════════════════════════════════════════════════════════
//  WiFi / SERVER STATE
// ═══════════════════════════════════════════════════════════════════
#define AP_SSID  "StressTrack-Setup"
#define AP_PASS  ""
#define DNS_PORT 53
DNSServer   dnsServer;
WebServer   server(80);
Preferences prefs;
bool   isConnected   = false;
String connectedSSID = "";
String ipAddress     = "";

// ═══════════════════════════════════════════════════════════════════
//  NTP
// ═══════════════════════════════════════════════════════════════════
const char* ntpServer     = "pool.ntp.org";
const long  gmtOffset_sec = 19800;
const int   dstOffset_sec = 0;

// ═══════════════════════════════════════════════════════════════════
//  GSR  (calculation UNCHANGED)
// ═══════════════════════════════════════════════════════════════════
int  averagedValue10bit = 0;
int  rawAveraged10bit   = 0;
int  afterOffsetValue   = 0;
int  constrainedValue   = 0;
const int calibrationOffset = -45;
int  zeroCount  = 0;
bool isUpdating = true;
String stressLevel = "No input";
int  gsrAccum = 0, gsrSampleCount = 0;

// ═══════════════════════════════════════════════════════════════════
//  MPU6050
// ═══════════════════════════════════════════════════════════════════
float ax, ay, az, gx, gy, gz, mpuTempC;
// Dedicated 50 Hz MPU6050 sampling task. Raw/benchmark logs are opt-in.
#define RAW_IMU_SERIAL_LOG 0
#define RAW_MULTISENSOR_SERIAL_LOG 0  // 50 Hz timestamped IMU + latest GSR/HRM/DS18B20 snapshot
#define EDGE_BENCH_SERIAL_LOG 0
#define IMU_SAMPLE_PERIOD_MS 20
#define IMU_I2C_MUTEX_WAIT_MS 25
#define IMU_TASK_PRIORITY 4
#define ML_WINDOW_N 128
#define ML_INFERENCE_STRIDE 25
portMUX_TYPE mlMux = portMUX_INITIALIZER_UNLOCKED;
uint32_t imuDroppedReadCount = 0;
uint32_t imuSampleSequence = 0;
uint32_t lastImuSampleMicros = 0;
uint32_t mlLastSampleIntervalUs = 0;
uint32_t mlAverageSampleIntervalUs = 0;
uint32_t imuMissedDeadlineCount = 0;
uint32_t imuSuccessfulSampleCount = 0;
uint32_t mlInferenceCount = 0;
float mlWindow[ML_WINDOW_N][6];  // Interleaved accel XYZ + gyro XYZ; model may consume 3 or 6 channels.
uint16_t mlWindowIndex = 0;
uint16_t mlWindowCount = 0;
uint16_t mlSamplesAfterInference = ML_INFERENCE_STRIDE;
int mlPredictedClass = -1;
float mlScore = 0.0f;
float mlProbabilities[4] = {0,0,0,0};
uint32_t mlLastInferenceUs = 0;

// ═══════════════════════════════════════════════════════════════════
//  TREMOR DETECTION — SURGICAL GLOVE CONTEXT
//
//  Designed so that normal surgical hand movements (0.1–2 Hz) do NOT
//  trigger false alarms. Only true pathological tremor (4–8 Hz,
//  sustained for ≥6 seconds) will alert.
//
//  Algorithm:
//   1. High-pass filter (α=0.87) removes gravity DC from accel magnitude.
//   2. 200-sample rolling buffer (4 seconds at 50 Hz) fed every 20 ms.
//   3. Analysis runs every 2 seconds (not every sample).
//   4. Frequency estimated from zero-crossing count.
//   5. Amplitude = RMS of HP-filtered buffer (robust against outliers).
//   6. Classification requires 3 consecutive positive 2-second windows
//      → minimum 6 seconds of sustained tremor before any alert fires.
//   7. Frequency must be consistent (±1.5 Hz) between windows.
//
//  Thresholds (surgical, calibrated higher than generic):
//   Mild     → RMS ≥ 0.40 m/s²   in 4–8 Hz band
//   Moderate → RMS ≥ 0.90 m/s²
//   Severe   → RMS ≥ 2.00 m/s²
// ═══════════════════════════════════════════════════════════════════
#define TREMOR_BUF_SZ       200    // 200 × 20ms = 4-second rolling window
#define TREMOR_MIN_HZ       4.0    // Surgical / essential tremor starts at 4 Hz
#define TREMOR_MAX_HZ       8.0    // Above 8 Hz = physiological, not pathological
#define TREMOR_MILD_AMP     0.40   // RMS m/s² — mild threshold
#define TREMOR_MOD_AMP      0.90   // RMS m/s² — moderate threshold
#define TREMOR_SEV_AMP      2.00   // RMS m/s² — severe threshold
#define TREMOR_CONFIRM_RQED 3      // consecutive positive windows needed

float tremorBuf[TREMOR_BUF_SZ];
int   tremorBufIdx  = 0;
bool  tremorBufFull = false;
float tremorHPPrev  = 0, tremorMagPrev = 0;
const float TREMOR_HP_ALPHA = 0.87;

float       tremorAmplitude = 0;   // RMS of HP-filtered signal
float       tremorFrequency = 0;
float       tremorPrevFreq  = 0;   // for consistency check
int         tremorConfirmCount = 0;
const char* tremorStatus    = "Analyzing";
bool        tremorActive    = false;
unsigned long lastTremorAnalysis = 0;
const unsigned long TREMOR_ANALYSIS_INTERVAL = 2000;

// ═══════════════════════════════════════════════════════════════════
//  DS18B20
// ═══════════════════════════════════════════════════════════════════
float bodyTempC = 0;
float bodyTempF = 0;
unsigned long lastTempRequest = 0;
bool tempRequestPending = false;
const unsigned long TEMP_INTERVAL = 2000;

// ═══════════════════════════════════════════════════════════════════
//  HRM2511E  (analog pulse on A2/GPIO4)
// ═══════════════════════════════════════════════════════════════════
#define HRM_FINGER_THRESHOLD  800
#define HRM_BEAT_THRESHOLD    2500
#define HRM_BEAT_RESET_MARGIN 150
#define HRM_ACCURACY_RAMP_S   120
#define HRM_ROLLING_WINDOW    20
#define HRM_MAX_HISTORY       300
#define HRM_QUALITY_WINDOW_MS 5000
#define HRM_FINGER_LOST_MS    1500
#define HRM_FILTER_SIZE       5

bool  hrmBeatDetected  = false;
bool  hrmSessionActive = false;
bool  hrmFingerContact = false;
bool  hrmBeatEvent     = false;
unsigned long hrmLastBeat = 0, hrmSessionStart = 0;
int   hrmBeatCount = 0;
float hrmBpm = 0, hrmAvgBpm = 0, hrmMinBpm = 999, hrmMaxBpm = 0;
float hrmRR = 0, hrmPulsePeriod = 0;
float hrmRRHistory[HRM_MAX_HISTORY];
int   hrmRRCount = 0;
float hrmSDNN = 0, hrmRMSSD = 0, hrmPNN50 = 0;
int   hrmNN50 = 0;
int   hrmQualMin = 4095, hrmQualMax = 0;
unsigned long hrmQualWindowStart = 0;
const char* hrmSignalQuality = "Checking...";
bool  hrmBelowThreshold = false;
unsigned long hrmBelowThresholdSince = 0;
int   hrmFilterBuf[HRM_FILTER_SIZE] = {0};
int   hrmFilterIdx = 0;
int   hrmRawSignal = 0;

// Timestamped snapshots used only by the optional multimodal capture logger.
// These values are also exposed through the existing /data dashboard endpoint.
portMUX_TYPE sensorTelemetryMux = portMUX_INITIALIZER_UNLOCKED;
int telemetryGsr10bit = 0;
int telemetryHrmRaw12bit = 0;
float telemetryHrmBpm = 0.0f;
float telemetryBodyTempC = 0.0f;
uint32_t telemetryGsrUpdatedUs = 0;
uint32_t telemetryHrmRawUpdatedUs = 0;
uint32_t telemetryHrmBpmUpdatedUs = 0;
uint32_t telemetryBodyTempUpdatedUs = 0;

// OLED waveform buffer
#define WAVE_W 120
int16_t waveBuf[WAVE_W] = {0};
int     oledBeatFlash   = 0;

// ── Physical button (GPIO5 / D3) — screen change ─────────────────
bool          btnLastState    = HIGH;
unsigned long btnLastDebounce = 0;
const unsigned long BTN_DEBOUNCE = 200;

// ═══════════════════════════════════════════════════════════════════
//  OLED MULTI-SCREEN
// ═══════════════════════════════════════════════════════════════════
int  currentScreen = 0;
const int NUM_SCREENS = 5;
// NOTE: IMU is no longer used for screen switching (v8).
// Screen change is handled by the physical button on GPIO5.
float needleAngle = 180.0;

#define SPARK_N 24
float sparkAX[SPARK_N], sparkAY[SPARK_N], sparkAZ[SPARK_N];
float sparkGX[SPARK_N], sparkGY[SPARK_N], sparkGZ[SPARK_N];
int   sparkIdx = 0; bool sparkFilled = false;
unsigned long lastSparkPush = 0;
const unsigned long SPARK_INTERVAL = 150;

unsigned long lastOLEDUpdate = 0;
// SH1106 transfers a full 1 KB frame over the shared I2C bus.
// Refreshing at 20 Hz starved the MPU6050 50 Hz sampler; 1 Hz keeps
// the OLED readable while giving the sensor bus priority.
const unsigned long OLED_INTERVAL = 1000;

// ═══════════════════════════════════════════════════════════════════
//  HISTORY BUFFER
// ═══════════════════════════════════════════════════════════════════
#define BUF_SZ 60
struct Sample {
  int   gsr;
  float ax,ay,az,gx,gy,gz,mpuTemp;
  float bodyTemp,bpm,avgBpm;
  char  time[9];
};
Sample buf[BUF_SZ];
int   bufIdx=0; bool bufFilled=false;
unsigned long lastBufPush=0;
const unsigned long BUF_INTERVAL=1000;

// ═══════════════════════════════════════════════════════════════════
//  UTILITY
// ═══════════════════════════════════════════════════════════════════
float toF(float c) { return c * 9.0 / 5.0 + 32.0; }

void syncTime() {
  if (!isConnected) return;
  configTime(gmtOffset_sec,dstOffset_sec,ntpServer);
  struct tm ti;
  #if !RAW_MULTISENSOR_SERIAL_LOG
  if (!getLocalTime(&ti)) Serial.println("NTP fail"); else Serial.println("NTP ok");
#else
  getLocalTime(&ti);
#endif
}

// ═══════════════════════════════════════════════════════════════════
//  TREMOR DETECTION
// ═══════════════════════════════════════════════════════════════════
void updateTremor() {
  // ── Step 1: HP filter + push sample every 20ms ─────────────────
  float rawMag = sqrt(ax*ax + ay*ay + az*az);
  float hp = TREMOR_HP_ALPHA * (tremorHPPrev + rawMag - tremorMagPrev);
  tremorHPPrev = hp; tremorMagPrev = rawMag;
  tremorBuf[tremorBufIdx] = hp;
  tremorBufIdx = (tremorBufIdx+1) % TREMOR_BUF_SZ;
  if (tremorBufIdx==0) tremorBufFull=true;

  // ── Step 2: Full analysis only every 2 seconds ──────────────────
  // This means 3 consecutive positive analyses = ≥6s of sustained tremor
  // before any alert fires — normal surgical hand movements (brief,
  // arrhythmic) will NOT accumulate enough positive windows.
  if (millis() - lastTremorAnalysis < TREMOR_ANALYSIS_INTERVAL) return;
  lastTremorAnalysis = millis();

  int count = tremorBufFull ? TREMOR_BUF_SZ : tremorBufIdx;
  if (count < 20) { tremorStatus="Analyzing"; return; }

  // ── Step 3: RMS amplitude (more robust than peak-to-peak) ───────
  float sumSq = 0, mean = 0;
  for (int i=0;i<count;i++) {
    const int idx = tremorBufFull ? (tremorBufIdx+i)%TREMOR_BUF_SZ : i;
    const float v = tremorBuf[idx];
    sumSq += v*v; mean += v;
  }
  tremorAmplitude = sqrt(sumSq / count);   // RMS
  mean /= count;

  // ── Step 4: Zero-crossing frequency (chronological ring-buffer order) ──
  int crossings = 0;
  for (int i=1;i<count;i++) {
    const int a = tremorBufFull ? (tremorBufIdx+i-1)%TREMOR_BUF_SZ : i-1;
    const int b = tremorBufFull ? (tremorBufIdx+i)%TREMOR_BUF_SZ : i;
    if ((tremorBuf[a]-mean)*(tremorBuf[b]-mean)<0) crossings++;
  }
  float timeSec = count * 0.02f;
  tremorFrequency = (crossings / 2.0f) / timeSec;

  // ── Step 5: Frequency consistency with previous window ──────────
  bool freqConsistent = (tremorPrevFreq < 0.1f) ||
                        (fabs(tremorFrequency - tremorPrevFreq) < 1.5f);
  tremorPrevFreq = tremorFrequency;

  // ── Step 6: Confirmation count (surgical false-positive guard) ───
  bool inBand = (tremorFrequency >= TREMOR_MIN_HZ &&
                 tremorFrequency <= TREMOR_MAX_HZ);
  bool positive = inBand && freqConsistent &&
                  (tremorAmplitude >= TREMOR_MILD_AMP);

  if (positive) {
    if (tremorConfirmCount < TREMOR_CONFIRM_RQED) tremorConfirmCount++;
  } else {
    // Bleed down slowly so a single clear window doesn't reset instantly
    if (tremorConfirmCount > 0) tremorConfirmCount--;
  }

  // ── Step 7: Classify only after confirmation threshold ──────────
  if (tremorConfirmCount < TREMOR_CONFIRM_RQED) {
    tremorStatus = (tremorConfirmCount > 0) ? "Checking" : "None";
    tremorActive = false;
  } else if (tremorAmplitude < TREMOR_MOD_AMP) {
    tremorStatus = "Mild";    tremorActive = true;
  } else if (tremorAmplitude < TREMOR_SEV_AMP) {
    tremorStatus = "Moderate"; tremorActive = true;
  } else {
    tremorStatus = "Severe";  tremorActive = true;
  }
}

// ═══════════════════════════════════════════════════════════════════
//  ON-DEVICE CNN INFERENCE (50 Hz, 128 x 3 or 128 x 6 input)
//  Full-integer TFLite Micro model and preprocessing execute locally on XIAO.
// ═══════════════════════════════════════════════════════════════════
void pushMLSample(float axv,float ayv,float azv,float gxv,float gyv,float gzv){
  taskENTER_CRITICAL(&mlMux);
  mlWindow[mlWindowIndex][0]=axv; mlWindow[mlWindowIndex][1]=ayv; mlWindow[mlWindowIndex][2]=azv;
  mlWindow[mlWindowIndex][3]=gxv; mlWindow[mlWindowIndex][4]=gyv; mlWindow[mlWindowIndex][5]=gzv;
  mlWindowIndex=(mlWindowIndex+1)%ML_WINDOW_N;
  if(mlWindowCount<ML_WINDOW_N) mlWindowCount++;
  if(mlSamplesAfterInference<65535) mlSamplesAfterInference++;
  taskEXIT_CRITICAL(&mlMux);
}

void runMLIfReady(){
  static float ordered[ML_WINDOW_N][6]; bool ready=false;
  taskENTER_CRITICAL(&mlMux);
  if(mlWindowCount>=ML_WINDOW_N && mlSamplesAfterInference>=ML_INFERENCE_STRIDE){
    for(int i=0;i<ML_WINDOW_N;i++){
      int src=(mlWindowIndex+i)%ML_WINDOW_N;
      for(int c=0;c<6;c++) ordered[i][c]=mlWindow[src][c];
    }
    mlSamplesAfterInference=0; ready=true;
  }
  taskEXIT_CRITICAL(&mlMux);
  if(!ready) return;
#if STRESSTRACK_CNN_AVAILABLE
  const uint32_t t0=micros();
  mlPredictedClass=cnn_tflm_predict(&ordered[0][0],mlProbabilities);
  mlLastInferenceUs=(uint32_t)(micros()-t0);
  if(mlPredictedClass>=0){ mlScore=mlProbabilities[mlPredictedClass]; mlInferenceCount++; }
  else { mlScore=0.0f; for(int c=0;c<4;c++) mlProbabilities[c]=0.0f; }
#if EDGE_BENCH_SERIAL_LOG
  Serial.print(F("CNN_BENCH,")); Serial.print(mlInferenceCount); Serial.print(',');
  Serial.print(mlPredictedClass); Serial.print(','); Serial.print(mlScore,6); Serial.print(',');
  Serial.print(mlLastInferenceUs); Serial.print(','); Serial.println(ESP.getFreeHeap());
#endif
#else
  mlPredictedClass=-1; mlScore=0.0f;
#endif
}
// ================================================================
//  FIXED-RATE IMU SAMPLING TASK
//  Target: one MPU6050 read every 20 ms (50 Hz).
//  The OLED shares I2C, so its refresh is deliberately rate-limited.
//  A missed deadline is counted and the scheduler is re-anchored; the
//  task never performs rapid catch-up reads that would distort timing.
// ================================================================
void imuSamplingTask(void *parameter) {
    (void)parameter;

    TickType_t lastWake = xTaskGetTickCount();
    TickType_t periodTicks = pdMS_TO_TICKS(IMU_SAMPLE_PERIOD_MS);
    if (periodTicks == 0) periodTicks = 1;

    uint32_t previousSampleMicros = 0;

    for (;;) {
        vTaskDelayUntil(&lastWake, periodTicks);

        sensors_event_t a, g, t;
        bool i2cLocked = true;

        if (i2cMutex != nullptr) {
            i2cLocked = (xSemaphoreTake(
                i2cMutex,
                pdMS_TO_TICKS(IMU_I2C_MUTEX_WAIT_MS)
            ) == pdTRUE);
        }

        if (!i2cLocked) {
            ++imuDroppedReadCount;
            ++imuMissedDeadlineCount;
            // Do not try to catch up against an expired absolute deadline.
            lastWake = xTaskGetTickCount();
            continue;
        }

        mpu.getEvent(&a, &g, &t);

        if (i2cMutex != nullptr) {
            xSemaphoreGive(i2cMutex);
        }

        // Timestamp after the successful read: this is the actual spacing
        // between acquired samples, including any I2C contention.
        const uint32_t sampleMicros = micros();
        if (previousSampleMicros != 0) {
            const uint32_t intervalUs =
                (uint32_t)(sampleMicros - previousSampleMicros);
            mlLastSampleIntervalUs = intervalUs;

            // Exponential moving average smooths one-off bus delays while
            // still exposing sustained under-sampling to the companion app.
            if (mlAverageSampleIntervalUs == 0) {
                mlAverageSampleIntervalUs = intervalUs;
            } else {
                mlAverageSampleIntervalUs =
                    (mlAverageSampleIntervalUs * 7U + intervalUs) / 8U;
            }
        }
        previousSampleMicros = sampleMicros;
        ++imuSuccessfulSampleCount;

        ax = a.acceleration.x;
        ay = a.acceleration.y;
        az = a.acceleration.z;
        gx = g.gyro.x;
        gy = g.gyro.y;
        gz = g.gyro.z;
        mpuTempC = t.temperature;

        pushMLSample(ax, ay, az, gx, gy, gz);
        updateTremor();

#if RAW_MULTISENSOR_SERIAL_LOG
        const uint32_t seq = imuSampleSequence;
        int gsrSnap, hrmRawSnap;
        float bpmSnap, bodyTempSnap;
        uint32_t gsrUs, hrmRawUs, bpmUs, bodyTempUs;

        taskENTER_CRITICAL(&sensorTelemetryMux);
        gsrSnap = telemetryGsr10bit;
        hrmRawSnap = telemetryHrmRaw12bit;
        bpmSnap = telemetryHrmBpm;
        bodyTempSnap = telemetryBodyTempC;
        gsrUs = telemetryGsrUpdatedUs;
        hrmRawUs = telemetryHrmRawUpdatedUs;
        bpmUs = telemetryHrmBpmUpdatedUs;
        bodyTempUs = telemetryBodyTempUpdatedUs;
        taskEXIT_CRITICAL(&sensorTelemetryMux);

        const uint32_t logNowUs = micros();
        const uint32_t gsrAgeMs = gsrUs
            ? (uint32_t)(logNowUs - gsrUs) / 1000U : 0xFFFFFFFFU;
        const uint32_t hrmRawAgeMs = hrmRawUs
            ? (uint32_t)(logNowUs - hrmRawUs) / 1000U : 0xFFFFFFFFU;
        const uint32_t bpmAgeMs = bpmUs
            ? (uint32_t)(logNowUs - bpmUs) / 1000U : 0xFFFFFFFFU;
        const uint32_t bodyTempAgeMs = bodyTempUs
            ? (uint32_t)(logNowUs - bodyTempUs) / 1000U : 0xFFFFFFFFU;

        Serial.print(F("MULTI_RAW,"));
        Serial.print(seq); Serial.print(',');
        Serial.print(sampleMicros); Serial.print(',');
        Serial.print(ax, 6); Serial.print(',');
        Serial.print(ay, 6); Serial.print(',');
        Serial.print(az, 6); Serial.print(',');
        Serial.print(gx, 6); Serial.print(',');
        Serial.print(gy, 6); Serial.print(',');
        Serial.print(gz, 6); Serial.print(',');
        Serial.print(gsrSnap); Serial.print(',');
        Serial.print(gsrAgeMs); Serial.print(',');
        Serial.print(hrmRawSnap); Serial.print(',');
        Serial.print(hrmRawAgeMs); Serial.print(',');
        Serial.print(bpmSnap, 2); Serial.print(',');
        Serial.print(bpmAgeMs); Serial.print(',');
        Serial.print(bodyTempSnap, 2); Serial.print(',');
        Serial.println(bodyTempAgeMs);
#endif

#if EDGE_BENCH_SERIAL_LOG
        Serial.print(F("IMU_TIMING,"));
        Serial.print(imuSampleSequence); Serial.print(',');
        Serial.print(sampleMicros); Serial.print(',');
        Serial.print(mlLastSampleIntervalUs); Serial.print(',');
        Serial.println(ESP.getFreeHeap());
#endif

        ++imuSampleSequence;

        // vTaskDelayUntil() advances lastWake by one period. If the sensor
        // read or a shared-bus transfer ran past the next deadline, count
        // the missed period(s) and restart the schedule from the present.
        const TickType_t nowTicks = xTaskGetTickCount();
        const TickType_t latenessTicks = (TickType_t)(nowTicks - lastWake);
        if (latenessTicks >= periodTicks) {
            imuMissedDeadlineCount += latenessTicks / periodTicks;
            lastWake = nowTicks;
        }
    }
}

const char* mlClassName(int c){
  switch(c){case 0:return "NO TREMOR";case 1:return "MILD";case 2:return "MODERATE";case 3:return "SEVERE";default:return "MODEL N/A";}
}

// ═══════════════════════════════════════════════════════════════════
//  HRM HELPERS
// ═══════════════════════════════════════════════════════════════════
int hrmSmooth(int val) {
  hrmFilterBuf[hrmFilterIdx]=val;
  hrmFilterIdx=(hrmFilterIdx+1)%HRM_FILTER_SIZE;
  long s=0; for(int i=0;i<HRM_FILTER_SIZE;i++) s+=hrmFilterBuf[i];
  return s/HRM_FILTER_SIZE;
}
void addRRInterval(float rr) {
  if(hrmRRCount<HRM_MAX_HISTORY) hrmRRHistory[hrmRRCount++]=rr;
  else { for(int i=1;i<HRM_MAX_HISTORY;i++) hrmRRHistory[i-1]=hrmRRHistory[i]; hrmRRHistory[HRM_MAX_HISTORY-1]=rr; }
}
float rollingAvgBPM() {
  int n=min(hrmRRCount,HRM_ROLLING_WINDOW); if(!n) return 0;
  float s=0; for(int i=hrmRRCount-n;i<hrmRRCount;i++) s+=60000.0/hrmRRHistory[i]; return s/n;
}
void computeHRV() {
  hrmSDNN=hrmRMSSD=hrmPNN50=0; hrmNN50=0;
  if(hrmRRCount<2) return;
  float mean=0; for(int i=0;i<hrmRRCount;i++) mean+=hrmRRHistory[i]; mean/=hrmRRCount;
  float sd=0; for(int i=0;i<hrmRRCount;i++) sd+=(hrmRRHistory[i]-mean)*(hrmRRHistory[i]-mean);
  hrmSDNN=sqrt(sd/(hrmRRCount-1));
  float rs=0; int nn=0,dc=0;
  for(int i=1;i<hrmRRCount;i++){float d=hrmRRHistory[i]-hrmRRHistory[i-1];rs+=d*d;if(fabs(d)>50)nn++;dc++;}
  hrmRMSSD=sqrt(rs/dc); hrmNN50=nn; hrmPNN50=dc>0?100.0*nn/dc:0;
}
float getAccuracy() {
  if(!hrmSessionActive) return 0;
  float p=((millis()-hrmSessionStart)/1000.0)/HRM_ACCURACY_RAMP_S*100.0;
  return p>100?100:p;
}
const char* getHeartRateZone(float b) {
  if (!hrmFingerContact || b<=0) return "No Input";
  if (b<60)  return "Resting";
  if (b<100) return "Normal";
  if (b<140) return "Elevated";
  return "High";
}
void resetHRMSession() {
  hrmBeatDetected=hrmSessionActive=hrmFingerContact=hrmBeatEvent=false;
  hrmLastBeat=hrmBeatCount=0; hrmBpm=hrmAvgBpm=hrmRR=hrmPulsePeriod=0;
  hrmMinBpm=999; hrmMaxBpm=hrmRRCount=hrmSDNN=hrmRMSSD=hrmPNN50=hrmNN50=0;
  hrmQualMin=4095; hrmQualMax=0; hrmQualWindowStart=millis();
  hrmSignalQuality="Checking..."; hrmBelowThreshold=false; hrmBelowThresholdSince=0;
  hrmBeatEvent=false; oledBeatFlash=0;
}

// ═══════════════════════════════════════════════════════════════════
//  WiFi HELPERS
// ═══════════════════════════════════════════════════════════════════
bool tryConnect(const char* ssid, const char* pass, int t) {
  Serial.print(F("WIFI_CONNECTING_SSID=")); Serial.println(ssid);
  display.clearDisplay(); display.setTextColor(SH110X_WHITE); display.setTextSize(1);
  display.setCursor(0,0); display.println("Connecting WiFi...");
  display.drawLine(0,9,127,9,SH110X_WHITE);
  display.setCursor(0,14); String s=String(ssid); if(s.length()>20)s=s.substring(0,17)+"...";
  display.println(s); display.setCursor(0,26); display.println("Please wait..."); flushDisplay();
  WiFi.mode(WIFI_STA); WiFi.begin(ssid,pass);
  for(int i=0;i<t*2;i++){
    if(WiFi.status()==WL_CONNECTED){
      isConnected=true; connectedSSID=WiFi.SSID(); ipAddress=WiFi.localIP().toString();
      Serial.print(F("WIFI_CONNECTED_SSID=")); Serial.println(connectedSSID);
      Serial.print(F("WIFI_IP=")); Serial.println(ipAddress);
      return true;
    }
    display.fillRect(0,38,128,10,SH110X_BLACK);display.setCursor(0,38);display.print("Timeout: ");display.print(t-(i/2));display.println("s");flushDisplay();delay(500);
  }
  Serial.print(F("WIFI_CONNECT_FAILED_STATUS=")); Serial.println((int)WiFi.status());
  WiFi.disconnect(); delay(300); return false;
}
bool tryKnownNetworks() {
  WiFi.mode(WIFI_STA); display.clearDisplay(); display.setTextColor(SH110X_WHITE); display.setTextSize(1);
  display.setCursor(0,0); display.println("Scanning WiFi..."); flushDisplay();
  int n=WiFi.scanNetworks();
  Serial.print(F("WIFI_SCAN_COUNT=")); Serial.println(n);
  bool foundKnown = false;
  for(int k=0;k<NUM_KNOWN;k++){
    for(int i=0;i<n;i++){
      if(WiFi.SSID(i)==knownNets[k].ssid){
        foundKnown = true;
        Serial.print(F("WIFI_FOUND_KNOWN_SSID=")); Serial.println(knownNets[k].ssid);
        if(tryConnect(knownNets[k].ssid,knownNets[k].pass,15)){ WiFi.scanDelete(); return true; }
      }
    }
  }
  WiFi.scanDelete();
  // Try configured SSIDs directly once even when scan results omit a hotspot
  // that has only just started advertising.
  if(!foundKnown){
    for(int k=0;k<NUM_KNOWN;k++){
      if(tryConnect(knownNets[k].ssid,knownNets[k].pass,15)) return true;
    }
  }
  return false;
}
bool connectWithSavedCredentials() {
  prefs.begin("stresstrack",true); String ssid=prefs.getString("ssid",""); String pass=prefs.getString("pass",""); prefs.end();
  if(ssid.isEmpty()) return false;
  // Do not waste another timeout retrying a known network already tried above.
  for(int k=0;k<NUM_KNOWN;k++) if(ssid==knownNets[k].ssid) return false;
  return tryConnect(ssid.c_str(),pass.c_str(),12);
}

// ═══════════════════════════════════════════════════════════════════
//  PROVISIONING
// ═══════════════════════════════════════════════════════════════════
void startProvisioningMode() {
  WiFi.mode(WIFI_AP); WiFi.softAP(AP_SSID,AP_PASS); delay(500);
  dnsServer.start(DNS_PORT,"*",WiFi.softAPIP());
  server.on("/",HTTP_GET,handleProvisionRoot); server.on("/scan",HTTP_GET,handleProvisionScan); server.on("/save",HTTP_POST,handleProvisionSave);
  server.onNotFound([](){server.sendHeader("Location","/");server.send(302);}); server.begin();
  display.clearDisplay(); display.setTextColor(SH110X_WHITE); display.setTextSize(1);
  display.setCursor(0,0); display.println("WiFi Setup Required"); display.drawLine(0,9,127,9,SH110X_WHITE);
  display.setCursor(0,12); display.println("1. Search WiFi:");
  display.setCursor(0,20); display.print("   "); display.println(AP_SSID);
  display.setCursor(0,28); display.println("2. Connect (no pass)");
  display.setCursor(0,36); display.print("3. Open: "); display.println(WiFi.softAPIP().toString());
  display.setCursor(0,44); display.println("   in browser &");
  display.setCursor(0,52); display.println("   enter WiFi details");
  flushDisplay();
}
void handleProvisionRoot(){
  server.send(200,"text/html",R"rawliteral(<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>StressTrack Setup</title><style>@import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@700&display=swap');*{box-sizing:border-box;margin:0;padding:0}body{background:#0b0e1a;color:#d8d9f7;font-family:'Share Tech Mono',monospace;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}.box{background:#11152a;border:1px solid rgba(155,144,251,.3);border-radius:12px;padding:28px 24px;width:100%;max-width:380px}h1{font-family:'Orbitron',sans-serif;font-size:1.1rem;color:#9b90fb;text-align:center;margin-bottom:4px;letter-spacing:2px}.sub{text-align:center;font-size:.75rem;color:rgba(205,201,245,.75);margin-bottom:22px}label{font-size:.78rem;color:rgba(216,213,250,.9);display:block;margin-bottom:5px;letter-spacing:1px}select,input{width:100%;background:#171c38;border:1px solid rgba(155,144,251,.3);border-radius:6px;padding:10px 12px;color:#f5f6ff;font-family:'Share Tech Mono',monospace;font-size:.88rem;margin-bottom:14px;outline:none}.btn-p{width:100%;background:linear-gradient(90deg,#6a5fd1,#9b90fb);border:none;border-radius:6px;padding:12px;color:#0b0e1a;font-family:'Orbitron',sans-serif;font-weight:700;font-size:.88rem;cursor:pointer;margin-top:4px}.btn-s{width:100%;background:transparent;border:1px solid rgba(155,144,251,.4);color:#b5acff;font-family:'Share Tech Mono',monospace;font-size:.82rem;padding:8px;margin-bottom:14px;border-radius:6px;cursor:pointer}.tab-bar{display:flex;margin-bottom:18px;border:1px solid rgba(155,144,251,.2);border-radius:6px;overflow:hidden}.tab{flex:1;padding:8px;text-align:center;font-size:.72rem;cursor:pointer;background:transparent;border:none;color:rgba(205,201,245,.7);font-family:'Share Tech Mono',monospace}.tab.active{background:rgba(155,144,251,.2);color:#b5acff}#pS,#pM{display:none}#pS.show,#pM.show{display:block}.note{font-size:.68rem;color:rgba(205,201,245,.55);text-align:center;margin-top:14px}</style></head><body><div class="box"><h1>&#9670; STRESSTRACK SETUP</h1><p class="sub">4-Sensor Suite &bull; WiFi Configuration</p><div class="tab-bar"><button class="tab active" onclick="st('s')">&#8635; SCAN</button><button class="tab" onclick="st('m')">&#9112; MANUAL</button></div><div id="pS" class="show"><form method="POST" action="/save"><label>DETECTED NETWORKS</label><select id="sel" name="ssid"><option>-- scanning... --</option></select><button type="button" class="btn-s" id="sb" onclick="doScan()">&#8635; REFRESH SCAN</button><label>PASSWORD</label><input type="password" name="pass" placeholder="WiFi password" autocomplete="off"><button type="submit" class="btn-p">CONNECT &amp; SAVE</button></form></div><div id="pM"><form method="POST" action="/save"><label>SSID</label><input type="text" name="ssid" placeholder="Exact SSID" autocomplete="off"><label>PASSWORD</label><input type="password" name="pass" placeholder="WiFi password" autocomplete="off"><button type="submit" class="btn-p">CONNECT &amp; SAVE</button></form></div><p class="note">Device restarts after saving</p></div><script>function st(t){document.getElementById('pS').classList.toggle('show',t==='s');document.getElementById('pM').classList.toggle('show',t==='m');document.querySelectorAll('.tab').forEach((el,i)=>el.classList.toggle('active',(t==='s'&&i===0)||(t==='m'&&i===1)));}function doScan(){const btn=document.getElementById('sb');btn.textContent='Scanning...';fetch('/scan').then(r=>r.json()).then(nets=>{const sel=document.getElementById('sel');sel.innerHTML='';if(!nets.length){sel.innerHTML='<option>No networks found</option>';return;}nets.forEach(n=>{const o=document.createElement('option');o.value=n.ssid;o.textContent=n.ssid+' ('+n.rssi+' dBm'+(n.enc?' 🔒':'')+')';sel.appendChild(o);});btn.textContent='↻ REFRESH';}).catch(()=>{btn.textContent='↻ REFRESH';});}window.onload=doScan;</script></body></html>)rawliteral");
}
void handleProvisionScan(){
  int n=WiFi.scanNetworks(); String j="[";
  for(int i=0;i<n;i++){if(i)j+=",";String s=WiFi.SSID(i);s.replace("\"","\\\"");j+="{\"ssid\":\""+s+"\",\"rssi\":"+WiFi.RSSI(i)+",\"enc\":"+(WiFi.encryptionType(i)!=WIFI_AUTH_OPEN?"true":"false")+"}";}
  server.send(200,"application/json",j+"]");
}
void handleProvisionSave(){
  String ssid=server.arg("ssid"),pass=server.arg("pass");
  prefs.begin("stresstrack",false);prefs.putString("ssid",ssid);prefs.putString("pass",pass);prefs.end();
  server.send(200,"text/html","<html><body style='background:#0b0e1a;color:#9b90fb;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;text-align:center'><div><h2>&#10003; SAVED</h2><p style='color:#ccc;margin-top:12px'>Restarting...<br>Open IP shown on OLED.</p></div></body></html>");
  delay(2000);ESP.restart();
}

// ═══════════════════════════════════════════════════════════════════
//  HISTORY BUFFER
// ═══════════════════════════════════════════════════════════════════
void pushToBuffer(){
  if(millis()-lastBufPush<BUF_INTERVAL) return; lastBufPush=millis();
  struct tm ti; char ts[9];
  if(getLocalTime(&ti)) strftime(ts,9,"%H:%M:%S",&ti); else strcpy(ts,"--:--:--");
  buf[bufIdx]={averagedValue10bit,ax,ay,az,gx,gy,gz,mpuTempC,bodyTempC,hrmBpm,hrmAvgBpm};
  strncpy(buf[bufIdx].time,ts,9); bufIdx=(bufIdx+1)%BUF_SZ; if(bufIdx==0)bufFilled=true;
}

// ═══════════════════════════════════════════════════════════════════
//  /data JSON
// ═══════════════════════════════════════════════════════════════════
void addDataCorsHeaders(){
  // The built-in dashboard is same-origin. These headers also let a browser-based
  // companion app on the same trusted LAN read the live JSON endpoint.
  // This is not authentication: do not expose the device API to an untrusted WAN.
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
  server.sendHeader("Cache-Control", "no-store");
}

void handleData(){
  addDataCorsHeaders();
  if(!isConnected){server.send(503,"application/json","{\"error\":\"offline\"}");return;}
  int gsrSnap, hrmRawSnap;
  float bpmSnap, bodyTempSnap;
  uint32_t gsrUs, hrmRawUs, bpmUs, bodyTempUs;
  taskENTER_CRITICAL(&sensorTelemetryMux);
  gsrSnap = telemetryGsr10bit; hrmRawSnap = telemetryHrmRaw12bit;
  bpmSnap = telemetryHrmBpm; bodyTempSnap = telemetryBodyTempC;
  gsrUs = telemetryGsrUpdatedUs; hrmRawUs = telemetryHrmRawUpdatedUs;
  bpmUs = telemetryHrmBpmUpdatedUs; bodyTempUs = telemetryBodyTempUpdatedUs;
  taskEXIT_CRITICAL(&sensorTelemetryMux);
  const uint32_t apiNowUs = micros();
  const long gsrAgeMs = gsrUs ? (long)((uint32_t)(apiNowUs-gsrUs)/1000U) : -1L;
  const long hrmRawAgeMs = hrmRawUs ? (long)((uint32_t)(apiNowUs-hrmRawUs)/1000U) : -1L;
  const long bpmAgeMs = bpmUs ? (long)((uint32_t)(apiNowUs-bpmUs)/1000U) : -1L;
  const long bodyTempAgeMs = bodyTempUs ? (long)((uint32_t)(apiNowUs-bodyTempUs)/1000U) : -1L;
  struct tm ti; char ds[11],ts[9];
  if(getLocalTime(&ti)){strftime(ds,11,"%Y-%m-%d",&ti);strftime(ts,9,"%H:%M:%S",&ti);}else{strcpy(ds,"N/A");strcpy(ts,"N/A");}
  String j="{\"current\":{";
  j+="\"gsr\":"+String(gsrSnap)+",\"gsr_age_ms\":"+String(gsrAgeMs)+",\"stress\":\""+stressLevel+"\"";
  j+=",\"hrm_raw_adc_12bit\":"+String(hrmRawSnap)+",\"hrm_raw_age_ms\":"+String(hrmRawAgeMs);
  j+=",\"hrm_bpm_age_ms\":"+String(bpmAgeMs)+",\"body_temp_age_ms\":"+String(bodyTempAgeMs);
  j+=",\"ax\":"+String(ax,2)+",\"ay\":"+String(ay,2)+",\"az\":"+String(az,2);
  j+=",\"gx\":"+String(gx,2)+",\"gy\":"+String(gy,2)+",\"gz\":"+String(gz,2);
  j+=",\"mpuTemp\":"+String(mpuTempC,1);
  j+=",\"tremor\":{\"status\":\""+String(tremorStatus)+"\"";
  j+=",\"frequency\":"+String(tremorFrequency,1)+",\"amplitude\":"+String(tremorAmplitude,3);
  j+=",\"active\":"+(tremorActive?String("true"):String("false"))+"}";
  j+=",\"ml\":{\"available\":"+(cnn_tflm_is_ready()?String("true"):String("false"));
  j+=",\"algorithm\":\"tflite_micro_cnn_int8\"";
  j+=",\"version\":\""+String(cnn_tflm_is_ready()?STRESSTRACK_CNN_MODEL_VERSION:"none")+"\"";
  j+=",\"input_channels\":"+String(cnn_tflm_channels());
  j+=",\"input_profile\":\""+String(cnn_tflm_channels()==6?"accel_xyz+gyro_xyz":(cnn_tflm_channels()==3?"accel_xyz":"none"))+"\"";
  j+=",\"class\":"+String(mlPredictedClass)+",\"label\":\""+String(mlClassName(mlPredictedClass))+"\"";
  j+=",\"score\":"+String(mlScore,4)+",\"inference_us\":"+String(mlLastInferenceUs);
  j+=",\"probabilities\":["+String(mlProbabilities[0],4)+","+String(mlProbabilities[1],4)+","+String(mlProbabilities[2],4)+","+String(mlProbabilities[3],4)+"]";
  const float measuredSampleHz = (mlAverageSampleIntervalUs > 0)
      ? (1000000.0f / (float)mlAverageSampleIntervalUs) : 0.0f;
  j+=",\"sample_hz\":"+String(measuredSampleHz,1);
  j+=",\"target_sample_hz\":50,\"sample_interval_us\":"+String(mlLastSampleIntervalUs);
  j+=",\"average_sample_interval_us\":"+String(mlAverageSampleIntervalUs);
  j+=",\"dropped_samples\":"+String(imuDroppedReadCount);
  j+=",\"missed_deadlines\":"+String(imuMissedDeadlineCount);
  j+=",\"successful_samples\":"+String(imuSuccessfulSampleCount)+"}";
  j+=",\"bodyTemp\":"+String(bodyTempSnap,1)+",\"bodyTempF\":"+String(toF(bodyTempSnap),1);
  j+=",\"hrm\":{\"bpm\":"+String(bpmSnap,1)+",\"avgBpm\":"+String(hrmAvgBpm,1);
  j+=",\"minBpm\":"+String(hrmMinBpm==999?0:hrmMinBpm,1)+",\"maxBpm\":"+String(hrmMaxBpm,1);
  j+=",\"zone\":\""+String(getHeartRateZone(hrmBpm))+"\"";
  j+=",\"quality\":\""+String(hrmSignalQuality)+"\",\"accuracy\":"+String(getAccuracy(),1);
  j+=",\"rr\":"+String(hrmRR,0)+",\"pulsePeriod\":"+String(hrmPulsePeriod,0);
  j+=",\"beatCount\":"+String(hrmBeatCount);
  j+=",\"fingerContact\":"+(hrmFingerContact?String("true"):String("false"));
  j+=",\"sessionActive\":"+(hrmSessionActive?String("true"):String("false"));
  j+=",\"sdnn\":"+String(hrmSDNN,1)+",\"rmssd\":"+String(hrmRMSSD,1);
  j+=",\"nn50\":"+String(hrmNN50)+",\"pnn50\":"+String(hrmPNN50,1)+"}";
  j+=",\"ssid\":\""+connectedSSID+"\",\"ip\":\""+ipAddress+"\"";
  j+=",\"date\":\""+String(ds)+"\",\"time\":\""+String(ts)+"\"}";
  // Flutter only renders the current sensor snapshot. Skip the 60-point
  // dashboard history for compact=1 to reduce Wi-Fi traffic and JSON work.
  // The default /data response retains history for the embedded dashboard.
  if(server.hasArg("compact") && server.arg("compact")=="1"){
    j+=",\"history\":[]";
  }else{
    j+=",\"history\":[";
    int count=bufFilled?BUF_SZ:bufIdx;
    for(int i=0;i<count;i++){
      int idx=bufFilled?(bufIdx+i)%BUF_SZ:i; if(i)j+=",";
      j+="{\"gsr\":"+String(buf[idx].gsr)+",\"ax\":"+String(buf[idx].ax,2)+",\"ay\":"+String(buf[idx].ay,2)+",\"az\":"+String(buf[idx].az,2)+",\"gx\":"+String(buf[idx].gx,2)+",\"gy\":"+String(buf[idx].gy,2)+",\"gz\":"+String(buf[idx].gz,2)+",\"mpuTemp\":"+String(buf[idx].mpuTemp,1)+",\"bodyTemp\":"+String(buf[idx].bodyTemp,1)+",\"bpm\":"+String(buf[idx].bpm,1)+",\"avgBpm\":"+String(buf[idx].avgBpm,1)+",\"time\":\""+String(buf[idx].time)+"\"}";
    }
    j+="]";
  }
  j+="}"; server.send(200,"application/json",j);
}

// ═══════════════════════════════════════════════════════════════════
//  MAIN DASHBOARD  /
// ═══════════════════════════════════════════════════════════════════
void handleRoot(){
  if(!isConnected) return;
  String html=R"rawliteral(<!DOCTYPE html>
<html lang="en" data-theme="dark"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>StressTrack &mdash; Live Monitor</title>
<link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700;900&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
[data-theme="dark"]{--bg:#0b0e1a;--card:#11152a;--pr:#9b90fb;--good:#6ee7a0;--warn:#fcd34d;--high:#fb923c;--vhigh:#f87171;--text:#f1f3ff;--tm:#bec1e8;--td:#8082b8;--bd:#2a3070;--bd2:#1a1f48;--hd:linear-gradient(90deg,#0a0d1e,#121838,#0a0d1e);--tk:#0b0e22;--sh:0 0 20px rgba(155,144,251,.45);--sl:rgba(0,0,0,.07)}
[data-theme="light"]{--bg:#faf3e8;--card:#fff;--pr:#9a4e18;--good:#16773f;--warn:#875200;--high:#8a3300;--vhigh:#821628;--text:#1a1208;--tm:#3d2f1a;--td:#5e4a2e;--bd:#ccb890;--bd2:#e8d8b4;--hd:linear-gradient(135deg,#f2e0c0,#fdf5e6,#f2e0c0);--tk:#f0e0c0;--sh:0 2px 16px rgba(154,78,24,.28);--sl:transparent}
*{box-sizing:border-box;margin:0;padding:0}
html,body{min-height:100%;background:var(--bg);color:var(--text);font-family:'Share Tech Mono',monospace;overflow-x:hidden;transition:background .35s,color .35s}
[data-theme="dark"] body::before{content:'';position:fixed;inset:0;z-index:1000;pointer-events:none;background:repeating-linear-gradient(0deg,transparent,transparent 2px,var(--sl) 2px,var(--sl) 4px)}
header{display:flex;align-items:center;justify-content:space-between;padding:14px 24px;border-bottom:2px solid var(--bd);background:var(--hd);position:relative;gap:12px;transition:background .35s}
[data-theme="dark"] header::after{content:'';position:absolute;bottom:-2px;left:0;right:0;height:2px;background:linear-gradient(90deg,transparent,var(--pr),transparent);animation:sweep 3s ease-in-out infinite}
@keyframes sweep{0%,100%{opacity:.25}50%{opacity:1}}
.logo-name{font-family:'Orbitron',sans-serif;font-size:1.35rem;font-weight:900;color:var(--pr);letter-spacing:2px;text-shadow:var(--sh);white-space:nowrap}
.logo-sub{font-size:.72rem;color:var(--tm);letter-spacing:1px;margin-top:3px;font-weight:600}
.dev-link{color:var(--pr);text-decoration:none;font-weight:700}.dev-link:hover{text-decoration:underline}
.live-badge{font-size:.78rem;color:var(--good);letter-spacing:2px;display:flex;align-items:center;gap:6px;font-weight:700}
.sdot{width:10px;height:10px;border-radius:50%;background:var(--good);box-shadow:0 0 10px var(--good);animation:pulse 2s ease-in-out infinite;flex-shrink:0}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.tbtn{background:none;border:2px solid var(--bd);border-radius:50px;width:58px;height:29px;cursor:pointer;display:flex;align-items:center;padding:3px;transition:.3s;flex-shrink:0}
.tbtn:hover{border-color:var(--pr);box-shadow:var(--sh)}
.tthumb{width:22px;height:22px;border-radius:50%;background:var(--pr);display:flex;align-items:center;justify-content:center;font-size:.9rem;transition:transform .35s cubic-bezier(.4,0,.2,1)}
[data-theme="dark"] .tthumb{transform:translateX(0)}[data-theme="light"] .tthumb{transform:translateX(28px)}
.ticker{padding:6px 24px;background:var(--tk);border-bottom:1px solid var(--bd);font-size:.74rem;color:var(--tm);white-space:nowrap;overflow:hidden;font-weight:600;transition:background .35s}
.ticker-inner{display:inline-block;animation:tickerMove 36s linear infinite}
@keyframes tickerMove{0%{transform:translateX(100vw)}100%{transform:translateX(-100%)}}
main{padding:20px 24px;display:grid;grid-template-columns:repeat(4,1fr);gap:14px}
.sec{font-family:'Orbitron',sans-serif;font-size:.78rem;letter-spacing:3px;color:var(--pr);text-transform:uppercase;display:flex;align-items:center;gap:8px;font-weight:700;margin:4px 0}
.sec::after{content:'';flex:1;height:1px;background:linear-gradient(90deg,var(--bd),transparent)}
.hint{font-size:.7rem;color:var(--td);margin-bottom:4px;font-style:italic}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px 15px;position:relative;overflow:hidden;cursor:pointer;transition:border-color .3s,box-shadow .3s,background .35s,opacity .3s}
.card:hover{border-color:var(--pr);box-shadow:var(--sh)}
.card.dim{opacity:.35}
.card.flash{animation:flashGlow .6s ease-out}
@keyframes flashGlow{0%{box-shadow:0 0 0 0 var(--ac,var(--pr))}50%{box-shadow:0 0 28px 6px var(--ac,var(--pr))}100%{box-shadow:none}}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,var(--ac,var(--pr)),transparent);opacity:.9}
.card-icon{font-size:1.6rem;position:absolute;top:12px;right:14px;opacity:.22;animation:iconFloat 4s ease-in-out infinite}
@keyframes iconFloat{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
.card-label{font-size:.7rem;letter-spacing:2px;color:var(--tm);text-transform:uppercase;margin-bottom:8px;font-weight:700}
.card-value{font-family:'Orbitron',sans-serif;font-size:2rem;font-weight:700;color:var(--ac,var(--pr));line-height:1;text-shadow:0 0 14px color-mix(in srgb,var(--ac,var(--pr)) 55%,transparent)}
[data-theme="light"] .card-value{text-shadow:none;filter:brightness(.65) saturate(1.3)}
[data-theme="light"] .card-icon{filter:brightness(.55) saturate(1.3)}
.card-unit{font-size:.76rem;color:var(--tm);margin-top:6px;font-weight:600}
.card-text{font-family:'Orbitron',sans-serif;font-size:1.2rem;font-weight:700;margin-top:8px;letter-spacing:1px;transition:color .3s}
.card-small{font-family:'Orbitron',sans-serif;font-size:1.1rem;font-weight:700;color:var(--ac,var(--pr));line-height:1.3;margin-top:6px}
[data-theme="light"] .card-small{filter:brightness(.65) saturate(1.3)}
.card-sub{font-size:.68rem;color:var(--td);margin-top:4px}
.bar-track{height:5px;background:var(--bd2);border-radius:3px;margin-top:12px;overflow:hidden}
.bar-fill{height:100%;border-radius:3px;background:linear-gradient(90deg,color-mix(in srgb,var(--ac,var(--pr)) 40%,transparent),var(--ac,var(--pr)));transition:width .9s cubic-bezier(.4,0,.2,1);position:relative}
.bar-fill::after{content:'';position:absolute;right:0;top:-3px;width:10px;height:11px;border-radius:50%;background:var(--ac,var(--pr));box-shadow:0 0 8px var(--ac,var(--pr))}
[data-theme="light"] .card-value{filter:brightness(.65) saturate(1.3)}
[data-theme="light"] .bar-fill{filter:brightness(.7) saturate(1.3)}
[data-theme="light"] .bar-fill::after{box-shadow:none}
.span2{grid-column:span 2}.span3{grid-column:span 3}.span4{grid-column:span 4}
.panel{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:18px;transition:background .35s;overflow:hidden}
.chart-wrap{position:relative;height:280px;margin-top:8px}
.wtable{width:100%;border-collapse:collapse}
.srow td{padding:8px 10px;font-size:.82rem;border-bottom:1px solid var(--bd2)}
.srow:last-child td{border-bottom:none}
.sk{color:var(--tm);font-size:.7rem;letter-spacing:1px;text-transform:uppercase;white-space:nowrap;width:120px;font-weight:700}
.sv{color:var(--text);font-weight:600;font-size:.88rem}
.hrv-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:12px}
.hrv-box{background:var(--bd2);border-radius:10px;padding:12px 14px;text-align:center}
.hrv-label{font-size:.66rem;color:var(--td);letter-spacing:2px;text-transform:uppercase;margin-bottom:5px;font-weight:700}
.hrv-val{font-family:'Orbitron',sans-serif;font-size:1.35rem;font-weight:700;color:var(--pr)}
[data-theme="light"] .hrv-val{filter:brightness(.65)}
.hrv-unit{font-size:.64rem;color:var(--td);margin-top:3px}
.btn-graphs{grid-column:span 4;display:flex;align-items:center;justify-content:center;gap:12px;background:linear-gradient(90deg,color-mix(in srgb,var(--pr) 25%,transparent),var(--pr),color-mix(in srgb,var(--pr) 25%,transparent));border:none;border-radius:10px;padding:15px;cursor:pointer;font-family:'Orbitron',sans-serif;font-size:.85rem;font-weight:700;color:#0b0e1a;letter-spacing:2px;text-decoration:none;transition:opacity .2s,transform .1s}
[data-theme="light"] .btn-graphs{color:#fff}
.btn-graphs:hover{opacity:.88;transform:translateY(-1px)}
/* glossary */
.ghead{display:flex;align-items:center;justify-content:space-between;cursor:pointer;user-select:none}
.ghead .garrow{font-size:.9rem;transition:transform .3s;color:var(--pr)}
.gcontent{display:none;margin-top:14px}
.gcontent.open{display:block}
.gentry{border-bottom:1px solid var(--bd2);padding:10px 0}
.gentry:last-child{border-bottom:none}
.gterm{font-family:'Orbitron',sans-serif;font-size:.8rem;color:var(--pr);font-weight:700;margin-bottom:5px;letter-spacing:1px}
.gdesc{font-size:.78rem;color:var(--tm);line-height:1.6}
.gdesc strong{color:var(--text)}
footer{text-align:center;padding:14px;font-size:.68rem;color:var(--td);letter-spacing:1px;border-top:1px solid var(--bd)}
@media(max-width:960px){main{grid-template-columns:repeat(2,1fr)}.span4,.btn-graphs{grid-column:span 2}.span2,.span3,.panel{grid-column:span 2}.hrv-grid{grid-template-columns:repeat(2,1fr)}}
@media(max-width:520px){main{grid-template-columns:1fr}.card,.panel,.btn-graphs,.span2,.span3,.span4{grid-column:span 1}.hrv-grid{grid-template-columns:repeat(2,1fr)}}
</style></head><body>
<header>
  <div><div class="logo-name">&#9670; STRESSTRACK</div>
  <div class="logo-sub">4-SENSOR SUITE &bull; BY <a href="https://sites.google.com/view/iitraushan" target="_blank" class="dev-link">DR. RAUSHAN SINGH</a></div></div>
  <div><div class="live-badge"><span class="sdot"></span>LIVE TELEMETRY</div></div>
  <button class="tbtn" onclick="toggleTheme()"><div class="tthumb" id="themeThumb">&#127769;</div></button>
</header>
<div class="ticker"><span class="ticker-inner">&#11835; STRESSTRACK &#11835; GSR &bull; MPU6050 &bull; HRM2511E &bull; DS18B20 &#11835; LIVE TELEMETRY &#11835; DR. RAUSHAN SINGH &#11835; XIAO ESP32C3 &#11835;</span></div>
<main>
<!-- GSR -->
<div class="sec span4">&#9670; GSR Sensor &mdash; Stress / Skin Conductance</div>
<div class="card span2" id="card-gsr" style="--ac:#8b66f7" onclick="toggleSeries('gsr')"><div class="card-icon">&#128167;</div><div class="card-label">GSR Value</div><div class="card-value" id="gsr">--</div><div class="card-unit">0&ndash;500 scale</div><div class="bar-track"><div class="bar-fill" id="gsrBar" style="--ac:#8b66f7"></div></div></div>
<div class="card span2" id="card-stress"><div class="card-label">Stress Level</div><div class="card-text" id="stress">--</div></div>
<!-- MPU6050 -->
<div class="sec span4">&#9670; MPU6050 &mdash; Accelerometer &amp; Gyroscope</div>
<div class="card" id="card-ax" style="--ac:#4f9dde" onclick="toggleSeries('ax')"><div class="card-icon">&#8596;</div><div class="card-label">Accel X</div><div class="card-value" id="ax">--</div><div class="card-unit">m/s&sup2;</div><div class="bar-track"><div class="bar-fill" id="axBar" style="--ac:#4f9dde"></div></div></div>
<div class="card" id="card-ay" style="--ac:#4f9dde" onclick="toggleSeries('ay')"><div class="card-icon">&#8597;</div><div class="card-label">Accel Y</div><div class="card-value" id="ay">--</div><div class="card-unit">m/s&sup2;</div><div class="bar-track"><div class="bar-fill" id="ayBar" style="--ac:#4f9dde"></div></div></div>
<div class="card" id="card-az" style="--ac:#4f9dde" onclick="toggleSeries('az')"><div class="card-icon">&#11014;</div><div class="card-label">Accel Z</div><div class="card-value" id="az">--</div><div class="card-unit">m/s&sup2;</div><div class="bar-track"><div class="bar-fill" id="azBar" style="--ac:#4f9dde"></div></div></div>
<div class="card" id="card-mpuTemp" style="--ac:#a78bfa" onclick="toggleSeries('mpuTemp')"><div class="card-icon">&#127777;</div><div class="card-label">MPU Die Temp</div><div class="card-value" id="mpuTemp">--</div><div class="card-unit">&deg;C</div><div class="bar-track"><div class="bar-fill" id="mpuTempBar" style="--ac:#a78bfa"></div></div></div>
<div class="card" id="card-gx" style="--ac:#f2a154" onclick="toggleSeries('gx')"><div class="card-icon">&#128260;</div><div class="card-label">Gyro X</div><div class="card-value" id="gx">--</div><div class="card-unit">rad/s</div><div class="bar-track"><div class="bar-fill" id="gxBar" style="--ac:#f2a154"></div></div></div>
<div class="card" id="card-gy" style="--ac:#f2a154" onclick="toggleSeries('gy')"><div class="card-icon">&#128257;</div><div class="card-label">Gyro Y</div><div class="card-value" id="gy">--</div><div class="card-unit">rad/s</div><div class="bar-track"><div class="bar-fill" id="gyBar" style="--ac:#f2a154"></div></div></div>
<div class="card" id="card-gz" style="--ac:#f2a154" onclick="toggleSeries('gz')"><div class="card-icon">&#127744;</div><div class="card-label">Gyro Z</div><div class="card-value" id="gz">--</div><div class="card-unit">rad/s</div><div class="bar-track"><div class="bar-fill" id="gzBar" style="--ac:#f2a154"></div></div></div>
<div class="card" style="visibility:hidden"></div>
<!-- TREMOR -->
<div class="sec span4">&#9889; Tremor Analysis (MPU6050 &mdash; 3&ndash;12 Hz Band)</div>
<div class="card span2" id="card-tremorStatus"><div class="card-label">Tremor Classifier</div><div class="card-text" id="tremorStatus">--</div><div class="card-sub">Top softmax output (not calibration-verified): <span id="tremorConfidence">not loaded</span></div><div class="card-sub" id="tremorProbabilities">Class outputs unavailable</div><div class="card-sub">Model: <span id="modelVersion">not loaded</span> · Inputs: <span id="modelInputs">--</span> · Inference: <span id="modelLatency">--</span></div><div class="card-sub">Legacy threshold status remains separate</div></div>
<div class="card" id="card-tremorFreq" style="--ac:#22d3ee"><div class="card-icon">&#128302;</div><div class="card-label">Frequency</div><div class="card-value" id="tremorFreq">--</div><div class="card-unit">Hz</div></div>
<div class="card" id="card-tremorAmp" style="--ac:#22d3ee"><div class="card-icon">&#128200;</div><div class="card-label">Amplitude</div><div class="card-value" id="tremorAmp">--</div><div class="card-unit">m/s&sup2; (HP filtered)</div></div>
<!-- HEART -->
<div class="sec span4">&#9829; Heart Rate Sensor &mdash; HRM2511E</div>
<div class="card span2" id="card-bpm" style="--ac:#ff6b8a" onclick="toggleSeries('bpm')"><div class="card-icon">&#10084;</div><div class="card-label">Current BPM</div><div class="card-value" id="bpm">--</div><div class="card-unit">beats / min</div><div class="bar-track"><div class="bar-fill" id="bpmBar" style="--ac:#ff6b8a"></div></div></div>
<div class="card" id="card-avgBpm" style="--ac:#f06292" onclick="toggleSeries('avgBpm')"><div class="card-icon">&#128200;</div><div class="card-label">Avg BPM (rolling)</div><div class="card-value" id="avgBpm">--</div><div class="card-unit">last 20 beats</div><div class="bar-track"><div class="bar-fill" id="avgBpmBar" style="--ac:#f06292"></div></div></div>
<div class="card" id="card-hrmZone"><div class="card-label">HR Zone</div><div class="card-text" id="hrmZone">--</div></div>
<div class="card" id="card-hrmQuality"><div class="card-label">Signal Quality</div><div class="card-text" id="hrmQuality" style="font-size:.95rem">--</div></div>
<div class="card" id="card-accuracy" style="--ac:#ec4899"><div class="card-icon">&#127919;</div><div class="card-label">Accuracy</div><div class="card-value" id="accuracy">--</div><div class="card-unit">% (ramps over 2 min)</div><div class="bar-track"><div class="bar-fill" id="accuracyBar" style="--ac:#ec4899"></div></div></div>
<div class="card" id="card-rr"><div class="card-label">RR Interval</div><div class="card-small" id="rr">-- ms</div></div>
<div class="card" id="card-beatCount"><div class="card-label">Beat Count</div><div class="card-small" id="beatCount">--</div></div>
<div class="card"><div class="card-label">Min / Max BPM</div><div class="card-small" id="minmax">-- / --</div></div>
<!-- HRV -->
<div class="panel span4">
  <div class="sec">&#9670; HRV Analysis (Time-Domain)</div>
  <div class="hint">Heart Rate Variability &mdash; accumulates more accurately after 60+ beats</div>
  <div class="hrv-grid">
    <div class="hrv-box"><div class="hrv-label">SDNN</div><div class="hrv-val" id="sdnn">--</div><div class="hrv-unit">ms</div></div>
    <div class="hrv-box"><div class="hrv-label">RMSSD</div><div class="hrv-val" id="rmssd">--</div><div class="hrv-unit">ms</div></div>
    <div class="hrv-box"><div class="hrv-label">NN50</div><div class="hrv-val" id="nn50">--</div><div class="hrv-unit">count</div></div>
    <div class="hrv-box"><div class="hrv-label">pNN50</div><div class="hrv-val" id="pnn50">--</div><div class="hrv-unit">%</div></div>
  </div>
</div>
<!-- DS18B20 -->
<div class="sec span4">&#9670; DS18B20 &mdash; Body Temperature</div>
<div class="card span2" id="card-bodyTemp" style="--ac:#f59e0b" onclick="toggleSeries('bodyTemp')"><div class="card-icon">&#127777;</div><div class="card-label">Body Temp &mdash; Celsius</div><div class="card-value" id="bodyTempC">--</div><div class="card-unit">&deg;C &nbsp;|&nbsp; Normal: 36.1&ndash;37.2 &deg;C</div><div class="bar-track"><div class="bar-fill" id="bodyTempBar" style="--ac:#f59e0b"></div></div></div>
<div class="card span2" id="card-bodyTempF" style="--ac:#fb923c"><div class="card-icon">&#9832;</div><div class="card-label">Body Temp &mdash; Fahrenheit</div><div class="card-value" id="bodyTempFval">--</div><div class="card-unit">&deg;F &nbsp;|&nbsp; Normal: 97&ndash;99 &deg;F &nbsp;&bull;&nbsp; Fever: &gt;100.4 &deg;F</div></div>
<!-- Combined chart -->
<div class="panel span4">
  <div class="sec">&#9670; Combined Live Graph</div>
  <div class="hint">Click any sensor card above to show / hide its line on this graph.</div>
  <div class="chart-wrap"><canvas id="combinedChart"></canvas></div>
</div>
<a href="/graphs" target="_blank" class="btn-graphs">&#9670; VIEW INDIVIDUAL SENSOR GRAPHS &#9670;</a>
<!-- System Info -->
<div class="panel span4">
  <div class="sec">&#9670; System Info</div>
  <table class="wtable"><tbody>
    <tr class="srow"><td class="sk">DEVICE</td><td class="sv">StressTrack 4-Sensor Suite v7</td></tr>
    <tr class="srow"><td class="sk">DEVELOPER</td><td class="sv"><a href="https://sites.google.com/view/iitraushan" target="_blank" class="dev-link">Dr. Raushan Singh</a></td></tr>
    <tr class="srow"><td class="sk">SENSORS</td><td class="sv">GSR &bull; MPU6050 &bull; HRM2511E &bull; DS18B20</td></tr>
    <tr class="srow"><td class="sk">NETWORK</td><td class="sv" id="sysSSID">--</td></tr>
    <tr class="srow"><td class="sk">IP ADDRESS</td><td class="sv" id="sysIP">--</td></tr>
    <tr class="srow"><td class="sk">LAST UPDATE</td><td class="sv" id="sysTime">--</td></tr>
    <tr class="srow"><td class="sk">SENSOR FRESHNESS</td><td class="sv" id="sensorFreshness">--</td></tr>
  </tbody></table>
</div>
<!-- Glossary -->
<div class="panel span4">
  <div class="ghead" onclick="toggleGlossary()">
    <div class="sec" style="margin:0;flex:1">&#128218; Reading Guide &amp; Glossary</div>
    <span class="garrow" id="garrow">&#9654;</span>
  </div>
  <div class="gcontent" id="gcontent">
    <div class="gentry"><div class="gterm">GSR &mdash; Galvanic Skin Response</div><div class="gdesc">Measures how much your skin conducts electricity, which rises when you sweat. <strong>Higher GSR = more emotional arousal / stress.</strong> Values 0–200 = None, 201–300 = Minor, 301–400 = High, 401–500 = Very High.</div></div>
    <div class="gentry"><div class="gterm">BPM &mdash; Beats Per Minute</div><div class="gdesc">How many times your heart beats each minute. <strong>Normal adult resting range: 60–100 BPM.</strong> Athletes may sit at 40–60. Above 100 at rest may indicate stress, fever, or dehydration. Calculated from peak intervals in the PPG waveform.</div></div>
    <div class="gentry"><div class="gterm">Avg BPM &mdash; Rolling Average</div><div class="gdesc">The mean of the last 20 detected heartbeats. <strong>More stable than instant BPM</strong> and tracks real trends rather than single-beat noise. Resets when the finger is removed.</div></div>
    <div class="gentry"><div class="gterm">HR Zone &mdash; Heart Rate Zone</div><div class="gdesc"><strong>Resting</strong> (&lt;60): very calm or athletic. <strong>Normal</strong> (60–99): healthy awake state. <strong>Elevated</strong> (100–139): light exertion, stress, or caffeine. <strong>High</strong> (&ge;140): vigorous exercise or arrhythmia — consult a doctor if sustained at rest.</div></div>
    <div class="gentry"><div class="gterm">Accuracy %</div><div class="gdesc">Ramps from 0% to 100% over 2 minutes of continuous finger contact. <strong>More beats = more stable HRV numbers.</strong> This reflects data accumulation, not validation against a clinical device.</div></div>
    <div class="gentry"><div class="gterm">RR Interval (ms)</div><div class="gdesc">The time in milliseconds between two consecutive heartbeats. At 60 BPM this is ~1000 ms. <strong>All HRV metrics are derived from the variability in these RR intervals.</strong></div></div>
    <div class="gentry"><div class="gterm">SDNN &mdash; Standard Deviation of NN Intervals</div><div class="gdesc">Overall variability of all RR intervals collected in the session. <strong>Higher SDNN = healthier autonomic nervous system.</strong> Normal resting: 50–100 ms. Below 20 ms may indicate autonomic dysfunction.</div></div>
    <div class="gentry"><div class="gterm">RMSSD &mdash; Root Mean Square of Successive Differences</div><div class="gdesc">Measures beat-to-beat variation, primarily reflecting <strong>parasympathetic (rest-and-digest) activity.</strong> Higher RMSSD = more relaxed. Lower RMSSD = stress, fatigue, or illness. Normal: 20–50 ms.</div></div>
    <div class="gentry"><div class="gterm">NN50 &amp; pNN50</div><div class="gdesc">NN50 counts how many consecutive RR intervals differ by more than 50 ms. pNN50 is that count as a percentage. <strong>Higher pNN50 = better cardiac vagal tone</strong> (relaxation/recovery). Normal young adults: 15–40%.</div></div>
    <div class="gentry"><div class="gterm">Tremor &mdash; Severity Classification</div><div class="gdesc">Detected from rhythmic 3–12 Hz oscillations in the accelerometer after gravity is filtered out. <strong>None</strong>: no significant oscillation. <strong>Mild</strong>: 0.15–0.5 m/s², possibly physiological. <strong>Moderate</strong>: 0.5–1.2 m/s², may be essential or drug-induced. <strong>Severe</strong>: &gt;1.2 m/s², warrants clinical attention. Not a diagnostic tool.</div></div>
    <div class="gentry"><div class="gterm">AX / AY / AZ &mdash; Accelerometer Axes</div><div class="gdesc">Linear acceleration in three axes (m/s²). At rest, <strong>AZ ≈ ±9.8 m/s²</strong> (gravity). AX and AY near zero. Large values in any axis indicate movement or impact. Used for tremor detection and fall analysis.</div></div>
    <div class="gentry"><div class="gterm">GX / GY / GZ &mdash; Gyroscope Axes</div><div class="gdesc">Angular rotation rate in radians per second. <strong>Near zero when stationary.</strong> Positive/negative reflects direction of rotation. Used together with accelerometer to compute motion intensity.</div></div>
    <div class="gentry"><div class="gterm">Body Temperature (DS18B20)</div><div class="gdesc">Contact temperature from a digital OneWire sensor. <strong>Normal human body temperature: 36.1–37.2 °C (97–99 °F).</strong> Sensor readings depend on placement — best accuracy at axilla or held against skin for 30+ seconds.</div></div>
    <div class="gentry"><div class="gterm">Signal Quality (HRM)</div><div class="gdesc">Assessed from the peak-to-peak swing of the PPG waveform over 5 seconds. <strong>Excellent</strong>: clear strong pulse (&gt;1500 raw swing). <strong>Good</strong>: readable (&gt;800). <strong>Weak</strong>: poor contact, motion, or ambient light interference.</div></div>
  </div>
</div>
</main>
<footer>StressTrack &copy; 2026 <a href="https://sites.google.com/view/iitraushan" target="_blank" class="dev-link">Dr. Raushan Singh</a> &bull; For research use only &bull; Not a medical device</footer>
<script>
function isDark(){return document.documentElement.getAttribute('data-theme')==='dark';}
function cssVar(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim();}
function toggleTheme(){const d=isDark();document.documentElement.setAttribute('data-theme',d?'light':'dark');document.getElementById('themeThumb').textContent=d?'\u2600\uFE0F':'\uD83C\uDF19';localStorage.setItem('st-theme',d?'light':'dark');refreshChartTheme();}
(function(){const s=localStorage.getItem('st-theme');if(s){document.documentElement.setAttribute('data-theme',s);document.getElementById('themeThumb').textContent=s==='light'?'\u2600\uFE0F':'\uD83C\uDF19';}})();
function toggleGlossary(){const c=document.getElementById('gcontent');const a=document.getElementById('garrow');const open=c.classList.toggle('open');a.textContent=open?'▾':'▸';a.style.transform=open?'rotate(0)':'';}

const zoneColors={"No Input":"var(--td)","Resting":"var(--td)","Normal":"var(--good)","Elevated":"var(--warn)","High":"var(--vhigh)"};
const stressColors={"No input":"var(--td)","None":"var(--good)","Minor":"var(--warn)","High":"var(--high)","V.High":"var(--vhigh)"};
const qualColors={"Checking...":"var(--td)","Weak":"var(--warn)","Good":"var(--good)","Excellent":"#22d3ee"};
const tremorColors={"Analyzing":"var(--td)","Paused":"var(--td)","None":"var(--good)","Mild":"var(--warn)","Moderate":"var(--high)","Severe":"var(--vhigh)"};

const chartCfg=[
  {key:'gsr',label:'GSR',color:'#8b66f7'},
  {key:'ax',label:'Accel X',color:'#4f9dde'},{key:'ay',label:'Accel Y',color:'#3f86c2'},{key:'az',label:'Accel Z',color:'#2f6ea8'},
  {key:'gx',label:'Gyro X',color:'#f2a154'},{key:'gy',label:'Gyro Y',color:'#e08c3a'},{key:'gz',label:'Gyro Z',color:'#c97520'},
  {key:'mpuTemp',label:'MPU Temp',color:'#a78bfa'},
  {key:'bpm',label:'BPM',color:'#ff6b8a'},{key:'avgBpm',label:'Avg BPM',color:'#f06292'},
  {key:'bodyTemp',label:'Body Temp',color:'#f59e0b'},
];
let visible={};chartCfg.forEach(c=>visible[c.key]=true);
let chart=null,lastHistory=[];
let prev={};chartCfg.forEach(c=>prev[c.key]=null);
let prevStress=null,prevZone=null,prevQual=null,prevTremor=null;
const thresh={gsr:1,ax:.3,ay:.3,az:.3,gx:.1,gy:.1,gz:.1,mpuTemp:.1,bpm:1,avgBpm:1,bodyTemp:.1};

function clamp(v,mx){return Math.max(0,Math.min(100,Math.abs(v)/mx*100));}
function set(id,val){const e=document.getElementById(id);if(e)e.textContent=val;}
function flashCard(id){const el=document.getElementById(id);if(!el)return;el.classList.remove('flash');void el.offsetWidth;el.classList.add('flash');}
function maybeFlash(key,val){if(prev[key]!==null&&Math.abs(val-prev[key])>=thresh[key])flashCard('card-'+key);prev[key]=val;}
function setBar(id,w){const e=document.getElementById(id);if(e)e.style.width=w+'%';}

function toggleSeries(key){
  visible[key]=!visible[key];
  const idx=chartCfg.findIndex(c=>c.key===key);
  if(chart&&idx>=0){chart.data.datasets[idx].hidden=!visible[key];chart.update();}
  const el=document.getElementById('card-'+key);if(el)el.classList.toggle('dim',!visible[key]);
}
function buildOrUpdateChart(history){
  lastHistory=history; const labels=history.map(h=>h.time);
  if(!chart){
    const ds=chartCfg.map(c=>({label:c.label,data:history.map(h=>h[c.key]),borderColor:c.color,backgroundColor:c.color+'22',tension:.3,pointRadius:0,borderWidth:2,hidden:!visible[c.key]}));
    chart=new Chart(document.getElementById('combinedChart').getContext('2d'),{type:'line',data:{labels,datasets:ds},options:{responsive:true,maintainAspectRatio:false,animation:{duration:250},plugins:{legend:{display:false}},scales:{x:{ticks:{color:cssVar('--tm'),maxTicksLimit:8},grid:{color:cssVar('--bd2')}},y:{ticks:{color:cssVar('--tm')},grid:{color:cssVar('--bd2')}}}}});
  }else{chart.data.labels=labels;chartCfg.forEach((c,i)=>{chart.data.datasets[i].data=history.map(h=>h[c.key]);});chart.update();}
}
function refreshChartTheme(){if(chart){chart.destroy();chart=null;}buildOrUpdateChart(lastHistory);}

function updateDashboard(){
  fetch('/data').then(r=>r.json()).then(d=>{
    if(d.error)return; const c=d.current;
    maybeFlash('gsr',c.gsr);set('gsr',c.gsr);setBar('gsrBar',clamp(c.gsr,500));
    if(prevStress!==c.stress)flashCard('card-stress');prevStress=c.stress;
    const sEl=document.getElementById('stress');if(sEl){sEl.textContent=c.stress;sEl.style.color=stressColors[c.stress]||'var(--pr)';}

    maybeFlash('ax',c.ax);set('ax',c.ax.toFixed(2));setBar('axBar',clamp(c.ax,20));
    maybeFlash('ay',c.ay);set('ay',c.ay.toFixed(2));setBar('ayBar',clamp(c.ay,20));
    maybeFlash('az',c.az);set('az',c.az.toFixed(2));setBar('azBar',clamp(c.az,20));
    maybeFlash('gx',c.gx);set('gx',c.gx.toFixed(2));setBar('gxBar',clamp(c.gx,5));
    maybeFlash('gy',c.gy);set('gy',c.gy.toFixed(2));setBar('gyBar',clamp(c.gy,5));
    maybeFlash('gz',c.gz);set('gz',c.gz.toFixed(2));setBar('gzBar',clamp(c.gz,5));
    maybeFlash('mpuTemp',c.mpuTemp);set('mpuTemp',c.mpuTemp.toFixed(1));setBar('mpuTempBar',Math.max(0,Math.min(100,(c.mpuTemp-15)/45*100)));

    // Tremor
    const tr=c.tremor; const ml=c.ml||{};
    const shownStatus=(ml.available && ml['class']>=0)?ml.label:('RULE: '+tr.status);
    if(prevTremor!==shownStatus)flashCard('card-tremorStatus');prevTremor=shownStatus;
    const tEl=document.getElementById('tremorStatus');
    if(tEl){tEl.textContent=shownStatus;tEl.style.color=tremorColors[tr.status]||'var(--pr)';}
    set('tremorConfidence',(ml.available && ml['class']>=0)?(ml.score*100).toFixed(1)+'%':'not loaded');
    set('modelVersion',(ml.available && ml.version)?ml.version:'not loaded');
    set('modelInputs',(ml.available && ml.input_profile)?ml.input_profile:'--');
    set('modelLatency',(ml.available && Number(ml.inference_us)>0)?(Number(ml.inference_us)/1000).toFixed(2)+' ms':'--');
    const mp=Array.isArray(ml.probabilities)?ml.probabilities:null;
    set('tremorProbabilities',(ml.available && ml['class']>=0 && mp && mp.length===4)?['No','Mild','Moderate','Severe'].map((n,i)=>n+' '+(Number(mp[i]||0)*100).toFixed(0)+'%').join(' · '):'Class outputs unavailable');
    set('tremorFreq',tr.status==='None'||tr.status==='Analyzing'?'--':tr.frequency.toFixed(1));
    set('tremorAmp',tr.status==='None'||tr.status==='Analyzing'?'--':tr.amplitude.toFixed(3));

    // Heart
    const h=c.hrm;
    maybeFlash('bpm',h.bpm);set('bpm',h.bpm>0?h.bpm.toFixed(0):'--');setBar('bpmBar',clamp(h.bpm,220));
    maybeFlash('avgBpm',h.avgBpm);set('avgBpm',h.avgBpm>0?h.avgBpm.toFixed(0):'--');setBar('avgBpmBar',clamp(h.avgBpm,220));
    const zone=h.zone;
    if(prevZone!==zone)flashCard('card-hrmZone');prevZone=zone;
    const zEl=document.getElementById('hrmZone');if(zEl){zEl.textContent=zone;zEl.style.color=zoneColors[zone]||'var(--pr)';}
    if(prevQual!==h.quality)flashCard('card-hrmQuality');prevQual=h.quality;
    const qEl=document.getElementById('hrmQuality');if(qEl){qEl.textContent=h.quality;qEl.style.color=qualColors[h.quality]||'var(--pr)';}
    set('accuracy',h.accuracy.toFixed(0));setBar('accuracyBar',h.accuracy);
    set('rr',h.rr>0?h.rr.toFixed(0)+' ms':'-- ms');
    set('beatCount',h.beatCount);
    set('minmax',(h.minBpm>0?h.minBpm.toFixed(0):'--')+' / '+(h.maxBpm>0?h.maxBpm.toFixed(0):'--'));
    set('sdnn',h.sdnn>0?h.sdnn.toFixed(1):'--');set('rmssd',h.rmssd>0?h.rmssd.toFixed(1):'--');
    set('nn50',h.nn50>0?h.nn50:'--');set('pnn50',h.pnn50>0?h.pnn50.toFixed(1):'--');

    // Body temp
    maybeFlash('bodyTemp',c.bodyTemp);
    set('bodyTempC',c.bodyTemp>0?c.bodyTemp.toFixed(1):'--');
    set('bodyTempF',c.bodyTempF>0?c.bodyTempF.toFixed(1)+' °F':'-- °F');
    setBar('bodyTempBar',Math.max(0,Math.min(100,(c.bodyTemp-30)/15*100)));

    set('sysSSID',c.ssid);set('sysIP',c.ip);set('sysTime',c.date+' '+c.time);
    const ageLabel=v=>Number.isFinite(Number(v))&&Number(v)>=0?Math.round(Number(v))+' ms':'not sampled';
    set('sensorFreshness','GSR '+ageLabel(c.gsr_age_ms)+' · HRM raw '+ageLabel(c.hrm_raw_age_ms)+' · beat '+ageLabel(c.hrm_bpm_age_ms)+' · DS18B20 '+ageLabel(c.body_temp_age_ms));
    buildOrUpdateChart(d.history);
  }).catch(()=>{});
}
setInterval(updateDashboard,1500);updateDashboard();
</script></body></html>)rawliteral";
  server.send(200,"text/html",html);
}

// ═══════════════════════════════════════════════════════════════════
//  /graphs
// ═══════════════════════════════════════════════════════════════════
void handleGraphs(){
  if(!isConnected) return;
  server.send(200,"text/html",R"rawliteral(<!DOCTYPE html><html lang="en" data-theme="dark"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>StressTrack Graphs</title><link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@700&family=Share+Tech+Mono&display=swap" rel="stylesheet"><script src="https://cdn.jsdelivr.net/npm/chart.js"></script><style>[data-theme="dark"]{--bg:#0b0e1a;--card:#11152a;--pr:#9b90fb;--text:#f1f3ff;--tm:#bec1e8;--bd:#2a3070;--hd:linear-gradient(90deg,#0a0d1e,#121838,#0a0d1e)}[data-theme="light"]{--bg:#faf3e8;--card:#fff;--pr:#9a4e18;--text:#1a1208;--tm:#3d2f1a;--bd:#ccb890;--hd:linear-gradient(135deg,#f2e0c0,#fdf5e6,#f2e0c0)}*{box-sizing:border-box;margin:0;padding:0}html,body{min-height:100%;background:var(--bg);color:var(--text);font-family:'Share Tech Mono',monospace;transition:background .35s,color .35s}header{display:flex;align-items:center;justify-content:space-between;padding:14px 24px;border-bottom:2px solid var(--bd);background:var(--hd);gap:12px}.logo{font-family:'Orbitron',sans-serif;font-size:1.15rem;color:var(--pr);font-weight:900;letter-spacing:2px}.back{color:var(--pr);text-decoration:none;font-size:.82rem;border:1px solid var(--bd);padding:8px 14px;border-radius:6px;font-weight:700}.tbtn{background:none;border:2px solid var(--bd);border-radius:50px;width:58px;height:29px;cursor:pointer;display:flex;align-items:center;padding:3px}.tthumb{width:22px;height:22px;border-radius:50%;background:var(--pr);display:flex;align-items:center;justify-content:center;font-size:.9rem;transition:transform .35s}[data-theme="dark"] .tthumb{transform:translateX(0)}[data-theme="light"] .tthumb{transform:translateX(28px)}.sec{font-family:'Orbitron',sans-serif;font-size:.8rem;letter-spacing:3px;color:var(--pr);margin:20px 24px 10px;font-weight:700;text-transform:uppercase}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;padding:0 24px 20px}.cbox{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px}.cbox h3{font-family:'Orbitron',sans-serif;font-size:.84rem;color:var(--pr);margin-bottom:10px}.mw{position:relative;height:180px}@media(max-width:700px){.grid{grid-template-columns:1fr}}</style></head><body><header><div class="logo">&#9670; STRESSTRACK GRAPHS</div><a href="/" class="back">&larr; DASHBOARD</a><button class="tbtn" onclick="toggleTheme()"><div class="tthumb" id="themeThumb">&#127769;</div></button></header><div class="sec">&#9670; GSR Sensor</div><div class="grid"><div class="cbox"><h3>GSR Value</h3><div class="mw"><canvas id="c_gsr"></canvas></div></div></div><div class="sec">&#9670; MPU6050</div><div class="grid"><div class="cbox"><h3>Accel X</h3><div class="mw"><canvas id="c_ax"></canvas></div></div><div class="cbox"><h3>Accel Y</h3><div class="mw"><canvas id="c_ay"></canvas></div></div><div class="cbox"><h3>Accel Z</h3><div class="mw"><canvas id="c_az"></canvas></div></div><div class="cbox"><h3>Gyro X</h3><div class="mw"><canvas id="c_gx"></canvas></div></div><div class="cbox"><h3>Gyro Y</h3><div class="mw"><canvas id="c_gy"></canvas></div></div><div class="cbox"><h3>Gyro Z</h3><div class="mw"><canvas id="c_gz"></canvas></div></div><div class="cbox"><h3>MPU Die Temp</h3><div class="mw"><canvas id="c_mpuTemp"></canvas></div></div></div><div class="sec">&#9829; Heart Rate (HRM2511E)</div><div class="grid"><div class="cbox"><h3>BPM Current</h3><div class="mw"><canvas id="c_bpm"></canvas></div></div><div class="cbox"><h3>BPM Rolling Avg</h3><div class="mw"><canvas id="c_avgBpm"></canvas></div></div></div><div class="sec">&#9670; DS18B20 Body Temperature</div><div class="grid"><div class="cbox"><h3>Body Temperature (&deg;C)</h3><div class="mw"><canvas id="c_bodyTemp"></canvas></div></div></div><script>function isDark(){return document.documentElement.getAttribute('data-theme')==='dark';}function cssVar(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim();}function toggleTheme(){const d=isDark();document.documentElement.setAttribute('data-theme',d?'light':'dark');document.getElementById('themeThumb').textContent=d?'\u2600\uFE0F':'\uD83C\uDF19';localStorage.setItem('st-theme',d?'light':'dark');}(function(){const s=localStorage.getItem('st-theme');if(s){document.documentElement.setAttribute('data-theme',s);document.getElementById('themeThumb').textContent=s==='light'?'\u2600\uFE0F':'\uD83C\uDF19';}})();const metrics=[{key:'gsr',id:'c_gsr',color:'#8b66f7'},{key:'ax',id:'c_ax',color:'#4f9dde'},{key:'ay',id:'c_ay',color:'#3f86c2'},{key:'az',id:'c_az',color:'#2f6ea8'},{key:'gx',id:'c_gx',color:'#f2a154'},{key:'gy',id:'c_gy',color:'#e08c3a'},{key:'gz',id:'c_gz',color:'#c97520'},{key:'mpuTemp',id:'c_mpuTemp',color:'#a78bfa'},{key:'bpm',id:'c_bpm',color:'#ff6b8a'},{key:'avgBpm',id:'c_avgBpm',color:'#f06292'},{key:'bodyTemp',id:'c_bodyTemp',color:'#f59e0b'}];let charts={};function buildAll(history){const labels=history.map(h=>h.time);metrics.forEach(m=>{const data=history.map(h=>h[m.key]);if(!charts[m.key]){charts[m.key]=new Chart(document.getElementById(m.id).getContext('2d'),{type:'line',data:{labels,datasets:[{data,borderColor:m.color,backgroundColor:m.color+'22',tension:.3,pointRadius:0,borderWidth:2,fill:true}]},options:{responsive:true,maintainAspectRatio:false,animation:{duration:250},plugins:{legend:{display:false}},scales:{x:{ticks:{color:cssVar('--tm'),maxTicksLimit:6}},y:{ticks:{color:cssVar('--tm')}}}}})}else{charts[m.key].data.labels=labels;charts[m.key].data.datasets[0].data=data;charts[m.key].update();}});}function poll(){fetch('/data').then(r=>r.json()).then(d=>{if(d.error)return;buildAll(d.history);}).catch(()=>{});}setInterval(poll,1500);poll();</script></body></html>)rawliteral");
}

// ═══════════════════════════════════════════════════════════════════
//  OLED SCREEN FUNCTIONS
// ═══════════════════════════════════════════════════════════════════

// Screen 0 — All sensors + IP address + temp in C and F
void drawCombinedScreen() {
  display.clearDisplay(); display.setTextSize(1); display.setTextColor(SH110X_WHITE);

  // Header with IP shown permanently alongside title
  display.setCursor(2,0); display.print("ALL SENSORS");
  // Show last two octets of IP to save space, or full IP if short enough
  if (ipAddress.length() > 0 && isConnected) {
    int lastDot = ipAddress.lastIndexOf('.');
    int prevDot = ipAddress.lastIndexOf('.', lastDot-1);
    String shortIP = ipAddress.substring(prevDot+1); // e.g. "1.100"
    display.setCursor(80, 0); display.print(shortIP);
  }
  display.drawLine(0,9,127,9,SH110X_WHITE);
  display.drawLine(64,9,64,47,SH110X_WHITE);

  display.setCursor(2,11);  display.print("GSR:"); display.print(averagedValue10bit);
  display.setCursor(68,11); display.print(stressLevel);

  display.setCursor(2,19);  display.print("AX:"); display.print(ax,1);
  display.setCursor(68,19); display.print("GX:"); display.print(gx,1);

  display.setCursor(2,27);  display.print("AY:"); display.print(ay,1);
  display.setCursor(68,27); display.print("GY:"); display.print(gy,1);

  display.setCursor(2,35);  display.print("AZ:"); display.print(az,1);
  display.setCursor(68,35); display.print("GZ:"); display.print(gz,1);

  display.drawLine(0,44,127,44,SH110X_WHITE);

  // Row 5: IP address in full
  display.setCursor(2,46);
  if (isConnected) {
    display.print("IP:"); display.print(ipAddress);
  } else {
    display.print("WiFi: disconnected");
  }

  // Row 6: HR + body temp both units
  display.setCursor(2,55);
  display.print("HR:"); display.print((int)hrmBpm);
  display.print(" ");
  display.print(bodyTempC,1); display.print("C/");
  display.print(bodyTempF,1); display.print("F");

  flushDisplay();
}

// Screen 1 — GSR gauge (unchanged)
void drawGsrScreen() {
  const int cx=64,cy=58,R=46;
  display.clearDisplay(); display.setTextSize(1); display.setTextColor(SH110X_WHITE);
  display.setCursor(2,0); display.print("GSR:"); display.print(averagedValue10bit);
  display.setCursor(70,0); display.print(stressLevel);
  display.drawLine(0,9,127,9,SH110X_WHITE);
  int px=cx+R,py=cy;
  for(int deg=4;deg<=180;deg+=4){float t=radians(deg);int x=cx+(int)(R*cos(t)),y=cy-(int)(R*sin(t));display.drawLine(px,py,x,y,SH110X_WHITE);px=x;py=y;}
  for(int k=0;k<=10;k++){float t=radians(180.0-k*18.0);bool maj=(k==0||k==4||k==6||k==8||k==10);int ri=maj?R-10:R-5;display.drawLine(cx+(int)(R*cos(t)),cy-(int)(R*sin(t)),cx+(int)(ri*cos(t)),cy-(int)(ri*sin(t)),SH110X_WHITE);}
  float ta=180.0-((float)averagedValue10bit/500.0)*180.0;
  needleAngle+=(ta-needleAngle)*0.15;
  float nt=radians(needleAngle); int nl=R-6,nx=cx+(int)(nl*cos(nt)),ny=cy-(int)(nl*sin(nt));
  display.drawLine(cx,cy,nx,ny,SH110X_WHITE); display.drawLine(cx+1,cy,nx+1,ny,SH110X_WHITE);
  display.drawLine(cx,cy+1,nx,ny+1,SH110X_WHITE); display.fillCircle(cx,cy,3,SH110X_WHITE);
  flushDisplay();
}

// Screen 2 — MPU sparklines
void pushSpark() {
  if(millis()-lastSparkPush<SPARK_INTERVAL) return; lastSparkPush=millis();
  sparkAX[sparkIdx]=ax;sparkAY[sparkIdx]=ay;sparkAZ[sparkIdx]=az;
  sparkGX[sparkIdx]=gx;sparkGY[sparkIdx]=gy;sparkGZ[sparkIdx]=gz;
  sparkIdx=(sparkIdx+1)%SPARK_N; if(sparkIdx==0)sparkFilled=true;
}
void drawSparkline(float* arr,int x,int y,int w,int h){
  int count=sparkFilled?SPARK_N:sparkIdx; display.drawRect(x,y,w,h,SH110X_WHITE);
  if(count<2) return;
  float mn=arr[0],mx=arr[0],mean=0;
  for(int i=0;i<count;i++){int idx=sparkFilled?(sparkIdx+i)%SPARK_N:i;if(arr[idx]<mn)mn=arr[idx];if(arr[idx]>mx)mx=arr[idx];}
  float range=mx-mn; if(range<0.5)range=0.5;
  int ppx=-1,ppy=-1;
  for(int i=0;i<count;i++){int idx=sparkFilled?(sparkIdx+i)%SPARK_N:i;int px=x+1+(int)((float)i/(SPARK_N-1)*(w-2));int py=y+h-2-(int)((arr[idx]-mn)/range*(h-3));if(ppx>=0)display.drawLine(ppx,ppy,px,py,SH110X_WHITE);ppx=px;ppy=py;}
}
void drawMpuGraphScreen(){
  pushSpark(); display.clearDisplay(); display.setTextSize(1); display.setTextColor(SH110X_WHITE);
  display.setCursor(12,0); display.println("MPU6050 - TRENDS");
  display.drawLine(0,9,127,9,SH110X_WHITE);
  const int W=60,H=15,rY[3]={12,30,48},cX[2]={2,66};
  drawSparkline(sparkAX,cX[0],rY[0],W,H); drawSparkline(sparkGX,cX[1],rY[0],W,H);
  drawSparkline(sparkAY,cX[0],rY[1],W,H); drawSparkline(sparkGY,cX[1],rY[1],W,H);
  drawSparkline(sparkAZ,cX[0],rY[2],W,H); drawSparkline(sparkGZ,cX[1],rY[2],W,H);
  flushDisplay();
}

// Screen 3 — Hospital ECG waveform
// Flat baseline when no finger; scrolling waveform when finger detected.
void drawHeartScreen(){
  display.clearDisplay(); display.setTextColor(SH110X_WHITE);

  // Beat flash
  bool beatOn=(oledBeatFlash>0); if(oledBeatFlash>0) oledBeatFlash--;

  // Header bar
  if(beatOn){ display.fillRect(0,0,128,10,SH110X_WHITE); display.setTextColor(SH110X_BLACK); }
  display.setTextSize(1);
  display.setCursor(2,1); display.print(beatOn?"v":"o");   // beat indicator
  if(hrmFingerContact && hrmBpm>0){
    display.setTextSize(2); display.setCursor(14,0);
    display.print((int)hrmBpm);
    display.setTextSize(1); display.setCursor(46,4); display.print("BPM");
  } else {
    display.setTextSize(1); display.setCursor(14,2);
    display.print(hrmFingerContact ? "Detecting..." : "No finger");
  }
  display.setTextColor(SH110X_WHITE);
  display.setCursor(70,1); display.print(getHeartRateZone(hrmBpm));
  display.setTextSize(1);

  display.drawLine(0,11,127,11,SH110X_WHITE);

  // Waveform area y=12..51 (40px)
  if(!hrmFingerContact){
    // Flat baseline — hospital monitor "no signal" line
    int midY=31;
    display.drawLine(4,midY,WAVE_W+3,midY,SH110X_WHITE);
    // Draw small "no signal" dashes
    for(int x=20;x<WAVE_W;x+=16) display.drawPixel(x+4,midY-4,SH110X_WHITE);
  } else {
    // Scrolling waveform
    int wMin=waveBuf[0],wMax=waveBuf[0];
    for(int i=1;i<WAVE_W;i++){if(waveBuf[i]<wMin)wMin=waveBuf[i];if(waveBuf[i]>wMax)wMax=waveBuf[i];}
    int wRange=wMax-wMin; if(wRange<200)wRange=200;
    for(int i=1;i<WAVE_W;i++){
      int y1=51-(int)((float)(waveBuf[i-1]-wMin)/wRange*37);
      int y2=51-(int)((float)(waveBuf[i]-wMin)/wRange*37);
      display.drawLine(i-1+4,constrain(y1,12,51),i+4,constrain(y2,12,51),SH110X_WHITE);
    }
  }

  display.drawLine(0,53,127,53,SH110X_WHITE);

  // Status bar
  display.setCursor(2,56);
  display.print("Q:");
  if(strcmp(hrmSignalQuality,"Excellent")==0) display.print("EXC");
  else if(strcmp(hrmSignalQuality,"Good")==0) display.print("GD");
  else if(strcmp(hrmSignalQuality,"Weak")==0) display.print("WK");
  else display.print("--");
  display.print(" A:"); display.print((int)getAccuracy()); display.print("%");
  display.print(" T:"); display.print(bodyTempF,0); display.print("F");
  display.print(" #"); display.print(hrmBeatCount);

  flushDisplay();
}

// Screen 4 — actual embedded ML result (or explicit not-yet-built status).
void drawMLScreen(){
  display.clearDisplay(); display.setTextColor(SH110X_WHITE); display.setTextSize(1);
  display.setCursor(4,0); display.println("TREMOR ML CLASSIFIER");
  display.drawLine(0,10,127,10,SH110X_WHITE);
#if STRESSTRACK_CNN_AVAILABLE
  if(!cnn_tflm_is_ready()){
    display.setCursor(2,18); display.println("CNN MODEL NOT READY");
    display.setCursor(2,31); display.println("Check TFLM + model");
  }else if(mlPredictedClass<0){
    display.setCursor(2,18); display.println("Collecting 128 samples");
    display.setCursor(2,31); display.println("50 Hz input / 2.56 sec");
  }else{
    display.setTextSize(2); display.setCursor(2,15); display.println(mlClassName(mlPredictedClass));
    display.setTextSize(1); display.setCursor(2,39); display.print("CNN score: "); display.print(mlScore*100.0f,1); display.println("%");
    display.setCursor(2,51); display.print("Inference: "); display.print(mlLastInferenceUs/1000.0f,2); display.println(" ms");
  }
#else
  display.setCursor(2,17); display.println("TFLM / CNN NOT FOUND");
  display.setCursor(2,30); display.println("Install TFLM runtime");
  display.setCursor(2,42); display.println("Copy tflite_model_data.h");
  display.setCursor(2,54); display.println("beside this sketch");
#endif
  flushDisplay();
}

// ── Physical button screen change (GPIO5) ───────────────────────
// Call this every loop. Button is INPUT_PULLUP: press = LOW.
// IMU is no longer used for screen switching — it is dedicated to
// tremor analysis only, so normal surgical movements are irrelevant.
void checkButton(){
  bool reading = digitalRead(BUTTON_PIN);
  if (reading == LOW && btnLastState == HIGH &&
      millis() - btnLastDebounce > BTN_DEBOUNCE) {
    btnLastDebounce = millis();
    currentScreen = (currentScreen + 1) % NUM_SCREENS;
#if !RAW_MULTISENSOR_SERIAL_LOG
    Serial.print("Button -> screen "); Serial.println(currentScreen);
#endif
    display.fillScreen(SH110X_WHITE); flushDisplay(); delay(40);
  }
  btnLastState = reading;
}

// ── Google Sheets logging ────────────────────────────────────────
void sendToSheets(){
  if (strlen(SHEETS_URL) == 0) return;
  if (!isConnected) return;
  static unsigned long lastSend = 0;
  if (millis() - lastSend < SHEETS_INTERVAL_MS) return;
  lastSend = millis();

  struct tm ti; char ds[11], ts[9];
  if (getLocalTime(&ti)){strftime(ds,11,"%Y-%m-%d",&ti);strftime(ts,9,"%H:%M:%S",&ti);}
  else{strcpy(ds,"N/A");strcpy(ts,"N/A");}

  String p="{";
  p+="\"date\":\""+String(ds)+"\"";
  p+=",\"time\":\""+String(ts)+"\"";
  p+=",\"gsr\":"+String(averagedValue10bit);
  p+=",\"stress\":\""+stressLevel+"\"";
  p+=",\"bpm\":"+String(hrmBpm,1);
  p+=",\"avgBpm\":"+String(hrmAvgBpm,1);
  p+=",\"minBpm\":"+String(hrmMinBpm==999?0:hrmMinBpm,1);
  p+=",\"maxBpm\":"+String(hrmMaxBpm,1);
  p+=",\"zone\":\""+String(getHeartRateZone(hrmBpm))+"\"";
  p+=",\"rr\":"+String(hrmRR,0);
  p+=",\"pulsePeriod\":"+String(hrmPulsePeriod,0);
  p+=",\"beatCount\":"+String(hrmBeatCount);
  p+=",\"sdnn\":"+String(hrmSDNN,1);
  p+=",\"rmssd\":"+String(hrmRMSSD,1);
  p+=",\"nn50\":"+String(hrmNN50);
  p+=",\"pnn50\":"+String(hrmPNN50,1);
  p+=",\"accuracy\":"+String(getAccuracy(),1);
  p+=",\"quality\":\""+String(hrmSignalQuality)+"\"";
  p+=",\"tremorStatus\":\""+String(tremorStatus)+"\"";
  p+=",\"tremorFreq\":"+String(tremorFrequency,1);
  p+=",\"tremorAmp\":"+String(tremorAmplitude,3);
  p+=",\"bodyTempC\":"+String(bodyTempC,1);
  p+=",\"bodyTempF\":"+String(bodyTempF,1);
  p+=",\"ax\":"+String(ax,2);
  p+=",\"ay\":"+String(ay,2);
  p+=",\"az\":"+String(az,2);
  p+=",\"gx\":"+String(gx,2);
  p+=",\"gy\":"+String(gy,2);
  p+=",\"gz\":"+String(gz,2);
  p+=",\"mpuTemp\":"+String(mpuTempC,1);
  p+=",\"mlClass\":"+String(mlPredictedClass);
  p+=",\"mlLabel\":\""+String(mlClassName(mlPredictedClass))+"\"";
  p+=",\"mlScore\":"+String(mlScore,4);
  p+=",\"mlInferenceUs\":"+String(mlLastInferenceUs);
  p+="}";

  HTTPClient http;
  http.begin(SHEETS_URL);
  http.addHeader("Content-Type","application/json");
  int code = http.POST(p);
#if !EDGE_BENCH_SERIAL_LOG && !RAW_IMU_SERIAL_LOG && !RAW_MULTISENSOR_SERIAL_LOG
  Serial.print("Sheets: HTTP "); Serial.println(code > 0 ? String(code) : http.errorToString(code));
#endif
  http.end();
}

// ═══════════════════════════════════════════════════════════════════
//  setup()
// ═══════════════════════════════════════════════════════════════════
void setup(){
#if RAW_MULTISENSOR_SERIAL_LOG
  Serial.begin(460800);
#else
  Serial.begin(115200);
#endif
  delay(1000);
  Serial.println(STRESSTRACK_CNN_AVAILABLE ? F("STRESSTRACK_CNN_RUNTIME=COMPILED") : F("STRESSTRACK_CNN_RUNTIME=MISSING"));
  const bool cnnReady = cnn_tflm_init();
  Serial.println(cnnReady ? F("STRESSTRACK_CNN_MODEL=READY") : F("STRESSTRACK_CNN_MODEL=NOT_READY"));
#if RAW_IMU_SERIAL_LOG
  Serial.println(F("IMU_RAW,seq,device_micros,ax_m_s2,ay_m_s2,az_m_s2,gx_rad_s,gy_rad_s,gz_rad_s"));
#endif
#if RAW_MULTISENSOR_SERIAL_LOG
  Serial.println(F("MULTI_RAW,seq,device_micros,ax_m_s2,ay_m_s2,az_m_s2,gx_rad_s,gy_rad_s,gz_rad_s,gsr_filtered_10bit,gsr_age_ms,hrm_raw_adc_12bit,hrm_raw_age_ms,hrm_bpm,hrm_bpm_age_ms,body_temp_c,body_temp_age_ms"));
#endif
  i2cMutex=xSemaphoreCreateMutex();
  Wire.begin(I2C_SDA,I2C_SCL);
  Wire.setClock(400000);
  analogReadResolution(12);
  pinMode(GSR_PIN,INPUT); pinMode(HRM_PIN,INPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);   // physical screen-change button

  if(!display.begin(OLED_ADDR,true)){Serial.println("OLED ERROR");while(1);}
  display.clearDisplay(); display.setTextColor(SH110X_WHITE);
  display.setTextSize(2); display.setCursor(8,2); display.println("StressTrack");
  display.setTextSize(1);
  display.setCursor(0,26); display.println("Developer:");
  display.setCursor(0,36); display.println("Dr. Raushan Singh");
  display.setCursor(0,50); display.println("4-Sensor Suite v50Hz");
  flushDisplay(); delay(2200);

  display.clearDisplay(); display.setCursor(0,0); display.println("Init MPU6050..."); flushDisplay();
  if(!mpu.begin()){display.setCursor(0,12);display.println("MPU6050 ERROR!");flushDisplay();while(1);}
  // Configure the MPU6050's filtered output rate to 50 Hz.
  // In DLPF mode the internal base rate is 1 kHz; divisor 19 -> 1000/(1+19)=50 Hz.
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  mpu.setSampleRateDivisor(19);
  display.setCursor(0,12); display.println("MPU6050: OK / 50Hz");

  display.setCursor(0,22); display.println("Init DS18B20..."); flushDisplay();
  ds18b20.begin(); ds18b20.setWaitForConversion(false);
  ds18b20.requestTemperatures(); lastTempRequest=millis(); tempRequestPending=true;
  display.setCursor(0,32); display.print("DS18B20: ");
  display.println(ds18b20.getDeviceCount()>0?"OK":"not found");
  display.setCursor(0,42); display.println("HRM2511E: A2/GPIO4");
  display.setCursor(0,52); display.println(cnn_tflm_is_ready()?"CNN model: loaded":"CNN: runtime/model missing");
  flushDisplay(); delay(1000);

  hrmQualWindowStart=millis();

  // Start local sensor acquisition before Wi-Fi. The classifier remains local
  // even when the network is unavailable; only the dashboard needs Wi-Fi.
  if(xTaskCreate(imuSamplingTask,"imu50hz",4096,nullptr,IMU_TASK_PRIORITY,nullptr)!=pdPASS){
    Serial.println(F("ERROR: could not start 50 Hz IMU task"));
    display.clearDisplay(); display.setCursor(0,0); display.println("IMU TASK ERROR"); flushDisplay();
    while(true) delay(1000);
  }

  display.clearDisplay(); display.setCursor(0,0); display.println("WiFi connecting..."); flushDisplay();
  // Prefer the explicitly configured iPhone hotspot so a stale Preferences
  // entry cannot delay the deployment connection by 12 seconds.
  bool ok=tryKnownNetworks();
  if(!ok){display.clearDisplay();display.setCursor(0,0);display.println("Trying saved WiFi...");flushDisplay();ok=connectWithSavedCredentials();}
  if(!ok){
    startProvisioningMode();
    while(true){
      dnsServer.processNextRequest(); server.handleClient();
      runMLIfReady();
      // Keep the Wi-Fi setup instructions visible. The previous code redrew
      // the CNN screen here every second, hiding the setup network and IP.
      delay(1);
    }
  }

  syncTime();
  server.on("/",       handleRoot);
  server.on("/data", HTTP_GET, handleData);
  server.on("/data", HTTP_OPTIONS, [](){
    addDataCorsHeaders();
    server.send(204, "text/plain", "");
  });
  // Alias for companion apps using a namespaced API path.
  server.on("/api/data", HTTP_GET, handleData);
  server.on("/api/data", HTTP_OPTIONS, [](){
    addDataCorsHeaders();
    server.send(204, "text/plain", "");
  });
  server.on("/graphs", handleGraphs);
  server.begin();
#if !RAW_MULTISENSOR_SERIAL_LOG
  Serial.println("Dashboard @ http://" + ipAddress);
#endif
  display.clearDisplay(); display.setTextSize(1); display.setTextColor(SH110X_WHITE);
  display.setCursor(0,0); display.println("System Ready!");
  display.drawLine(0,9,127,9,SH110X_WHITE);
  display.setCursor(0,14); display.print("IP: "); display.println(ipAddress);
  display.setCursor(0,26); display.println("Open IP in browser");
  display.setCursor(0,38); display.println("Button = next screen");
  display.setCursor(0,50); display.println("ML result on screen 4");
  flushDisplay(); delay(4000);  // 4 seconds so user can read the IP
}

// ═══════════════════════════════════════════════════════════════════
//  loop()
// ═══════════════════════════════════════════════════════════════════
void loop(){
  unsigned long now=millis();

  // Non-blocking Wi-Fi watchdog. Sensor sampling and local inference continue
  // while reconnecting; only dashboard/Sheets communication pauses offline.
  static unsigned long lastWifiRetry=0;
  if(isConnected && WiFi.status()!=WL_CONNECTED){
    isConnected=false; lastWifiRetry=now; WiFi.reconnect();
  }
  if(!isConnected && WiFi.status()==WL_CONNECTED){
    isConnected=true; connectedSSID=WiFi.SSID(); ipAddress=WiFi.localIP().toString(); syncTime(); server.begin();
  }else if(!isConnected && now-lastWifiRetry>=10000){
    lastWifiRetry=now; WiFi.reconnect();
  }
  if(isConnected) server.handleClient();

  // DS18B20 async
  if(tempRequestPending && now-lastTempRequest>=750){
    float t=ds18b20.getTempCByIndex(0);
    if(t!=DEVICE_DISCONNECTED_C){
      bodyTempC=t; bodyTempF=toF(t);
      taskENTER_CRITICAL(&sensorTelemetryMux);
      telemetryBodyTempC = t;
      telemetryBodyTempUpdatedUs = micros();
      taskEXIT_CRITICAL(&sensorTelemetryMux);
    }
    tempRequestPending=false;
  }
  if(!tempRequestPending && now-lastTempRequest>=TEMP_INTERVAL){
    ds18b20.requestTemperatures(); lastTempRequest=now; tempRequestPending=true;
  }

  // HRM2511E — every iteration
  hrmRawSignal=analogRead(HRM_PIN);
  taskENTER_CRITICAL(&sensorTelemetryMux);
  telemetryHrmRaw12bit = hrmRawSignal;
  telemetryHrmRawUpdatedUs = micros();
  taskEXIT_CRITICAL(&sensorTelemetryMux);
  int hrmSignal=hrmSmooth(hrmRawSignal);
  memmove(waveBuf,waveBuf+1,(WAVE_W-1)*sizeof(int16_t));
  waveBuf[WAVE_W-1]=(int16_t)hrmRawSignal;

  // Finger contact + debounce
  if(hrmSignal>HRM_FINGER_THRESHOLD){hrmFingerContact=true;hrmBelowThreshold=false;hrmBelowThresholdSince=0;}
  else{
    if(!hrmBelowThreshold){hrmBelowThreshold=true;hrmBelowThresholdSince=now;}
    else if(now-hrmBelowThresholdSince>=HRM_FINGER_LOST_MS){hrmFingerContact=false;if(hrmSessionActive)resetHRMSession();}
  }
  if(hrmFingerContact){
    if(hrmSignal<hrmQualMin)hrmQualMin=hrmSignal; if(hrmSignal>hrmQualMax)hrmQualMax=hrmSignal;
    if(now-hrmQualWindowStart>HRM_QUALITY_WINDOW_MS){
      int sw=hrmQualMax-hrmQualMin;
      hrmSignalQuality=sw>1500?"Excellent":sw>800?"Good":"Weak";
      hrmQualMin=4095;hrmQualMax=0;hrmQualWindowStart=now;
    }
    if(hrmSignal>HRM_BEAT_THRESHOLD && !hrmBeatDetected){
      hrmBeatDetected=true;
      if(!hrmSessionActive){hrmSessionActive=true;hrmSessionStart=now;}
      if(hrmLastBeat!=0){
        float rr=now-hrmLastBeat;
        if(rr>300&&rr<2000){
          hrmBpm=60000.0/rr; hrmPulsePeriod=hrmRR=rr;
          hrmBeatCount++; addRRInterval(rr); hrmAvgBpm=rollingAvgBPM();
          if(hrmBpm<hrmMinBpm)hrmMinBpm=hrmBpm; if(hrmBpm>hrmMaxBpm)hrmMaxBpm=hrmBpm;
          computeHRV(); hrmBeatEvent=true; oledBeatFlash=4;
        }
      }
      hrmLastBeat=now;
    }
    if(hrmSignal<(HRM_BEAT_THRESHOLD-HRM_BEAT_RESET_MARGIN))hrmBeatDetected=false;
  }

  taskENTER_CRITICAL(&sensorTelemetryMux);
  telemetryHrmBpm = hrmBpm;
  if (hrmBeatEvent) telemetryHrmBpmUpdatedUs = micros();
  taskEXIT_CRITICAL(&sensorTelemetryMux);
  hrmBeatEvent = false;

  // GSR non-blocking
  gsrAccum+=map(analogRead(GSR_PIN),0,4095,0,1023); gsrSampleCount++;
  if(gsrSampleCount>=10){
    rawAveraged10bit=gsrAccum/10; afterOffsetValue=rawAveraged10bit+calibrationOffset;
    constrainedValue=constrain(afterOffsetValue,0,1023); averagedValue10bit=constrainedValue;
    if(averagedValue10bit>500||averagedValue10bit<=10){averagedValue10bit=0;zeroCount++;if(zeroCount>=3)isUpdating=false;}
    else{zeroCount=0;isUpdating=true;}
    if(!isUpdating||averagedValue10bit<=10) stressLevel="No input";
    else if(averagedValue10bit<=200)stressLevel="None";
    else if(averagedValue10bit<=300)stressLevel="Minor";
    else if(averagedValue10bit<=400)stressLevel="High";
    else if(averagedValue10bit<=500)stressLevel="V.High";
    else stressLevel="No input";
    taskENTER_CRITICAL(&sensorTelemetryMux);
    telemetryGsr10bit = averagedValue10bit;
    telemetryGsrUpdatedUs = micros();
    taskEXIT_CRITICAL(&sensorTelemetryMux);
    gsrAccum=0;gsrSampleCount=0;
  }

  // The MPU6050 is sampled by imuSamplingTask at a nominal 50 Hz.
  runMLIfReady();

  pushToBuffer();
  sendToSheets();   // logs to Google Sheets if SHEETS_URL is set

  // Poll the physical screen button on every loop iteration; only the
  // expensive full-frame OLED refresh is rate-limited to protect the IMU bus.
  checkButton();
  if(now-lastOLEDUpdate>=OLED_INTERVAL){
    lastOLEDUpdate=now;
    pushSpark();      // dashboard trend buffer
    switch(currentScreen){
      case 0: drawCombinedScreen();  break;
      case 1: drawGsrScreen();       break;
      case 2: drawMpuGraphScreen();  break;
      case 3: drawHeartScreen();     break;
      case 4: drawMLScreen();        break;
    }
  }

#if !RAW_IMU_SERIAL_LOG && !EDGE_BENCH_SERIAL_LOG && !RAW_MULTISENSOR_SERIAL_LOG
  // Serial every 2s; disabled during high-rate serial capture/benchmark.
  static unsigned long lastSerial=0;
  if(now-lastSerial>=2000){
    lastSerial=now;
    Serial.println("================================================");
    Serial.print("RAW(12bit):"); Serial.print(analogRead(GSR_PIN));
    Serial.print(" AVG-RAW:"); Serial.print(rawAveraged10bit);
    Serial.print(" OFFSET:"); Serial.print(afterOffsetValue);
    Serial.print(" CONSTRAINED:"); Serial.println(constrainedValue);
    Serial.print("GSR:"); Serial.print(averagedValue10bit); Serial.print(" Stress:"); Serial.println(stressLevel);
    Serial.print("AX:"); Serial.print(ax,2); Serial.print(" AY:"); Serial.print(ay,2); Serial.print(" AZ:"); Serial.println(az,2);
    Serial.print("GX:"); Serial.print(gx,2); Serial.print(" GY:"); Serial.print(gy,2); Serial.print(" GZ:"); Serial.println(gz,2);
    Serial.print("Tremor:"); Serial.print(tremorStatus); Serial.print(" "); Serial.print(tremorFrequency,1); Serial.print("Hz amp:"); Serial.println(tremorAmplitude,3);
    Serial.print("HR:"); Serial.print(hrmBpm,0); Serial.print(" Avg:"); Serial.print(hrmAvgBpm,0); Serial.print(" Zone:"); Serial.println(getHeartRateZone(hrmBpm));
    Serial.print("SDNN:"); Serial.print(hrmSDNN,1); Serial.print(" RMSSD:"); Serial.print(hrmRMSSD,1); Serial.print(" pNN50:"); Serial.println(hrmPNN50,1);
    Serial.print("Body:"); Serial.print(bodyTempC,1); Serial.print("C / "); Serial.print(bodyTempF,1); Serial.println("F");
    Serial.print("Accuracy:"); Serial.print(getAccuracy(),0); Serial.print("% Q:"); Serial.println(hrmSignalQuality);
  }
#endif
  delay(1);
}
