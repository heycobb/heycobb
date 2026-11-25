# Harbor

A private, native client for Synology NAS on iPhone, iPad and Mac.
"Harbor" is a working name; see [docs/APP_STORE.md](docs/APP_STORE.md#name).

- Browse shared folders in a list or photo grid, sort, search
- NAS-generated thumbnails with an on-device cache
- Quick Look previews for photos, video, PDFs, Office/iWork files and text
- Keep files or whole folders offline (encrypted at rest, no background sync)
- Picks the best address automatically: home network → Tailscale → internet
- 2-factor sign-in with "remember this device"
- Certificate pinning for DSM's self-signed certificate
- Optional Face ID / Touch ID lock and app-switcher privacy cover
- Built-in demo library, which you can use without a NAS (App Review needs it too)
- No analytics, no third-party SDKs, no servers of our own

## Build

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd harbor
xcodegen generate
open Harbor.xcodeproj
```

In Xcode, pick your team under Signing & Capabilities, then run on "My Mac",
an iPhone/iPad simulator, or a device. The project file is generated from
`project.yml`, so make project changes there.

Run the core tests with `swift test` in `Packages/HarborKit`, or with ⌘U in Xcode.

## NAS setup

The app has the same steps, in plainer language, under **Settings › Setup Guide** (also linked from the welcome screen and Add NAS).

1. DSM: **Control Panel → Login Portal → DSM**: make sure HTTPS is on (port 5001).
   Harbor doesn't use plain HTTP.
2. The account needs File Station permission (Control Panel → Application Privileges).
3. Tailscale: install the Tailscale package on the NAS and the Tailscale app
   on your devices. Enter the NAS's MagicDNS name (e.g. `nas.tailnet-name.ts.net`)
   or its `100.x.y.z` address as the Tailscale address.
4. The first time you connect, Harbor shows the certificate's SHA-256
   fingerprint (the same value Safari shows), then you tap Trust. Trust
   covers all of that NAS's addresses. Harbor refuses to connect if the
   certificate later changes.

## Layout

```
harbor/
├── project.yml                  XcodeGen spec: one SwiftUI target, iOS + macOS
├── Config/                      Info.plist keys, entitlements
├── App/                         SwiftUI app (shared by all platforms)
│   ├── AppModel.swift           servers, connection, offline, lock
│   ├── Views/                   screens
│   ├── Support/                 design tokens, platform helpers
│   └── PrivacyInfo.xcprivacy    privacy manifest (no tracking, no data collected)
├── Packages/HarborKit/          UI-free core, unit tested
│   ├── FileStationClient.swift  Synology File Station Web API
│   ├── CertificateTrust.swift   TLS pinning
│   ├── ConnectionResolver.swift LAN / Tailscale / internet selection
│   ├── ThumbnailCache.swift     memory + disk thumbnail cache
│   ├── OfflineStore.swift       pinned files, file protection
│   └── DemoFileService.swift    built-in sample library
└── docs/
    ├── APP_STORE.md             what's needed to sell it
    └── DESIGN.md                design direction
```
