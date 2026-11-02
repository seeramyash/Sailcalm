# Publish this project to GitHub

Repository: <https://github.com/seeramyash/Sailcalm>

## 1. Update the local submission folder

Extract `Group19_edge_SailmCalm_GitHub_Ready.zip` into `C:\Desktop` and choose **Replace files in the destination** when Windows asks. This merges the updated README, logo, animation, assets and publishing guide into the existing folder; it does not remove the local MP4/APK files that are not in the ZIP.

Expected project folder:

```text
C:\Desktop\Group19_edge_SailmCalm_final
```

Check these local deliverables before pushing:

- `Live_demo_Sailmcalm.mp4` in the project root (the demo video visible in your File Explorer screenshot; match its exact spelling/capitalisation).
- `assets\sailmcalm-logo.png` and `assets\sailmcalm-wave.gif`.
- Hardware and dashboard images under `assets\`.
- APK at `04_Android_Release\SailmCalm-app-release.apk` locally. It is excluded from normal Git commits and should be attached to a GitHub Release instead.

## 2. Clone the repository and copy the project into the clone

Run in PowerShell:

```powershell
cd C:\Desktop

git clone https://github.com/seeramyash/Sailcalm.git Sailcalm-github

Copy-Item -Path .\Group19_edge_SailmCalm_final\* `
  -Destination .\Sailcalm-github `
  -Recurse -Force

# Ensure the root ignore file is copied as well.
Copy-Item .\Group19_edge_SailmCalm_final\.gitignore `
  .\Sailcalm-github\.gitignore -Force

cd .\Sailcalm-github
git branch -M main
```

If `git clone` reports an authentication problem, sign in with Git Credential Manager and retry. If the repository already contains a README or other files, this copy merges the new project files into the existing clone; it does not delete other remote files.

## 3. Review and push

```powershell
git add -A
git status --short
git diff --cached --stat
```

Review the staged filenames. Confirm there are no real Wi-Fi credentials, patient records, private keys, service-account files, signing keystores or `.env` files. The `.gitignore` excludes the APK and generated build/cache folders.

Then push:

```powershell
git commit -m "Publish SailmCalm final source and project documentation"
git push -u origin main
```

## 4. Publish the APK as a GitHub Release

The APK is approximately 70 MB. Keep it out of regular Git history and attach it to a GitHub Release:

1. Open <https://github.com/seeramyash/Sailcalm/releases>.
2. Select **Draft a new release**.
3. Create tag `v1.0.0` (or use the next version if a release already exists).
4. Title it `SailmCalm Android Release v1.0.0`.
5. Attach `04_Android_Release\SailmCalm-app-release.apk` from your PC.
6. Keep the uploaded asset filename exactly `SailmCalm-app-release.apk`.
7. Publish the release.

The README's APK button points to:

<https://github.com/seeramyash/Sailcalm/releases/latest/download/SailmCalm-app-release.apk>

## 5. Verify the public repository

Open <https://github.com/seeramyash/Sailcalm> and check:

- The SailmCalm logo and animated GIF render in the README.
- The live demo link opens the MP4.
- Hardware and dashboard images display.
- The APK link downloads the release asset after the release is published.
- The firmware, TFLite Micro runtime, model header, Flutter source and model-training source are present.

Do not add Flutter `build/`, `.dart_tool/`, Python `.venv/`, raw private patient records, or model experiments that are not part of the deployed model.
