# Mac App Store Submission Checklist

This checklist covers the project configuration and the manual App Store Connect work for Clops.

## In the project

- [x] Bundle identifier is `com.seamoss.Clops`.
- [x] App Sandbox and hardened runtime are enabled for Debug and Release.
- [x] Entitlements are limited to app sandbox, read-only user-selected files, app-scoped security bookmarks, and the app's own Keychain access group.
- [x] Incoming and outgoing network entitlements are disabled.
- [x] Launch at Login uses `SMAppService.mainApp` and requires an explicit user action.
- [x] Clipboard permission is explained before use.
- [x] The Release configuration compiles out Accessibility requests and synthetic Command-V events; history selection uses copy-and-return instead.
- [x] `PrivacyInfo.xcprivacy` declares no tracking or off-device collection and documents the required-reason APIs used by the code.
- [x] `ITSAppUsesNonExemptEncryption` is `false`; Clops uses Apple's CryptoKit implementation for local AES-GCM history encryption. Confirm the answers in App Store Connect for every release territory.
- [x] A public privacy policy is linked from the app.
- [x] A complete 10-size macOS `AppIcon` asset catalog is selected for Debug and Release.

## App Store Connect

- [ ] Create the macOS app record for `com.seamoss.Clops`.
- [ ] Confirm the registered App ID and Mac App Store provisioning profile authorize the app's Keychain access group.
- [ ] Set the Privacy Policy URL to `https://github.com/seamoss/Clops/blob/main/PRIVACY.md`.
- [ ] Answer App Privacy with **No, we do not collect data from this app** while Clops remains local-only and network-free.
- [ ] Complete the export-compliance questionnaire consistently with the Info.plist declaration.
- [ ] Set Copyright to `2026 <legal rights holder>` and replace the generic owner in `NSHumanReadableCopyright` with the same person or entity.
- [ ] Select the Productivity category, complete the age-rating questionnaire, and choose pricing and availability.
- [ ] Upload at least one representative macOS screenshot that contains no private clipboard data.
- [ ] Provide support and marketing URLs as required by the selected storefronts.

## Review notes

Explain these non-obvious behaviors to App Review:

- Clops is a menu-bar utility, so it intentionally has no Dock icon or conventional main window.
- Background history starts only after the user enables it and approves **Paste from Other Apps** access.
- Choosing a history item copies it and restores the previously active app. The Mac App Store Release build does not request Accessibility access or inject Command-V; the user completes the paste with Command-V.
- Launch at Login is off by default and is enabled only through the user's setting.
- Clipboard history remains on the Mac and can be deleted from **Settings → History & Privacy**.

## Validate the release

- [ ] Increment `CURRENT_PROJECT_VERSION` for every uploaded build and set the release `MARKETING_VERSION`.
- [ ] Archive the Release configuration with the Mac App Distribution certificate and Mac App Store provisioning profile.
- [ ] Run Xcode's **Validate App** and resolve every error before upload.
- [ ] Generate Xcode's privacy report from the archive and compare it with the App Privacy answers.
- [ ] Inspect the archived app's signature and entitlements with `codesign -dvvv --entitlements - <path-to-Clops.app>`.
- [ ] Confirm the submitted bundle contains no `com.apple.quarantine` extended attributes.
- [ ] Test a signed, sandboxed build on a clean macOS user account, including first-run clipboard permission, copy-and-return behavior, Keychain persistence, file bookmarks, and Launch at Login.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Encryption export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Add an app icon](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon)
