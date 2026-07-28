# Free Online Deployment (Web + Android)

## How the backend works

There is exactly ONE backend for every platform: the headless Godot server
(`scenes/game/Server.tscn`) speaking WebSocket. Web browsers, Android phones
and desktop builds all connect to the same `wss://` URL. No Epic Online
Services, no Firebase, no third-party gameplay SDK is needed — the server
is fully authoritative (shuffling, dealing, validation, scoring, timeouts).

```text
Web (mendigo.fernbuild.com) ─┐
Android client (APK)        ─┼─> wss://mendigo.onrender.com ─> Godot headless server
Desktop client              ─┘        (TLS by Render)           (Docker, port 12345)
```

All three share one lobby. The server deals in room codes and player ids and
knows nothing about platforms, so a phone and a laptop can sit at the same
table by swapping a room code.

Free hosting: **Render free tier** (recommended start) or **Oracle Cloud
Always Free** (always-on upgrade, no cold starts). Both are documented below.

---

## Step 1 — One-time editor setup

1. Open the project once in **Godot 4.7.1-stable**
   (`Desktop\Godot\Godot_v4.7.1-stable_win64\`). Do not use 4.8-dev1: its TLS
   stack is broken and `wss://` handshakes fail with mbedtls `-0x7b00`.
2. **Editor > Manage Export Templates > Download and Install.** Nothing can be
   exported without these, and they must be the *same version as the editor*.
   If you later update Godot, download the templates again or every export
   will fail with "export templates not found".

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

## Step 3 — Android client (APK)

### 3a. One-time tool setup

You need two things Godot does not ship with: a Java JDK, and the Android SDK.

1. **Install JDK 17.** Godot 4 needs 17 specifically — 21 and 24 are *not*
   drop-in replacements for the Android build tools. Get "Temurin 17 (LTS),
   JDK, Windows x64, .msi" from <https://adoptium.net>. Tick
   "Set JAVA_HOME variable" during install.

2. **Install the Android SDK.** Easiest route is Android Studio from
   <https://developer.android.com/studio> — run it once and accept the default
   "Standard" setup, which downloads the SDK and build tools. You never have to
   open Android Studio again; Godot only wants the files it installed. They
   land in `%LOCALAPPDATA%\Android\Sdk`.

3. **Create a debug keystore.** Android refuses to install an unsigned app.
   A debug key is fine for testing (not for the Play Store). In PowerShell:

```powershell
cd $env:USERPROFILE
& "$env:JAVA_HOME\bin\keytool.exe" -keyalg RSA -genkeypair -alias androiddebugkey -keypass android -keystore debug.keystore -storepass android -dname "CN=Android Debug,O=Android,C=US" -validity 9999
```

   That writes `debug.keystore` into your user folder. The password is
   literally `android` and the alias is `androiddebugkey` — those are the
   Android convention, not placeholders to change.

4. **Point Godot at all three.** In Godot: **Editor > Editor Settings**, then
   search for "android" in the search box at the top. Fill in:

   - `Export > Android > Android Sdk Path` → `C:\Users\<you>\AppData\Local\Android\Sdk`
   - `Export > Android > Java Sdk Path` → your JDK 17 folder
     (e.g. `C:\Program Files\Eclipse Adoptium\jdk-17...`)
   - `Export > Android > Debug Keystore` → `C:\Users\<you>\debug.keystore`
   - `Export > Android > Debug Keystore User` → `androiddebugkey`
   - `Export > Android > Debug Keystore Pass` → `android`

   Close Editor Settings.

### 3b. Export the APK

1. **Project > Export.** Select the **Android** preset in the list.
2. Look at the bottom of the window. If it says anything in **red**, the
   export will not work — it names exactly what is missing (usually a wrong
   SDK or Java path). Fix that first.
3. Click **Export Project**.
4. Choose where to save. The preset already suggests
   `..\builds\mendigo-android\MendiGo.apk` — note that is a folder *next to*
   the project folder, not inside it. Create `builds` if it does not exist.
5. **Untick "Export With Debug"** for a build you hand to other people. Leave
   it ticked if you want Godot's error output while testing.
6. Save. The APK takes a minute or two the first time.

### 3c. Put it on the phone

1. Copy the `.apk` to the phone (USB cable, Google Drive, email to yourself).
2. Tap it in the phone's file manager.
3. Android will refuse and offer a settings screen — allow that app (usually
   your file manager or browser) to **install unknown apps**, then tap the
   APK again.
4. Open MendiGo. It should start in landscape on its own: the project is set
   to sensor landscape, so the phone handles this and the rotate prompt never
   appears on the native app.

Notes:

- The preset already has the **INTERNET permission** on. Without it the game
  cannot reach the server at all.
- Android blocks plain `ws://` by default. We use `wss://`, so nothing extra
  is needed.
- For the Play Store later you need a **release** keystore (same `keytool`
  command, your own alias and password, kept safe — losing it means you can
  never update the app) and the preset switched to Gradle build + AAB.

## Step 4 — Web client

### 4a. Export the files

1. **Project > Export.** Select the **Web** preset.
2. Click **Export Project**, and save to `..\builds\mendigo-web\index.html`.
   Again: `builds` is a folder *next to* the project folder.
3. You get about half a dozen files — `index.html`, `index.wasm`,
   `index.pck`, `index.js` and so on. **All of them are needed.** The `.wasm`
   is large (tens of MB); that is normal.

Thread support is already off in this preset. That matters more than it
sounds: it means the build does not use `SharedArrayBuffer`, so it needs **no
special COOP/COEP server headers** and works in iOS Safari. That is the single
most common thing that makes Godot web exports impossible to host, and you are
already clear of it. Do not turn thread support on.

### 4b. Test it locally first

You **cannot** just double-click `index.html`. Browsers block `file://` pages
from loading `.wasm`, and you will get a black screen. Serve it over HTTP:

```powershell
cd ..\builds\mendigo-web
python -m http.server 8000
```

Then open <http://localhost:8000> in your browser. (If you do not have Python,
the Godot editor's **Remote Debug > Run in Browser** button does the same job.)

### 4c. Put it online with Vercel

Vercel has no drag-and-drop page like some hosts, so the route for a plain
folder of files is the **CLI**. It is still only two commands.

Do this from inside the export folder, not the project folder — you are
uploading the built game, not the source.

```powershell
cd ..\builds\mendigo-web
npx vercel
```

(`npx` comes with Node.js. If you do not have it, install Node LTS from
<https://nodejs.org> first.)

The first run asks a short list of questions:

- **Set up and deploy?** → yes
- **Which scope?** → your own account
- **Link to existing project?** → no
- **Project name** → `mendigo`
- **In which directory is your code located?** → `./` (you are already in it)
- **Want to modify the build settings?** → **no**

That last one matters. There is nothing to build — the game is already
compiled. Vercel should upload the folder as-is. If it tries to detect a
framework or run a build command, say no.

You get a preview URL like `mendigo-xxxx.vercel.app`. Open it on your phone
and check the game actually runs before going any further.

When you are happy with it, publish it as the live version:

```powershell
npx vercel --prod
```

**Every later update is just `npx vercel --prod` from that same folder** after
re-exporting from Godot.

#### Point mendigo.fernbuild.com at it

1. In the Vercel dashboard: your project → **Settings → Domains → Add**.
2. Enter `mendigo.fernbuild.com`.
3. Vercel shows you the DNS record it wants — for a subdomain that is a
   **CNAME**, usually to `cname.vercel-dns.com`. **Use the value Vercel shows
   you**, not the one written here; they have changed it before.
4. In **Namecheap**: Dashboard → Domain List → **Manage** next to
   `fernbuild.com` → **Advanced DNS** tab → **Add New Record**:

   - Type: **CNAME Record**
   - Host: `mendigo`
   - Value: whatever Vercel showed in step 3
   - TTL: Automatic

   Save. DNS usually takes 10-30 minutes, occasionally a few hours. Vercel's
   domain page shows "Valid Configuration" once it can see the record.
5. Vercel issues the HTTPS certificate automatically. **HTTPS is not optional
   here** — the page is `https://` and connects to `wss://`, and browsers
   require that pairing.

#### Two things to watch

- **Deployment size.** The `.wasm` and `.pck` together run to tens of MB. That
  is fine for a static site, but the free plan does have upload limits and they
  change from time to time. If a deploy is rejected for size, that is why —
  check Vercel's current Hobby limits rather than assuming the build is broken.
- **Do not commit the build to git for push-to-deploy.** Vercel can deploy from
  GitHub instead of the CLI, but the Web preset exports to `..\builds\`, which
  is *outside* the repo, so a repo-connected build would find nothing. Moving
  the export inside the repo would mean committing a fresh multi-tens-of-MB
  `.wasm` on every rebuild, which bloats the repository permanently. The CLI
  route keeps build artefacts out of git, which is why it is the one written up
  here.

### 4d. Phones in a browser

A web page cannot rotate a phone. `screen.orientation.lock()` is the only API
that exists anywhere, it requires fullscreen, and **Safari does not implement
it on any platform** — iPhone Safari has no element fullscreen either. So:

- **Every touch browser** gets a "Turn your phone sideways" overlay whenever
  the viewport is portrait, including a note about rotation lock (a player
  with rotation lock on will otherwise turn the phone, see nothing happen, and
  have no idea why). This is `scripts/ui/Orientation.gd`, an autoload, so it
  covers every screen in the game.
- **Android browsers** additionally get real fullscreen and a landscape lock,
  attempted once on the player's first tap, because browsers only grant those
  inside a user gesture.
- **Desktop browsers and the native Android app never see the overlay.** The
  app is pinned landscape by the project settings, and a desktop window is the
  player's own business.

The behaviour is decided by capability, not by sniffing the browser name:
`OS.has_feature("web")` plus `DisplayServer.is_touchscreen_available()`, and
the JavaScript checks for `requestFullscreen` and `screen.orientation.lock`
existing before calling them. Name-sniffing would get iPadOS wrong, since
Safari there requests desktop sites by default and does not report as iOS.

## Step 5 — Verify online multiplayer

1. Phone (APK) + PC browser (your domain), both on the live server.
2. Create a room on one, join by code on the other, add bots, start.
3. Play two full games (dealer must rotate after game 1).
4. Test a 6-player and an 8-player room with bots.
5. On a phone browser, hold it upright and check the rotate prompt appears,
   then turn it and check the prompt goes away and the game is playable.
6. Tap cards on the phone: one tap must select, a second tap must deselect.

## Keeping the three builds in step

The client and the server share `scripts/network/NetworkManager.gd`, so their
RPC signatures must match exactly. Whenever `Server.gd` or `NetworkManager.gd`
changes you must re-export **all** of: the dedicated server, the web build, and
the APK. An old APK talking to a new server produces RPC errors, not a helpful
message.

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
