import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Frozen Random Forest trained on the NeuroSense Glove workbook.
/// Its target is the firmware-reported status, not independently adjudicated
/// clinical tremor severity.
class GloveStatusModel {
  GloveStatusModel._({
    required List<String> featureNames,
    required List<String> classes,
    required List<double> imputerStatistics,
    required List<Map<String, dynamic>> trees,
  })  : _featureNames = featureNames,
        _classes = classes,
        _imputerStatistics = imputerStatistics,
        _trees = trees;

  final List<String> _featureNames;
  final List<String> _classes;
  final List<double> _imputerStatistics;
  final List<Map<String, dynamic>> _trees;

  static Future<GloveStatusModel> loadAsset({
    String assetPath = 'assets/models/glove_status_random_forest.json',
  }) async {
    final raw = await rootBundle.loadString(assetPath);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['schema_version'] != 1 ||
        decoded['model_type'] != 'RandomForestClassifier') {
      throw const FormatException('Unsupported Random Forest model file.');
    }

    final features = (decoded['feature_names'] as List<dynamic>)
        .map((e) => e.toString())
        .toList(growable: false);
    final classes = (decoded['classes'] as List<dynamic>)
        .map((e) => e.toString())
        .toList(growable: false);
    final statistics = (decoded['imputer_statistics'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    final trees = (decoded['trees'] as List<dynamic>)
        .map((tree) => Map<String, dynamic>.from(tree as Map))
        .toList(growable: false);

    if (features.length != 2 ||
        statistics.length != features.length ||
        classes.isEmpty ||
        trees.isEmpty) {
      throw const FormatException('Random Forest model file is incomplete.');
    }
    return GloveStatusModel._(
      featureNames: features,
      classes: classes,
      imputerStatistics: statistics,
      trees: trees,
    );
  }

  /// Uses the same frequency and amplitude fields that were used to train
  /// this model. The firmware-reported status is not passed into the model.
  GloveStatusPrediction predictFromApiCurrent(Map<String, dynamic> current) {
    final tremorValue = current['tremor'];
    if (tremorValue is! Map) {
      throw const FormatException('Missing current.tremor object in API data.');
    }
    final tremor = Map<String, dynamic>.from(tremorValue);
    final values = <String, double>{
      'Tremor Frequency': _apiNumberOrFallback(
        tremor['frequency'],
        _imputerStatistics[0],
        'tremor.frequency',
      ),
      'Tremor Amplitude': _apiNumberOrFallback(
        tremor['amplitude'],
        _imputerStatistics[1],
        'tremor.amplitude',
      ),
    };
    return predict(values);
  }

  GloveStatusPrediction predict(Map<String, double> featureValues) {
    final input = <double>[];
    for (var i = 0; i < _featureNames.length; i++) {
      final name = _featureNames[i];
      final value = featureValues[name];
      if (value == null || !value.isFinite) {
        throw FormatException('Missing or invalid model feature: $name');
      }
      // scikit-learn decision trees evaluate float32 input values. Match that
      // conversion to preserve the frozen model's split decisions exactly.
      input.add(_toFloat32(value));
    }

    final probabilities = List<double>.filled(_classes.length, 0.0);
    for (final tree in _trees) {
      final left = (tree['left'] as List<dynamic>).cast<num>();
      final right = (tree['right'] as List<dynamic>).cast<num>();
      final feature = (tree['feature'] as List<dynamic>).cast<num>();
      final threshold = (tree['threshold'] as List<dynamic>).cast<num>();
      final values = tree['value'] as List<dynamic>;

      var node = 0;
      while (feature[node].toInt() >= 0) {
        final featureIndex = feature[node].toInt();
        node = input[featureIndex] <= threshold[node].toDouble()
            ? left[node].toInt()
            : right[node].toInt();
      }

      final leaf = (values[node] as List<dynamic>).cast<num>();
      final total = leaf.fold<double>(0.0, (sum, value) => sum + value.toDouble());
      if (total > 0) {
        for (var i = 0; i < probabilities.length; i++) {
          probabilities[i] += leaf[i].toDouble() / total;
        }
      }
    }

    for (var i = 0; i < probabilities.length; i++) {
      probabilities[i] /= _trees.length;
    }

    var bestIndex = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[bestIndex]) bestIndex = i;
    }

    final scores = <String, double>{};
    for (var i = 0; i < _classes.length; i++) {
      scores[_classes[i]] = probabilities[i];
    }
    return GloveStatusPrediction(
      status: _classes[bestIndex],
      modelScore: probabilities[bestIndex],
      classScores: Map.unmodifiable(scores),
    );
  }

  static double _apiNumberOrFallback(dynamic value, double fallback, String name) {
    if (value == null) return fallback;
    if (value is num && value.toDouble().isFinite) return value.toDouble();
    throw FormatException('Invalid API value: $name');
  }

  static double _toFloat32(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getFloat32(0, Endian.little);
  }
}

class GloveStatusPrediction {
  const GloveStatusPrediction({
    required this.status,
    required this.modelScore,
    required this.classScores,
  });

  final String status;
  /// Average per-tree class score. It is not a calibrated clinical probability.
  final double modelScore;
  final Map<String, double> classScores;

  String get modelScorePercent =>
      '${(math.max(0, math.min(1, modelScore)) * 100).round()}%';
}
