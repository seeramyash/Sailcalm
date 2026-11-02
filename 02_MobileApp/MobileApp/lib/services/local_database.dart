import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Encrypted, on-device storage for SailmCalm health information.
///
/// Firebase Authentication is used only to identify the signed-in account.
/// Every health record is scoped by Firebase UID and stays in this local DB.
/// This service requires Android/iOS/macOS; it is not a web database.
class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();

  static const _secureStorage = FlutterSecureStorage();
  static const _keyName = 'sailmcalm_sqlcipher_key_v1';
  static const _dbName = 'sailmcalm_health.db';
  static const _dbVersion = 2;

  Database? _db;

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;

    final supportDir = await getApplicationSupportDirectory();
    final path = p.join(supportDir.path, _dbName);
    final key = await _getOrCreateDatabaseKey();

    _db = await openDatabase(
      path,
      password: key,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE health_profiles (
            uid TEXT PRIMARY KEY,
            display_name TEXT,
            age_years INTEGER,
            diagnosis_status TEXT,
            affected_side TEXT,
            symptom_onset TEXT,
            clinician_notes TEXT,
            medical_conditions TEXT,
            allergies TEXT,
            surgeries TEXT,
            current_treatments TEXT,
            emergency_contact_name TEXT,
            emergency_contact_phone TEXT,
            updated_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE medications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uid TEXT NOT NULL,
            name TEXT NOT NULL,
            prescribed_instructions TEXT NOT NULL,
            times_json TEXT NOT NULL DEFAULT '[]',
            notes TEXT,
            active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_medications_uid ON medications(uid, active)',
        );

        await db.execute('''
          CREATE TABLE daily_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uid TEXT NOT NULL,
            log_date TEXT NOT NULL,
            perceived_intensity INTEGER,
            duration_minutes INTEGER,
            affected_area TEXT,
            activity TEXT,
            possible_trigger TEXT,
            medication_taken INTEGER,
            notes TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_daily_logs_uid_date ON daily_logs(uid, log_date)',
        );

        await db.execute('''
          CREATE TABLE episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uid TEXT NOT NULL,
            recorded_at TEXT NOT NULL,
            duration_seconds REAL,
            frequency_hz REAL,
            amplitude REAL,
            predicted_class INTEGER,
            model_confidence REAL,
            signal_quality TEXT,
            source TEXT NOT NULL DEFAULT 'local_model'
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_episodes_uid_time ON episodes(uid, recorded_at)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE health_profiles ADD COLUMN medical_conditions TEXT');
          await db.execute('ALTER TABLE health_profiles ADD COLUMN allergies TEXT');
          await db.execute('ALTER TABLE health_profiles ADD COLUMN surgeries TEXT');
          await db.execute('ALTER TABLE health_profiles ADD COLUMN current_treatments TEXT');
        }
      },
    );

    return _db!;
  }

  Future<String> _getOrCreateDatabaseKey() async {
    final existing = await _secureStorage.read(key: _keyName);
    if (existing != null && existing.isNotEmpty) return existing;

    // Store a random per-install SQLCipher key in platform secure storage.
    // Never hard-code the key or store it in the health database itself.
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = base64UrlEncode(bytes);
    await _secureStorage.write(key: _keyName, value: key);
    return key;
  }

  Future<void> saveProfile({
    required String uid,
    String? displayName,
    int? ageYears,
    String? diagnosisStatus,
    String? affectedSide,
    String? symptomOnset,
    String? clinicianNotes,
    String? medicalConditions,
    String? allergies,
    String? surgeries,
    String? currentTreatments,
    String? emergencyContactName,
    String? emergencyContactPhone,
  }) async {
    final db = await database;
    await db.insert(
      'health_profiles',
      {
        'uid': uid,
        'display_name': displayName,
        'age_years': ageYears,
        'diagnosis_status': diagnosisStatus,
        'affected_side': affectedSide,
        'symptom_onset': symptomOnset,
        'clinician_notes': clinicianNotes,
        'medical_conditions': medicalConditions,
        'allergies': allergies,
        'surgeries': surgeries,
        'current_treatments': currentTreatments,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getProfile(String uid) async {
    final db = await database;
    final rows = await db.query(
      'health_profiles',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> addMedication({
    required String uid,
    required String name,
    required String prescribedInstructions,
    List<String> times = const [],
    String? notes,
  }) async {
    final db = await database;
    return db.insert('medications', {
      'uid': uid,
      'name': name.trim(),
      'prescribed_instructions': prescribedInstructions.trim(),
      'times_json': jsonEncode(times),
      'notes': notes,
      'active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getMedications(
    String uid, {
    bool activeOnly = true,
  }) async {
    final db = await database;
    return db.query(
      'medications',
      where: activeOnly ? 'uid = ? AND active = 1' : 'uid = ?',
      whereArgs: [uid],
      orderBy: 'id DESC',
    );
  }

  Future<int> setMedicationActive({
    required String uid,
    required int id,
    required bool active,
  }) async {
    final db = await database;
    return db.update(
      'medications',
      {'active': active ? 1 : 0},
      where: 'uid = ? AND id = ?',
      whereArgs: [uid, id],
    );
  }

  Future<int> deleteMedication({
    required String uid,
    required int id,
  }) async {
    final db = await database;
    return db.delete(
      'medications',
      where: 'uid = ? AND id = ?',
      whereArgs: [uid, id],
    );
  }

  Future<int> addDailyLog({
    required String uid,
    required String logDate,
    int? perceivedIntensity,
    int? durationMinutes,
    String? affectedArea,
    String? activity,
    String? possibleTrigger,
    bool? medicationTaken,
    String? notes,
  }) async {
    if (perceivedIntensity != null &&
        (perceivedIntensity < 0 || perceivedIntensity > 10)) {
      throw ArgumentError.value(
        perceivedIntensity,
        'perceivedIntensity',
        'Must be between 0 and 10',
      );
    }
    if (durationMinutes != null && durationMinutes < 0) {
      throw ArgumentError.value(durationMinutes, 'durationMinutes');
    }

    final db = await database;
    return db.insert('daily_logs', {
      'uid': uid,
      'log_date': logDate,
      'perceived_intensity': perceivedIntensity,
      'duration_minutes': durationMinutes,
      'affected_area': affectedArea,
      'activity': activity,
      'possible_trigger': possibleTrigger,
      'medication_taken': medicationTaken == null
          ? null
          : (medicationTaken ? 1 : 0),
      'notes': notes,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getDailyLogs(
    String uid, {
    int limit = 100,
  }) async {
    final db = await database;
    return db.query(
      'daily_logs',
      where: 'uid = ?',
      whereArgs: [uid],
      orderBy: 'log_date DESC, id DESC',
      limit: limit,
    );
  }

  Future<int> deleteDailyLog({
    required String uid,
    required int id,
  }) async {
    final db = await database;
    return db.delete(
      'daily_logs',
      where: 'uid = ? AND id = ?',
      whereArgs: [uid, id],
    );
  }

  Future<int> addEpisode({
    required String uid,
    required String recordedAt,
    double? durationSeconds,
    double? frequencyHz,
    double? amplitude,
    int? predictedClass,
    double? modelConfidence,
    String? signalQuality,
    String source = 'local_model',
  }) async {
    final db = await database;
    return db.insert('episodes', {
      'uid': uid,
      'recorded_at': recordedAt,
      'duration_seconds': durationSeconds,
      'frequency_hz': frequencyHz,
      'amplitude': amplitude,
      'predicted_class': predictedClass,
      'model_confidence': modelConfidence,
      'signal_quality': signalQuality,
      'source': source,
    });
  }

  Future<List<Map<String, Object?>>> getEpisodes(
    String uid, {
    int limit = 200,
  }) async {
    final db = await database;
    return db.query(
      'episodes',
      where: 'uid = ?',
      whereArgs: [uid],
      orderBy: 'recorded_at DESC, id DESC',
      limit: limit,
    );
  }

  Future<void> deleteAllHealthDataForUser(String uid) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('health_profiles', where: 'uid = ?', whereArgs: [uid]);
      await txn.delete('medications', where: 'uid = ?', whereArgs: [uid]);
      await txn.delete('daily_logs', where: 'uid = ?', whereArgs: [uid]);
      await txn.delete('episodes', where: 'uid = ?', whereArgs: [uid]);
    });
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
