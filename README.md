# DriveDroid

Your Android phone in Finder, over USB, without MTP.

DriveDroid is a macOS menu bar app plus a File Provider extension (the same mechanism Dropbox and Google Drive
use). Plug in a phone with USB debugging enabled and it appears in the Finder sidebar. Browse, open, copy, rename,
delete. Files transfer over ADB at USB speed; nothing is synced until you open it.

- macOS 15 or newer, Apple silicon or Intel
- Any Android 8+ phone with USB debugging on
- No app to install on the phone

## Install

1. Install adb (`brew install --cask android-platform-tools`). Android Studio's platform-tools work too. <a id="install-adb"></a>
2. Download `DriveDroid.dmg` from [Releases](https://github.com/mrbarkan/DriveDroid/releases), drag the app to
   Applications, launch it. It lives in the menu bar.
3. On the phone: Settings → About phone → tap *Build number* seven times, then Settings → System → Developer
   options → *USB debugging* on.
4. Plug in the phone. Tap **Allow** on the "Allow USB debugging?" prompt (tick *Always allow*).
5. The phone shows up in the Finder sidebar under Locations. The menu bar icon also has *Open in Finder*.

Unplugging the phone removes it from Finder, like ejecting a drive.

## How it works

The app keeps the adb server running and follows its device list. For each authorized phone it registers a
File Provider domain. The extension speaks the adb `sync` protocol directly to the local adb server, so
listing, downloading and uploading go straight over USB. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Only shared storage (`/sdcard`) is exposed; that is what a non-root `adbd` can read.

## Build from source

```sh
brew install xcodegen android-platform-tools
git clone https://github.com/mrbarkan/DriveDroid && cd DriveDroid
cp Local.xcconfig.example Local.xcconfig   # put your Apple Developer team ID in it
xcodegen generate
open DriveDroid.xcodeproj                  # Run the DriveDroid scheme
```

A team ID is required because File Provider extensions must be signed. A free Apple Developer account is enough
for running locally; a paid one is needed for Developer ID + notarization.

Unit tests for the protocol layer:

```sh
cd Packages/ADBKit && swift test
ADB_SERVER_TESTS=1 swift test   # also talks to a running adb server
```

## Release build (signed + notarized DMG)

One time: store notarization credentials in the keychain.

```sh
xcrun notarytool store-credentials DriveDroid \
  --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
```

Then:

```sh
scripts/release.sh                 # archive, Developer ID sign, notarize, staple, DMG in build/release/
SKIP_NOTARIZE=1 scripts/release.sh # sign only
```

## Troubleshooting

- **Phone missing from the menu.** Run `adb devices`. `unauthorized` means tap Allow on the phone. Nothing listed
  means the cable is charge-only or USB debugging is off.
- **Folder in Finder is empty or stuck.** Check `log stream --predicate 'subsystem == "com.mrbarkan.DriveDroid"'`.
- **Extension not showing up after building from source.** Launch the app once from Xcode; macOS registers the
  extension on first launch. `pluginkit -m -i com.mrbarkan.DriveDroid.FileProvider` should list it.
- **Files over 4 GB show the wrong size.** Your phone is older than Android 8 and lacks `stat_v2`; open an issue.

## License

MIT
