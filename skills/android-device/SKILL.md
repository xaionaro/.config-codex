---
name: android-device
description: Use when working with Android phones or tablets — fastboot, adb, flashing, kernel updates, device debugging.
---

# Android Device Operations

**User data is sacred.** `fastboot erase userdata`, `fastboot erase metadata`, `fastboot -w`, and factory reset require explicit user request. Erasing user data is never a side effect of another operation.

## Device Health

Handle health checks and routine fixes in-place in the current session; they generally do not need a separate agent.

Before calling a device healthy, check for crash handlers: `adb shell pgrep -a crash_dump64` (or `adb shell ps -A | grep '[c]rash_dump64'` if `pgrep` is unavailable). Any running `crash_dump64` process means the device is unhealthy; investigate crashes before flashing, benchmarking, or reporting success.
