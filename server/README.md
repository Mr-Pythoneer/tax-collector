# Relay server

Runs on the family's own always-on computer (a mini PC). It passes encrypted messages between Tax Collector and the parents' phones, and serves the parent app. It can't read what it passes on.

Protocol: [`docs/parent-link-v1.md`](../docs/parent-link-v1.md) (§6 is this server). Test vectors: [`spec/vectors/v1.json`](../spec/vectors/v1.json).

## What it can and can't see

Everything a computer and a phone send each other is sealed with a key that only those two share. The relay stores the sealed boxes and the hashes of tokens, never the tokens themselves.

- **It can see** IP addresses, browser user agents, when the computer is awake and active (from when it makes requests), roughly how much it has to say (from the size of the boxes), and when commands are sent.
- **It can't see** task text, verdicts, app names, activity, or what any command says.
- **It can't act for a parent.** Commands are signed by a key that never leaves the phone. Pairing ends with both screens showing a 6-digit code for the parent to compare, so whoever runs the relay can't slip in a phone of their own.

Whoever controls the mini PC could still serve a changed parent app. That's outside what the parent link protects against ([§1](../docs/parent-link-v1.md#1-what-it-protects-against)).

## Try it on any computer

It needs Node.js 22 or newer and nothing else: no `npm install`. From the repository root:

```sh
node server/server.mjs
```

It listens on `http://127.0.0.1:8787`, keeps its data in `server/data`, and prints the setup code the first time it starts. `node server/server.mjs --setup-code` shows the code again. Test scripts can start a throwaway relay with `node server/server.mjs <port> <setup code>`: that port, that setup code (12 Crockford characters), and a new empty data folder that's deleted when it stops. To check that it answers:

```sh
curl http://127.0.0.1:8787/v1/health
# {"ok":true,"v":1,"instance":"…","time":…}
```

Ctrl-C stops it. Phones need HTTPS, so for real use, run it on the mini PC behind Tailscale Funnel, as described below.

## Running it on the mini PC

The mini PC has to stay on, so turn off sleep. Choose one way to run the relay: [Docker](#with-docker), [systemd](#with-systemd-linux) on Linux, or a [scheduled task](#on-windows) on Windows. Each one listens on `127.0.0.1:8787` only, so nothing else on your network can reach the relay. [Tailscale Funnel](#https-with-tailscale-funnel) is the way in from outside.

### With Docker

Build the image on the mini PC, from the repository root. The same Dockerfile works on x86-64 and ARM.

```sh
docker build -f server/Dockerfile -t tax-collector-relay .
```

Run it:

```sh
docker run -d --name tax-collector-relay --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p 127.0.0.1:8787:8787 -v tcrelay-data:/app/server/data tax-collector-relay
```

The two `--log-opt` settings keep Docker's copy of the log to 30 MB. Or let Docker Compose build and run it in one step. Its file, `server/deploy/compose.yaml`, does the same and also makes the container's file system read-only.

```sh
docker compose -f server/deploy/compose.yaml up -d --build
```

Use one or the other. Both name the container `tax-collector-relay` and keep the data in the volume `tcrelay-data`.

The setup code is printed when the relay first starts:

```sh
docker logs tax-collector-relay
```

To see it again at any time:

```sh
docker exec tax-collector-relay node server/server.mjs --setup-code
```

Good to know:

- The relay runs as the image's `node` user (uid 1000). A named volume, as above, is made writable for it automatically. If you use a folder on the host instead (`-v /some/folder:/app/server/data`), make uid 1000 its owner first.
- Behind a published port, requests reach the relay from Docker's own address, not from loopback. So the image sets `TC_TRUST_PROXY=private`: the relay believes the `X-Forwarded-For` that Tailscale adds when a request comes from a private address, and its [per-address limits](#limits) see each visitor's own address. That's safe while the port is published on `127.0.0.1` only, as above. If you publish it on your whole network, set `TC_TRUST_PROXY` to Docker's bridge range instead (usually `172.17.0.1`), or use host networking on Linux: `--network host -e HOST=127.0.0.1 -e TC_TRUST_PROXY=loopback` in place of `-p 127.0.0.1:8787:8787`.
- On Windows, prefer the [scheduled task](#on-windows): Docker Desktop only runs while someone is signed in.

### With systemd (Linux)

1. **Install Node.js 22 or newer.** Use your distribution's package if it's new enough; [nodejs.org/en/download](https://nodejs.org/en/download) lists other ways. Check with `node --version`. The service expects `/usr/bin/node`. If `command -v node` prints another path, change `ExecStart` in the unit file to match. An nvm install won't do, because the service can't see `/home`.
2. **Copy the relay** to `/opt/tax-collector`, from a copy of this repository:

   ```sh
   sudo mkdir -p /opt/tax-collector/server
   sudo cp -r server/server.mjs server/package.json server/lib /opt/tax-collector/server/
   sudo cp -r parent /opt/tax-collector/
   ```

3. **Make the user** it runs as:

   ```sh
   sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin tcrelay
   ```

4. **Install the service**, start it, and have it start with the computer:

   ```sh
   sudo cp server/deploy/tax-collector-relay.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now tax-collector-relay
   systemctl status tax-collector-relay
   ```

5. **Read the setup code.** It's printed on first start (`sudo journalctl -u tax-collector-relay`). To see it again:

   ```sh
   sudo -u tcrelay TC_DATA_DIR=/var/lib/tax-collector-relay node /opt/tax-collector/server/server.mjs --setup-code
   ```

The data folder is `/var/lib/tax-collector-relay`. Logs: `journalctl -u tax-collector-relay`. Settings such as `TC_SETUP_CODE` go in `/etc/tax-collector-relay.env`, one `NAME=value` per line, readable by root only (`sudo chmod 600`). Restart the service after changing them. The unit also locks the service down: it can read its code, write its data folder and talk to localhost, and little else.

### On Windows

1. **Install Node.js LTS** (22 or newer) from [nodejs.org](https://nodejs.org) with the default options, which install it for all users.
2. **Copy** the repository's `server` and `parent` folders into `C:\Program Files\TaxCollectorRelay`, so that `C:\Program Files\TaxCollectorRelay\server\server.mjs` exists.
3. **Run the install script** in PowerShell, opened as administrator:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "C:\Program Files\TaxCollectorRelay\server\deploy\install-windows-task.ps1"
   ```

   It registers the scheduled task "Tax Collector relay", which starts the relay with Windows, before anyone signs in, and starts it again within a minute if it stops. The task runs as the built-in LOCAL SERVICE account, which can't change Windows or other people's files. The script prints the setup code and checks that the relay answers. It downloads nothing.

4. **To see the setup code again**, in PowerShell as administrator:

   ```powershell
   node --env-file="$env:ProgramData\TaxCollectorRelay\relay.env" "C:\Program Files\TaxCollectorRelay\server\server.mjs" --setup-code
   ```

The data folder is `C:\ProgramData\TaxCollectorRelay\data`. Settings are in `C:\ProgramData\TaxCollectorRelay\relay.env`; run the script again after changing them. Task Scheduler doesn't keep the relay's output, so if it won't start, look at the task's Last Run Result, or stop the task and run the relay by hand (the script's warning shows the command). To remove the task: `Unregister-ScheduledTask -TaskName 'Tax Collector relay'`.

## HTTPS with Tailscale Funnel

Phones talk to the relay only over HTTPS: the parent app's encryption and offline support work only on secure pages. [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) gives the mini PC a public HTTPS address, `https://<your-machine>.<your-tailnet>.ts.net`, with a certificate that Tailscale renews, and passes requests on to the relay at `http://127.0.0.1:8787`. No router changes or open ports are needed. With Docker, Tailscale runs on the mini PC itself, not in a container.

> [!WARNING]
> **The address must never change once a phone is paired.** Each phone's keys and saved data belong to that exact address. If it changes, every phone has to pair again. It changes if you rename the machine in Tailscale, rename the tailnet, rename the computer while Tailscale names the machine after it (the default), or set Tailscale up again on the mini PC while its old entry is still listed (it comes back as `<your-machine>-1`). Settle the name before pairing the first phone.

1. **Install Tailscale** on the mini PC from [tailscale.com/download](https://tailscale.com/download) and sign in (on Linux: `sudo tailscale up`).
2. **In the Tailscale admin console**, on the Machines page, open the menu on the mini PC's row:
   - **Edit machine name**: pick the name for good, and turn off **Auto-generate from OS hostname**.
   - **Disable key expiry**: otherwise its key expires (after 180 days, by default), and phones can't reach the relay until someone signs the mini PC in again.
3. **Turn on Funnel**, in the background so it stays on after restarts:

   ```sh
   sudo tailscale funnel --bg 8787
   ```

   On Windows, run `tailscale funnel --bg 8787` in PowerShell as administrator. The first time, it may show a link to allow Funnel for your tailnet, which also turns on HTTPS certificates; open it, approve, and run the command again. Funnel also needs MagicDNS, which is on unless someone turned it off. The command prints the public address and shows that it forwards to `http://127.0.0.1:8787`. Funnel serves on port 443, so the address needs no port number.
4. **Check it** from a phone on mobile data, not Wi-Fi: `https://<your-machine>.<your-tailnet>.ts.net/v1/health` should show `{"ok":true,...}`. A new address can take a few minutes to start working.

`tailscale funnel status` shows what's shared. `tailscale funnel --https=443 off` turns it off.

## Setting up computers

In Tax Collector's settings on each computer, enter the relay's address, `https://<your-machine>.<your-tailnet>.ts.net`, and the setup code. The code can be typed with or without its dashes.

Keep the setup code and the address somewhere safe, such as a password manager. Anyone who has the code can add computers to the relay (8 at most), so keep it in the family. Phones never need it: each phone is paired from a computer, which shows a pairing code for a parent to type into the parent app, installed from the same address ([`parent/README.md`](../parent/README.md)).

**Pinning the setup code (optional, recommended).** The relay makes its setup code once and keeps it in its data folder. If that folder is ever lost, the relay makes a new code, and each computer stays offline until someone types the new code into it. Setting `TC_SETUP_CODE` to your current code prevents that: a relay with an empty data folder takes that code, and computers set themselves up again on their own. Use the code the computers already have; a different one replaces it.

- **Docker:** add `-e TC_SETUP_CODE=<your setup code>` to `docker run` (or uncomment the two lines in `compose.yaml`), then remove and re-create the container.
- **systemd:** put `TC_SETUP_CODE=<your setup code>` in `/etc/tax-collector-relay.env`, then `sudo systemctl restart tax-collector-relay`.
- **Windows:** in `relay.env`, uncomment the `TC_SETUP_CODE` line and put your code in it, then run the install script again.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8787` | The port the relay listens on. |
| `HOST` | `127.0.0.1` (Docker image: `0.0.0.0`) | The address it listens on. Keep it local: Tailscale reaches it there. Inside Docker, `0.0.0.0` lets the published port reach it. |
| `TC_DATA_DIR` | `server/data` (in the Docker image, `/app/server/data`) | The data folder, with the setup code and the computers' channels. It must last across restarts. |
| `TC_SETUP_CODE` | not set | Pins the 12-character setup code ([above](#setting-up-computers)). |
| `TC_TRUST_PROXY` | `loopback` (Docker image: `private`) | Which proxies to believe about the visitor's address, for rate limits: for a request from one of them, the last `X-Forwarded-For` entry counts (Tailscale Funnel puts the real visitor's address there). `loopback`: this computer only. `private`: also private networks (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7). A comma-separated list of addresses and ranges, like `172.17.0.1,10.0.0.0/8`: loopback plus those. `0`: nobody. |
| `TC_LOG_REQUESTS` | off | `1` logs one line per request: time, method, route, status and duration. Never bodies or tokens, and channel IDs only as short hashes. |
| `TC_PARENT_DIR` | `parent` beside `server` | Where the parent app's files are. |

## Backups

The data folder is small. It holds the setup code, the relay's instance ID, and for each computer: the hash of its token, its phones' token hashes, its latest sealed state, and sealed commands not yet delivered.

| Running with | Data folder |
|---|---|
| Docker | the `tcrelay-data` volume (`/app/server/data` in the container) |
| systemd | `/var/lib/tax-collector-relay` |
| Windows | `C:\ProgramData\TaxCollectorRelay\data` |
| A quick try | `server/data` |

To back it up, copy the folder. With Docker: `docker cp tax-collector-relay:/app/server/data ./relay-backup`. Copying while the relay runs is fine, because it replaces each file in one step.

**If the data folder is lost**, the relay starts over with an empty one and a new instance ID. Computers notice, then re-create their channels, register their phones again and upload their state. They do this by themselves only if the setup code is unchanged, which means pinned with `TC_SETUP_CODE`. Otherwise the relay makes a new code, and each computer needs it typed in. Either way, phones don't need to pair again, as long as the address stays the same.

So with a pinned code, starting empty is often better than restoring an old copy: computers rebuild everything, including phones paired since the copy was made. A restored copy brings back the old instance ID, so computers don't notice the change, and a phone paired after the copy was made isn't registered with the relay.

## Updating

Phones and computers carry on through an update, as long as the address and the data folder stay the same. They see the relay as unreachable for the few seconds it takes to restart.

- **Docker:** get the new version of the repository (`git pull`), rebuild, and replace the container. The volume keeps the data. `--pull` also fetches the newest Node.js 24 base image, with its security fixes.

  ```sh
  docker build --pull -f server/Dockerfile -t tax-collector-relay .
  docker stop tax-collector-relay && docker rm tax-collector-relay
  # then the same docker run command as before
  ```

  With Compose: `docker compose -f server/deploy/compose.yaml build --pull`, then `docker compose -f server/deploy/compose.yaml up -d`.
- **systemd:** get the new version, copy the files again (step 2 above), then `sudo systemctl restart tax-collector-relay`. If the unit file changed, copy it again and run `sudo systemctl daemon-reload` first.
- **Windows:** copy the new `server` and `parent` folders over the old ones, then run the install script again. It restarts the relay.

## Limits

From [§6.3](../docs/parent-link-v1.md#63-limits-and-hygiene):

- 8 computers per relay, and 8 phones per computer.
- 2 waiting requests (long polls) per computer.
- Per visitor address, each minute: 10 pairing-code lookups, 60 other requests without a valid token, and 600 requests for parent app files. Requests carrying a computer's or a paired phone's token don't count.
- Request bodies up to 300 KB, and 40 seconds per request.
- Up to 256 KB of state per phone. Commands up to 16 KB each, at most 500 waiting per computer; any older than 14 days are dropped.
- A pairing code works for 10 minutes. After a computer unlinks, its phones are told so for 30 days.

## Running the tests

```sh
cd server && npm test
```

Or, from the repository root: `node --test server/test/`. The tests start their own relays on free ports, with temporary data folders.

## Testing tools

Stand-ins for trying the relay and the parent app without a Mac or a phone. Both follow the protocol exactly, and the end-to-end test (`server/test/e2e.test.mjs`) runs them against a real relay.

**Fake computer:** plays Tax Collector, with a believable week of homework (an overdue worksheet with a proof Claude turned down, repeats, apps, a track record). It makes its channel, shows a pairing code, approves pairings by itself, applies every command and uploads state.

```sh
node server/tools/fake-computer.mjs --server http://localhost:8787 --setup-code <code> --approve-delay 10
```

| Option | |
|---|---|
| `--name "Sam's MacBook Air"` | The computer's name. |
| `--platform windows` | Says it's a Windows computer. |
| `--file fake.json` | Keeps its keys, phones and homework in this file, so it survives a restart. |
| `--approve-delay 10` | Waits 10 seconds before approving a pairing, like a parent typing the guardian code, so the 6-digit number can be compared. |
| `--pair` | Shows a pairing code even if a phone is paired already. |
| `--no-seed` | Starts with no homework. |
| `--flag testMode` | Starts with a tamper warning. |

While it runs, type: `pair` (a new code), `sleep` and `wake`, `overdue` (adds an overdue task), `proof` (adds a proof to approve), `flag <kind>` and `unflag`, `reject <reason>` (turns down the next command), `remove <phone name>` (as the guardian would on the computer), `status`, `quit`.

**Fake phone:** runs the parent app's own protocol code (`parent/js/phone.js`). It pairs by code, then sends every command type and checks what the computer did, one line per check.

```sh
node server/tools/fake-phone.mjs --server http://localhost:8787 --code <pairing code> --name "Test Phone"
```

`--pair-only` stops after pairing, to add a second phone to a computer.
