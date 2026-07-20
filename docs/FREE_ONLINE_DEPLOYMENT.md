# Free Online Deployment (Web + Android)

## How the backend works

There is exactly ONE backend for every platform: the headless Godot server
(`scenes/game/Server.tscn`) speaking WebSocket. Web browsers, Android phones
and desktop builds all connect to the same `wss://` URL. No Epic Online
Services, no Firebase, no third-party gameplay SDK is needed — the server
is fully authoritative (shuffling, dealing, validation, scoring, timeouts).

```text
Web client (itch.io)  ─┐
Android client (APK)  ─┼──>  wss://your-app.onrender.com  ──>  Godot headless server
Desktop client        ─┘         (TLS by Render)               (Docker, port 12345)
```

Free hosting: **Render free tier** (recommended start) or **Oracle Cloud
Always Free** (always-on upgrade, no cold starts). Both are documented below.

---

## Step 1 — One-time editor setup

1. Open the project in Godot 4.6 once (it will import the new fonts/theme).
2. Editor > Manage Export Templates > download templates for 4.6.

## Step 2 — Deploy the server (Render free tier)

1. Push this repo to GitHub.
2. In the Godot editor: Project > Export > `server.x86_64` (Linux dedicated
   server preset) and put fresh `server.x86_64` + `server.pck` into `server/`.
   Commit and push. **Repeat this every time Server.gd or NetworkManager.gd
   changes** — old server + new client will not match.
3. On render.com (free account, no card): New > Web Service > pick the repo.
   - Runtime: **Docker**, Root Directory: `server`
   - Instance type: **Free**
   - Environment variable: `PORT` = `12345`
4. Deploy → you get `https://your-app.onrender.com`.
5. In `res://scripts/network/NetworkManager.gd` set:

```gdscript
var production_websocket_url: String = "wss://your-app.onrender.com"
```

Free-tier caveat: the service sleeps after ~15 min idle; the first player
waits ~30-60 s while it wakes. Active games keep it awake. If that bothers
players later, move to Oracle (bottom of this file) — clients don't change,
only the URL.

## Step 3 — Web client (itch.io, free)

1. Project > Export > **Web** preset (thread support already disabled, so
   itch.io needs no special settings) > Export Project.
2. Zip the export folder contents (index.html at the zip root).
3. itch.io > Upload new project > Kind: **HTML** > upload zip > tick
   "This file will be played in the browser".
4. Set embed size to something like 1280x720 and allow fullscreen.

## Step 4 — Android client (free)

Requirements (one-time):

1. Install **JDK 17** (Temurin) and **Android Studio** (for the SDK).
2. Godot Editor > Editor Settings > Export > Android: set the paths to the
   SDK (`%LOCALAPPDATA%\Android\Sdk`) and Java.
3. Create a debug keystore if you don't have one:

```powershell
keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android -keystore debug.keystore -storepass android -dname "CN=Android Debug,O=Android,C=US" -validity 9999
```

   and point Editor Settings > Export > Android > Debug Keystore at it
   (user: `androiddebugkey`, password: `android`).

Then: Project > Export > **Android** preset > Export Project (APK).

- The preset already enables the **INTERNET permission** (required for
  multiplayer) and immersive landscape mode.
- Android blocks cleartext `ws://` by default — we use `wss://`, so nothing
  extra is needed.
- Install the APK on your phone (enable "install unknown apps") and test
  against the live server together with a browser client.
- For the Play Store later: switch the preset to Gradle build + AAB format
  and sign with a release keystore.

## Step 5 — Verify online multiplayer

1. Phone (APK) + PC browser (itch.io page), both on the live server.
2. Create a room on one, join by code on the other, add bots, start.
3. Play two full games (dealer must rotate after game 1).
4. Test a 6-player and an 8-player room with bots.

## Local testing (optional)

Run `scenes/game/Server.tscn` in the editor, then start clients with the
`--local-server` argument (web: append `?local=1` to the URL). Clients then
use `ws://127.0.0.1:12345` instead of the production URL.

---

## Upgrade path: Oracle Cloud Always Free (no cold starts)

1. Always Free Ubuntu VM, open ports 80/443.
2. Free hostname from DuckDNS → `yourname.duckdns.org` → VM IP.
3. Install Caddy, `/etc/caddy/Caddyfile`:

```caddy
yourname.duckdns.org {
    reverse_proxy 127.0.0.1:12345
}
```

4. Run `server.x86_64 --headless res://scenes/game/Server.tscn` under
   systemd (`Restart=always`).
5. Change the client URL to `wss://yourname.duckdns.org` and re-export
   clients. Nothing else changes.

## Notes

- `server/fly.toml` is from an earlier attempt; Fly.io no longer has a
  free tier for new accounts.
- EOS (Epic Online Services) was removed from the project entirely — it was
  unused, had no web binaries, and is not needed on Android either. The
  addon is backed up at `Desktop\Godot\_removed_from_mendigo\` if ever
  wanted again.
