# libperfmgr for HyperOS & AOSP

[![Build](https://github.com/Ctps1234/libperfmgr/actions/workflows/build.yml/badge.svg)](https://github.com/Ctps1234/libperfmgr/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Ctps1234/libperfmgr?color=blue)](https://github.com/Ctps1234/libperfmgr/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](NOTICE.md)

*Read this in [Português](README.pt-BR.md).*

---

A systemless **KernelSU**, **KernelSU Next**, **Magisk**, and **APatch** module that ports the official Google Pixel **libperfmgr** stack to **HyperOS** and **AOSP** custom ROMs.

It provides the complete userland power management framework:
- **`libperfmgr.so`** — Google's modern C++ performance manager.
- **`android.hardware.power-service.pixel-libperfmgr`** — Native Power HAL AIDL service with **ADPF** (*Android Dynamic Performance Framework* / hint sessions for frame pacing).
- **`sendhint`** — Command-line utility to trigger power and performance hints manually.
- **On-device `powerhint.json` generator** — Generates calibrated CPU/GPU frequencies and uclamp curves tailored specifically to your device kernel.

---

## 🚀 Key Features

1. **Native ADPF Support (SurfaceFlinger Frame Pacing)**:
   - Direct uclamp boost for rendering threads (TIDs), keeping 60 / 90 / 120 FPS rock-solid without jitter.
2. **Device-Specific Calibration**:
   - Probes `/sys/devices/system/cpu/cpufreq/` clusters and Adreno/Mali GPU nodes at installation.
   - Generates only valid, writable sysfs paths without hardcoded device values.
3. **Optimized Battery & Smooth Profile**:
   - CPU `LAUNCH` boost (1200ms) and micro `INTERACTION` touch pulse (250ms).
   - For **HyperOS Blur** composition, the GPU gets only an intermediate step: **450ms** on launch, **120ms** on touch, and **48ms** for `DISPLAY_UPDATE_IMMINENT`. It never forces maximum frequency or a permanent GPU floor.
   - Deep sleep friendly (`Race-to-Sleep`): keeps background standby drain as low as ~0.3% - 0.5% per hour.
4. **Universal Multi-Architecture Support**:
   - **`api34` (Pixel 5 Snapdragon)**: 100% ARMv8.0 compatible (Snapdragon 680, 685, 765G, older Cortex-A73/A53). No `Illegal instruction` errors.
   - **`api35` (Pixel Tensor Android 15)**: Power AIDL V5 for modern devices.
   - **`api36` (Pixel Tensor Android 16+)**: Power AIDL V6 for bleeding-edge ROMs.
5. **Port ROM Compatibility**:
   - Automatic execution wrappers (`LD_LIBRARY_PATH=/system/lib64:/vendor/lib64`) resolving missing symbols across hybrid system/vendor splits.
6. **Zero-Bootloop Safety Guard**:
   - Services wait for `sys.boot_completed=1` before switching HALs in runtime, preventing any bootanimation hang or white screen.

---

## 📦 Compatibility

- **Supported Root Solutions**: KernelSU, KernelSU Next, Magisk (v24+), APatch.
  *(Note for KernelSU: `meta-overlayfs` metamodule is recommended for `/vendor` partition mounting).*
- **Supported ROMs**:
  - HyperOS 1.0, 2.0, 3.0, 4.0 (including ports with A17 system + A15 vendor).
  - AOSP Custom ROMs (LineageOS, PixelOS, Evolution X, crDroid, etc.).
- **Supported Architectures**: `arm64-v8a` (ARMv8.0-A up to ARMv9-A).

---

## 📥 Installation

1. Download the latest **`libperfmgr-hyperos-v*.zip`** from [GitHub Actions Artifacts](../../actions) or [Releases](../../releases).
2. Open your Root Manager (KernelSU / Magisk / APatch) ➡️ **Modules** ➡️ **Install from storage**.
3. Select the ZIP and flash it.
4. Reboot your device.

The module starts in **Active & Safe Mode** automatically after the home screen loads!

---

## 🛠️ CLI Management (`action.sh`)

You can control and check the status of the module via Termux / Root Shell:

```sh
su
# Check current status, active HAL, and registered binder services:
/data/adb/modules/libperfmgr-hyperos/action.sh status

# Toggle Power HAL service:
/data/adb/modules/libperfmgr-hyperos/action.sh hal on|off

# Toggle sysfs powerhint boosts:
/data/adb/modules/libperfmgr-hyperos/action.sh hints on|off

# View execution logs:
/data/adb/modules/libperfmgr-hyperos/action.sh log
```

### Manual Hint Testing (`sendhint`):

```sh
su
# Test App Launch boost (1200ms):
/vendor/bin/sendhint -b LAUNCH -d 1200

# Test Touch Interaction boost (250ms):
/vendor/bin/sendhint -b INTERACTION -d 250
```

---

## ⚙️ Configuration Files

- **Persistent Configuration**: `/data/adb/libperfmgr/perfmgr.conf` (survives module updates):
  ```ini
  ENABLE_HAL=0
  ENABLE_HINTS=0
  START_METHOD=auto
  OVERRIDE_STOCK=0
  ALLOW_STOCK_OVERRIDE=0
  FORCE_VARIANT=auto
  ```
- **Custom Powerhint**: `/data/adb/libperfmgr/powerhint.json` (user-editable frequency and boost table).

### HyperOS Power HAL safety

On devices that already ship a power HAL, a new installation keeps the stock HAL, hints, and override **off**. `action.sh hal on` is deliberately blocked there so the power provider is never switched while composition is running — that can cause a white screen.

To use the full perfmgr stack and the Blur profile, make the choice once and reboot:

```sh
su
/data/adb/modules/libperfmgr-hyperos/action.sh override on
/data/adb/modules/libperfmgr-hyperos/action.sh hints on
reboot
```

The commands restore the module manifest, schedule hints, and write a second confirmation (`ALLOW_STOCK_OVERRIDE=1`); replacement only happens after Android finishes booting. **On later boots the HAL and hints start automatically** — do not start it through `hal on`. `action.sh override off` cancels replacement for the next boot. Old configurations with only `OVERRIDE_STOCK=1` can no longer activate replacement. If an override fails to boot, create the `disable` file in `/data/adb/modules/libperfmgr-hyperos/` or use your root manager's safe mode.

### Balanced Blur profile

When regenerating, the module selects two valid GPU frequency steps: the first above idle for app launch and the next one for the first touch/Blur frame. The `DISPLAY_UPDATE_IMMINENT` pulse is only **48 ms**, so a long animation is not turned into a sustained maximum-frequency request. This helps Blur entry and transitions while keeping idle consumption unchanged.

Existing persistent configurations are kept on module updates. To apply this profile to an existing powerhint file, run the following as root and **reboot the device**; do not restart the HAL manually:

```sh
/data/adb/modules/libperfmgr-hyperos/action.sh regen
reboot
```

---

## 📄 License & Attribution

- Shipped prebuilt binaries are extracted from official Google Pixel factory images under Google proprietary terms. See [NOTICE.md](NOTICE.md).
- Module scripts, wrappers, and tools are licensed under the Apache License 2.0.
