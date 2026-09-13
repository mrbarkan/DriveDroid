# Architecture

DriveDroid mounts an Android phone in Finder over USB without MTP. Two parts, plus a library both share.

```
┌──────────────────────┐   host:track-devices-l   ┌────────────┐   USB   ┌─────────┐
│ DriveDroid.app       │ ───────────────────────▶ │ adb server │ ◀─────▶ │ adbd    │
│ (menu bar, unsandbox)│   NSFileProviderManager  │ :5037      │         │ (phone) │
│ adds/removes domains │                          └────────────┘         └─────────┘
└──────────────────────┘                                ▲
                                                        │ sync: / shell,v2:
┌──────────────────────┐   Finder / FileProvider        │
│ DriveDroidFileProvider│ ◀────────────────────────────┘
│ (sandboxed .appex)   │   one instance per domain (= per phone serial)
└──────────────────────┘
```

## Why ADB and not MTP or a block device

Android has no USB mass-storage mode any more; the storage partition is mounted by the phone, so it cannot be
handed to the Mac as a block device. MTP is the official replacement and is slow and flaky on macOS. ADB's sync
service is a plain length-prefixed protocol over USB that every Android device speaks, and it runs at USB speed.

## ADBKit (`Packages/ADBKit`)

Pure Swift client for the adb server. No adb binary needed at runtime by the extension.

- `ADBProtocol` — encoding/decoding only (host protocol framing, `sync` v2 stat/dent structs, shell v2 frames).
  Unit-tested; layouts mirror `file_sync_protocol.h` in AOSP.
- `ADBConnection` — one TCP connection to `127.0.0.1:5037` wrapped as an actor with async send/receive.
- `ADBClient` — `devices()`, `trackDevices()` stream, `shell()` (shell v2 so exit codes are real), `sync()`.
- `ADBSyncSession` — `stat` (`LST2`), `list` (`LIS2`), `pull` (`RECV`), `push` (`SEND`). v2 stat/list give
  64-bit sizes (Android 8+); v1 transfer messages are universal.

## The app

`DeviceMonitor` runs `adb start-server`, then holds a `host:track-devices-l` stream open. Every change reconciles
File Provider domains: one domain per device in state `device`, identifier = serial, display name = model.
Unplugging removes the domain, like ejecting a drive. The app is not sandboxed because it spawns adb, which needs
USB and a listening port.

## The extension

`NSFileProviderReplicatedExtension`. Item identifiers are paths relative to `/sdcard` (root container = `/`).
Every callback opens a fresh `sync:` or `shell` connection through the adb server; that is cheap (local TCP) and
avoids lifetime management.

| Finder action | What happens on the phone |
| --- | --- |
| browse a folder | `LIS2` |
| open a file | `RECV` into the domain's temporary directory, then handed to the system |
| save / drop a file | `SEND path,0644` |
| new folder | `shell mkdir -p` |
| rename / move | `shell mv`, then both parents are re-enumerated |
| delete | `shell rm -rf` (trash syncing is disabled on the domain) |

Change tracking is deliberately dumb: `enumerateChanges` always answers `syncAnchorExpired`, which makes the
system re-list the folder. There is no change journal on a phone, and the USB link makes re-listing cheap.

## Known simplifications

- Path-based identifiers mean a rename produces a "new" item. Finder copes because both parents are resignalled.
- Symlinks are shown as files; Finder-created metadata files (`._*`, `.DS_Store`) are written to the phone like
  any other file.
- Only shared storage (`/sdcard`) is exposed; that is all a non-root `adbd` can read anyway.
