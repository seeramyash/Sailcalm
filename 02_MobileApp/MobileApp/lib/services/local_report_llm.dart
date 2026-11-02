/// Local report summarizer fallback.
///
/// This version intentionally avoids a native C++ LLM plugin because the
/// flutter_llama Vulkan/CMake build currently fails on this Windows toolchain.
/// It compiles a deterministic summary from facts already produced by the app.
/// It does not download a model and does not claim to perform generative AI.
class LocalReportLlm {
  LocalReportLlm._();
  static final LocalReportLlm instance = LocalReportLlm._();

  static const modelUrl = '';
  static const modelFileName = '';
  static const approximateModelSize = 'no model download required';

  bool _busy = false;
  bool get isBusy => _busy;

  /// Returns true because the built-in rule-based summarizer needs no model.
  Future<bool> isDownloaded() async => true;

  /// Retained for compatibility with the existing ReportsPage API.
  Future<void> downloadModel({required void Function(double progress) onProgress}) async {
    onProgress(1.0);
  }

  /// Retained for compatibility. No model needs to be loaded.
  Future<void> loadModel() async {}

  Future<String> summarize(String sourceFacts) async {
    if (_busy) throw StateError('The local summarizer is already running.');
    _busy = true;
    try {
      final lines = sourceFacts
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      const wantedStarts = <String>[
        'Period:',
        'Self-reported daily symptom logs:',
        'Stored glove/model samples:',
        'Average self-reported symptom intensity',
        'Average self-reported symptom duration',
        'Average stored frequency',
        'Average stored amplitude',
        'Daily logs reporting medication taken:',
        'Clinician-recorded diagnosis status',
        'Other medical conditions',
        'Allergies entered by user',
        'Current treatments/care plan',
        'Active medications in the saved schedule:',
        'Recent self-reported symptom notes:',
      ];
      final selected = <String>[];
      for (final prefix in wantedStarts) {
        for (final line in lines) {
          if (line.toLowerCase().startsWith(prefix.toLowerCase())) {
            selected.add('• $line');
            break;
          }
        }
      }
      if (selected.isEmpty) {
        selected.add('No report facts were available to summarize. Add daily logs or save glove samples first.');
      }
      return [
        'SailmCalm local report summary',
        '(Rule-based summary; no generative AI model is running.)',
        '',
        ...selected,
        '',
        'Important: These notes reflect saved user-entered records and stored glove/model readings. They are not a diagnosis or proof of medication ingestion. Check the source records and consult a clinician for medical decisions.',
      ].join('\n');
    } finally {
      _busy = false;
    }
  }
}
