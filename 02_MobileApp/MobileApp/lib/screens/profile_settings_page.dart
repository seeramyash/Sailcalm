import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_preferences.dart';
import '../services/local_database.dart';
import 'local_records_page.dart';

class ProfileSettingsPage extends StatefulWidget {
  final String uid;
  const ProfileSettingsPage({super.key, required this.uid});

  @override
  State<ProfileSettingsPage> createState() => _ProfileSettingsPageState();
}

class _ProfileSettingsPageState extends State<ProfileSettingsPage> {
  final _name = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _photoPath;
  double _scale = 1.0;
  bool _reduceMotion = false;
  Map<String, Object?>? _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await AppPreferences.load();
      await AppPreferences.loadAvatar(widget.uid);
      final prefs = await SharedPreferences.getInstance();
      final profile = await LocalDatabase.instance.getProfile(widget.uid);
      if (!mounted) return;
      _profile = profile;
      _name.text = (profile?['display_name'] as String?) ?? '';
      _photoPath = prefs.getString('sailmcalm_profile_photo_${widget.uid}');
      _scale = AppPreferences.textScale.value;
      _reduceMotion = AppPreferences.reduceMotion.value;
    } catch (e) {
      if (mounted) _message('Could not load profile settings: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 900,
        maxHeight: 900,
        imageQuality: 86,
      );
      if (picked == null) return;
      final path = await AppPreferences.saveAvatar(widget.uid, picked.path);
      if (mounted) setState(() => _photoPath = path);
      _message('Profile photo saved on this device.');
    } catch (e) {
      _message('Could not choose profile photo: $e');
    }
  }

  Future<void> _removePhoto() async {
    await AppPreferences.clearAvatar(widget.uid);
    if (mounted) setState(() => _photoPath = null);
  }

  Future<void> _saveName() async {
    final newName = _name.text.trim();
    if (newName.isEmpty) {
      _message('Enter a display name first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final profile = _profile ?? <String, Object?>{};
      await LocalDatabase.instance.saveProfile(
        uid: widget.uid,
        displayName: newName,
        ageYears: profile['age_years'] as int?,
        diagnosisStatus: profile['diagnosis_status'] as String?,
        affectedSide: profile['affected_side'] as String?,
        symptomOnset: profile['symptom_onset'] as String?,
        clinicianNotes: profile['clinician_notes'] as String?,
        medicalConditions: profile['medical_conditions'] as String?,
        allergies: profile['allergies'] as String?,
        surgeries: profile['surgeries'] as String?,
        currentTreatments: profile['current_treatments'] as String?,
        emergencyContactName: profile['emergency_contact_name'] as String?,
        emergencyContactPhone: profile['emergency_contact_phone'] as String?,
      );
      _profile = await LocalDatabase.instance.getProfile(widget.uid);
      if (newName.isNotEmpty) {
        try {
          await FirebaseAuth.instance.currentUser?.updateDisplayName(newName);
        } catch (_) {
          // The local profile remains saved even if account profile sync is unavailable.
        }
      }
      if (mounted) _message('Display name saved.');
    } catch (e) {
      _message('Could not save name: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final colors = Theme.of(context).colorScheme;
    final photo = _photoPath;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile and accessibility')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: colors.primaryContainer,
                    backgroundImage: photo != null && File(photo).existsSync() ? FileImage(File(photo)) : null,
                    child: photo == null || !File(photo).existsSync()
                        ? Icon(Icons.person_outline, size: 48, color: colors.onPrimaryContainer)
                        : null,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo_library_outlined), label: const Text('Choose profile picture')),
                  if (photo != null) TextButton(onPressed: _removePhoto, child: const Text('Remove picture')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Display name', prefixIcon: Icon(Icons.badge_outlined)),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _saving ? null : _saveName, icon: const Icon(Icons.save_outlined), label: Text(_saving ? 'Saving…' : 'Save display name'))),
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
                  Text('Text size', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text('Increase text across SailmCalm for easier reading.'),
                  Row(children: [const Text('A', style: TextStyle(fontSize: 13)), Expanded(child: Slider(value: _scale, min: .9, max: 1.6, divisions: 7, label: '${(_scale * 100).round()}%', onChanged: (value) async { setState(() => _scale = value); await AppPreferences.setTextScale(value); })), const Text('A', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700))]),
                  Text('${(_scale * 100).round()}% text scale', style: TextStyle(color: colors.primary, fontWeight: FontWeight.w700)),
                  const Divider(height: 28),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _reduceMotion,
                    title: const Text('Reduce animations'),
                    subtitle: const Text('Reduce motion effects in supported screens.'),
                    onChanged: (value) async { setState(() => _reduceMotion = value); await AppPreferences.setReduceMotion(value); },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Medical background and medication'),
              subtitle: const Text('Diagnosis details, allergies, conditions, care notes and prescribed medicine schedule.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LocalRecordsPage(uid: widget.uid, initialTab: 0))),
            ),
          ),
          const SizedBox(height: 14),
          const Text('Profile photo and health records are stored locally on this device. The local AI report summarizer is optional and should be used only to summarize the information shown in reports; it does not provide medical advice.', style: TextStyle(fontSize: 12, height: 1.5)),
        ],
      ),
    );
  }
}
