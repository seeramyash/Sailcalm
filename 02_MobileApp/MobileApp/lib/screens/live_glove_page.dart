import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/glove_status_model.dart';
import '../services/local_database.dart';
import 'care_tools_page.dart';
import 'local_records_page.dart';

/// Read-only monitor for the existing StressTrack /data endpoint.
/// Firmware readings plus a separate experimental Random Forest status-reproduction estimate.
class LiveGlovePage extends StatefulWidget {
  const LiveGlovePage({super.key});

  @override
  State<LiveGlovePage> createState() => _LiveGlovePageState();
}

class _LiveGlovePageState extends State<LiveGlovePage> {
  static final Uri _endpoint = Uri.parse('http://172.20.10.2/data');
  static const Duration _pollInterval = Duration(seconds: 1);

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  Timer? _timer;
  bool _requestInFlight = false;
  bool _connected = false;
  Map<String, dynamic>? _current;
  DateTime? _lastUpdated;
  String? _error;
  GloveStatusModel? _model;
  GloveStatusPrediction? _prediction;
  String? _modelError;

  // Foreground-only prompt: require three consecutive Severe model estimates,
  // then suppress repeats until five consecutive non-Severe estimates arrive.
  int _severeStreak = 0;
  int _nonSevereStreak = 0;
  bool _severeEpisodePrompted = false;
  bool _severityDialogOpen = false;
  DateTime? _lastStoredSampleAt;

  @override
  void initState() {
    super.initState();
    _loadModel();
    _fetchNow();
    _timer = Timer.periodic(_pollInterval, (_) => _fetchNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }

  Future<void> _fetchNow() async {
    if (_requestInFlight) return;
    _requestInFlight = true;

    try {
      final request = await _client
          .getUrl(_endpoint)
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 4));

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: _endpoint);
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Response is not a JSON object.');
      }
      final current = decoded['current'];
      if (current is! Map) {
        throw const FormatException('Response has no current sensor object.');
      }

      final currentMap = Map<String, dynamic>.from(current);
      GloveStatusPrediction? prediction;
      String? predictionError;
      final model = _model;
      if (model != null) {
        try {
          prediction = model.predictFromApiCurrent(currentMap);
        } catch (error) {
          predictionError = error.toString();
        }
      }

      if (!mounted) return;
      setState(() {
        _current = currentMap;
        _prediction = prediction;
        _modelError = predictionError;
        _connected = true;
        _lastUpdated = DateTime.now();
        _error = null;
      });
      await _storeGloveSample(currentMap, prediction);
      _evaluateSeverityPrompt(prediction);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _error = error is SocketException || error is TimeoutException
            ? 'Could not reach the glove. Check that this phone is connected to the iotdata hotspot and the glove is powered on.'
            : 'Could not read the glove response: $error';
      });
    } finally {
      _requestInFlight = false;
    }
  }

  /// Store one snapshot per minute for user-facing historical reports. This is
  /// sample logging, not a continuous/raw tremor waveform or a validated episode.
  Future<void> _storeGloveSample(
    Map<String, dynamic> current,
    GloveStatusPrediction? prediction,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    final now = DateTime.now();
    final last = _lastStoredSampleAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1))
      return;
    final tremorValue = current['tremor'];
    if (tremorValue is! Map) return;
    final tremor = Map<String, dynamic>.from(tremorValue);
    final frequency = tremor['frequency'] is num
        ? (tremor['frequency'] as num).toDouble()
        : null;
    final amplitude = tremor['amplitude'] is num
        ? (tremor['amplitude'] as num).toDouble()
        : null;
    if (frequency == null && amplitude == null && prediction == null) return;
    _lastStoredSampleAt = now;
    const classOrder = ['Mild', 'Moderate', 'None', 'Severe'];
    final predictedIndex = prediction == null
        ? -1
        : classOrder.indexWhere(
            (label) => label.toLowerCase() == prediction.status.toLowerCase(),
          );
    try {
      await LocalDatabase.instance.addEpisode(
        uid: uid,
        recordedAt: now.toIso8601String(),
        frequencyHz: frequency,
        amplitude: amplitude,
        predictedClass: predictedIndex < 0 ? null : predictedIndex,
        modelConfidence: prediction?.modelScore,
        signalQuality:
            'device_status=${tremor['status'] ?? 'unknown'}; active=${tremor['active'] ?? 'unknown'}',
        source: 'StressTrack 60-second snapshot; ML reproduces workbook status labels',
      );
    } catch (_) {
      // Live display and foreground check-in should remain usable if local
      // history storage fails (for example, before the user signs in).
    }
  }

  Future<void> _loadModel() async {
    try {
      final model = await GloveStatusModel.loadAsset();
      if (!mounted) return;
      GloveStatusPrediction? prediction;
      String? predictionError;
      final current = _current;
      if (current != null) {
        try {
          prediction = model.predictFromApiCurrent(current);
        } catch (error) {
          predictionError = error.toString();
        }
      }
      setState(() {
        _model = model;
        _prediction = prediction;
        _modelError = predictionError;
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _modelError = 'Could not load the experimental model: $error',
      );
    }
  }

  void _evaluateSeverityPrompt(GloveStatusPrediction? prediction) {
    if (!mounted || prediction == null) return;
    final isSevere = prediction.status.trim().toLowerCase() == 'severe';
    if (isSevere) {
      _severeStreak++;
      _nonSevereStreak = 0;
      if (_severeStreak >= 3 &&
          !_severeEpisodePrompted &&
          !_severityDialogOpen) {
        _severeEpisodePrompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showSeverityCarePrompt();
        });
      }
    } else {
      _severeStreak = 0;
      _nonSevereStreak++;
      if (_nonSevereStreak >= 5) _severeEpisodePrompted = false;
    }
  }

  Future<void> _showSeverityCarePrompt({bool preview = false}) async {
    if (!mounted || _severityDialogOpen) return;
    _severityDialogOpen = true;
    try {
      final action = await showDialog<_SeverityPromptAction>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.notifications_active_outlined),
          title: Text(
            preview ? 'Medication check-in preview' : 'Tremor status check-in',
          ),
          content: Text(
            preview
                ? 'This is a preview of the check-in workflow. No Severe event is being asserted. Have you taken medication according to your own prescribed schedule?'
                : 'The experimental model has reported Severe for three consecutive readings. This is not a medical alert or diagnosis. Have you taken your medication according to your prescribed schedule?',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_SeverityPromptAction.later),
              child: const Text('Not now'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(dialogContext)
                      .pop(_SeverityPromptAction.notTaken),
              child: const Text('Not yet — show schedule'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(dialogContext)
                      .pop(_SeverityPromptAction.emergencyContact),
              icon: const Icon(Icons.sos_outlined),
              label: const Text('SOS contact'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_SeverityPromptAction.taken),
              child: const Text('Taken — open care tools'),
            ),
          ],
        ),
      );
      if (!mounted || action == null || action == _SeverityPromptAction.later)
        return;

      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (action == _SeverityPromptAction.emergencyContact) {
        await _confirmEmergencyContactCall(uid);
        return;
      }
      final taken = action == _SeverityPromptAction.taken;
      if (!preview && uid.isNotEmpty) {
        try {
          final now = DateTime.now();
          await LocalDatabase.instance.addDailyLog(
            uid: uid,
            logDate:
                '${now.year.toString().padLeft(4, '0')}-'
                '${now.month.toString().padLeft(2, '0')}-'
                '${now.day.toString().padLeft(2, '0')}',
            medicationTaken: taken,
            notes:
                'Self-reported response to an in-app experimental Severe-status prompt at '
                '${now.toIso8601String()}. This is not a clinician-verified medication record.',
          );
        } catch (_) {
          // The prompt flow should remain usable if local logging is unavailable.
        }
      }

      if (taken) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const CareToolsPage()),
        );
      } else if (uid.isNotEmpty) {
        await _showSavedMedicationSchedule(uid);
      } else {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Medication schedule unavailable'),
            content: const Text(
              'Sign in to view medication details saved in your private local records. '
              'Follow only your existing prescription; do not take an extra dose because of this model estimate.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } finally {
      _severityDialogOpen = false;
    }
  }

  Future<void> _confirmEmergencyContactCall(String uid) async {
    if (!mounted) return;
    if (uid.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Emergency contact unavailable'),
          content: const Text(
            'Sign in and save an emergency contact name and phone number in Private health records > Profile. No call was placed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    Map<String, Object?>? profile;
    try {
      profile = await LocalDatabase.instance.getProfile(uid);
    } catch (_) {
      profile = null;
    }
    if (!mounted) return;
    final contactName =
        (profile?['emergency_contact_name'] as String?)?.trim() ?? '';
    final rawPhone =
        (profile?['emergency_contact_phone'] as String?)?.trim() ?? '';
    final phone = rawPhone.replaceAll(RegExp(r'[^0-9+*#,;]'), '');
    if (contactName.isEmpty || phone.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.contact_phone_outlined),
          title: const Text('Emergency contact not saved'),
          content: const Text(
            'Enter the emergency contact name and phone number under Private health records > Profile first. No call was placed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.sos_outlined, color: Colors.red),
        title: const Text('SOS — contact emergency person?'),
        content: Text(
          'Contact: $contactName\n$rawPhone\n\nThe tremor estimate is experimental and may be wrong. If you continue, SailmCalm opens the phone dialer with this number. You must press Call yourself; the app will not place an automatic call.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.call_outlined),
            label: const Text('Open phone dialer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final launched = await launchUrl(
        Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (!launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the phone dialer on this device.'),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the phone dialer: $error')),
      );
    }
  }

  Future<void> _showSavedMedicationSchedule(String uid) async {
    List<Map<String, Object?>> medications;
    try {
      medications = await LocalDatabase.instance.getMedications(uid);
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Could not open medication schedule'),
          content: Text('The local schedule could not be loaded: $error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;

    final hasMedications = medications.isNotEmpty;
    final openEditor = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          hasMedications
              ? 'Your saved medication schedule'
              : 'No medication schedule saved',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!hasMedications)
                const Text(
                  'Add the medication name, prescribed instructions and timing in your private local records.',
                ),
              for (final medication in medications) ...[
                Builder(
                  builder: (_) {
                    final name =
                        (medication['name'] as String?) ?? 'Medication';
                    final instructions =
                        (medication['prescribed_instructions'] as String?) ??
                        '';
                    final timesText =
                        (medication['times_json'] as String?) ?? '[]';
                    var times = <String>[];
                    try {
                      final decoded = jsonDecode(timesText);
                      if (decoded is List)
                        times = decoded
                            .map((value) => value.toString())
                            .toList();
                    } catch (_) {
                      // If an old entry has unreadable timing data, still show its instructions.
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          if (times.isNotEmpty)
                            Text(
                              'Scheduled time${times.length == 1 ? '' : 's'}: ${times.join(', ')}',
                            ),
                          const SizedBox(height: 4),
                          Text(instructions),
                        ],
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 6),
              const Text(
                'Use only the instructions you entered from your prescription. This app does not recommend extra doses or change medication timing.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(hasMedications ? 'Manage schedule' : 'Add medication'),
          ),
        ],
      ),
    );
    if (!mounted || openEditor != true) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LocalRecordsPage(uid: uid, initialTab: 2),
      ),
    );
  }

  static String _stringValue(dynamic value, {String fallback = '—'}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  static String _number(dynamic value, {int digits = 2}) {
    if (value is num && value.isFinite) return value.toStringAsFixed(digits);
    return '—';
  }

  static bool _bool(dynamic value) => value == true || value == 1;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final current = _current ?? const <String, dynamic>{};
    final tremorValue = current['tremor'];
    final tremor = tremorValue is Map
        ? Map<String, dynamic>.from(tremorValue)
        : <String, dynamic>{};
    final status = _stringValue(tremor['status'], fallback: 'Unknown');
    final isActive = _bool(tremor['active']);
    final statusColor = status.toLowerCase() == 'none'
        ? Colors.green
        : (isActive ? colors.tertiary : colors.onSurfaceVariant);

    // Read the actual on-device CNN output exposed by the XIAO firmware.
    // This is deliberately displayed separately from the pre-existing
    // experimental Random Forest estimate further down this screen.
    final mlValue = current['ml'];
    final cnn = mlValue is Map
        ? Map<String, dynamic>.from(mlValue)
        : <String, dynamic>{};
    final cnnAvailable = _bool(cnn['available']);
    final cnnLabel = _stringValue(cnn['label'], fallback: 'Waiting for prediction');
    final cnnClassLower = cnnLabel.toLowerCase();
    final cnnClassColor = cnnClassLower.contains('severe')
        ? colors.error
        : (cnnClassLower.contains('moderate')
            ? colors.tertiary
            : (cnnClassLower.contains('mild') ? Colors.orange : Colors.green));
    final cnnScore = cnn['score'] is num
        ? (cnn['score'] as num).toDouble()
        : null;
    final cnnInferenceMs = cnn['inference_us'] is num
        ? (cnn['inference_us'] as num).toDouble() / 1000.0
        : null;
    final sampleHz = cnn['sample_hz'] is num
        ? (cnn['sample_hz'] as num).toDouble()
        : null;
    final targetSampleHz = cnn['target_sample_hz'] is num
        ? (cnn['target_sample_hz'] as num).toDouble()
        : 50.0;
    final droppedSamples = cnn['dropped_samples'];
    final missedDeadlines = cnn['missed_deadlines'];
    final modelVersion = _stringValue(cnn['version'], fallback: '—');
    final classNames = const ['No tremor', 'Mild', 'Moderate', 'Severe'];
    final probabilityRows = <Widget>[];
    final rawProbabilities = cnn['probabilities'];
    if (rawProbabilities is List) {
      for (var i = 0; i < classNames.length && i < rawProbabilities.length; i++) {
        final raw = rawProbabilities[i];
        final probability = raw is num
            ? raw.toDouble().clamp(0.0, 1.0).toDouble()
            : 0.0;
        probabilityRows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(classNames[i])),
                    Text('${(probability * 100).toStringAsFixed(1)}%'),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: probability, minHeight: 6),
              ],
            ),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live glove readings'),
        actions: [
          IconButton(
            tooltip: 'Refresh now',
            onPressed: _requestInFlight ? null : _fetchNow,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchNow,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _connected ? Icons.wifi : Icons.wifi_off,
                          color: _connected ? Colors.green : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _connected
                                ? 'Glove connected'
                                : 'Glove not connected',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (_requestInFlight)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Endpoint: ${_endpoint.toString()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _lastUpdated == null
                          ? 'Last update: not received yet'
                          : 'Last successful update: ${TimeOfDay.fromDateTime(_lastUpdated!).format(context)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: colors.error, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DEVICE-REPORTED TREMOR STATUS',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      status,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(
                          avatar: Icon(
                            isActive
                                ? Icons.warning_amber_rounded
                                : Icons.info_outline,
                            size: 18,
                          ),
                          label: Text(
                            isActive
                                ? 'Device says active'
                                : 'Device says inactive',
                          ),
                        ),
                        Chip(
                          label: Text(
                            _connected
                                ? 'Updating about every 1 s'
                                : 'Waiting for connection',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'These values come from the glove firmware. They are the original device outputs, not an ML prediction or a medical diagnosis.',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            // New display-only card for the CNN running on the XIAO.
            // Existing app widgets and the experimental model below remain unchanged.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ON-DEVICE CNN RESULT',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (!cnnAvailable)
                      Text(
                        _connected
                            ? 'CNN result is not available from the device yet.'
                            : 'Connect the glove to receive its CNN result.',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      )
                    else ...[
                      Text(
                        cnnLabel,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: cnnClassColor,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (cnnScore != null)
                            Chip(
                              avatar: const Icon(Icons.percent, size: 18),
                              label: Text(
                                'Top output: ${(cnnScore * 100).toStringAsFixed(1)}%',
                              ),
                            ),
                          if (cnnInferenceMs != null)
                            Chip(
                              avatar: const Icon(Icons.timer_outlined, size: 18),
                              label: Text('Inference: ${cnnInferenceMs.toStringAsFixed(2)} ms'),
                            ),
                        ],
                      ),
                      if (probabilityRows.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'CLASS PROBABILITIES',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11,
                            letterSpacing: 1.0,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...probabilityRows,
                      ],
                      const Divider(height: 20),
                      _DetailRow(label: 'Model', value: modelVersion),
                      _DetailRow(
                        label: 'Input',
                        value: _stringValue(cnn['input_profile'], fallback: 'accelerometer XYZ'),
                      ),
                      _DetailRow(
                        label: 'Sampling rate',
                        value: sampleHz == null
                            ? '—'
                            : '${sampleHz.toStringAsFixed(1)} / ${targetSampleHz.toStringAsFixed(0)} Hz',
                      ),
                      _DetailRow(
                        label: 'Dropped samples',
                        value: _stringValue(droppedSamples),
                      ),
                      _DetailRow(
                        label: 'Missed deadlines',
                        value: _stringValue(missedDeadlines),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'This prediction is produced by the CNN running locally on the XIAO ESP32-C3. The top output score is not the model’s independently measured accuracy and is not a medical diagnosis.',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'EXPERIMENTAL ML STATUS ESTIMATE',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_model == null && _modelError == null)
                      const Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Loading local model…'),
                        ],
                      )
                    else if (_modelError != null)
                      Text(
                        _modelError!,
                        style: TextStyle(color: colors.error, height: 1.4),
                      )
                    else if (_prediction == null)
                      const Text('Waiting for valid sensor values.')
                    else ...[
                      Text(
                        _prediction!.status,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: _prediction!.status.toLowerCase() == 'none'
                                  ? Colors.green
                                  : colors.tertiary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Chip(
                        avatar: const Icon(
                          Icons.account_tree_outlined,
                          size: 18,
                        ),
                        label: Text(
                          'Model score (uncalibrated): ${_prediction!.modelScorePercent}',
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'This local Random Forest was trained on the glove workbook using firmware-reported frequency and amplitude to reproduce recorded status labels. The score is not calibrated, and this is not an independent medical severity assessment.',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _severityDialogOpen
                  ? null
                  : () => _showSeverityCarePrompt(preview: true),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Preview medication check-in'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _ReadingCard(
                    title: 'Frequency',
                    value: '${_number(tremor['frequency'], digits: 1)} Hz',
                    icon: Icons.graphic_eq,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ReadingCard(
                    title: 'Amplitude',
                    value: _number(tremor['amplitude'], digits: 3),
                    subtitle: 'Firmware-reported units',
                    icon: Icons.show_chart,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Accelerometer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _ReadingCard(
                    title: 'AX',
                    value: _number(current['ax']),
                    icon: Icons.swap_horiz,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReadingCard(
                    title: 'AY',
                    value: _number(current['ay']),
                    icon: Icons.swap_vert,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReadingCard(
                    title: 'AZ',
                    value: _number(current['az']),
                    icon: Icons.height,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Gyroscope', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _ReadingCard(
                    title: 'GX',
                    value: _number(current['gx']),
                    icon: Icons.rotate_left,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReadingCard(
                    title: 'GY',
                    value: _number(current['gy']),
                    icon: Icons.rotate_right,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReadingCard(
                    title: 'GZ',
                    value: _number(current['gz']),
                    icon: Icons.screen_rotation_alt,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Other readings',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      label: 'GSR',
                      value: _stringValue(current['gsr']),
                    ),
                    _DetailRow(
                      label: 'Stress label',
                      value: _stringValue(current['stress']),
                    ),
                    _DetailRow(
                      label: 'MPU temperature',
                      value: '${_number(current['mpuTemp'], digits: 1)} °C',
                    ),
                    finalHr(current),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _requestInFlight ? null : _fetchNow,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh readings now'),
            ),
            const SizedBox(height: 8),
            Text(
              'Keep the device powered and this phone connected to the same iotdata hotspot. Severe-status check-ins run only while this Live glove readings screen is open. Sensor readings are read from the local endpoint and are not uploaded to Firebase.',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget finalHr(Map<String, dynamic> current) {
    final hrmValue = current['hrm'];
    final hrm = hrmValue is Map
        ? Map<String, dynamic>.from(hrmValue)
        : <String, dynamic>{};
    return _DetailRow(
      label: 'Heart rate',
      value: '${_number(hrm['bpm'], digits: 0)} BPM',
    );
  }
}

enum _SeverityPromptAction { taken, notTaken, emergencyContact, later }

class _ReadingCard extends StatelessWidget {
  final String title;
  final String value;
  final String? subtitle;
  final IconData icon;

  const _ReadingCard({
    required this.title,
    required this.value,
    required this.icon,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.primary, size: 20),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 5),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(
                subtitle!,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
