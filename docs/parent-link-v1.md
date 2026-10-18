# Parent link, version 1

How a parent's phone watches and controls Tax Collector on a student's computer, through a relay server the family runs. Three programs implement this:

- the computer app: Tax Collector for Mac (`Sources/`) and for Windows (`windows/`);
- the relay server (`server/`);
- the parent app, a home-screen web app the server hosts (`parent/`).

They have to agree byte for byte. When this document and code disagree, this document wins; change it first. Test vectors are in `spec/vectors/v1.json`, made by `spec/vectors/gen.mjs`. Every implementation checks itself against them.

Words like "must" mean what they say. `‖` means joining bytes end to end.

---

## 1. What it protects against

The student controls their computer account, every data file the app keeps, the mini PC that runs the server, and this repository, so also the parent app's code. With that in mind:

- **Strangers on the internet get nothing.** They can't read anything, send commands, or pair a phone. Assume they can find the server: its address is public, because HTTPS certificates are published.
- **The student can't forge or replay a parent's commands through the server.** Commands are signed by a key that never leaves the parent's phone.
- **Cutting the link shows on the parents' phones.** That includes stopping the app, deleting its files, putting it in test mode, or changing its clock.
- **The remote path is never the easiest way around a lock.**

**Out of scope, said plainly in the README:** a student who rebuilds the app, runs a modified server, or serves a modified parent app from their own server can defeat this. The app holds the student to their own deadlines with a parent watching; it isn't device management. It also can't block websites: Arc stays open during a lock.

---

## 2. Encodings

| Thing | Encoding |
|---|---|
| Binary in JSON | base64url (RFC 4648 §5), no padding |
| Times | integer milliseconds since 1970-01-01 UTC |
| Calendar dates | `"YYYY-MM-DD"` text, in the computer's time zone |
| UUIDs | lowercase, with dashes. Swift's `uuidString` is uppercase, so lower it. |
| Text | UTF-8 |
| Public keys | P-256, 65-byte uncompressed point (`04 ‖ X ‖ Y`) |
| Signatures | ECDSA P-256 with SHA-256, raw `r ‖ s` (64 bytes). This is the native format of WebCrypto, CryptoKit and .NET's `SignData`. |
| Key agreement | ECDH P-256; the shared secret is the raw 32-byte X coordinate |
| Key derivation | HKDF-SHA256 (RFC 5869) |
| Encryption | AES-256-GCM, 12-byte random nonce, 16-byte tag. A sealed **box** is `nonce ‖ ciphertext ‖ tag`, base64url. |
| Compression | raw DEFLATE, no zlib header (RFC 1951): `CompressionStream('deflate-raw')`, Apple's `COMPRESSION_ZLIB` / `NSData.compressed(using: .zlib)`, .NET's `DeflateStream` |
| Labels | the exact ASCII bytes shown, like `tc v1 pair slot` |

`HKDF(ikm, salt, info, n)` below means HKDF-SHA256 with those inputs and `n` bytes of output. A missing salt means an empty salt.

---

## 3. Names

- **Channel**: one computer's mailbox on the server. Its ID is 16 random bytes in base64url (22 characters), made by the computer. The computer makes the channel ID, not the server, so it can re-create its channel on a server that lost its data.
- **Computer token**: 32 random bytes made by the computer. Sent as `Authorization: Bearer <base64url>`.
- **Device**: one paired parent phone. Its ID is a lowercase UUID chosen by the computer at pairing.
- **Device token**: 32 random bytes made by the phone. The server learns only `SHA-256(token)`, and only from the computer.
- **Link key**: the AES key one phone and the computer share (§4.4). Every phone has its own.

The server stores token hashes, never tokens.

---

## 4. Pairing

Pairing happens with a parent at the computer, after they've typed the guardian code. It's built so that whoever runs the server, or watches the screen, can't slip their own phone in: the phone commits first, the computer reveals second, and both screens then show a 6-digit code the parent compares.

### 4.1 The pairing code

The computer shows a **pairing code**: 10 characters from Crockford's base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (about 50 bits), shown as `ABCDE-FGHJK`.

- It works for 10 minutes and once only.
- The parent types it into the **installed** parent app. On iPhone, a home-screen app has its own storage, separate from Safari, so a link or QR code opened from the camera can't pair it.
- The computer may also show a QR code holding `https://<server>/#code=ABCDEFGHJK`, for Android and desktop browsers.

To normalise, the reader uppercases, drops everything that isn't in the alphabet, and maps `O→0`, `I→1`, `L→1`. Then:

```
ikm     = UTF-8(normalised code, 10 characters)
slot    = base64url(HKDF(ikm, salt = "tc v1 pair", info = "tc v1 pair slot", 16))
pairKey = HKDF(ikm, salt = "tc v1 pair", info = "tc v1 pair key", 32)
```

Every pairing message is a box sealed with `pairKey`, using the additional data `"tc v1 pair|" + slot`. The plaintext is UTF-8 JSON with a `"t"` field naming the step.

### 4.2 Steps

| # | From | Server call | Plaintext |
|---|---|---|---|
| 1 | computer | `PUT /v1/pair/{slot}` with `{"hello": box}` | `{"t":"hello","v":1,"ch":channel,"name":computerName,"platform":"mac"|"windows","dhKey":computerDhPublic}` |
| 2 | phone | `POST /v1/pair/{slot}/toComputer` with `{"box": box}` | `{"t":"commit","commit":C}` |
| 3 | computer | `POST /v1/pair/{slot}/toPhone` | `{"t":"nonce","nonce":computerNonce}` (32 bytes) |
| 4 | phone | `POST /v1/pair/{slot}/toComputer` | `{"t":"reveal","signKey":…,"dhKey":…,"nonce":phoneNonce,"tokenHash":…,"name":deviceName}` |
| 5 | both | (on screen) | show the 6-digit code; the parent compares them |
| 6 | computer | `POST /v1/pair/{slot}/toPhone` | `{"t":"done","dev":deviceId}` or `{"t":"rejected","why":…}` |

**Step 1.**
- `computerDhPublic` is the computer's long-term ECDH public key. Make it once per install and keep it with the link file (§9).
- The server stores the hello for 10 minutes.

**Step 2.** The phone fetches the hello with `GET /v1/pair/{slot}` and opens it. Then it makes:
- a **signing key pair** (ECDSA P-256, private key non-extractable);
- an **ECDH key pair** (P-256, private key non-extractable);
- `phoneNonce` (32 random bytes);
- a device token (32 random bytes).

It sends only a commitment:

```
tokenHash = SHA-256(deviceToken)
C = base64url(SHA-256("tc v1 commit" ‖ signPub(65) ‖ dhPub(65) ‖ phoneNonce(32) ‖ tokenHash(32) ‖ UTF-8(deviceName)))
```

**Step 3.**
- The computer waits for the first commit, then sends `computerNonce` (32 random bytes).
- If a second commit arrives before step 6, it stops. Both screens show "Two phones tried to pair at once. Start again." The code is then dead.

**Step 4.** The phone reveals. The computer recomputes `C` and stops if it doesn't match.

**Step 5.** Both sides compute the code:

```
h   = SHA-256("tc v1 sas" ‖ computerNonce(32) ‖ phoneNonce(32) ‖ computerDhPub(65) ‖ phoneSignPub(65) ‖ phoneDhPub(65))
sas = (first 4 bytes of h as a big-endian unsigned 32-bit number) mod 1 000 000
```

Show it as six digits with leading zeros, split `123 456`.

- The computer shows: "Does *Mom's iPhone* show **123 456**?" next to a guardian-code field.
- The parent checks that the two codes match and types the guardian code. The panel may have been left open, so the code is asked for again.
- The parent app never asks for the guardian code.

**Step 6.** When approved, the computer:
- picks `deviceId`;
- saves the phone's two public keys, name and token hash;
- works out the link key;
- registers the token hash with the server (`PUT /v1/ch/{ch}/devices`);
- sends `done`;
- deletes the slot.

The phone saves the server's origin, channel, device ID, device token, `computerDhPublic`, `computerName` and the link key. It keeps its private keys in IndexedDB as non-extractable `CryptoKey`s.

**Timing out.** If 10 minutes pass, a box won't open, or anything else is off, either side stops and says so. Nothing is saved.

### 4.3 Why this holds

- **Someone who knows the code**, such as the student watching the screen or running the server, can stand in for either side. But they must commit to their phone's keys before they see `computerNonce`. And they can't see `phoneNonce` until after they've sent a fake computer nonce to the real phone.
- **So both codes match only by luck**: one chance in a million.
- **A stranger without the code** can't find the slot, and the server limits guesses (§6.3).

### 4.4 The link key

```
shared  = ECDH(computer DH private, phone DH public)    // or the reverse, on the phone: the same 32 bytes
linkKey = HKDF(shared, salt = base64url-decode(channel), info = "tc v1 link|" + deviceId, 32)
```

---

## 5. Messages

### 5.1 Commands (phone → computer)

The phone writes the command as UTF-8 JSON, the **body**:

```json
{"v":1,"ch":"<channel>","dev":"<device id>","n":1729200000123,"at":1729200000123,
 "id":"<uuid>","type":"lock","args":{"until":null,"strength":"homework"}}
```

**Fields:**
- `n` is the device's counter. Make it `max(previous n + 1, now in ms)`, and keep it in IndexedDB.
- Send one command at a time per device: use `navigator.locks` so two tabs can't race.
- `at` is the phone's clock when the command was made.

**Sending:**

```
sig       = ECDSA-P256-SHA256(signing private key, body bytes)   // 64 bytes, raw r‖s
plaintext = sig(64) ‖ body bytes
box       = AES-GCM(linkKey, plaintext, additional data = "tc v1 cmd|" + channel + "|" + deviceId)
```

The phone sends `POST /v1/ch/{ch}/cmd` with `{"box": box}` and its device token. The server answers `{"seq": int, "receivedAt": ms}`.

**The computer, for each command it fetches:**

1. Finds the device by the server's `dev`. An unknown device is rejected with `unknown_device`.
2. Opens the box with that device's link key.
3. Checks the signature over the body bytes **as received, before parsing them**.
4. Parses the body. Checks `v == 1`, `ch` is this channel and `dev` matches. Otherwise rejects with `wrong_target`.
5. **Replay.** If `n <= lastCounter[dev]`, rejects with `replayed` and reports `lastCounter` in the result.
6. **Freshness.** If `|receivedAt − at| > 10 minutes`, rejects with `stale`. Don't use the computer's clock here: Tax Collector's clock guard only moves forward, so it can't be trusted to compare.
7. Saves `lastCounter[dev] = n`, applies the command, and records a result (§5.3).

Commands are safe to run twice and late:
- new things carry IDs the phone made;
- times are absolute ("until 9 PM", never "for 2 hours");
- approving a proof names the exact submission.

**Settings.** For "setting" commands (§7), the change with the latest `at` wins. Each setting keeps the `at` of its last change. Guardian actions on the computer write the same records, using the computer's time.

### 5.2 State (computer → phones)

The computer builds one state document (§8), compresses it with raw DEFLATE, and seals one copy per device:

```
box = AES-GCM(linkKey of that device, deflateRaw(UTF-8 JSON), additional data = "tc v1 state|" + channel + "|" + deviceId)
```

It sends `PUT /v1/ch/{ch}/state` with `{"seq": seq, "copies": {"<deviceId>": box, …}}`.

**`seq`** goes up by one with every upload and is also inside the document. The phone ignores any state with a lower `seq` than one it has shown, so a server can't feed it old news.

**When to upload:**
- Check for changes every 5 seconds, and upload 2 seconds after something changes.
- Upload right away after applying commands, and on wake.
- Upload at least every 10 minutes.

### 5.3 Results

The state carries the last 50 results:

```json
{"dev":"…","n":1729200000123,"id":"<command id>","type":"lock","outcome":"applied","reason":"","at":1729200001000}
```

**`outcome`** is one of:
- `applied`;
- `noop` (already so, or the item is gone);
- `rejected` (with a reason: `replayed`, `stale`, `bad_signature`, `wrong_target`, `unknown_device`, `bad_args`, `not_found`);
- `unsupported` (unknown `type`, or not in this computer's capabilities).

A box that won't open, or a bad signature, is acknowledged and logged as a tamper warning. No command is applied from it.

---

## 6. Server API

**Requests:**
- JSON in and out. Every response carries `X-TC-Instance`, a random ID made once when the server's data folder is created.
- API responses carry `Cache-Control: no-store`.
- Errors look like `{"error":"code","message":"…"}` with an HTTP status: `400 bad_request`, `401 unauthorized`, `403 forbidden`, `404 not_found`, `409 conflict`, `410 gone`, `413 too_large`, `429 rate_limited`.

**Tokens:** `Authorization: Bearer <base64url token>`.
- A **computer token** may call the endpoints marked *computer*. The server checks `SHA-256(token)` against the hash stored for that channel.
- A **device token** may call the endpoints marked *phone*. The server finds the device by the hash.

### 6.1 Endpoints

| Method and path | Who | Body / answer |
|---|---|---|
| `GET /v1/health` | anyone | → `{"ok":true,"v":1,"instance":"…","time":ms}` |
| `PUT /v1/channels/{ch}` | computer (its token as Bearer; `tokenHash` must equal SHA-256 of it) | `{"setupCode":"…","tokenHash":"…"}` → `201` created, `200` already yours, `403` wrong setup code, `409` taken by another token, `429` too many channels |
| `DELETE /v1/channels/{ch}` | computer | → `204`. Afterwards, phone calls on this channel get `410 {"unlinkedAt":ms}` for 30 days. |
| `PUT /v1/ch/{ch}/devices` | computer | `{"devices":[{"id":"…","tokenHash":"…"}]}`. Replaces the list, at most 8. → `204` |
| `PUT /v1/ch/{ch}/state` | computer | `{"seq":int,"copies":{"<dev>":box}}`. Each copy at most 256 KB. → `204` |
| `GET /v1/ch/{ch}/state` | phone | → `200 {"seq","box","updatedAt","serverTime","computerSeen","computerAwake","ackedUpTo","lastCmdSeq"}`. Supports an `ETag`, answered `304` when nothing changed. `204` when there's no state yet. |
| `POST /v1/ch/{ch}/cmd` | phone | `{"box"}`, at most 16 KB → `201 {"seq","receivedAt"}`. At most 500 waiting per channel; anything older than 14 days is dropped. |
| `GET /v1/ch/{ch}/cmd?wait=25` | computer | → `200 {"serverTime":ms,"commands":[{"seq","dev","box","receivedAt"}]}`. Returns every command after `ackedUpTo`, waiting up to `wait` seconds (25 at most) if there are none. |
| `POST /v1/ch/{ch}/cmd/ack` | computer | `{"upTo":seq}` → `204` |
| `POST /v1/ch/{ch}/presence` | computer | `{"awake":bool}` → `204`. Sent on going to sleep and on waking. |
| `PUT /v1/pair/{slot}` | computer | `{"ch":"…","hello":box}`. The token must own `ch`. Expires in 10 minutes. → `201` |
| `GET /v1/pair/{slot}` | anyone | → `200 {"hello":box}` or `404`. Rate-limited (§6.3). |
| `POST /v1/pair/{slot}/toComputer` | anyone holding the slot | `{"box"}` → `201 {"n":int}`. At most 4 messages per slot. |
| `GET /v1/pair/{slot}/toComputer?after=n&wait=25` | computer | → `200 {"messages":[{"n","box"}]}` |
| `POST /v1/pair/{slot}/toPhone` | computer | `{"box"}` → `201 {"n":int}` |
| `GET /v1/pair/{slot}/toPhone?after=n&wait=25` | anyone holding the slot | → `200 {"messages":[{"n","box"}]}` |
| `DELETE /v1/pair/{slot}` | computer | → `204` |

**Liveness:**
- `computerSeen` is the server's time of the computer's most recent request.
- A waiting `GET …/cmd` counts the whole time it's open, so it doubles as the heartbeat.
- `computerAwake` is the last `presence` value. It turns `true` whenever the computer makes a request.

The parent app works out how fresh things are from `serverTime − computerSeen`. Neither the phone's nor the computer's clock is used for this.

**Server reset.** If the server lost its data, the computer gets `404` on its channel or sees `X-TC-Instance` change. It then re-creates the channel (`PUT /v1/channels/{ch}`, using the setup code it keeps), re-registers its devices, and uploads state.

### 6.2 Setup code

The first time it starts, the server makes a **setup code**: 12 Crockford base32 characters. It saves the code in its data folder and prints it. A channel can't be created without it, so strangers can't use the server as free storage. The computer's settings hold the server address and the setup code.

### 6.3 Limits and hygiene

**Limits:**
- 8 channels per server and 8 devices per channel.
- 2 waiting requests per channel.
- Pairing lookups (`GET /v1/pair/{slot}`): 10 per minute per IP. Other unauthenticated calls: 60 per minute per IP.
- Request bodies: 300 KB. Request timeout: 40 seconds.

**Hygiene:**
- Never log bodies or tokens; log channel IDs only as short hashes.
- Serve the parent app from a fixed list of files, never from a path built from the URL.
- Send `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`. The parent app's pages also get `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`.

**What the server can see:** IP addresses, browser user agents, when the computer is awake and active (from request times), roughly how much it has to say (from box sizes), and when commands are sent. It can't see task text, verdicts, app names, activity, or what any command says.

---

## 7. Commands

Every command has the common fields of §5.1. Under **Setting**, "—" means it's an action rather than a setting. Arguments not listed must be absent.

| `type` | `args` | What the computer does | Setting |
|---|---|---|---|
| `lock` | `{"until":ms\|null,"strength":"homework"\|"all","note":text?}` | Parent lock, regardless of tasks, until `until` (or until lifted). `homework` keeps the allowed apps open; `all` closes everything except system apps and Tax Collector. | access |
| `free` | `{"until":ms}` | Unlocked until `until`, whatever is overdue. The same as the guardian's "unlock for a while". Clears a parent lock. | access |
| `normal` | `{}` | Back to the normal rules: clears a parent lock or an unlock. | access |
| `addTask` | `{"task":{"id","title","details","due":ms}}` | Adds it. If that ID exists already: `noop`. | — |
| `editTask` | `{"id","title"?,"details"?,"due"?}` | Changes the fields given. Parents aren't held to the 24-hour freeze. | — |
| `deleteTask` | `{"id"}` | Deletes it (`noop` if it's gone). | — |
| `excuseTask` | `{"id"}` | Marks it excused. | — |
| `approveProof` | `{"taskId","proofId"}` | Approves **that** submission (guardian-approved). Its submit time decides on time or late. `noop` if the task is already settled. | — |
| `addRepeat` | `{"repeat":{"id","title","details","unit":"days"\|"weeks","interval","weekdays":[1–7],"minuteOfDay","startDate":"YYYY-MM-DD"}}` | Adds a repeating task. `weekdays` uses 1 = Sunday … 7 = Saturday, for `weeks`. | — |
| `stopRepeat` | `{"id"}` | Stops it. Copies already out stay. | — |
| `allowApp` | `{"app":{"id","name"}}` | Keeps the app open during locks. | per app |
| `disallowApp` | `{"app":{"id","name"}}` | Removes it from the extra allowed apps. | per app |
| `blockApp` | `{"app":{"id","name"}}` | Closes the app whenever it runs, locked or not. Blocking beats allowing. | per app |
| `unblockApp` | `{"app":{"id","name"}}` | Removes the block. | per app |
| `setPenalty` | `{"minutes":0–720}` | Late penalty length. | penalty |
| `setExtensions` | `{"enabled":bool}` | Turns asking Claude for more time on or off. | extensions |
| `message` | `{"text":≤300 characters}` | Shows a notification and keeps the message on the main window and lock screen for 24 hours. | — |
| `removeDevice` | `{"id"}` | Unpairs that phone (it may be the sender). Its key and state copy are dropped, and its token is deregistered. | — |

**App IDs:** bundle IDs on Mac, `windows:<identity>` strings on Windows. The parent app picks them from the state's `apps.running` and `apps.recent`.

**Messages to the student.** Every applied command shows a notification on the computer naming the device, for example "Mom's iPhone locked this Mac until 9:00 PM". It's also added to the activity list.

---

## 8. State document

UTF-8 JSON, before compression. Text fields are cut to the lengths shown. A field whose value is `null` may also be left out, so read a missing field as `null`.

```json
{
  "v": 1,
  "seq": 42,
  "sentAt": 1729200000000,
  "computer": {
    "name": "…", "platform": "mac", "app": "0.7.0", "os": "macOS 26.1",
    "timeZone": "America/Toronto",
    "capabilities": ["lock","tasks","repeats","apps","block","penalty","extensions","message","approveProof"]
  },
  "access": {"mode": "normal" | "locked" | "free", "until": null, "strength": null, "by": "…", "at": 0},
  "lock": {"locked": false, "reasons": [{"kind": "overdue" | "penalty" | "parent", "taskId": "…", "title": "…", "until": 0}]},
  "tasks": [{
    "id": "…", "title": "≤200", "course": "≤100", "details": "≤500", "due": 0, "created": 0,
    "status": "pending" | "proven" | "provenLate" | "excused", "statusAt": null, "penaltyEndsAt": null,
    "source": "manual" | "blackbaud" | "repeat", "repeatId": null, "checking": false,
    "proofs": [{"id": "…", "at": 0, "files": 1, "note": "≤300",
                "verdict": null | "accepted" | "rejected" | "error" | "guardianApproved", "reason": "≤300"}],
    "extensions": [{"at": 0, "hoursAsked": 3, "hoursGranted": 0, "decision": null | "granted" | "denied" | "error",
                    "reason": "≤300", "answer": "≤300"}]
  }],
  "repeats": [{"id": "…", "title": "…", "details": "…", "unit": "weeks", "interval": 1, "weekdays": [2],
               "minuteOfDay": 510, "startDate": "2026-10-19", "currentDue": null,
               "schedule": "Every Monday at 8:30 AM"}],
  "apps": {
    "builtIn":  [{"id": "…", "name": "…"}],
    "allowed":  [{"id": "…", "name": "…"}],
    "blocked":  [{"id": "…", "name": "…"}],
    "running":  [{"id": "…", "name": "…"}],
    "recent":   [{"id": "…", "name": "…", "lastSeen": 0}]
  },
  "settings": {"penaltyMinutes": 30, "extensionsEnabled": true},
  "trackRecord": {"onTime": 5, "late": 0, "missed": 0, "extensionsThisWeek": 0},
  "activity": [{"at": 0, "kind": "…", "text": "≤200"}],
  "results": [],
  "devices": [{"id": "…", "name": "…", "pairedAt": 0}],
  "flags": [{"kind": "…", "text": "≤200", "at": 0}],
  "message": null
}
```

**What's included:**
- `tasks` holds every pending task, plus tasks settled in the last 14 days, newest first, 150 at most.
- `apps.running` and `apps.recent` hold at most 50 apps each.
- `activity` holds the latest 100 events.
- Text from the computer contains no line breaks: they're replaced with spaces.

**`flags`** carry tamper and health warnings. Each has a `kind`:

| `kind` | Meaning |
|---|---|
| `testMode` | Dry run, limited enforcement, or a test data folder is in use |
| `noBackgroundAgent` | The LaunchAgent (Mac) or scheduled task (Windows) is missing |
| `guardianChanged` | The guardian code changed without a guardian action the app saw |
| `overrideMismatch` | The saved unlock time isn't the one the app wrote |
| `clockSkew` | The computer's clock is more than 2 minutes off the server's time |
| `gap` | The app wasn't running while the computer was awake. Its text says when. |
| `linkRestored` | The link file was missing and restored from the backup copy |
| `restarts` | It was stopped and restarted today. Its text says how many times. |
| `badCommand` | A command box failed to open or its signature was bad |

**Never in the state:** the Blackbaud feed link or sign-in, the Claude token, the guardian code's hash, link secrets, proof files.

---

## 9. What the computer keeps

`parent-link.json` sits next to the other data files. It holds:
- the server URL and setup code;
- the channel, the computer token, and the computer's ECDH private key;
- the paired devices, each with its ID, name, sign key, DH key, token hash, link key and paired time;
- `lastCounter` for each device;
- the per-setting `at` times;
- `stateSeq`;
- the last 50 results.

A second copy goes in the app's preferences (Mac) or the registry (Windows), and `settings.json` gets `"parentLinked": true`.

**When the file is missing:**
- If the marker is set, restore it from the copy and raise `linkRestored`.
- If both the file and its copy are gone, the phones see the computer go quiet. That is the alarm.

**While linked**, a missing guardian code must not bring back the first-run welcome screen. The app shows "Ask a parent" instead.

The file's permissions (0600) keep out other accounts on the computer, not the student.

---

## 10. Versions

- Paths start with `/v1/`, and every message carries `"v": 1`.
- Within v1, fields and command types may be **added** but never changed or removed.
- Readers ignore fields they don't know.
- The parent app hides controls whose capability the computer doesn't list. The Windows app may support fewer.
