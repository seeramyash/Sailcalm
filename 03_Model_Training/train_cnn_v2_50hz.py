#!/usr/bin/env python3
"""Train a compact, grouped-validation 1D CNN for 50 Hz tremor windows.

Accepts dataset_50hz.npz with X=[N,128,3] (public accelerometer data) or
X=[N,128,6] (device accelerometer+gyroscope data). Each window is centered,
then channel-wise normalization is fitted on training groups only. Those
preprocessing statistics are exported for firmware execution before INT8
quantization, then a full-integer INT8 TFLite model is exported.

This script intentionally does not mix 3-axis public data and 6-axis device
captures. A six-axis model must be trained with actual synchronized gyro data.
"""
from __future__ import annotations
import argparse
import csv
import json
import os
import random
import time
import warnings
from pathlib import Path

import numpy as np
from sklearn.metrics import (
    accuracy_score, balanced_accuracy_score, classification_report,
    confusion_matrix, f1_score, precision_score, recall_score,
)
from sklearn.model_selection import GroupShuffleSplit, StratifiedGroupKFold

SEED = 42
LABELS = [0, 1, 2, 3]
CLASS_NAMES = ["no_tremor", "mild", "moderate", "severe"]
FS_HZ = 50
WINDOW_N = 128


def set_seeds(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    os.environ.setdefault("PYTHONHASHSEED", str(seed))


def metric_dict(y_true: np.ndarray, y_pred: np.ndarray) -> dict:
    return {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "balanced_accuracy": float(balanced_accuracy_score(y_true, y_pred)),
        "macro_precision": float(precision_score(y_true, y_pred, labels=LABELS, average="macro", zero_division=0)),
        "macro_recall": float(recall_score(y_true, y_pred, labels=LABELS, average="macro", zero_division=0)),
        "macro_f1": float(f1_score(y_true, y_pred, labels=LABELS, average="macro", zero_division=0)),
        "weighted_f1": float(f1_score(y_true, y_pred, average="weighted", zero_division=0)),
    }


def save_evaluation(out_dir: Path, suffix: str, y_true: np.ndarray, y_pred: np.ndarray) -> dict:
    cm = confusion_matrix(y_true, y_pred, labels=LABELS)
    with (out_dir / f"confusion_matrix_cnn_v2_{suffix}.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["true_label", "predicted_0", "predicted_1", "predicted_2", "predicted_3"])
        for label, row in zip(LABELS, cm):
            writer.writerow([label, *[int(v) for v in row]])
    (out_dir / f"classification_report_cnn_v2_{suffix}.txt").write_text(
        classification_report(y_true, y_pred, labels=LABELS, target_names=CLASS_NAMES, zero_division=0),
        encoding="utf-8",
    )
    return classification_report(y_true, y_pred, labels=LABELS, target_names=CLASS_NAMES,
                                 zero_division=0, output_dict=True)


def check_dataset(npz_path: Path):
    if not npz_path.exists():
        raise FileNotFoundError(f"Dataset not found: {npz_path}")
    with np.load(npz_path, allow_pickle=False) as z:
        required = {"X", "y", "groups", "sources"}
        missing = required.difference(z.files)
        if missing:
            raise ValueError(f"Dataset is missing NPZ arrays: {sorted(missing)}")
        X = z["X"].astype(np.float32)
        y = z["y"].astype(np.int64).reshape(-1)
        groups = z["groups"].astype(str).reshape(-1)
        sources = z["sources"].astype(str).reshape(-1)
    if X.ndim != 3 or X.shape[1] != WINDOW_N or X.shape[2] not in (3, 6):
        raise ValueError(f"Expected X=[N,{WINDOW_N},3] or [N,{WINDOW_N},6], got {X.shape}")
    if not (len(X) == len(y) == len(groups) == len(sources)):
        raise ValueError("X/y/groups/sources lengths do not match")
    if not np.isfinite(X).all():
        raise ValueError("X has NaN or infinite values")
    if not np.isin(y, LABELS).all():
        raise ValueError("Labels must be 0, 1, 2, or 3")
    if len(np.unique(groups)) < 5:
        raise ValueError("At least five independent groups are needed for 5-fold grouped CV")
    counts = np.bincount(y, minlength=4)
    if np.any(counts == 0):
        raise ValueError(f"All four classes are required; found counts {counts.tolist()}")
    return X, y, groups, sources


def effective_class_alpha(y: np.ndarray) -> np.ndarray:
    """Mild inverse-frequency alpha for focal loss; avoid extreme minority weights."""
    counts = np.bincount(y, minlength=4).astype(np.float64)
    alpha = 1.0 / np.sqrt(np.maximum(counts, 1.0))
    alpha /= alpha.mean()
    return np.clip(alpha, 0.5, 2.0).astype(np.float32)


def build_cnn(tf, channels: int, seed: int):
    """Compact multi-scale/dilated CNN. Inputs are already fold-normalized."""
    tf.keras.utils.set_random_seed(seed)
    inp = tf.keras.Input(shape=(WINDOW_N, channels), name="normalized_imu_window")

    # A multi-scale stem captures short impacts and slower tremor cycles.
    stem = tf.keras.layers.Conv1D(12, 7, padding="same", use_bias=False, name="stem_conv")(inp)
    stem = tf.keras.layers.BatchNormalization(name="stem_bn")(stem)
    stem = tf.keras.layers.ReLU(name="stem_relu")(stem)

    b3 = tf.keras.layers.Conv1D(8, 3, padding="same", activation="relu", name="scale_k3")(stem)
    b7 = tf.keras.layers.Conv1D(8, 7, padding="same", activation="relu", name="scale_k7")(stem)
    b15 = tf.keras.layers.Conv1D(8, 15, padding="same", activation="relu", name="scale_k15")(stem)
    x = tf.keras.layers.Concatenate(name="multi_scale_concat")([b3, b7, b15])
    x = tf.keras.layers.Conv1D(24, 1, padding="same", use_bias=False, name="mix_projection")(x)
    x = tf.keras.layers.BatchNormalization(name="mix_bn")(x)
    x = tf.keras.layers.ReLU(name="mix_relu")(x)

    # Two small residual temporal blocks with larger effective receptive fields.
    for block, dilation in enumerate((1, 2), start=1):
        shortcut = x
        y = tf.keras.layers.Conv1D(24, 3, padding="same", dilation_rate=dilation,
                                   use_bias=False, name=f"res{block}_conv1")(x)
        y = tf.keras.layers.BatchNormalization(name=f"res{block}_bn1")(y)
        y = tf.keras.layers.ReLU(name=f"res{block}_relu1")(y)
        y = tf.keras.layers.Conv1D(24, 1, padding="same", use_bias=False,
                                   name=f"res{block}_conv2")(y)
        y = tf.keras.layers.BatchNormalization(name=f"res{block}_bn2")(y)
        x = tf.keras.layers.Add(name=f"res{block}_add")([shortcut, y])
        x = tf.keras.layers.ReLU(name=f"res{block}_out")(x)

    x = tf.keras.layers.AveragePooling1D(pool_size=2, name="time_pool")(x)
    x = tf.keras.layers.GlobalAveragePooling1D(name="temporal_average")(x)
    x = tf.keras.layers.Dense(24, activation="relu", name="classifier_dense")(x)
    x = tf.keras.layers.Dropout(0.20, name="classifier_dropout")(x)
    out = tf.keras.layers.Dense(4, activation="softmax", name="class_probabilities")(x)
    return tf.keras.Model(inp, out, name=f"neurosense_cnn_v2_{channels}axis")


def x_to_numpy_for_norm(X: np.ndarray) -> np.ndarray:
    """Remove each window's DC component before estimating channel scales."""
    return X - np.mean(X, axis=1, keepdims=True)


def fit_preprocessor(X_fit: np.ndarray) -> dict:
    """Estimate channel-wise mean/std from the fit groups only."""
    centered = x_to_numpy_for_norm(X_fit).astype(np.float32)
    mean = centered.mean(axis=(0, 1)).astype(np.float32)
    std = centered.std(axis=(0, 1)).astype(np.float32)
    std = np.maximum(std, 1e-4).astype(np.float32)
    return {"mean": mean, "std": std}


def preprocess_windows(X: np.ndarray, prep: dict) -> np.ndarray:
    """Must match cnn_tflm_runtime.h exactly: window DC removal, then channel z-score."""
    centered = x_to_numpy_for_norm(X).astype(np.float32)
    return ((centered - prep["mean"].reshape(1, 1, -1)) /
            prep["std"].reshape(1, 1, -1)).astype(np.float32)


def make_focal_loss(tf, y_fit: np.ndarray, gamma: float = 1.5):
    alpha = tf.constant(effective_class_alpha(y_fit), dtype=tf.float32)

    def loss(y_true, y_pred):
        y_idx = tf.cast(tf.reshape(y_true, [-1]), tf.int32)
        y_onehot = tf.one_hot(y_idx, depth=4)
        p_t = tf.reduce_sum(y_onehot * y_pred, axis=-1)
        a_t = tf.reduce_sum(y_onehot * alpha, axis=-1)
        p_t = tf.clip_by_value(p_t, 1e-7, 1.0)
        return tf.reduce_mean(-a_t * tf.pow(1.0 - p_t, gamma) * tf.math.log(p_t))

    return loss


def make_train_dataset(tf, X: np.ndarray, y: np.ndarray, batch_size: int, seed: int, prep: dict):
    """Augment raw training windows, then apply fold-local preprocessing."""
    channels = X.shape[-1]
    centered = x_to_numpy_for_norm(X)
    noise_std = np.maximum(np.std(centered, axis=(0, 1)) * 0.008, 1e-5).astype(np.float32)
    noise_tf = tf.constant(noise_std.reshape(1, 1, channels), dtype=tf.float32)
    mean_tf = tf.constant(prep["mean"].reshape(1, 1, channels), dtype=tf.float32)
    std_tf = tf.constant(prep["std"].reshape(1, 1, channels), dtype=tf.float32)

    def augment(xb, yb):
        batch = tf.shape(xb)[0]
        angles = tf.random.uniform(tf.stack([batch, 3]), minval=-0.18, maxval=0.18)
        rx, ry, rz = angles[:, 0], angles[:, 1], angles[:, 2]
        cx, sx = tf.cos(rx), tf.sin(rx)
        cy, sy = tf.cos(ry), tf.sin(ry)
        cz, sz = tf.cos(rz), tf.sin(rz)
        rows = [
            tf.stack([cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx], axis=-1),
            tf.stack([sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx], axis=-1),
            tf.stack([-sy, cy * sx, cy * cx], axis=-1),
        ]
        rotation = tf.stack(rows, axis=1)
        accel = tf.einsum("bti,bij->btj", xb[:, :, :3], rotation)
        accel *= tf.random.uniform(tf.stack([batch, 1, 1]), 0.94, 1.06)
        if channels == 6:
            gyro = tf.einsum("bti,bij->btj", xb[:, :, 3:6], rotation)
            gyro *= tf.random.uniform(tf.stack([batch, 1, 1]), 0.94, 1.06)
            out = tf.concat([accel, gyro], axis=-1)
        else:
            out = accel
        out += tf.random.normal(tf.shape(out), stddev=noise_tf)
        out = out - tf.reduce_mean(out, axis=1, keepdims=True)
        out = (out - mean_tf) / std_tf
        return out, yb

    ds = tf.data.Dataset.from_tensor_slices((X.astype(np.float32), y.astype(np.int64)))
    ds = ds.shuffle(min(len(X), 8192), seed=seed, reshuffle_each_iteration=True)
    ds = ds.batch(batch_size).map(augment, num_parallel_calls=tf.data.AUTOTUNE)
    return ds.prefetch(tf.data.AUTOTUNE)


def train_one(tf, X_fit, y_fit, X_val, y_val, epochs, batch_size, seed, out_model=None):
    prep = fit_preprocessor(X_fit)
    model = build_cnn(tf, int(X_fit.shape[-1]), seed)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=8e-4),
        loss=make_focal_loss(tf, y_fit),
        metrics=[tf.keras.metrics.SparseCategoricalAccuracy(name="accuracy")],
    )
    callbacks = [
        tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=9, restore_best_weights=True, min_delta=1e-4),
        tf.keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=4, min_lr=2e-5),
    ]
    train_ds = make_train_dataset(tf, X_fit, y_fit, batch_size, seed, prep)
    X_val_norm = preprocess_windows(X_val, prep)
    model.fit(train_ds, validation_data=(X_val_norm, y_val), epochs=epochs, verbose=0, callbacks=callbacks)
    if out_model is not None:
        model.save(out_model)
    return model, prep


def format_cpp_float(value: float) -> str:
    """Format a valid C++ float literal, including integral-valued floats."""
    rendered = format(float(value), ".10g")
    if "." not in rendered and "e" not in rendered.lower():
        rendered += ".0"
    return rendered + "f"


def write_tflite_header(flat: bytes, channels: int, prep: dict, output_path: Path) -> None:
    """Export model bytes and exact firmware-side normalization statistics."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        f.write("#pragma once\n#include <stdint.h>\n")
        f.write("const unsigned char g_tremor_cnn_model[] = {\n")
        for start in range(0, len(flat), 16):
            f.write("  " + ", ".join(str(v) for v in flat[start:start + 16]) + ",\n")
        f.write("};\nconst unsigned int g_tremor_cnn_model_len = sizeof(g_tremor_cnn_model);\n")
        f.write(f"static const unsigned int g_tremor_cnn_channel_count = {channels};\n")
        mean_txt = ", ".join(format_cpp_float(v) for v in prep["mean"])
        std_txt = ", ".join(format_cpp_float(v) for v in prep["std"])
        f.write(f"static const float g_tremor_cnn_channel_mean[{channels}] = {{{mean_txt}}};\n")
        f.write(f"static const float g_tremor_cnn_channel_std[{channels}] = {{{std_txt}}};\n")


def quantized_predictions(tf, model, X_train_norm, X_test_norm, y_test, out_dir: Path, seed: int, prep: dict):
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    rng = np.random.default_rng(seed)
    n_rep = min(500, len(X_train_norm))
    ids = rng.choice(len(X_train_norm), size=n_rep, replace=False)
    calibration = X_train_norm[ids]

    def representative_dataset():
        for row in calibration:
            yield [row[np.newaxis, ...].astype(np.float32)]

    converter.representative_dataset = representative_dataset
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    flat = converter.convert()
    tflite_path = out_dir / "tiny_1d_cnn_v2_int8.tflite"
    tflite_path.write_bytes(flat)

    interpreter = tf.lite.Interpreter(model_content=flat, num_threads=1)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    if input_detail["dtype"] != np.int8 or output_detail["dtype"] != np.int8:
        raise RuntimeError("Converter did not produce int8 input and output tensors")
    in_scale, in_zero = input_detail["quantization"]
    out_scale, out_zero = output_detail["quantization"]
    if in_scale <= 0 or out_scale <= 0:
        raise RuntimeError("Invalid tensor quantization scales")

    preds, probabilities = [], []
    t0 = time.perf_counter()
    for row in X_test_norm:
        q = np.clip(np.rint(row / in_scale + in_zero), -128, 127).astype(np.int8)
        interpreter.set_tensor(input_detail["index"], q[np.newaxis, ...])
        interpreter.invoke()
        raw = interpreter.get_tensor(output_detail["index"])[0]
        deq = (raw.astype(np.float32) - out_zero) * out_scale
        probabilities.append(deq)
        preds.append(int(np.argmax(deq)))
    elapsed = time.perf_counter() - t0
    pred = np.asarray(preds, dtype=np.int64)
    probs = np.asarray(probabilities, dtype=np.float32)
    save_evaluation(out_dir, "int8", y_test, pred)
    channels = int(X_test_norm.shape[-1])
    io = {
        "input_shape": input_detail["shape"].tolist(),
        "input_dtype": str(input_detail["dtype"]),
        "input_scale": float(in_scale), "input_zero_point": int(in_zero),
        "output_shape": output_detail["shape"].tolist(),
        "output_dtype": str(output_detail["dtype"]),
        "output_scale": float(out_scale), "output_zero_point": int(out_zero),
        "window_samples": WINDOW_N, "sampling_hz": FS_HZ,
        "channels": channels,
        "channel_order": ["ax_m_s2", "ay_m_s2", "az_m_s2"] if channels == 3 else
                         ["ax_m_s2", "ay_m_s2", "az_m_s2", "gx_rad_s", "gy_rad_s", "gz_rad_s"],
        "preprocessing_in_firmware": [
            "subtract each window's per-channel mean",
            "subtract channel mean estimated from training-fold centred windows",
            "divide by channel standard deviation estimated from training-fold centred windows",
        ],
        "preprocessing_channel_mean": [float(v) for v in prep["mean"]],
        "preprocessing_channel_std": [float(v) for v in prep["std"]],
        "classes": dict(enumerate(CLASS_NAMES)),
        "tflite_bytes": len(flat),
        "host_total_inference_seconds": elapsed,
        "host_us_per_window": elapsed * 1e6 / max(1, len(X_test_norm)),
        "host_timing_is_not_device_timing": True,
    }
    (out_dir / "cnn_v2_tflite_io.json").write_text(json.dumps(io, indent=2), encoding="utf-8")
    write_tflite_header(flat, channels, prep, out_dir / "tflite_model_data.h")
    try:
        ops = sorted({item["op_name"] for item in interpreter._get_ops_details()})
    except Exception:
        ops = []
    io["tflite_operator_names"] = ops
    (out_dir / "cnn_v2_tflite_io.json").write_text(json.dumps(io, indent=2), encoding="utf-8")
    return pred, metric_dict(y_test, pred), io


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=Path("prepared_50hz/dataset_50hz.npz"))
    parser.add_argument("--out", type=Path, default=Path("outputs_cnn_v2"))
    parser.add_argument("--folds", type=int, default=5)
    parser.add_argument("--epochs", type=int, default=70)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    set_seeds(args.seed)

    X, y, groups, sources = check_dataset(args.dataset)
    channels = X.shape[-1]
    print(f"X={X.shape}; channel_count={channels}; groups={len(np.unique(groups))}", flush=True)
    print(f"sources={dict(zip(*np.unique(sources, return_counts=True)))}", flush=True)
    print(f"class_counts={dict(zip(*np.unique(y, return_counts=True)))}", flush=True)
    class_group_coverage = {str(c): int(len(np.unique(groups[y == c]))) for c in LABELS}
    print(f"independent_groups_per_class={class_group_coverage}", flush=True)
    min_class_groups = args.folds + 1
    weak_classes = {c: n for c, n in class_group_coverage.items() if n < min_class_groups}
    if len(np.unique(groups)) < args.folds + 2 or weak_classes:
        raise SystemExit(
            f"Nested grouped evaluation needs at least {args.folds + 2} total groups and "
            f"at least {min_class_groups} independent groups containing each class. "
            f"Current total_groups={len(np.unique(groups))}, class_support={class_group_coverage}"
        )
    if channels == 3 and np.any(sources == "NeuroSense_Device_6axis"):
        raise ValueError("Dataset source metadata says 6-axis device data but X has 3 channels")
    if channels == 6 and np.any(sources != "NeuroSense_Device_6axis"):
        raise ValueError("6-axis training accepts only real NeuroSense_Device_6axis captures. Do not zero-pad or mix 3-axis public data into a 6-axis tensor.")

    try:
        import tensorflow as tf
    except Exception as exc:
        raise SystemExit(f"TensorFlow is required. Install requirements-cnn.txt. Import error: {exc}")

    if args.folds < 3 or args.folds > 10:
        raise SystemExit("--folds must be between 3 and 10")
    gpu_devices = tf.config.list_physical_devices("GPU")
    for gpu in gpu_devices:
        try:
            tf.config.experimental.set_memory_growth(gpu, True)
        except Exception:
            pass
    print(f"TensorFlow={tf.__version__}; visible_GPU_devices={[d.name for d in gpu_devices]}", flush=True)

    outer = StratifiedGroupKFold(n_splits=args.folds, shuffle=True, random_state=args.seed)
    splits = list(outer.split(X, y, groups))
    # Prefer a held-out group fold that contains every class; never split windows
    # from the same group across train/test merely to force class coverage.
    valid_outer = [(tr, te) for tr, te in splits if set(np.unique(y[te])) == set(LABELS)
                   and set(np.unique(y[tr])) == set(LABELS)
                   and len(np.unique(groups[tr])) >= args.folds]
    if not valid_outer:
        supports = [dict(zip(*np.unique(y[te], return_counts=True))) for _, te in splits]
        raise RuntimeError(f"No grouped held-out fold contains all four classes. Fold supports={supports}. Collect more independent groups per class or use fewer folds.")
    train_idx, test_idx = valid_outer[0]
    X_train, X_test = X[train_idx], X[test_idx]
    y_train, y_test = y[train_idx], y[test_idx]
    g_train, g_test = groups[train_idx], groups[test_idx]
    if set(g_train).intersection(set(g_test)):
        raise RuntimeError("Group leakage detected between final train and test folds")
    if set(np.unique(y_test)) != set(LABELS):
        raise RuntimeError("Selected held-out fold unexpectedly lacks a class")

    cv = StratifiedGroupKFold(n_splits=args.folds, shuffle=True, random_state=args.seed + 1)
    cv_splits = list(cv.split(X_train, y_train, g_train))
    cv_scores = []
    cv_supports = []
    for fold_no, (fit_idx, val_idx) in enumerate(cv_splits, start=1):
        if set(g_train[fit_idx]).intersection(set(g_train[val_idx])):
            raise RuntimeError("Group leakage inside CNN cross-validation")
        model, fold_prep = train_one(tf, X_train[fit_idx], y_train[fit_idx], X_train[val_idx], y_train[val_idx],
                                     args.epochs, args.batch_size, args.seed + fold_no)
        X_val_norm = preprocess_windows(X_train[val_idx], fold_prep)
        val_pred = model.predict(X_val_norm, batch_size=256, verbose=0).argmax(axis=1)
        score = float(f1_score(y_train[val_idx], val_pred, labels=LABELS, average="macro", zero_division=0))
        cv_scores.append(score)
        fold_support = {str(c): int((y_train[val_idx] == c).sum()) for c in LABELS}
        cv_supports.append(fold_support)
        print(f"CNN v2 fold {fold_no}/{args.folds}: Macro-F1={score:.4f}; class_support={fold_support}", flush=True)
        tf.keras.backend.clear_session()

    # Use a group-exclusive early-stopping set and prefer one containing all classes.
    inner = GroupShuffleSplit(n_splits=30, test_size=0.15, random_state=args.seed + 100)
    candidate_splits = list(inner.split(X_train, y_train, g_train))
    final_fit_rel, final_val_rel = max(
        candidate_splits,
        key=lambda pair: (len(set(np.unique(y_train[pair[1]])) & set(LABELS)),
                          -abs(len(pair[1]) / len(y_train) - 0.15)),
    )
    if set(np.unique(y_train[final_fit_rel])) != set(LABELS):
        raise RuntimeError("Final CNN fit subset lost a class; collect more group-level data")
    final_fit_idx, final_val_idx = train_idx[final_fit_rel], train_idx[final_val_rel]
    model, final_prep = train_one(tf, X[final_fit_idx], y[final_fit_idx], X[final_val_idx], y[final_val_idx],
                                  args.epochs, args.batch_size, args.seed, args.out / "cnn_v2_float.keras")
    X_test_norm = preprocess_windows(X_test, final_prep)
    X_fit_norm = preprocess_windows(X[final_fit_idx], final_prep)

    float_prob = model.predict(X_test_norm, batch_size=256, verbose=0)
    float_pred = float_prob.argmax(axis=1)
    float_class_report = save_evaluation(args.out, "float", y_test, float_pred)
    float_metrics = metric_dict(y_test, float_pred)
    q_pred, q_metrics, io = quantized_predictions(tf, model, X_fit_norm, X_test_norm, y_test, args.out, args.seed, final_prep)
    int8_class_report = classification_report(y_test, q_pred, labels=LABELS, target_names=CLASS_NAMES,
                                              zero_division=0, output_dict=True)
    all_results = {
        "model": f"neurosense_cnn_v2_{channels}axis",
        "sampling_hz": FS_HZ, "window_samples": WINDOW_N, "window_seconds": WINDOW_N / FS_HZ,
        "channels": channels,
        "channel_order": io["channel_order"],
        "preprocessing": io["preprocessing_in_firmware"],
        "preprocessing_channel_mean": io["preprocessing_channel_mean"],
        "preprocessing_channel_std": io["preprocessing_channel_std"],
        "n_windows": int(len(y)), "n_groups": int(len(np.unique(groups))),
        "group_overlap_train_test": False,
        "grouped_cv_fold_class_support": cv_supports,
        "held_out_group_count": int(len(np.unique(g_test))),
        "source_signal_audit": {
            str(src): {
                "windows": int((sources == src).sum()),
                "axis_mean": [float(v) for v in X[sources == src].reshape(-1, channels).mean(axis=0)],
                "axis_std": [float(v) for v in X[sources == src].reshape(-1, channels).std(axis=0)],
                "axis_p05_p50_p95": [[float(v) for v in np.percentile(X[sources == src].reshape(-1, channels)[:, c], [5, 50, 95])] for c in range(channels)],
            } for src in np.unique(sources)
        },
        "sources": {str(k): int(v) for k, v in zip(*np.unique(sources, return_counts=True))},
        "class_counts": {str(k): int(v) for k, v in zip(*np.unique(y, return_counts=True))},
        "independent_groups_per_class": class_group_coverage,
        "grouped_cv_macro_f1_mean": float(np.mean(cv_scores)),
        "grouped_cv_macro_f1_std": float(np.std(cv_scores, ddof=1) if len(cv_scores) > 1 else 0.0),
        "held_out_float_metrics": float_metrics,
        "held_out_int8_metrics": q_metrics,
        "held_out_float_per_class": {name: {k: float(v) for k, v in values.items() if isinstance(v, (int, float))}
                                      for name, values in float_class_report.items() if name in CLASS_NAMES},
        "held_out_int8_per_class": {name: {k: float(v) for k, v in values.items() if isinstance(v, (int, float))}
                                     for name, values in int8_class_report.items() if name in CLASS_NAMES},
        "int8_minus_float_macro_f1": float(q_metrics["macro_f1"] - float_metrics["macro_f1"]),
        "float_model_parameters": int(model.count_params()),
        "int8_tflite_bytes": int(io["tflite_bytes"]),
        "tflite_operator_names": io.get("tflite_operator_names", []),
        "limitations": [
            "The held-out fold is grouped by the groups array; subject-independent results require real subject IDs in groups.",
            "Public datasets in this package contain 3-axis accelerometer data only; they cannot train gyro effects.",
            "The 6-axis variant requires independently labelled XIAO captures with synchronized accelerometer and gyroscope channels.",
            "Firmware must apply the exported per-window centering and fold-channel normalization arrays before INT8 quantization; the CNN graph expects normalized input.",
            "All sensor units, orientation and preprocessing must match the glove's actual configuration; source_signal_audit is supplied for review, not proof of unit equivalence.",
            "ESP32-C3 latency, peak RAM, arena size and flash use require on-device measurement.",
            "This is a research classifier, not a clinical diagnostic device.",
        ],
    }
    (args.out / "cnn_v2_report.json").write_text(json.dumps(all_results, indent=2), encoding="utf-8")
    with (args.out / "cnn_v2_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["model", "cv_macro_f1_mean", "cv_macro_f1_std", "held_out_float_macro_f1",
                                                "held_out_int8_macro_f1", "held_out_float_balanced_accuracy",
                                                "held_out_int8_balanced_accuracy", "parameters", "int8_tflite_bytes"])
        writer.writeheader()
        writer.writerow({
            "model": all_results["model"],
            "cv_macro_f1_mean": all_results["grouped_cv_macro_f1_mean"],
            "cv_macro_f1_std": all_results["grouped_cv_macro_f1_std"],
            "held_out_float_macro_f1": float_metrics["macro_f1"],
            "held_out_int8_macro_f1": q_metrics["macro_f1"],
            "held_out_float_balanced_accuracy": float_metrics["balanced_accuracy"],
            "held_out_int8_balanced_accuracy": q_metrics["balanced_accuracy"],
            "parameters": model.count_params(),
            "int8_tflite_bytes": io["tflite_bytes"],
        })
    print(json.dumps(all_results, indent=2), flush=True)
    print(f"INT8 model exported: {args.out / 'tflite_model_data.h'}", flush=True)


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=UserWarning)
    main()
