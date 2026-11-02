# CNN training source — scope and reproducibility note

`train_cnn_v2_50hz.py` is the training/export script corresponding to the deployed `neurosense_cnn_v2_3axis` model. It contains the network definition, preprocessing, grouped split/evaluation, augmentation, focal loss, INT8 quantization and C-header export code.

## Input required

The script expects a prepared NPZ dataset, by default:

```text
prepared_50hz/dataset_50hz.npz
```

The NPZ must contain arrays `X`, `y`, `groups`, and `sources`; `X` must be `[N,128,3]` for the deployed model. This submission deliberately does not bundle the public raw datasets or prepared NPZ file.

## Environment

The included `requirements-cnn.txt` reflects the core dependencies for this trainer. The recorded Windows training environment used Python 3.11, TensorFlow 2.18.0, NumPy 2.0.2 and scikit-learn 1.5.2.

## Run

From this folder, after placing the prepared dataset at the expected relative path:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\requirements-cnn.txt
.\.venv\Scripts\python.exe .\train_cnn_v2_50hz.py --dataset .\prepared_50hz\dataset_50hz.npz --out .\outputs_cnn_v2 --folds 5
```

The exported `tflite_model_data.h` should only replace the firmware header after checking the generated report, confusion matrices and preprocessing compatibility. Do not retrain or replace the currently deployed header as part of a normal firmware build.

**Reproducibility gap:** the preparation/normalization pipeline that assembled the public sources into `dataset_50hz.npz`, the source dataset files, and the original full training-run output directory are not included in this handoff. Therefore, this folder contains the actual trainer and deployment artifact, but is not a complete from-raw-data retraining archive. Obtain those exact inputs/scripts before claiming full end-to-end reproducibility in a paper.
