# Cutting a TestFlight release

```sh
./scripts/release.sh                    # iOS: archive, export, upload
./scripts/release.sh --no-upload        # iOS: archive and export only
./scripts/release.sh --mac              # Mac: archive, export .pkg, upload
./scripts/release.sh --mac --no-upload  # Mac: archive and export only
```

The script is the same pipeline that ships SeaTime (`sailing-logbook/scripts/release.sh`),
pointed at this project. It runs on a Mac with Xcode, XcodeGen and the App Store Connect API
key; there is no CI upload. Same team (`3ED9V77D6W`), same API key.

**Use `--no-upload` first whenever you have touched signing, the bundle ID, entitlements, the
privacy manifest or `project.yml`.** It reaches the same signing and packaging steps without
paying for the upload and 5 to 15 minutes of Apple-side processing.

## One-time setup (needs the Apple Developer account)

Do these once, in order. Everything else is already in the repo.

1. **API key on this Mac.** `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, the same
   file SeaTime uses. Its role must be **Admin**, not App Manager, or export fails with
   `Cloud signing permission error`. Override the key with `ASC_KEY_ID` / `ASC_ISSUER_ID`.
2. **Bundle ID and capabilities.** `com.gabrielconlon.CustomMapApp` with iCloud (CloudKit,
   container `iCloud.com.gabrielconlon.CustomMapApp`) and Push Notifications. If you have run
   the app on a device from Xcode, this exists already. If not, `./scripts/release.sh
   --no-upload` registers it through `-allowProvisioningUpdates`. Check it in
   developer.apple.com → Certificates, IDs & Profiles → Identifiers.
   The bundle ID is permanent once the App Store Connect record exists. If you want something
   other than `CustomMapApp`, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` *before* step 3.
3. **App Store Connect record.** The API cannot create one; use the web UI. Apps → ＋ → New
   App → iOS, bundle ID `com.gabrielconlon.CustomMapApp`, SKU `bettermaps-001`, any name.
   App Store names are globally unique, so "BetterMaps" may be taken; something like
   "BetterMaps Dublin" works and the home screen still says BetterMaps (`CFBundleDisplayName`).
   Without this record the upload fails with `No suitable application records were found`.
4. **CloudKit schema to Production.** This one fails silently. TestFlight builds talk to the
   **Production** CloudKit environment, and Xcode device builds talk to Development. If the
   SwiftData record types (`Place`, `Layer`, `Trail`, `FavoriteTransitRoute`) were never
   deployed, the TestFlight app opens fine and nothing syncs. To deploy:
   - Run a Debug build on a device signed into iCloud and create one of each: a place, a
     layer, a trail, and a favourite transit route, so every record type and field exists in
     Development.
   - CloudKit Console → `iCloud.com.gabrielconlon.CustomMapApp` → Schema → **Deploy Schema
     Changes** (Development → Production).
   - Repeat whenever a `@Model` gains a field, before the TestFlight build that uses it ships.
5. **Ship it.** `./scripts/release.sh`. Then in App Store Connect → the app → TestFlight, fill
   in **What to Test** on the build and add yourself (and anyone else) to Internal Testing.
   Internal testers skip Beta App Review, so the build arrives minutes after it goes VALID.

## The Mac app

The Mac app is the iOS target built for **Mac Catalyst** (`SUPPORTS_MACCATALYST` in
`project.yml`), not a second codebase. It keeps the iOS bundle ID, so App Store Connect lists
it as the macOS platform of the same "BetterMaps Ireland" record (universal purchase), and it
uses the same CloudKit container, so places, layers, trails and favourite routes sync between
the iPhone and the Mac through the user's iCloud account. The interface is "Scale Interface
to Match iPad": the Mac gets the iPad layout.

Why Catalyst and not a native macOS SwiftUI target: the app leans on UIKit-era presentation
(sheet detents with the map live behind them, full-screen covers, `UIApplication`), and
Catalyst compiles all of it unchanged. A native target would mean a Mac-specific presentation
layer before anything shipped. Catalyst gets a synced Mac app onto TestFlight now; a native
port stays possible later because the bundle ID and container would not change.

**One-time setup for the Mac**, after the iOS steps above:

1. **Add the macOS platform to the app record.** App Store Connect → BetterMaps Ireland →
   the platform list in the sidebar (or the ＋ next to the iOS App heading) → **Add macOS
   App**. Without it the Mac upload fails with `No suitable application records were found`.
2. **Dry run.** `./scripts/release.sh --mac --no-upload`. Automatic signing registers the Mac
   side of the bundle ID and makes the Mac provisioning profile and the Mac Installer
   Distribution certificate through the API key.
3. **Upload.** `./scripts/release.sh --mac`. Then App Store Connect → TestFlight → **macOS**
   builds, add yourself to Internal Testing, and install from the TestFlight app on the Mac.

The CloudKit schema needs nothing new: the Mac uses the same record types, and TestFlight
Mac builds also talk to Production.

**What differs on the Mac.** `BetterMaps-macOS.entitlements` replaces the iOS file for
`sdk=macosx*`: the Mac App Store requires the App Sandbox, so it adds sandbox, outgoing
network and location, and spells the push key `com.apple.developer.aps-environment`.
`LSApplicationCategoryType` (Navigation) in `Info.plist` is required for a Mac upload.
Anything the app starts doing that the sandbox blocks (writing outside its container,
opening user-chosen files) needs an entitlement here too.

**Checking sync.** Settings → iCloud sync shows whether this device is actually syncing: Off
when the store fell back to local-only, when there is no iCloud account, or when iCloud is
restricted; Problem with CloudKit's own message when an import or export fails; otherwise the
time of the last successful sync. To prove propagation end to end: add a place on the Mac,
wait for "Last synced" to move, then open the app on the iPhone (bring it to the foreground;
CloudKit pushes usually land within a minute).

## What the script decides, so you do not

**The build number is `git rev-list --count HEAD`.** App Store Connect permanently rejects a
build number it has seen, and the commit count only climbs. `CURRENT_PROJECT_VERSION` in
`project.yml` is a placeholder the script overrides. Run it from a full clone, not a shallow
one, or the count is wrong.

**`MARKETING_VERSION` in `project.yml` is the only version you edit by hand.**

**A dirty working tree warns but does not block.**

## Compliance, already handled: keep it true

- `BetterMaps/Resources/PrivacyInfo.xcprivacy`: no tracking; UserDefaults (`CA92.1`) and file
  attributes (`C617.1`, the timetable size check); a place's coordinate sent to Yelp declared
  as unlinked app-functionality data. If the app starts sending anything new, this changes.
- `ITSAppUsesNonExemptEncryption = NO` in `Info.plist` clears export compliance on every
  upload. True while the only crypto is system HTTPS.
- `UISupportedInterfaceOrientations~ipad` lists all four orientations. XcodeGen builds iOS
  apps for iPhone and iPad, and an iPad build without upside-down is rejected for multitasking.
- The 1024×1024 icon has no alpha channel (it was RGBA, fully opaque; flattened to RGB).
- `aps-environment` is `development` in the entitlements file. That is right: the App Store
  export re-signs it as `production` from the distribution profile.
- `api.irishrail.ie` is plain HTTP under an ATS exception. Fine for TestFlight; App Review
  may ask about it if the app ever goes to the public store.

## Verifying a build before you trust it

```sh
cd build/export && unzip -q -o CustomMapApp.ipa -d /tmp/ipa && cd /tmp/ipa
plutil -extract CFBundleVersion raw Payload/CustomMapApp.app/Info.plist                 # climbing?
plutil -extract ITSAppUsesNonExemptEncryption raw Payload/CustomMapApp.app/Info.plist   # false
ls Payload/CustomMapApp.app/PrivacyInfo.xcprivacy                                        # bundle root
codesign -d --entitlements - Payload/CustomMapApp.app | grep -A1 aps-environment          # production
codesign -dvvv Payload/CustomMapApp.app 2>&1 | grep Authority                            # Apple Distribution
```

`xcrun altool --validate-app` before `--upload-app` catches server-side rejections in seconds.

## Failures and what they mean

| Symptom | Cause |
|---|---|
| `Cloud signing permission error` | API key is not Admin |
| `No profiles for 'com.gabrielconlon.CustomMapApp' were found` (alone) | bundle ID not registered |
| `No suitable application records were found` | step 3 not done |
| Upload fails vaguely | Account Holder has not accepted an updated agreement; check the App Store Connect banner |
| TestFlight app works but places never sync | step 4: CloudKit schema not in Production; Settings → iCloud sync shows which |
| Mac upload: `No suitable application records were found` | macOS platform not added to the app record |
| Mac app opens but never syncs, Settings says Off | the Mac fell back to local-only; check it is signed in to iCloud and the Mac entitlements were signed in (`codesign -d --entitlements -`) |
| Build uploads, never appears | still processing; give it 15 minutes |

## Two things that bite

**Builds expire 90 days after upload.** Each upload resets the clock.

**A SwiftData `@Model` change can break installed copies.** A new non-optional property, or a
change lightweight migration can't absorb, only fails on a store that already has data, so a
fresh install on your phone will not show it. On CloudKit-mirrored models every property also
needs a default and every relationship must be optional (see `Trail.swift`).
