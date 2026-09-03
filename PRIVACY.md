# Clops Privacy Policy

Effective September 2, 2026

Clops is a local-only clipboard history utility for macOS. It does not include accounts, advertising, analytics, telemetry, cloud sync, or networking code. Clops does not transmit clipboard contents or other user data off the Mac.

## Data handled on the Mac

After the user enables background capture and grants macOS clipboard access, Clops reads supported clipboard content so it can provide clipboard history. That content can include text, rich text, images, and file references.

Clipboard history is stored in the app's sandboxed Application Support container. History is encrypted with AES-GCM using a device-local key stored in the macOS Keychain. File entries retain read-only security-scoped bookmarks so the user can copy those files again later. Clops skips clipboard items marked concealed, confidential, or transient, although source applications are responsible for supplying those markers.

Clops does not collect this data as Apple defines collection because it is processed and retained only on the user's Mac. It is not shared with the developer or any third party.

## Permissions

- **Paste from Other Apps:** Used only to read new clipboard content for background history. Background capture can be disabled in Clops Settings, and access can be changed in System Settings.
- **Accessibility:** The Mac App Store release does not request Accessibility access or send synthetic keystrokes to other apps. Choosing a history item copies it and returns focus so the user can press Command-V.
- **Launch at Login:** Optional and disabled until the user enables it in Clops Settings. It can be disabled there or in System Settings.
- **Files:** Read-only access is used for file references the user copies or applications the user explicitly selects for the exclusion list.

## Retention and deletion

Users choose the retention period and maximum count for unpinned history. Pinned entries remain until the user unpins or deletes them. Individual entries can be deleted at any time, unpinned history can be cleared, and **Reset History Storage** in Clops Settings permanently deletes all clipboard history and creates a fresh encrypted store.

Users can stop future clipboard processing by disabling Background Capture and can revoke system permissions in **System Settings → Privacy & Security**. To remove locally retained history before uninstalling Clops, use **Reset History Storage** first.

## Third parties

Clops contains no third-party SDKs and shares no data with third parties.

## Changes and contact

Material changes to this policy will be published with an updated effective date. Questions can be filed in the [Clops GitHub repository](https://github.com/seamoss/Clops/issues).
