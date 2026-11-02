import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device accessibility and profile-photo preferences. No health data is uploaded.
class AppPreferences {
  AppPreferences._();

  static final ValueNotifier<double> textScale = ValueNotifier<double>(1.0);
  static final ValueNotifier<bool> reduceMotion = ValueNotifier<bool>(false);
  static final ValueNotifier<ImageProvider?> avatarImage = ValueNotifier<ImageProvider?>(null);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    textScale.value = (prefs.getDouble('sailmcalm_text_scale') ?? 1.0).clamp(0.9, 1.6).toDouble();
    reduceMotion.value = prefs.getBool('sailmcalm_reduce_motion') ?? false;
  }

  static Future<void> setTextScale(double value) async {
    final safe = value.clamp(0.9, 1.6).toDouble();
    textScale.value = safe;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('sailmcalm_text_scale', safe);
  }

  static Future<void> setReduceMotion(bool value) async {
    reduceMotion.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sailmcalm_reduce_motion', value);
  }

  static String _photoKey(String uid) => 'sailmcalm_profile_photo_$uid';

  static Future<void> loadAvatar(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_photoKey(uid));
    if (path == null || path.isEmpty || !await File(path).exists()) {
      avatarImage.value = null;
      return;
    }
    avatarImage.value = FileImage(File(path));
  }

  static Future<String> saveAvatar(String uid, String sourcePath) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/profile_photos');
    await directory.create(recursive: true);
    final extension = sourcePath.contains('.') ? sourcePath.split('.').last : 'jpg';
    final target = File('${directory.path}/profile_${uid.hashCode}.$extension');
    await File(sourcePath).copy(target.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoKey(uid), target.path);
    avatarImage.value = FileImage(target);
    return target.path;
  }

  static Future<void> clearAvatar(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_photoKey(uid));
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await prefs.remove(_photoKey(uid));
    avatarImage.value = null;
  }
}
