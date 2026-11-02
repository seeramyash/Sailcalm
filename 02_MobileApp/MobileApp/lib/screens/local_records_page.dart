import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/local_database.dart';

/// Local-only health profile, daily symptom log, and medication schedule.
/// These pages require the authenticated user's Firebase UID but never upload
/// the health information to Firebase.
class LocalRecordsPage extends StatelessWidget {
  final String uid;
  final int initialTab;

  const LocalRecordsPage({super.key, required this.uid, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final colors = baseTheme.colorScheme;
    final fieldRadius = BorderRadius.circular(20);
    final polishedTheme = baseTheme.copyWith(
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        border: OutlineInputBorder(borderRadius: fieldRadius),
        enabledBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: colors.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: fieldRadius,
          borderSide: BorderSide(color: colors.error, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 17,
        ),
      ),
    );
    return Theme(
      data: polishedTheme,
      child: DefaultTabController(
        length: 3,
        initialIndex: initialTab.clamp(0, 2).toInt(),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Private health records'),
            bottom: const TabBar(
              isScrollable: true,
              tabs: [
                Tab(icon: Icon(Icons.person_outline), text: 'Profile'),
                Tab(icon: Icon(Icons.edit_note), text: 'Daily log'),
                Tab(icon: Icon(Icons.medication_outlined), text: 'Medication'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: _HealthProfileForm(uid: uid),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: _DailyLogForm(uid: uid),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: _MedicationForm(uid: uid),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HealthProfileForm extends StatefulWidget {
  final String uid;
  const _HealthProfileForm({required this.uid});

  @override
  State<_HealthProfileForm> createState() => _HealthProfileFormState();
}

class _HealthProfileFormState extends State<_HealthProfileForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _onset = TextEditingController();
  final _notes = TextEditingController();
  final _conditions = TextEditingController();
  final _allergies = TextEditingController();
  final _surgeries = TextEditingController();
  final _treatments = TextEditingController();
  final _contactName = TextEditingController();
  final _contactPhone = TextEditingController();

  String _diagnosis = 'Not diagnosed';
  String _affectedSide = 'Both / varies';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await LocalDatabase.instance.getProfile(widget.uid);
      if (!mounted) return;
      if (profile != null) {
        _name.text = (profile['display_name'] as String?) ?? '';
        _age.text = profile['age_years']?.toString() ?? '';
        _onset.text = (profile['symptom_onset'] as String?) ?? '';
        _notes.text = (profile['clinician_notes'] as String?) ?? '';
        _conditions.text = (profile['medical_conditions'] as String?) ?? '';
        _allergies.text = (profile['allergies'] as String?) ?? '';
        _surgeries.text = (profile['surgeries'] as String?) ?? '';
        _treatments.text = (profile['current_treatments'] as String?) ?? '';
        _contactName.text =
            (profile['emergency_contact_name'] as String?) ?? '';
        _contactPhone.text =
            (profile['emergency_contact_phone'] as String?) ?? '';
        final diagnosis = profile['diagnosis_status'] as String?;
        final side = profile['affected_side'] as String?;
        if (diagnosis != null) _diagnosis = diagnosis;
        if (side != null) _affectedSide = side;
      }
    } catch (e) {
      if (mounted) _message('Could not load local profile: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ageText = _age.text.trim();
    final age = ageText.isEmpty ? null : int.tryParse(ageText);
    if (ageText.isNotEmpty && (age == null || age < 1 || age > 120)) {
      _message('Enter an age between 1 and 120, or leave it blank.');
      return;
    }

    setState(() => _saving = true);
    try {
      await LocalDatabase.instance.saveProfile(
        uid: widget.uid,
        displayName: _name.text.trim().isEmpty ? null : _name.text.trim(),
        ageYears: age,
        diagnosisStatus: _diagnosis,
        affectedSide: _affectedSide,
        symptomOnset: _onset.text.trim().isEmpty ? null : _onset.text.trim(),
        clinicianNotes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        medicalConditions: _conditions.text.trim().isEmpty
            ? null
            : _conditions.text.trim(),
        allergies: _allergies.text.trim().isEmpty
            ? null
            : _allergies.text.trim(),
        surgeries: _surgeries.text.trim().isEmpty
            ? null
            : _surgeries.text.trim(),
        currentTreatments: _treatments.text.trim().isEmpty
            ? null
            : _treatments.text.trim(),
        emergencyContactName: _contactName.text.trim().isEmpty
            ? null
            : _contactName.text.trim(),
        emergencyContactPhone: _contactPhone.text.trim().isEmpty
            ? null
            : _contactPhone.text.trim(),
      );
      if (mounted) _message('Profile saved on this device.');
    } catch (e) {
      if (mounted) _message('Could not save profile: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _onset.dispose();
    _notes.dispose();
    _conditions.dispose();
    _allergies.dispose();
    _surgeries.dispose();
    _treatments.dispose();
    _contactName.dispose();
    _contactPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const _PrivacyNote(
            text: 'These fields are stored in the encrypted local database on this phone. They are not uploaded to Firebase.',
          ),
          const SizedBox(height: 18),
          Text(
            'Basic information',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Preferred name (optional)',
            child: TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Age (optional)',
            child: TextFormField(
              controller: _age,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: 12),
          const _FieldLabel('Diagnosis status'),
          const SizedBox(height: 7),
          DropdownButtonFormField<String>(
            initialValue: _diagnosis,
            decoration: const InputDecoration(
              hintText: 'Choose diagnosis status',
              prefixIcon: Icon(Icons.medical_information_outlined),
            ),
            borderRadius: BorderRadius.circular(18),
            menuMaxHeight: 360,
            items: const [
              DropdownMenuItem(
                value: 'Not diagnosed',
                child: Text('Not diagnosed'),
              ),
              DropdownMenuItem(
                value: 'Parkinson’s diagnosed by clinician',
                child: Text('Parkinson’s diagnosed by clinician'),
              ),
              DropdownMenuItem(
                value: 'Other clinician-diagnosed tremor',
                child: Text('Other clinician-diagnosed tremor'),
              ),
              DropdownMenuItem(
                value: 'Unsure / prefer not to say',
                child: Text('Unsure / prefer not to say'),
              ),
            ],
            onChanged: (value) =>
                setState(() => _diagnosis = value ?? _diagnosis),
          ),
          const SizedBox(height: 12),
          const _FieldLabel('Affected side (if applicable)'),
          const SizedBox(height: 7),
          DropdownButtonFormField<String>(
            initialValue: _affectedSide,
            decoration: const InputDecoration(
              hintText: 'Choose affected side',
              prefixIcon: Icon(Icons.pan_tool_alt_outlined),
            ),
            borderRadius: BorderRadius.circular(18),
            items: const [
              DropdownMenuItem(value: 'Left', child: Text('Left')),
              DropdownMenuItem(value: 'Right', child: Text('Right')),
              DropdownMenuItem(
                value: 'Both / varies',
                child: Text('Both / varies'),
              ),
              DropdownMenuItem(
                value: 'Not sure / not applicable',
                child: Text('Not sure / not applicable'),
              ),
            ],
            onChanged: (value) =>
                setState(() => _affectedSide = value ?? _affectedSide),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'When symptoms began (optional)',
            child: TextFormField(
              controller: _onset,
              decoration: const InputDecoration(
                hintText: 'e.g. around March 2025',
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Care notes and emergency contact',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Relevant clinician notes (optional)',
            child: TextFormField(
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Other medical conditions (optional)',
            child: TextFormField(
              controller: _conditions,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Enter clinician-diagnosed conditions only',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Allergies (optional)',
            child: TextFormField(
              controller: _allergies,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'Medicines, foods, or other allergies',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Past surgeries / relevant history (optional)',
            child: TextFormField(
              controller: _surgeries,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Current treatments / care plan (optional)',
            child: TextFormField(
              controller: _treatments,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Copy your clinician-provided plan',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Emergency contact name (optional)',
            child: TextFormField(
              controller: _contactName,
              decoration: const InputDecoration(),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Emergency contact phone (optional)',
            child: TextFormField(
              controller: _contactPhone,
              decoration: const InputDecoration(),
              keyboardType: TextInputType.phone,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving...' : 'Save private profile'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Only enter information you are comfortable storing on this device. This profile is not a diagnosis or medical assessment.',
            style: TextStyle(fontSize: 12, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _DailyLogForm extends StatefulWidget {
  final String uid;
  const _DailyLogForm({required this.uid});

  @override
  State<_DailyLogForm> createState() => _DailyLogFormState();
}

class _DailyLogFormState extends State<_DailyLogForm> {
  final _formKey = GlobalKey<FormState>();
  final _duration = TextEditingController();
  final _area = TextEditingController();
  final _activity = TextEditingController();
  final _trigger = TextEditingController();
  final _notes = TextEditingController();
  int _intensity = 0;
  String _medicationTaken = 'Unsure / not applicable';
  bool _saving = false;
  bool _loading = true;
  List<Map<String, Object?>> _logs = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final logs = await LocalDatabase.instance.getDailyLogs(
        widget.uid,
        limit: 20,
      );
      if (mounted) setState(() => _logs = logs);
    } catch (e) {
      if (mounted) _message('Could not load local logs: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final durationText = _duration.text.trim();
    final duration = durationText.isEmpty ? null : int.tryParse(durationText);
    if (durationText.isNotEmpty &&
        (duration == null || duration < 0 || duration > 1440)) {
      _message('Enter a duration from 0 to 1440 minutes, or leave it blank.');
      return;
    }

    final bool? medicationTaken = switch (_medicationTaken) {
      'Yes' => true,
      'No' => false,
      _ => null,
    };

    setState(() => _saving = true);
    try {
      final today = DateTime.now();
      await LocalDatabase.instance.addDailyLog(
        uid: widget.uid,
        logDate:
            '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}',
        perceivedIntensity: _intensity,
        durationMinutes: duration,
        affectedArea: _area.text.trim().isEmpty ? null : _area.text.trim(),
        activity: _activity.text.trim().isEmpty ? null : _activity.text.trim(),
        possibleTrigger: _trigger.text.trim().isEmpty
            ? null
            : _trigger.text.trim(),
        medicationTaken: medicationTaken,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      _duration.clear();
      _area.clear();
      _activity.clear();
      _trigger.clear();
      _notes.clear();
      await _reload();
      if (mounted) _message('Daily symptom log saved on this device.');
    } catch (e) {
      if (mounted) _message('Could not save daily log: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteLog(int id) async {
    try {
      await LocalDatabase.instance.deleteDailyLog(uid: widget.uid, id: id);
      await _reload();
      if (mounted) _message('Log deleted from this device.');
    } catch (e) {
      if (mounted) _message('Could not delete log: $e');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _duration.dispose();
    _area.dispose();
    _activity.dispose();
    _trigger.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const _PrivacyNote(
          text: 'This is your self-reported symptom log, not the AI prediction or a clinical severity score.',
        ),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How was today?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const _FieldLabel('Your perceived symptom intensity (0–10)'),
              const SizedBox(height: 7),
              DropdownButtonFormField<int>(
                initialValue: _intensity,
                decoration: const InputDecoration(
                  hintText: 'Choose intensity',
                  prefixIcon: Icon(Icons.tune_rounded),
                ),
                borderRadius: BorderRadius.circular(18),
                items: List.generate(
                  11,
                  (i) => DropdownMenuItem<int>(
                    value: i,
                    child: Text(
                      i == 0
                          ? '0 — none'
                          : i == 10
                          ? '10 — worst you experienced'
                          : '$i',
                    ),
                  ),
                ),
                onChanged: (value) => setState(() => _intensity = value ?? 0),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Approximate total duration in minutes (optional)',
                child: TextFormField(
                  controller: _duration,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(),
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Affected area (optional)',
                child: TextFormField(
                  controller: _area,
                  decoration: const InputDecoration(
                    hintText: 'e.g. right hand',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'What were you doing? (optional)',
                child: TextFormField(
                  controller: _activity,
                  decoration: const InputDecoration(),
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Possible trigger (optional)',
                child: TextFormField(
                  controller: _trigger,
                  decoration: const InputDecoration(
                    hintText: 'e.g. stress, tiredness, unknown',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const _FieldLabel('Did you take medication as prescribed?'),
              const SizedBox(height: 7),
              DropdownButtonFormField<String>(
                initialValue: _medicationTaken,
                decoration: const InputDecoration(
                  hintText: 'Choose an answer',
                  prefixIcon: Icon(Icons.medication_outlined),
                ),
                borderRadius: BorderRadius.circular(18),
                items: const [
                  DropdownMenuItem(value: 'Yes', child: Text('Yes')),
                  DropdownMenuItem(value: 'No', child: Text('No')),
                  DropdownMenuItem(
                    value: 'Unsure / not applicable',
                    child: Text('Unsure / not applicable'),
                  ),
                ],
                onChanged: (value) => setState(
                  () => _medicationTaken = value ?? _medicationTaken,
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Notes for yourself or your clinician (optional)',
                child: TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving...' : 'Save daily log'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Recent logs on this device',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_logs.isEmpty)
          const _EmptyLocalState(message: 'No daily logs saved yet.')
        else
          ..._logs.map((log) {
            final id = log['id'] as int;
            final date = (log['log_date'] as String?) ?? '';
            final intensity = log['perceived_intensity']?.toString() ?? '—';
            final notes = (log['notes'] as String?) ?? '';
            final area = (log['affected_area'] as String?) ?? '';
            return Card(
              child: ListTile(
                title: Text('$date  •  Intensity $intensity/10'),
                subtitle: Text(
                  [area, notes].where((s) => s.isNotEmpty).join(' — ').isEmpty
                      ? 'No extra notes'
                      : [area, notes].where((s) => s.isNotEmpty).join(' — '),
                ),
                trailing: IconButton(
                  tooltip: 'Delete this log',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteLog(id),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _MedicationForm extends StatefulWidget {
  final String uid;
  const _MedicationForm({required this.uid});

  @override
  State<_MedicationForm> createState() => _MedicationFormState();
}

class _MedicationFormState extends State<_MedicationForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _instructions = TextEditingController();
  final _times = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  bool _loading = true;
  List<String> _selectedTimes = [];
  List<Map<String, Object?>> _medications = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  String _formatTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  int _minutesSinceMidnight(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2}) (AM|PM)$').firstMatch(value);
    if (match == null) return 0;
    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final period = match.group(3)!;
    if (hour == 12) hour = 0;
    if (period == 'PM') hour += 12;
    return hour * 60 + minute;
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final initial = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      (now.minute ~/ 5) * 5,
    );
    var selected = initial;
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: scheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 340,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Choose reminder time',
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(selected),
                      child: const Text('Add time'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    brightness: Theme.of(sheetContext).brightness,
                    primaryColor: scheme.primary,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: false,
                    initialDateTime: initial,
                    minuteInterval: 1,
                    onDateTimeChanged: (value) => selected = value,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final formatted = _formatTime(picked);
    if (_selectedTimes.contains(formatted)) {
      _message('That reminder time is already selected.');
      return;
    }
    setState(() {
      _selectedTimes = [..._selectedTimes, formatted]
        ..sort(
          (a, b) =>
              _minutesSinceMidnight(a).compareTo(_minutesSinceMidnight(b)),
        );
      _times.text = _selectedTimes.join(', ');
    });
  }

  void _removeTime(String value) {
    setState(() {
      _selectedTimes.remove(value);
      _times.text = _selectedTimes.join(', ');
    });
  }

  Future<void> _reload() async {
    try {
      final records = await LocalDatabase.instance.getMedications(widget.uid);
      if (mounted) setState(() => _medications = records);
    } catch (e) {
      if (mounted) _message('Could not load medication schedule: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final times = List<String>.from(_selectedTimes);
      await LocalDatabase.instance.addMedication(
        uid: widget.uid,
        name: _name.text.trim(),
        prescribedInstructions: _instructions.text.trim(),
        times: times,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      _name.clear();
      _instructions.clear();
      _times.clear();
      _notes.clear();
      _selectedTimes.clear();
      await _reload();
      if (mounted)
        _message(
          'Medication schedule saved locally. Notifications are not enabled yet.',
        );
    } catch (e) {
      if (mounted) _message('Could not save medication: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deactivate(int id) async {
    try {
      await LocalDatabase.instance.setMedicationActive(
        uid: widget.uid,
        id: id,
        active: false,
      );
      await _reload();
      if (mounted) _message('Medication entry archived on this device.');
    } catch (e) {
      if (mounted) _message('Could not update medication: $e');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    _times.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const _PrivacyNote(
          text: 'Enter only medication names and instructions from a prescription or clinician. This screen stores the schedule; it does not advise doses or send reminders yet.',
        ),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Prescribed medication schedule',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Medication name',
                child: TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter the medication name.'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Prescribed instructions',
                child: TextFormField(
                  controller: _instructions,
                  decoration: const InputDecoration(
                    hintText: 'Copy from your prescription',
                  ),
                  minLines: 2,
                  maxLines: 3,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter the prescribed instructions.'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              const _FieldLabel('Reminder times (optional)'),
              const SizedBox(height: 7),
              TextFormField(
                controller: _times,
                readOnly: true,
                onTap: _pickTime,
                decoration: InputDecoration(
                  hintText: 'Tap to choose time(s) in AM/PM',
                  prefixIcon: const Icon(Icons.schedule_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Add reminder time',
                    onPressed: _pickTime,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ),
              ),
              if (_selectedTimes.isNotEmpty) ...[
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _selectedTimes
                      .map(
                        (time) => InputChip(
                          label: Text(time),
                          onDeleted: () => _removeTime(time),
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Notes (optional)',
                child: TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: Text(_saving ? 'Saving...' : 'Save schedule locally'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Saved medication entries',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_medications.isEmpty)
          const _EmptyLocalState(message: 'No medication entries saved yet.')
        else
          ..._medications.map((item) {
            final id = item['id'] as int;
            final name = (item['name'] as String?) ?? 'Medication';
            final instructions =
                (item['prescribed_instructions'] as String?) ?? '';
            final rawTimes = item['times_json'] as String? ?? '[]';
            var savedTimes = <String>[];
            try {
              final decoded = jsonDecode(rawTimes);
              if (decoded is List)
                savedTimes = decoded.whereType<String>().toList();
            } catch (_) {
              savedTimes = [];
            }
            final subtitleLines = <String>[
              if (instructions.isNotEmpty) instructions,
              if (savedTimes.isNotEmpty) 'Times: ${savedTimes.join(', ')}',
            ];
            return Card(
              child: ListTile(
                isThreeLine: savedTimes.isNotEmpty,
                title: Text(name),
                subtitle: Text(
                  subtitleLines.join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Archive medication entry',
                  icon: const Icon(Icons.archive_outlined),
                  onPressed: () => _deactivate(id),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [_FieldLabel(label), const SizedBox(height: 7), child],
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  final String text;
  const _PrivacyNote({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, color: colors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLocalState extends StatelessWidget {
  final String message;
  const _EmptyLocalState({required this.message});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
