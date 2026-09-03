# Clops

Clops is a native macOS menu-bar clipboard history app. It watches new copies, keeps a searchable local history, and lets you return a selected item to the app you were using.

## What works

- Text, rich text, images, and sandbox-safe Finder file references
- Duplicate-aware history that resurfaces repeat copies and recognizes rapid same-content copy bursts
- Search, keyboard navigation, pinned items, deletion, and clear-unpinned
- Row context menus for Copy, Copy as Plain Text, Pin, and Delete
- Layout-aware `⌃⌘V` picker shortcut with an automatic `⌃⌥⌘V` fallback when the primary shortcut is already in use
- Copy-only fallback that restores focus and shows a small confirmation HUD
- Pause/resume, retention and size limits, excluded applications, and launch at login
- macOS clipboard privacy onboarding and concealed/transient item filtering
- AES-GCM encrypted history with a device-local key stored in Keychain
- App Sandbox, hardened runtime, and no network entitlements or dependencies

## Requirements

- macOS 15.4 or newer
- Xcode 26 or newer

## Run it

1. Open `Clops.xcodeproj` in Xcode.
2. Select the **Clops** target, open **Signing & Capabilities**, and choose an Apple Development team. Clops includes the Keychain Sharing capability for its encrypted-history key; Xcode must sign that entitlement with your team. Stable signing is also needed for persistent privacy grants and Launch at Login. If Xcode has no valid Apple Development identity, open **Xcode Settings → Accounts → Manage Certificates**, create or download one, then clean and rebuild.
3. Run the **Clops** scheme.
4. Click the clipboard icon in the menu bar. Clops explains why access is needed before it reads anything.
5. Click **Enable**. On macOS 26 or newer, Clops deliberately reads the current clipboard so macOS can show its **Paste from Other Apps** prompt. Allow that requested read.
6. Choose **Always Allow** for Clops under **System Settings → Privacy & Security → Paste from Other Apps** so it can watch later copies in the background. If the clipboard was empty and no prompt appeared, copy something and click **Continue** first. macOS may ask you to quit and reopen Clops once after changing the setting.

For reliable **Launch at Login** testing, copy a validly signed `Clops.app` to `/Applications`, launch that copy, then enable it in Clops Settings. An Xcode DerivedData build can move or disappear on the next clean build. If macOS requires approval, Clops opens **System Settings → General → Login Items & Extensions**.

On macOS 15.x, Apple ships pasteboard privacy as a disabled developer preview. Unless that preview was enabled manually, Clops will report access as already allowed and no prompt or Paste from Other Apps entry will appear; no extra action is needed.

The Mac App Store Release build does not request Accessibility access or inject keystrokes into other apps. Choosing an item copies it, returns focus to the app you were using, and prompts you to press `⌘V`. Debug builds retain the optional one-step-paste implementation for development only.

Keychain access does not have an **Allow** dialog. If history reports error `-34018`, the running build is missing a valid signed Keychain entitlement. Re-select the Development Team, clean/rebuild Clops, and launch the newly built app. Unsigned builds are supported for tests only because tests inject a temporary encryption key.

If Clops reports that it cannot unlock encrypted history, try **Retry History Storage** first. A damaged file or a changed signing team/Keychain access group can make the old device key unavailable. Clops preserves the file unless you explicitly choose **Reset History Storage**, which permanently deletes that old history and creates a fresh encrypted store.

## Tests

```sh
xcodebuild test \
  -project Clops.xcodeproj \
  -scheme Clops \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The hosted test app uses temporary history, a private pasteboard, isolated defaults, and a fixed test key. It does not open the production history file or Keychain key.

## Distribution

See [MAC_APP_STORE.md](MAC_APP_STORE.md) for the release checklist and [PRIVACY.md](PRIVACY.md) for the public privacy policy.

## Privacy model

Clipboard history never leaves the Mac. Clops does not include analytics, sync, or networking code. History is encrypted before it is written to Application Support. Entries marked concealed, confidential, transient, or auto-generated are skipped, and individual source applications can be excluded in Settings.

At launch, Clops checks only macOS's clipboard-access status. It does not read the clipboard until you explicitly enable access; if that access is still unresolved on a later launch, Clops shows setup again before attempting another read.

Those pasteboard markers are voluntary, and macOS does not identify which process wrote a pasteboard change. Application exclusions use foreground-app transitions and are best-effort rather than a security boundary. Pause capture around especially sensitive work.

## Deliberate MVP limits

- `NSPasteboard` has no change notification, so Clops polls `changeCount`. It can recognize that several clipboard changes occurred inside one polling interval, but macOS exposes only the latest payload, so the burst count is best-effort and intermediate content cannot be recovered.
- File entries retain read-only security-scoped bookmarks. A moved or deleted file may still become unavailable.
- Context menus live inside the Clops picker. macOS has no supported API for injecting a universal item into every app’s right-click menu.
- The Mac App Store build intentionally uses copy-and-return rather than synthetic paste. Press `⌘V` in the restored destination app to finish pasting.
