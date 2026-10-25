# Pico notifications: hostd sends straight to APNs

Status: design, 2026-10-22. Decision D24. Replaces §15's relay design for installs signed by the
user's own paid team; Bark (§7) stays for everyone else.

## 1. Why there is no relay

§15 put a relay between hosts and APNs because a published app is signed by one team, and that
team's APNs key can push to every app of the team, so it cannot be handed to users. A Pico built
with `scripts/ios-personal-device.sh` is signed by the user's own team. The user creates the APNs
key, keeps it on their own host, and hostd signs its requests to APNs itself. Nothing else runs.

What this gives over Bark: no second app, the notification shows as Pico, and a tap opens the event
with no "Open in Pico?" prompt. Notices are grouped per host.

## 2. Setup

1. **The key (once per team):** in the Apple Developer site, Certificates, Identifiers & Profiles →
   Keys → +, tick Apple Push Notifications service, download `AuthKey_<KEY_ID>.p8`. Copy it to the
   host as `~/.minis/hostd/AuthKey_<KEY_ID>.p8`, mode 0600.
2. **Config:** replace `[bark]` with
   ```toml
   [apns]
   key_file = "AuthKey_ABC123DEFG.p8"   # relative to ~/.minis/hostd, or absolute
   key_id = "ABC123DEFG"
   team_id = "28ZGY8C268"
   ```
   A config with both sections, or neither, is refused.
3. **The phone:** Settings → Remote Hosts → host → Notifications → **Send to This iPhone**. Pico asks
   for notification permission, gets its device token and registers it on the host (§4).
4. **Check:** `minis-hostd doctor --push-test` sends an encrypted test notice through APNs.

The build must keep the push entitlement: `ios-personal-device.sh --keep-push` (added with the app
side of D24), which a free team cannot sign.

## 3. Sending

- **Endpoint:** `https://api.sandbox.push.apple.com` for a development registration,
  `https://api.push.apple.com` for production, `POST /3/device/<token>` over HTTP/2.
- **Auth:** an ES256 JWT `{alg: ES256, kid: key_id}.{iss: team_id, iat}` signed with the `.p8` key.
  APNs rejects a token refreshed more than once per 20 minutes and one older than an hour, so hostd
  reuses one for 40 minutes.
- **Headers:** `apns-topic: <bundle id>`, `apns-push-type: alert`, `apns-priority: 10`,
  `apns-expiration` set to the UNIX time 24 hours ahead, so a phone that is off gets the notice when it comes back.
- **Payload:**
  ```json
  {"aps": {"alert": {"title": "New event", "body": "Open Pico to read it."},
           "mutable-content": 1, "thread-id": "<host>", "sound": "default"},
   "pico": {"v": 1, "host": "<host>", "k": "<key id>", "c": "<base64 ciphertext>"}}
  ```
  The visible alert is a placeholder; the real title, body and link are inside `c` (§5).
- **Errors:** HTTP 200 is sent. Each refusal names its cause:
  - `Unregistered`: the app was removed or its token changed; tap Send to This iPhone again.
  - `BadDeviceToken`: the token does not belong to the registered environment (a development token
    sent to production or the reverse), or is malformed.
  - `DeviceTokenNotForTopic`, `BadTopic`, `TopicDisallowed`: the registered bundle id is not the
    app the token belongs to, or the key's team does not sign it.
  - `InvalidProviderToken`, `ExpiredProviderToken`: check `key_id`, `team_id` and the key file.

  Resending the same request cannot fix any of these, nor any other 4xx, so they fail at once.
  429 and 5xx are retried as today (§5.4). A connection lost after the request was written is "may
  have been delivered", as with Bark.

## 4. Registration

Each registration draws a new key, and the phone must hold it before hostd encrypts with it. A
key the phone never saved, because the SSH session dropped or iOS suspended the app halfway, would
leave every later notice unreadable. So registration has two steps, and keys have ids:

1. `minis-hostd apns register <device token> --topic <bundle id> --environment development|production --json`
   draws a 32-byte AES key and an 8-byte key id and stores them as the **pending** registration
   beside the active one. It prints `{schemaVersion, keyId, key}`. The key travels back over the SSH
   session, so it never appears in a command line on the host.
2. The app saves the key in the keychain under host and key id.
3. `minis-hostd apns activate <key id> --json` makes the pending registration the active one and
   prints `{schemaVersion, ok: true}`. A key id that is not the pending one is refused.

hostd encrypts only with the active registration, so a run that stops after step 1 or 2 changes
nothing; registering again replaces the pending one. A run that stops after step 3 leaves both
sides on the new key. The app keeps the keys of earlier registrations, so notices APNs still holds
from before (up to 24 hours) decrypt by their key id.

- `minis-hostd apns unregister --json` deletes the registration; Pico calls it when a host is
  removed, so notices stop instead of arriving sealed with a key the phone just deleted. An older
  minis-hostd answers "unknown command", which the app logs and ignores.
- State lives in `~/.minis/hostd/apns-device.json` (mode 0600, replaced atomically).
- One phone per host; activating a new registration replaces the old phone.
- The daemon reads the file for every send, so registering needs no restart. Before the first
  activation, sends fail with "No iPhone is registered for Pico notifications" and are retried
  within the usual window.
- **The environment** comes from the app's `embedded.mobileprovision` (`aps-environment`); an App
  Store build has none and is production.
- **Token changes:** on launch, Pico registers for remote notifications again; when the token
  differs from the one it registered on a host, it runs the two steps for that host in the
  background. A failed run changes nothing on the host, and the host's Notifications screen shows the
  error with Send to This iPhone to retry.

## 5. Encryption and display

- **Cipher:** AES-256-GCM, `c = base64(nonce ‖ ciphertext ‖ tag)` with a fresh 12-byte nonce,
  additional data `pico-push-v1:<host>`. The plaintext is `{"title", "body", "url"}`.
- **What Apple sees:** the device token, the bundle id (topic), the host name (thread id), the key
  id, timing and the fixed placeholder text. Not the sender, subject, repository or link.
- **Notification Service Extension** (`PicoNotificationService`): reads the host's key from a
  keychain group shared with the app (`<team prefix>.com.openminis.app.push`) by host and key id, decrypts, and replaces
  title and body; it puts the link in `userInfo["pico_url"]` and then removes the `pico` envelope.
  When decryption fails it shows "Pico could not decrypt this notice. Open Settings → Remote Hosts →
  <host> → Notifications and tap Send to This iPhone." and leaves the envelope in place, with no
  `pico_url`, so the tap can try the same keys again.
  The keys are stored After First Unlock (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), since
  the extension runs while the phone is locked.
- **Tap:** the notification delegate passes `userInfo["pico_url"]` to the same `host-event` opener as the
  `pico://` link (§9.1). Whenever the delivered notice has no `pico_url` but still has the `pico`
  envelope (the extension crashed, or its time ran out before it decrypted), the delegate opens the
  envelope itself with the same keys.

## 6. Where the code goes

| Part | Location |
|---|---|
| APNs notifier, JWT, payload | `host/minis-hostd/internal/notify/apns.go` |
| Registration file, `apns register`, `apns unregister` | `internal/notify/registration.go`, `internal/cli/apns.go` |
| Config `[apns]` | `internal/config` |
| Envelope, cipher, provisioning parser (tested with `swift test`) | `src/ios/Packages/PicoPush` |
| Extension target | `src/ios/PicoNotificationService/` |
| Registration UI and token handling | `Agent/Remote/PushRegistration.swift`, `HostNotificationsView` |
| Tap routing | one fork-marked line in `ShortcutNotificationDelegate` |

## 7. Out of scope

- Several phones per host.
- Notification actions (mark read, explain), the app badge and time-sensitive interruption.
- The relay of §15, needed only for a distributed build.
