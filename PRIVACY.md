# Privacy Policy for Retappd

**Effective date:** November 21, 2026

Retappd is an iOS client for Untappd developed by David Sansome. This policy explains what data Retappd accesses, where it is sent, how it is stored, and how you can delete it.

Retappd contains no advertising, uses no third-party analytics or crash-reporting SDKs, and does not sell, rent, or share your personal data for tracking or advertising.

---

## 1. Data Sent Directly to Untappd

Retappd communicates directly with Untappd's servers (`api.untappd.com`) over HTTPS to provide core app functionality:

- **Account sign-in:** Your Untappd username/email and password are sent directly to Untappd to obtain an access token. Retappd never stores your password. Your access token is stored securely in the iOS Keychain on your device.
- **Device identifier:** A random or vendor-scoped device identifier (`identifierForVendor`) is generated on your device and sent to Untappd during sign-in.
- **User content & social activity:** Check-ins, ratings, comments, toasts, friend requests, blocks, mutes, and account settings changes are sent directly to Untappd.
- **Photos:** Photos you take or select for a check-in are resized on your device and uploaded directly to Untappd's image storage (Amazon S3).
- **Location:** When you grant location access, your coordinates are sent to Untappd to find nearby venues and attach venues to your check-ins.

Data sent to Untappd is governed by [Untappd's Privacy Policy](https://untappd.com/privacy).

---

## 2. Optional Push Notifications Server

Push notifications are **off by default** and are only enabled if you turn them on in **Settings → Notifications**.

When push notifications are enabled, Retappd registers your device with Retappd's notification relay server (`retappd-notify.davidsansome.workers.dev`, hosted on Cloudflare Workers) and stores:

- **Your Untappd access token**, encrypted at rest using AES-256-GCM envelope encryption with per-device data keys.
- **Your Apple Push Notification service (APNs) device token** and push environment.
- **Your Untappd numeric user ID**, notification preferences (toasts, comments, tags, friend requests), and app version.

The server periodically checks your Untappd activity (about once a minute) solely to send you push alerts via Apple's APNs. It does **not** store check-in text, comments, usernames, or notification contents—only poll timestamps and delivery state.

To prevent abuse, the server temporarily stores rate-limiting counters keyed by a cryptographic hash (HMAC) of your IP address (with IPv6 collapsed to `/64`) or APNs token. Raw IP addresses are never stored.

### Deleting Notification Server Data

Turning off **Push notifications** in Settings, or **signing out** of Retappd, immediately deletes your device registration and encrypted token from the notification server (and automatically retries on next launch if your device is offline). Cloudflare D1's automated point-in-time backups may retain deleted database rows for up to 30 days before permanent expiration.

---

## 3. Optional Shop Prices (Metabeer)

When **Show shop prices** is turned on in **Settings** (enabled by default in Australia and the UK), Retappd fetches in-stock beer prices from [Metabeer](https://metabeer.com.au) (`metabeer.com.au` or `metabeer.co.uk`).

- Only the **Untappd beer ID** is sent to Metabeer.
- No account information, usernames, tokens, or location data are sent.
- Tapping a shop offer opens that retailer's website in your browser.

---

## 4. Beer Search (Algolia)

When you search for beers, your search query is sent directly to Untappd's public Algolia search index to return fast search results.

---

## 5. Device Permissions

Retappd only requests iOS permissions when needed for specific features:

- **Location (When In Use):** Used to find nearby venues and suggest your current venue when checking in. Requested when you open Discover or start a check-in.
- **Camera:** Used to take check-in photos, scan beer barcodes, or scan friend QR codes.
- **Photo Library:** Used when you pick a photo or attach your most recent photo to a check-in.
- **Notifications:** Requested only if you turn on Push Notifications in Settings.

You can revoke any permission at any time in the iOS **Settings** app.

---

## 6. Local Storage on Your Device

Retappd stores the following locally on your device:

- Your Untappd access token and notification device secret (in the iOS Keychain).
- Your username, app preferences, last known coordinates (so nearby venues load quickly), and cached API responses and images.

Signing out clears your access token, cached responses, and local search index from the device.

---

## 7. Account Deletion

Retappd does not create or host Untappd accounts. To delete your Untappd account and its associated data, manage your account directly on [Untappd](https://untappd.com). To delete all data held by Retappd's notification server, turn off Push Notifications in Settings or sign out.

---

## 8. Age Requirement

Retappd is intended only for adults of legal drinking age in their country or region and is not directed at children.

---

## 9. Changes to This Policy

If this policy changes in a material way, the updated version will be published here with a new effective date.

---

## 10. Contact

If you have questions or requests regarding this Privacy Policy, please contact:

**David Sansome**  
Email: [me@davidsansome.com](mailto:me@davidsansome.com)
