# Shipping on the App Store

A checklist of what Apple will require for this app, what's already built in,
and what's still open. Check Apple's current
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
before submitting; they change.

## Distribution

- **One purchase across iPhone, iPad and Mac.** The project is a single
  multiplatform SwiftUI target, so it ships as one App Store Connect record
  with universal purchase. Someone who buys on iPhone also gets the Mac version.
- **Apple Developer Program** membership ($99/yr) is required to sell.
  To sell paid apps, you also need to accept the Paid Apps agreement and
  enter tax and banking details in App Store Connect.

## Things App Review will check

| Requirement | Status |
|---|---|
| **2.1 Demo access.** Reviewers can't use your NAS. Apple asks for a demo account or a fully featured demo mode. | ✅ Built-in demo library ("Try the demo library" on first launch). In the App Review notes, explain that it's a client for the user's own NAS and point to demo mode. Be ready to send a short video of the app on a real device with your NAS. |
| **5.2 Intellectual property.** Don't use Synology's or Tailscale's names or logos so it looks like their app. | ✅ Independent name. ⚠️ Mention compatibility only in descriptive text ("works with Synology DSM 7"). Don't put a Synology logo in screenshots or the icon. The About screen carries a "not affiliated" line. |
| **5.1.1 Privacy policy URL.** Required for every app. | ✅ Written: `site/privacy.html` (also linked in Settings › About as `https://ownhold.app/privacy`). ⬜ Fill in your name (yellow placeholder), host it at `ownhold.app/privacy`, and set up `privacy@ownhold.app`. |
| **Support URL.** Required on the App Store listing. | ✅ Written: `site/support.html` (setup, Tailscale and other VPNs, DDNS, QuickConnect, certificates, offline files, fixes for every in-app error message; linked in Settings › About as `https://ownhold.app/support`). ⬜ Host it at `ownhold.app/support` and set up `support@ownhold.app`. |
| **App Privacy "nutrition label".** | ✅ Answer "Data Not Collected". This matches `PrivacyInfo.xcprivacy`. |
| **Privacy manifest** with reasons for "required reason" APIs. | ✅ `App/PrivacyInfo.xcprivacy` declares UserDefaults, file timestamps and disk space. |
| **Purpose strings** for local network and Face ID. | ✅ `Config/Info.plist`. |
| **Encryption export compliance.** | ✅ `ITSAppUsesNonExemptEncryption = NO`. Standard HTTPS only. |
| **Mac App Sandbox.** | ✅ `Config/Ownhold-macOS.entitlements` (network client + user-selected files). |
| **4.2 Minimum functionality.** It has to feel like an app, not a web wrapper. | ✅ Native SwiftUI on every platform. |
| **App icon.** | ✅ `App/AppIcon.icon` (Icon Composer / Liquid Glass), the "oh" monogram on deep evergreen. Sources in `Design/AppIcon/`. |
| **Screenshots.** iPhone 6.9", iPad 13", Mac. | ⬜ Take them in demo mode, so no personal files appear. |

## Name

**Ownhold** (chosen 2026-11-25; replaces the working name "Harbor").
Own + hold, echoing *freehold* and *stronghold*: your cloud is owned, not
rented. App Store subtitle: "Files and photos from your NAS". Keep
marketing copy plain and specific; avoid slogan fragments ("Your cloud.
Owned.") and stock phrases, which read as AI-written.

Domains (checked 2026-11-25): `ownhold.app`, `getownhold.com` and
`ownholdapp.com` were free; `ownhold.com` is registered (since 2025, no site).
No app, company or website using the name was found.

Still to do:
1. Register the domains (at least `ownhold.app` and `getownhold.com`).
2. Search USPTO for conflicts in Class 9 (software) and Class 42 (software
   services), and in any other market you'll sell in.
3. Reserve it by creating the app record in App Store Connect. That holds the
   name.
4. Keep "Synology", "DS", "DSM" and "Tailscale" out of the app name and
   subtitle. Using them in the description keywords to say it's compatible is
   common, but it's Apple's call in review.

## Pricing options

- **Paid up front** ($4.99–$9.99 is typical for pro utilities). Simplest, and it
  matches "no accounts, no tracking". No server costs, since the app talks
  only to the user's NAS.
- **Free with a one-time unlock** (StoreKit 2 non-consumable). For example,
  browsing is free and offline, Face ID and multiple servers are paid.
  Converts better, but adds StoreKit code and a "Restore Purchases" button,
  which Apple requires.
- Avoid a subscription unless there's ongoing cost or service behind it.
  Reviewers and customers both push back on subscriptions for a local tool.

## Synology API

Ownhold uses the File Station Web API that Synology documents publicly for
third-party developers. It needs no Synology account, cloud relay or SDK
license. Re-check Synology's developer terms before launch.

## Before submitting

- [ ] Test on a real NAS over LAN, Tailscale and (optionally) the internet
- [ ] Test a QuickConnect ID lookup against a real NAS (success response shape is unverified)
- [ ] Test 2-factor sign-in, including "remember this device"
- [ ] Test with a self-signed certificate and with a Let's Encrypt certificate
- [ ] VoiceOver pass, Dynamic Type at the largest sizes, Reduce Transparency
- [ ] Test offline: airplane mode, then open saved files
- [ ] TestFlight with a few friends who own Synology boxes
