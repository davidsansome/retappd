# Releasing

## CI

[Xcode Cloud](https://developer.apple.com/xcode-cloud/) builds the app on every push to `main`
(except pushes that only change Markdown files) and uploads it to TestFlight. The *Internal
testers* group gets it as soon as Apple has processed it (about 5–15 minutes), with no review.

The workflow lives in App Store Connect, not in this repository. It doesn't run on pull requests
or run the tests, to save compute hours (the Developer Program includes 25 a month), so run
`RetappdTests` locally before pushing.

What is in the repository is `ci_scripts/ci_post_clone.sh`, which Xcode Cloud runs after it
clones. The Xcode project isn't committed, so the script installs XcodeGen and generates it.

Build numbers are Xcode Cloud's own counter (`CI_BUILD_NUMBER`): it sets the build number
itself, replacing `CURRENT_PROJECT_VERSION` from `project.yml`, so they don't match commit
counts. The version is `MARKETING_VERSION` in `project.yml`.

Signing is Xcode Cloud's: it makes and keeps the distribution certificate and profile itself.
There are no certificates, keys or secrets in the repository.

## One-time setup

1. **Keep the repository private.** The source has the Untappd API's client secret and the
   Algolia key in it, and Xcode Cloud is given access to it.

2. **Create the app** in [App Store Connect](https://appstoreconnect.apple.com), if it isn't
   there: *Apps → + → New App*: platform iOS, name *Retappd*, bundle ID
   `com.davidsansome.retappd` (register both `com.davidsansome.retappd` and the notification
   extension's `com.davidsansome.retappd.NotificationService` under *Identifiers* in the
   [developer portal](https://developer.apple.com/account/resources/identifiers/list) if automatic
   signing doesn't create them), SKU anything (`retappd`), *Full Access*.

3. **Make the workflow.** Run `xcodegen generate` and open `Retappd.xcodeproj` in Xcode. In the
   Report navigator (⌘9), *Cloud* tab, choose *Get Started* (or *Product → Xcode Cloud →
   Create Workflow*), pick the *Retappd* app, and grant Apple's GitHub app access to this
   repository. Then edit the workflow:

   - **Environment:** the latest release Xcode, and macOS.
   - **Start Conditions:** delete the default *Branch Changes*, and add one with *Branch*:
     `main`, and under *Files and Folders*, *Don't start a build if only these files change*:
     `**/*.md`. Leave *Pull Request Changes* and *Tag Changes* out.
   - **Actions:** one *Archive* action: the *Retappd* scheme, platform iOS, *TestFlight and App
     Store* deployment preparation. No *Test* action.
   - **Post-Actions:** *TestFlight Internal Testing*, to the group *Internal testers*.

4. **TestFlight testers:** the builds go to the internal group *Internal testers* (*TestFlight →
   Internal Testing*). Internal testers have to be users of the App Store Connect team (*Users
   and Access*), and install the TestFlight app on their iPhone.

   Stick to internal testing. External groups need Apple's beta review, which an unofficial
   client of a third-party API with another company's name may not pass.

5. **Check it:** in App Store Connect, *Xcode Cloud → Start Build* on `main`. When the build
   shows under *TestFlight → iOS Builds*, it's on its way to the testers.

## App Store screenshots & releases (Fastlane)

Fastlane (`fastlane/Fastfile`) automates screenshot capture, screenshot upload, and promoting
an Xcode Cloud TestFlight build to an App Store release. Because Xcode Cloud owns the build
counter, `fastlane release` never builds or uploads a binary locally — it selects the latest
Xcode Cloud build for `MARKETING_VERSION` in `project.yml`.

### One-time setup

1. Install Fastlane (`brew install fastlane`, version 2.233+ for 6.9" iPhone / 13" iPad screenshot sizes).
2. In App Store Connect (*Users and Access → Integrations → App Store Connect API → Team Keys*),
   create a key with **App Manager** access and download the `.p8` file.
3. Save a gitignored JSON file at the root of the main checkout (shared across worktrees, like
   `test-accounts.local`): `asc-api-key.local.json`:
   ```json
   {
     "key_id": "<KEY_ID>",
     "issuer_id": "<ISSUER_ID>",
     "key_filepath": "/absolute/path/to/AuthKey_<KEY_ID>.p8"
   }
   ```
   (Alternatively, set `ASC_API_KEY_PATH` or save it at `fastlane/api_key.json`.)

### Lanes

- `fastlane capture_screenshots` — builds Debug, spins up temporary dedicated iPhone 6.9" and iPad 13"
  simulators, captures all 6 demo screens, frames them into `screenshots/{iphone,ipad}/`, and
  deletes the temporary simulators. Pass `upload:true` to upload right after.
- `fastlane upload_screenshots` — stages and uploads the framed PNGs in
  `screenshots/{iphone,ipad}/` to App Store Connect (default locale `en-US`; override with
  `locale:en-AU`).
- `fastlane draft_release_notes` — previews AI-generated App Store release notes from git commits
  since the last `v*` tag (using `claude -p --model sonnet`, falling back to
  `agy -p --model gemini-4-neon-low`; pass `since:<ref>` to override the base).
- `fastlane release` — attaches the latest Xcode Cloud TestFlight build for `MARKETING_VERSION`,
  auto-generates release notes from `<last v* tag>..origin/main` (on the first release, before any
  `v*` tag exists, prompts to enter notes manually in `$EDITOR` or skip), lets you
  **Accept / Edit in `$EDITOR` / Cancel**, submits for App Store review (manual release after
  approval by default), and creates + pushes an annotated `v<version>` tag on `origin/main`.
  Useful options: `release_notes:"..."`, `screenshots:true`, `automatic_release:true`,
  `phased_release:true`, `submit:false`, `tag:false`, `force:true`, `build_number:42`.

Both `asc-api-key.local.json` and `*.p8` are gitignored.

## When something fails

- *The post-clone script fails:* the log's *Post-Clone* step shows it. Run it as Xcode Cloud
  does with `CI_PRIMARY_REPOSITORY_PATH=$PWD ci_scripts/ci_post_clone.sh` in a throwaway clone,
  since it edits `project.yml`.
- *"The bundle version must be higher than the previously uploaded version"*: a build with that
  number, or a higher one, was uploaded already, by hand or by the old GitHub workflow. Xcode
  Cloud's counter can't be set, so upload nothing by hand: each build then takes the next
  number.
- *"Invalid bundle … iPad Multitasking support requires these orientations"*: an iPad app
  has to support every orientation. Either support them on iPad
  (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` in `project.yml`), or make the app
  iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`).
- *Out of compute hours:* the month's 25 are used up (*Xcode Cloud → Usage* in App Store
  Connect). They reset on the next billing date; more cost $49.99 a month for 100.
