# Releasing

## CI

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

- **test** generates the Xcode project from `project.yml`, builds the app for an iPhone
  simulator and runs `RetappdTests`. Require it in branch protection.
- **testflight** runs only on `main`, after **test** passes. It builds the app with
  `scripts/archive.sh` and uploads it to TestFlight. Internal testers get it as soon as Apple
  has processed it (about 5–15 minutes), with no review.

Build numbers are `main`'s commit count, so each upload's is higher than the last. Don't rewrite
`main`'s history: a lower count would repeat a build number, and App Store Connect would refuse
the upload. The version is `MARKETING_VERSION` in `project.yml`.

## How it signs

There are no certificates or provisioning profiles in the repository or its secrets, and CI
never makes one. `scripts/archive.sh` builds the archive unsigned, and Xcode's cloud signing
signs it as it's exported, with a distribution certificate Apple keeps, and the profile Xcode
makes the first time it needs it. (With automatic signing, the archive step would make a new
development certificate on every run, as the runner never has a private key.)

CI signs in to App Store Connect with an API key, in three repository secrets:

| Secret            | What                                    |
|-------------------|-----------------------------------------|
| `ASC_KEY_ID`      | The key's ID                            |
| `ASC_ISSUER_ID`   | The issuer ID, above the list of keys   |
| `ASC_PRIVATE_KEY` | The contents of the key's `.p8` file    |

Until they're set, the **testflight** job skips, with a notice saying so.

## One-time setup

1. **Keep the repository private.** The source has the Untappd API's client secret and the
   Algolia key in it.

2. **Register the bundle ID.** In the [developer portal](https://developer.apple.com/account/resources/identifiers/list),
   *Identifiers → +*, *App IDs → App*, with the explicit bundle ID `dev.retappd.app`. Skip
   this if it's listed already: building to a device from Xcode registers it.

3. **Create the app** in [App Store Connect](https://appstoreconnect.apple.com): *Apps → + →
   New App*: platform iOS, name *Retappd*, bundle ID `dev.retappd.app`, SKU anything
   (`retappd`), *Full Access*. The name has to be unique across the whole App Store; if it's
   taken, any other works, since the home screen shows `CFBundleDisplayName` ("Retappd").

4. **Make the API key:** *Users and Access → Integrations → App Store Connect API → Team Keys →
   +*, with the **Admin** role, which cloud signing needs. Download the `.p8` (it can only be
   downloaded once), and set the secrets:

   ```sh
   gh secret set ASC_KEY_ID --body <key ID>
   gh secret set ASC_ISSUER_ID --body <issuer ID>
   gh secret set ASC_PRIVATE_KEY < AuthKey_<key ID>.p8
   ```

5. **TestFlight testers:** in the app, *TestFlight → Internal Testing → +*, create a group
   with *Enable automatic distribution* on, and add yourself and the other testers. Internal
   testers have to be users of the App Store Connect team (*Users and Access*), and install
   the TestFlight app on their iPhone.

   Stick to internal testing. External groups need Apple's beta review, which an unofficial
   client of a third-party API with another company's name may not pass.

6. **Check it:** run the workflow on `main` (*Actions → ci → Run workflow*). When the build
   shows under *TestFlight → iOS Builds*, it's on its way to the testers.

## When something fails

- *"No Accounts"* or *"No profiles for 'dev.retappd.app'"* at the export: the API key
  secrets are missing or wrong, or the key isn't Admin.
- *"The bundle version must be higher than the previously uploaded version"*: a build with
  that number was uploaded already, by hand or before a history rewrite. Add a commit.
- *"Invalid bundle … iPad Multitasking support requires these orientations"*: an iPad app
  has to support every orientation. Either support them on iPad
  (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` in `project.yml`), or make the app
  iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`).
