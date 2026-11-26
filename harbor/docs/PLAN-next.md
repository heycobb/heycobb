# Next up (planned 2026-11-26)

Work through in this order. Each item: build on iOS and Mac where it applies,
test only in `home/TEST FOLDER`, add Kit tests for logic, update
`site/support.html` and `site/privacy.html`, commit per item. No GPL/LGPL/AGPL
or non-commercial code. Anything that runs in the background gets its own
switch and respects the cellular rules below.

## 0. Cellular data rules (do first; the others use it)

- One place for the rule: `NetworkPolicy` in Kit, fed by `NWPathMonitor`
  (`isExpensive` = cellular or Personal Hotspot, `isConstrained` = Low Data
  Mode).
- Settings › **Cellular Data** (iOS; on Mac only when on a hotspot):
  - Photo Backup: off by default (replaces Photo Backup's Only on Wi-Fi).
  - Large Uploads: on by default; "large" = over 50 MB.
  - Keep Downloaded / offline refresh: off by default.
  - Low Data Mode always pauses background work.
- Anything paused shows "Waiting for Wi-Fi" in its status, never a silent stop.
- Migrate the existing `wifiOnly` Photo Backup setting.

## 1. Wake the NAS (Wake-on-LAN)

- Send a magic packet (UDP broadcast, port 9) to the NAS's MAC address.
- Get the MAC once while connected (DSM `SYNO.Core.Network` needs admin;
  fallback: let the user paste it in Edit NAS). Store it in `ServerProfile`.
- Show **Wake NAS** on the Can't Reach NAS row, in the server menu and the Mac
  menu bar, only when a MAC is known. Then retry connecting for ~60 s.
- Works only on the home network (broadcast); say so if on VPN.
- Needs `NSLocalNetworkUsageDescription` (already there).

## 2. Recently Deleted (DSM Recycle Bin)

- List `#recycle` in each share via File Station (only shares with Recycle
  Bin enabled). Sidebar item **Recently Deleted**, hidden when none exist.
- Restore = move back to the original path (DSM keeps the folder structure in
  `#recycle`); name clash → keep both. Delete Permanently with confirmation.
- Permission errors (non-admin users often can't see `#recycle`): hide quietly.

## 3. Shortcuts actions (App Intents)

- Upload Files to NAS (folder parameter), Get Share Link (file → URL),
  Back Up Photos Now (iOS), Open Folder (deep link), Wake NAS.
- `AppEntity` for saved NAS and favorite folders; `perform()` hops to the
  main actor for the model; irreversible work last.
- Read the app-intents skills (`app-intents-specialist`,
  `app-intents-whats-new-27`) before writing them.

## 4. Scan to NAS (iOS/iPadOS)

- VisionKit `VNDocumentCameraViewController` → PDF (PDFKit) → upload queue.
- Entry points: **+** menu in a folder ("Scan Document"), and a Shortcuts action.
- Name: "Scan 2026-11-26 14.32.pdf", editable before saving.
- Camera permission string; nothing kept on device after upload.

## 5. Photos timeline

- A **Photos** view (sidebar item) over folders the user picks (default: the
  Photo Backup destination). Grid by month, newest first, like Photos.
- Dates: File Station `additional=time` (mtime; Photo Backup already sets mtime
  to the taken date). Optional later: EXIF via thumbnails.
- Reuse `PhotoTile`, `ThumbnailCache` and the existing viewer/swipe. Index
  stored in Caches; refresh incrementally on open, never in the background.
- Big libraries: page listings; cap memory with lazy grids.

## 8. Uploads that continue in the background (iOS)

- Move uploads to a background `URLSession` (multipart body written to a temp
  file first; background sessions can't stream from memory).
- Re-attach on launch (`handleEventsForBackgroundURLSession`), keep the queue
  UI, honour the cellular rule, keep the session cookie/SID per request.
- Photo Backup and Scan to NAS use the same path.
- Test: start a 200 MB upload, leave the app, confirm it finishes.

## Supporting other NAS brands (plan only; after the above)

Goal: QNAP, UniFi (UNAS), UGREEN, TrueNAS and others, without a separate app.

1. **Make the app brand-neutral.** `FileService` is already a protocol. Add
   `ServerProfile.kind` (`.synology`, `.qnap`, `.webdav`, `.smb`, …) and a
   `Capabilities` set on each service (share links, compress/extract, recycle
   bin, search, thumbnails, status, QuickConnect). The UI shows features by
   capability, not by brand (QuickConnect only for Synology, etc.).
2. **Generic backends first** (cover most brands at once):
   - **WebDAV**: QNAP, Synology, UGREEN, TrueNAS and Nextcloud all offer it.
     Write our own client on `URLSession` (PROPFIND/MOVE/COPY/PUT); small.
   - **SMB**: every NAS. Use `SMBClient` (MIT, Swift). Check it handles SMB3
     encryption and large files. No libsmb2/AMSMB2 (LGPL).
3. **Brand adapters where they add value**: QNAP File Station API
   (`/cgi-bin/filemanager/utilRequest.cgi`) for thumbnails, share links,
   search; UniFi Drive only if a documented API exists (check first).
4. **Discovery**: keep the SMB Bonjour browse; identify brand by probing
   (DSM API, QNAP `/cgi-bin/authLogin.cgi`, else WebDAV/SMB). Onboarding lists
   any NAS; brand only changes the sign-in details asked for.
5. **Per-brand help**: setup guide split by brand; QuickConnect stays Synology.
6. **Testing**: needs access to each brand (QNAP and UniFi test units or
   loaners). Don't ship a brand we haven't tested on real hardware.

## Pricing (decided 2026-11-26)

Free download, plus **Ownhold Pro: one-time $9.99**, a single universal
purchase covering iPhone, iPad and Mac, with Family Sharing on. No
subscription. No free trial of Pro for now.

- **Free:** browse, open, preview, search, upload/download, players and PiP,
  offline files, Favorites, Recents, share links, compress/extract, one saved
  NAS, app lock and all privacy/security settings, onboarding (discovery,
  Tailscale, QuickConnect), Show NAS in Finder/Files (browsing), Photo Backup
  "Back Up Now".
- **Pro:** automatic Photo Backup, Folder Backup (Mac), Keep Downloaded and
  Keep Finder Up to Date, Photos timeline, Shortcuts actions, Scan to NAS,
  background uploads, more than one NAS, Wake NAS, Recently Deleted; later NAS
  status and other NAS brands.
- **Build:** StoreKit 2 non-consumable (`app.ownhold.pro`), `Entitlement`
  check in Kit (transaction listener, `Transaction.currentEntitlements`),
  universal purchase across platforms (same bundle ID family), Family Sharing
  enabled in App Store Connect. Settings: one **Ownhold Pro** row (buy,
  restore) and a small lock on Pro switches; no pop-ups or nagging. Restore
  Purchases always available. Test with a StoreKit configuration file.
- Update `site/support.html` (what's free vs Pro) and the App Store text.

## Still open from before

- Recently Deleted: Restore and Delete Permanently untested (Recycle Bin is
  off for homes/home on the test NAS). Turn it on, then delete and restore a
  file inside TEST FOLDER. If it still isn't in #recycle, check whether DSM's
  File Station Delete API skips the Recycle Bin.
- Wake NAS: not yet tried on a sleeping NAS; iOS broadcast needs Apple's
  multicast entitlement (request before release if the direct send isn't
  reliable enough).

- Real-iPhone tests: background Photo Backup, Live Photos, Lock Screen
  controls, iPhone Picture in Picture.
- Photo Backup on the Mac (reads the Mac's Photos library: ask first).
- NAS status at a glance (item 6), share with NAS users, file versions.
