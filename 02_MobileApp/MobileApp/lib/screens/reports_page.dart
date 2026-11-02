import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/local_database.dart';
import '../services/local_report_llm.dart';

enum _ReportPeriod { week, month, year }

class ReportsPage extends StatefulWidget {
  final String uid;
  const ReportsPage({super.key, required this.uid});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  _ReportPeriod _period = _ReportPeriod.week;
  bool _loading = true;
  bool _exporting = false;
  bool _summarizing = false;
  double _downloadProgress = 0;
  bool _modelDownloaded = false;
  String? _error;
  String? _summary;
  final TextEditingController _chatController = TextEditingController();
  final List<_ReportChatMessage> _chatMessages = [];
  List<Map<String, Object?>> _allLogs = [];
  List<Map<String, Object?>> _allEpisodes = [];
  List<Map<String, Object?>> _medications = [];
  Map<String, Object?>? _profile;

  DateTime get _start {
    final now = DateTime.now();
    switch (_period) {
      case _ReportPeriod.week:
        final today = DateTime(now.year, now.month, now.day);
        return today.subtract(Duration(days: today.weekday - DateTime.monday));
      case _ReportPeriod.month:
        return DateTime(now.year, now.month, 1);
      case _ReportPeriod.year:
        return DateTime(now.year, 1, 1);
    }
  }

  String get _periodName => switch (_period) {
    _ReportPeriod.week => 'Weekly',
    _ReportPeriod.month => 'Monthly',
    _ReportPeriod.year => 'Yearly',
  };

  String get _rangeLabel =>
      '${_dateLabel(_start)} – ${_dateLabel(DateTime.now())}';

  List<Map<String, Object?>> get _logs => _allLogs.where((row) {
    final date = DateTime.tryParse((row['log_date'] as String?) ?? '');
    return date != null &&
        !date.isBefore(_start) &&
        !date.isAfter(DateTime.now());
  }).toList();

  List<Map<String, Object?>> get _episodes => _allEpisodes.where((row) {
    final date = DateTime.tryParse((row['recorded_at'] as String?) ?? '');
    return date != null &&
        !date.isBefore(_start) &&
        !date.isAfter(DateTime.now());
  }).toList();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.uid.isEmpty)
        throw StateError('Sign in to view private reports.');
      final results = await Future.wait([
        LocalDatabase.instance.getDailyLogs(widget.uid, limit: 5000),
        LocalDatabase.instance.getEpisodes(widget.uid, limit: 50000),
        LocalDatabase.instance.getMedications(widget.uid),
        LocalDatabase.instance.getProfile(widget.uid),
        LocalReportLlm.instance.isDownloaded(),
      ]);
      if (!mounted) return;
      setState(() {
        _allLogs = List<Map<String, Object?>>.from(results[0] as List);
        _allEpisodes = List<Map<String, Object?>>.from(results[1] as List);
        _medications = List<Map<String, Object?>>.from(results[2] as List);
        _profile = results[3] as Map<String, Object?>?;
        _modelDownloaded = results[4] as bool;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  void _sendReportQuestion() {
    final question = _chatController.text.trim();
    if (question.isEmpty || _summary == null) return;
    final answer = _answerReportQuestion(question);
    setState(() {
      _chatMessages.add(_ReportChatMessage(isUser: true, text: question));
      _chatMessages.add(_ReportChatMessage(isUser: false, text: answer));
      if (_chatMessages.length > 20) {
        _chatMessages.removeRange(0, _chatMessages.length - 20);
      }
      _chatController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  String _answerReportQuestion(String rawQuestion) {
    final q = rawQuestion.toLowerCase();
    final profile = _profile ?? const <String, Object?>{};
    final metrics = _summaryMetrics();

    final emergencyTerms = [
      'cannot breathe',
      'can\'t breathe',
      'difficulty breathing',
      'shortness of breath',
      'chest pain',
      'stroke',
      'face drooping',
      'sudden weakness',
      'overdose',
      'unconscious',
      'suicid',
      'severe bleeding',
      'seizure',
    ];
    if (emergencyTerms.any(q.contains)) {
      return 'This chat cannot assess emergencies. Contact your local emergency service immediately or ask someone nearby for urgent help. Do not wait for an app response.';
    }

    final relevantTerms = [
      'health',
      'medical',
      'doctor',
      'clinician',
      'report',
      'summary',
      'symptom',
      'tremor',
      'shak',
      'parkinson',
      'frequency',
      'amplitude',
      'severity',
      'severe',
      'moderate',
      'mild',
      'status',
      'class',
      'model',
      'reading',
      'medication',
      'medicine',
      'dose',
      'pill',
      'prescription',
      'allerg',
      'diagnos',
      'condition',
      'intensity',
      'duration',
      'trigger',
      'episode',
      'sample',
      'glove',
      'exercise',
      'breath',
      'care',
      'treatment',
      'side effect',
      'interaction',
      'profile',
      'log',
      'pain',
      'worse',
      'better',
      'improve',
      'change',
      'my data',
    ];
    if (!relevantTerms.any(q.contains)) {
      return 'I can answer only questions about this SailmCalm report, your saved health profile, symptom logs, glove readings, medication schedule, and care features. Try asking “What does the frequency value mean?” or “Which medication entries are saved?”.';
    }

    final medicationQuestion = [
      'medication',
      'medicine',
      'prescription',
      'dose',
      'pill',
      'side effect',
      'interaction',
    ].any(q.contains);
    if (medicationQuestion) {
      final dosingAdvice = [
        'should i take',
        'how much',
        'increase',
        'decrease',
        'stop taking',
        'skip dose',
        'extra dose',
        'change dose',
        'mix with',
        'interaction',
        'side effect',
        'safe to take',
        'which medicine should',
      ].any(q.contains);
      final schedule = _medications
          .map((m) {
            final name = (m['name'] as String?)?.trim() ?? 'Unnamed entry';
            final instructions =
                (m['prescribed_instructions'] as String?)?.trim() ?? '';
            final rawTimes = (m['times_json'] as String?) ?? '[]';
            var times = <String>[];
            try {
              final decoded = jsonDecode(rawTimes);
              if (decoded is List) times = decoded.whereType<String>().toList();
            } catch (_) {}
            return '• $name — ${instructions.isEmpty ? 'No instructions saved' : instructions}; times: ${times.isEmpty ? 'not entered' : times.join(', ')}.';
          })
          .join('\n');
      if (dosingAdvice) {
        return 'I cannot recommend starting, stopping, skipping, changing a dose, or combining medicines. Follow the instructions on your current prescription and ask your prescribing clinician or pharmacist about dosing, side effects, or interactions.\n\nSaved schedule for reference only:\n${schedule.isEmpty ? 'No medication entries are saved.' : schedule}';
      }
      return 'These are the medication details saved by you; this is not verification that a dose was taken and not dosing advice.\n\n${schedule.isEmpty ? 'No medication entries are saved yet.' : schedule}';
    }

    if (q.contains('allerg')) {
      final allergies = (profile['allergies'] as String?)?.trim();
      return allergies == null || allergies.isEmpty
          ? 'No allergy details are saved in this profile. That does not mean the person has no allergies.'
          : 'Saved allergy field (user-entered): $allergies\nCheck it against the source record and confirm it with a clinician when needed.';
    }

    if (q.contains('diagnos') ||
        q.contains('condition') ||
        q.contains('parkinson')) {
      final diagnosis =
          (profile['diagnosis_status'] as String?)?.trim() ?? 'not entered';
      final conditions =
          (profile['medical_conditions'] as String?)?.trim() ?? '';
      return 'The profile records this diagnosis status: $diagnosis. ${conditions.isEmpty ? 'No other medical conditions are entered.' : 'Other conditions entered: $conditions.'} This is information saved by the user, not a diagnosis verified by SailmCalm. The app cannot confirm Parkinson’s disease or determine the cause of a tremor.';
    }

    if (q.contains('frequency') || q.contains('hz')) {
      return 'Average stored frequency for the selected ${_periodName.toLowerCase()} period: ${_num(metrics['average_recorded_frequency_hz'] as double?)} Hz, from ${metrics['glove_samples']} stored sample(s). Hz means cycles per second. This is the device-reported/stored value; by itself it does not establish a diagnosis or clinical severity.';
    }
    if (q.contains('amplitude')) {
      return 'Average stored amplitude for the selected ${_periodName.toLowerCase()} period: ${_num(metrics['average_recorded_amplitude'] as double?, decimals: 3)}, from ${metrics['glove_samples']} stored sample(s). The amplitude uses firmware-reported units, so do not treat it as a clinical severity score.';
    }
    if (q.contains('severity') ||
        q.contains('prediction') ||
        q.contains('confidence') ||
        q.contains('severe') ||
        q.contains('moderate') ||
        q.contains('status') ||
        q.contains('class') ||
        q.contains('model')) {
      return 'The Random Forest output is experimental and trained to reproduce status labels recorded in the glove workbook. It has not been validated as an independent clinical tremor-severity measure. Review the device-reported status and source records separately; ask a clinician about changes in symptoms.';
    }
    if (q.contains('worse') ||
        q.contains('better') ||
        q.contains('improve') ||
        q.contains('trend') ||
        q.contains('change')) {
      return 'This report summarizes only the selected period: ${_rangeLabel}. It cannot establish a medical trend or explain a cause by itself. Switch between weekly, monthly, and yearly reports to review saved records across periods, and discuss meaningful changes with your clinician.';
    }
    if (q.contains('exercise') || q.contains('breath') || q.contains('care')) {
      return 'Open the Care tab for optional gentle activities such as paced breathing, hand opening, shoulder release, and grounding. Stop if an activity causes pain, dizziness, fatigue, or worse symptoms, and follow any individualized advice from your clinician.';
    }
    if (q.contains('tremor') || q.contains('shak')) {
      return 'A tremor is an involuntary rhythmic shaking movement; causes can vary. SailmCalm records self-reported symptoms and device readings but cannot determine the cause of a tremor. A clinician can assess new, persistent, or worsening symptoms.';
    }
    if (q.contains('symptom') ||
        q.contains('intensity') ||
        q.contains('duration') ||
        q.contains('trigger') ||
        q.contains('log') ||
        q.contains('report') ||
        q.contains('summary') ||
        q.contains('my data') ||
        q.contains('how many')) {
      return 'Selected period: $_periodName ($_rangeLabel). Daily symptom logs: ${metrics['daily_logs']}. Stored glove/model samples: ${metrics['glove_samples']}. Average self-reported symptom intensity: ${_num(metrics['average_self_reported_intensity_0_10'])}/10. Average self-reported duration: ${_num(metrics['average_self_reported_duration_minutes'])} minutes. These are saved records, not necessarily clinical episodes.';
    }
    if (q.contains('pain')) {
      return 'This app cannot assess the cause of pain. Stop any activity that worsens symptoms and seek clinical advice for persistent or concerning pain; seek urgent local help if symptoms appear life-threatening.';
    }
    return 'I can explain the saved report values and repeat information you entered in the health profile, but I cannot diagnose conditions or recommend treatment. Try asking about the report period, symptom logs, frequency, amplitude, allergies, saved medication times, or the Care tab.';
  }

  Widget _reportChatSection() {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.health_and_safety_outlined, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ask about this report',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Limited offline Q&A. It answers using saved records and a few safety-focused rules; it is not a generative LLM or a clinician.',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            if (_chatMessages.isEmpty)
              Text(
                'Try: “What does frequency mean?”, “What medications are saved?”, or “What was my average symptom intensity?”.',
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
              ),
            if (_chatMessages.isNotEmpty) ...[
              for (final message in _chatMessages) ...[
                Align(
                  alignment: message.isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 560),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: message.isUser
                          ? colors.primaryContainer
                          : colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      message.text,
                      style: TextStyle(
                        color: message.isUser
                            ? colors.onPrimaryContainer
                            : colors.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _chatController,
              minLines: 1,
              maxLines: 3,
              maxLength: 500,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendReportQuestion(),
              decoration: InputDecoration(
                hintText: 'Ask a report or health-record question',
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                suffixIcon: IconButton(
                  tooltip: 'Send question',
                  onPressed: _sendReportQuestion,
                  icon: const Icon(Icons.send_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _dateLabel(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

  double? _mean(Iterable<num?> values) {
    final numbers = values
        .whereType<num>()
        .where((value) => value.isFinite)
        .toList();
    if (numbers.isEmpty) return null;
    return numbers.reduce((a, b) => a + b) / numbers.length;
  }

  int _countMedication(bool wanted) =>
      _logs.where((log) => log['medication_taken'] == (wanted ? 1 : 0)).length;

  String _num(double? value, {int decimals = 1}) =>
      value == null ? '—' : value.toStringAsFixed(decimals);

  Map<String, dynamic> _summaryMetrics() {
    final avgIntensity = _mean(
      _logs.map((row) => row['perceived_intensity'] as num?),
    );
    final avgDuration = _mean(
      _logs.map((row) => row['duration_minutes'] as num?),
    );
    final avgFrequency = _mean(
      _episodes.map((row) => row['frequency_hz'] as num?),
    );
    final avgAmplitude = _mean(
      _episodes.map((row) => row['amplitude'] as num?),
    );
    return {
      'period': _periodName,
      'range': _rangeLabel,
      'daily_logs': _logs.length,
      'glove_samples': _episodes.length,
      'average_self_reported_intensity_0_10': avgIntensity,
      'average_self_reported_duration_minutes': avgDuration,
      'average_recorded_frequency_hz': avgFrequency,
      'average_recorded_amplitude': avgAmplitude,
      'medication_reported_yes': _countMedication(true),
      'medication_reported_no': _countMedication(false),
    };
  }

  String _factsForLlm() {
    final metrics = _summaryMetrics();
    final p = _profile ?? const <String, Object?>{};
    final lines = <String>[
      'Period: ${metrics['period']} (${metrics['range']}).',
      'Self-reported daily symptom logs: ${metrics['daily_logs']}.',
      'Stored glove/model samples: ${metrics['glove_samples']}. These are available stored samples, not necessarily clinical episodes.',
      'Average self-reported symptom intensity on the 0–10 scale: ${_num(metrics['average_self_reported_intensity_0_10'] as double?)}.',
      'Average self-reported symptom duration in minutes: ${_num(metrics['average_self_reported_duration_minutes'] as double?)}.',
      'Average stored frequency (Hz): ${_num(metrics['average_recorded_frequency_hz'] as double?)}.',
      'Average stored amplitude: ${_num(metrics['average_recorded_amplitude'] as double?, decimals: 3)}.',
      'Daily logs reporting medication taken: ${metrics['medication_reported_yes']}; reporting not taken: ${metrics['medication_reported_no']}. These are self-reported log fields, not proof of ingestion.',
      'Clinician-recorded diagnosis status entered by user: ${p['diagnosis_status'] ?? 'not entered'}.',
      'Other medical conditions entered by user: ${p['medical_conditions'] ?? 'not entered'}.',
      'Allergies entered by user: ${p['allergies'] ?? 'not entered'}.',
      'Clinician notes entered by user: ${p['clinician_notes'] ?? 'not entered'}.',
      'Current treatments/care plan entered by user: ${p['current_treatments'] ?? 'not entered'}.',
      'Active medications in the saved schedule: ${_medications.map((m) => '${m['name']} (user-entered times: ${m['times_json'] ?? 'not entered'}; instructions: ${m['prescribed_instructions'] ?? 'not entered'})').join('; ')}.',
      'Recent self-reported symptom notes: ${_logs.take(8).map((l) => '${l['log_date']}: intensity ${l['perceived_intensity'] ?? 'not entered'}/10; activity ${l['activity'] ?? 'not entered'}; trigger ${l['possible_trigger'] ?? 'not entered'}; notes ${l['notes'] ?? 'none'}').join(' | ')}',
    ];
    return lines.join('\n');
  }

  Future<void> _createSummary() async {
    if (!_modelDownloaded) {
      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Set up offline report summarizer?'),
          content: const Text(
            'This downloads a Qwen 0.5B GGUF model (about 340 MB) to this device. After setup, report summaries run locally and do not send your health records to a cloud AI service. Download requires internet access; do this before connecting only to the glove hotspot. The summary is experimental and not medical advice.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Download model'),
            ),
          ],
        ),
      );
      if (shouldDownload != true) return;
    }
    setState(() {
      _summarizing = true;
      _error = null;
      _summary = null;
      _chatMessages.clear();
      _downloadProgress = 0;
    });
    try {
      if (!await LocalReportLlm.instance.isDownloaded()) {
        await LocalReportLlm.instance.downloadModel(
          onProgress: (progress) {
            if (mounted) setState(() => _downloadProgress = progress);
          },
        );
        _modelDownloaded = true;
      }
      final summary = await LocalReportLlm.instance.summarize(_factsForLlm());
      if (mounted) setState(() => _summary = summary);
    } catch (e) {
      if (mounted) setState(() => _error = 'Offline summary failed: $e');
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  Future<void> _exportWorkbook() async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final workbook = Excel.createExcel();
      final summary = workbook['Summary'];
      summary.appendRow([TextCellValue('SailmCalm health report')]);
      summary.appendRow([TextCellValue('Period'), TextCellValue(_periodName)]);
      summary.appendRow([
        TextCellValue('Date range'),
        TextCellValue(_rangeLabel),
      ]);
      summary.appendRow([
        TextCellValue('Created locally'),
        TextCellValue(DateTime.now().toIso8601String()),
      ]);
      final metrics = _summaryMetrics();
      for (final key in [
        'daily_logs',
        'glove_samples',
        'average_self_reported_intensity_0_10',
        'average_self_reported_duration_minutes',
        'average_recorded_frequency_hz',
        'average_recorded_amplitude',
        'medication_reported_yes',
        'medication_reported_no',
      ]) {
        summary.appendRow([
          TextCellValue(key.replaceAll('_', ' ')),
          TextCellValue('${metrics[key] ?? '—'}'),
        ]);
      }
      if (_summary != null && _summary!.trim().isNotEmpty) {
        summary.appendRow([
          TextCellValue(
            'On-device summary (rule-based; review against source records)',
          ),
          TextCellValue(_summary!.trim()),
        ]);
      }
      summary.appendRow([
        TextCellValue('Important'),
        TextCellValue(
          'Self-reported records and wearable/model output are not a medical diagnosis. The model reproduces workbook status labels and is experimental.',
        ),
      ]);

      final logsSheet = workbook['Daily Logs'];
      logsSheet.appendRow([
        TextCellValue('Date'),
        TextCellValue('Self-rated intensity (0–10)'),
        TextCellValue('Duration minutes'),
        TextCellValue('Affected area'),
        TextCellValue('Activity'),
        TextCellValue('Possible trigger'),
        TextCellValue('Medication self-report'),
        TextCellValue('Notes'),
      ]);
      for (final row in _logs) {
        logsSheet.appendRow([
          TextCellValue('${row['log_date'] ?? ''}'),
          TextCellValue('${row['perceived_intensity'] ?? ''}'),
          TextCellValue('${row['duration_minutes'] ?? ''}'),
          TextCellValue('${row['affected_area'] ?? ''}'),
          TextCellValue('${row['activity'] ?? ''}'),
          TextCellValue('${row['possible_trigger'] ?? ''}'),
          TextCellValue(
            row['medication_taken'] == 1
                ? 'Yes (self-reported)'
                : row['medication_taken'] == 0
                ? 'No (self-reported)'
                : 'Not entered',
          ),
          TextCellValue('${row['notes'] ?? ''}'),
        ]);
      }

      final gloveSheet = workbook['Glove Samples'];
      gloveSheet.appendRow([
        TextCellValue('Recorded at'),
        TextCellValue('Frequency Hz'),
        TextCellValue('Amplitude'),
        TextCellValue('Predicted class'),
        TextCellValue('Uncalibrated model vote score'),
        TextCellValue('Signal quality'),
        TextCellValue('Source'),
      ]);
      for (final row in _episodes) {
        gloveSheet.appendRow([
          TextCellValue('${row['recorded_at'] ?? ''}'),
          TextCellValue('${row['frequency_hz'] ?? ''}'),
          TextCellValue('${row['amplitude'] ?? ''}'),
          TextCellValue('${row['predicted_class'] ?? ''}'),
          TextCellValue('${row['model_confidence'] ?? ''}'),
          TextCellValue('${row['signal_quality'] ?? ''}'),
          TextCellValue('${row['source'] ?? ''}'),
        ]);
      }

      final medicationSheet = workbook['Medication Schedule'];
      medicationSheet.appendRow([
        TextCellValue('Medication'),
        TextCellValue('Prescribed instructions (user entered)'),
        TextCellValue('Times'),
        TextCellValue('Notes'),
      ]);
      for (final med in _medications) {
        medicationSheet.appendRow([
          TextCellValue('${med['name'] ?? ''}'),
          TextCellValue('${med['prescribed_instructions'] ?? ''}'),
          TextCellValue('${med['times_json'] ?? '[]'}'),
          TextCellValue('${med['notes'] ?? ''}'),
        ]);
      }

      final medicalSheet = workbook['Medical Background'];
      final p = _profile ?? const <String, Object?>{};
      for (final entry in <String, Object?>{
        'Display name': p['display_name'],
        'Age': p['age_years'],
        'Diagnosis status (user entered)': p['diagnosis_status'],
        'Affected side': p['affected_side'],
        'Symptom onset': p['symptom_onset'],
        'Medical conditions': p['medical_conditions'],
        'Allergies': p['allergies'],
        'Past surgeries / history': p['surgeries'],
        'Current treatments / care plan': p['current_treatments'],
        'Clinician notes': p['clinician_notes'],
        'Emergency contact name': p['emergency_contact_name'],
        'Emergency contact phone': p['emergency_contact_phone'],
      }.entries) {
        medicalSheet.appendRow([
          TextCellValue(entry.key),
          TextCellValue('${entry.value ?? ''}'),
        ]);
      }

      final bytes = workbook.encode();
      if (bytes == null || bytes.isEmpty)
        throw StateError('Excel workbook could not be encoded.');
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
        '${dir.path}/sailmcalm_${_period.name}_report_$stamp.xlsx',
      );
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'SailmCalm $_periodName report',
        text:
            'Locally generated SailmCalm report for $_rangeLabel. Review the workbook with your clinician; it is not a diagnosis.',
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not export report: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _metric(String title, String value, IconData icon) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final logs = _logs;
    final episodes = _episodes;
    final avgIntensity = _mean(
      logs.map((row) => row['perceived_intensity'] as num?),
    );
    final avgFrequency = _mean(
      episodes.map((row) => row['frequency_hz'] as num?),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports and summaries'),
        actions: [
          IconButton(
            tooltip: 'Refresh records',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
                children: [
                  SegmentedButton<_ReportPeriod>(
                    segments: const [
                      ButtonSegment(
                        value: _ReportPeriod.week,
                        label: Text('Weekly'),
                        icon: Icon(Icons.view_week_outlined),
                      ),
                      ButtonSegment(
                        value: _ReportPeriod.month,
                        label: Text('Monthly'),
                        icon: Icon(Icons.calendar_month_outlined),
                      ),
                      ButtonSegment(
                        value: _ReportPeriod.year,
                        label: Text('Yearly'),
                        icon: Icon(Icons.calendar_today_outlined),
                      ),
                    ],
                    selected: {_period},
                    onSelectionChanged: (selection) => setState(() {
                      _period = selection.first;
                      _summary = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _rangeLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _metric(
                        'Daily logs',
                        '${logs.length}',
                        Icons.edit_note_outlined,
                      ),
                      const SizedBox(width: 10),
                      _metric(
                        'Stored glove samples',
                        '${episodes.length}',
                        Icons.monitor_heart_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _metric(
                        'Average self-rated intensity',
                        _num(avgIntensity),
                        Icons.insights_outlined,
                      ),
                      const SizedBox(width: 10),
                      _metric(
                        'Average stored frequency',
                        '${_num(avgFrequency)} Hz',
                        Icons.waves_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Medication self-reports',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Yes: ${_countMedication(true)}  •  No: ${_countMedication(false)}  •  Unknown/not entered: ${logs.length - _countMedication(true) - _countMedication(false)}',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'These values come from self-reported daily logs, not a verified record of medication ingestion.',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Records in this period',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (logs.isEmpty && episodes.isEmpty)
                            const Text(
                              'No records have been saved for this period yet. Keep daily logs or collect stored glove samples to build a report.',
                            ),
                          if (logs.isNotEmpty)
                            Text(
                              '${logs.length} daily symptom log(s); average self-rated intensity ${_num(avgIntensity)}/10.',
                            ),
                          if (episodes.isNotEmpty)
                            Text(
                              '${episodes.length} stored glove/model sample(s); average frequency ${_num(avgFrequency)} Hz.',
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _exporting ? null : _exportWorkbook,
                    icon: _exporting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.table_view_outlined),
                    label: Text(
                      _exporting
                          ? 'Preparing Excel workbook…'
                          : 'Export report to Excel (.xlsx)',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.smart_toy_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Offline report summary',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _modelDownloaded
                                ? 'Generate a plain-English summary from saved report facts. This rule-based summary works offline and requires no model download.'
                                : 'Built-in rule-based summary. No generative AI model or download is used.',
                          ),
                          if (_summarizing && !_modelDownloaded) ...[
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: _downloadProgress > 0
                                  ? _downloadProgress
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${(_downloadProgress * 100).round()}% downloaded',
                            ),
                          ],
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _summarizing ? null : _createSummary,
                              icon: _summarizing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome_outlined),
                              label: Text(
                                _summarizing
                                    ? (_modelDownloaded
                                          ? 'Generating on device…'
                                          : 'Preparing local summary…')
                                    : (_modelDownloaded
                                          ? 'Generate local summary'
                                          : 'Generate local summary'),
                              ),
                            ),
                          ),
                          if (_summary != null) ...[
                            const Divider(height: 26),
                            Text(
                              _summary!,
                              style: const TextStyle(height: 1.5),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            'This is a rule-based summary, not a generative AI or medical model. Check every statement against the underlying records and consult a clinician for medical decisions.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_summary != null) ...[
                    const SizedBox(height: 12),
                    _reportChatSection(),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(_error!),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Reports distinguish self-reported symptoms from stored glove/model data. A missing sample is not evidence that no tremor occurred. These records and summaries are informational, not diagnostic.',
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ReportChatMessage {
  final bool isUser;
  final String text;
  const _ReportChatMessage({required this.isUser, required this.text});
}
