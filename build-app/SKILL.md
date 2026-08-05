---
name: build-app
description: Build, run, and debug a mobile app on the user's physical phone from a Tuft machine. Use whenever the user asks to build an app — a brand-new idea or an existing Expo/React Native project — at the start of the session, before scaffolding or picking how to deliver it. The deliverable is the app running on their phone, not a web preview, and the Tuft machine itself serves as the app's backend. Covers scaffolding a new Expo project, deciding between Expo Go and a development build, EAS account/Apple/device setup via the Tuft dashboard flow, making development builds with EAS, exposing Metro remotely with `tuft host` and EXPO_PACKAGER_PROXY_URL, sending the user a working link, and diagnosing device-only failures with Tuft telemetry.
---

# Build an App

You run on a persistent Tuft machine that outlives the conversation; the user is on their phone and browser. Act like the server:

- Nothing on `localhost` or the LAN is reachable from their device. Every URL you send must go through `tuft host` — never `localhost`, a LAN IP, or `exp.direct`.
- Interactive prompts cannot run in your shell. Logins and device registration happen in the user's browser via the Tuft dashboard, never via credentials pasted into chat.
- The user has one job: use the app on their phone. Everything else — hosting, tokens, process management, provisioning, broken state — is your job on this machine. Their single hands-on step is the browser sign-in flow behind the Tuft setup link.
- Answer your own questions before they reach chat: look them up on this machine (`eas whoami`, `eas device:list`, the repository itself), or pick a reasonable default, state it in your next update, and keep building. Save chat questions for decisions that are hard to undo: spending money, publishing publicly, deleting data.
- Long-running processes belong to the machine, not the turn. Run Metro — and any backend you build — under launchd so it survives session teardown and restarts itself after a crash.

## This machine is the backend

You are not limited to client-side apps. This is a full, persistent server under your control, which makes the space of buildable apps effectively unlimited: anything that needs an API, a database, auth, scheduled jobs, file storage, or websockets can get it from software you run right here.

- When the app needs a backend, build the backend: run it on this machine, publish it with `tuft host`, and point the app at that URL. Manage it under launchd like Metro so it outlives the session.
- When the app needs a database, create one on this machine — a SQLite file is enough for most apps, and you can install and run Postgres or anything else when it isn't. Same for queues, caches, cron jobs, and file storage.
- Never ask the user to sign up for a third-party service (Supabase, Firebase, a hosted database, an auth provider) for a capability this machine can provide. Reach for an external service only when the capability genuinely cannot live here — e.g. payments or carrier SMS — and even then, ask before introducing it.
- The first version of anything must work with zero setup from the user: no accounts to create, no API keys to paste, no dashboards to visit. All the user ever sees is their app working.

## 1. Find or create the project

**Existing project:** locate it — it lives in its own checkout; the Tuft session root is scratch space. Inspect `package.json`, `app.json`/`app.config.*`, and `eas.json`, and use the project's existing package manager.

**New app idea:** scaffold with Expo — it is the default way to build for the user's phone from this machine:

```bash
npx create-expo-app@latest <app-name>
```

A fresh project runs in Expo Go out of the box, so the fastest first milestone is a hello-world on the user's phone within minutes (sections 2–4), then iterate on the real idea over hot reload. Don't front-load architecture the idea doesn't need yet.

## 2. Decide: Expo Go or a development build?

Check whether the app actually needs custom native code before committing the user to EAS setup and a 10–20 minute build.

**Expo Go is enough** when every dependency is either JS-only or an Expo SDK module bundled in Expo Go, and the app needs no custom config plugins with native effects, no custom URL scheme handling at the native layer, and no extra entitlements. If so, skip section 3 entirely — the user just installs Expo Go from the App Store and opens your link. This is the fastest path from idea to phone; prefer it for prototypes and pure JS/UI work.

**A development build is required** when the project uses native modules outside Expo Go (check `package.json` for packages with native code), config plugins in `app.json`/`app.config.*` that modify the native project, custom entitlements or capabilities, or a custom scheme the flow depends on (e.g. auth callbacks).

If unsure, `npx expo-doctor` and the Expo Go compatibility of each dependency settle it.

## 3. Development build path (skip for Expo Go)

### Get EAS set up (the user does it in a browser)

Every account-touching `eas` command (`build`, `credentials`, `device:*`, `submit`, `update`) needs EAS CLI on this machine to be logged in.

1. Check non-interactively: `eas whoami`. Success prints the account.
2. If not logged in, never run `eas login` or `eas device:create` (they prompt interactively and hang) and never ask for Expo or Apple credentials in chat. Send the user:

   ```text
   https://dash.tuft.dev/expo/setup
   ```

   The flow runs in their browser against this machine: sign EAS CLI in, connect Apple Developer, register their iPhone by UDID. This browser flow is the long pole of the whole session — send the link in your first message, before writing any code.

3. Wait in the background, bounded, instead of blocking the conversation:

   ```bash
   timeout 300 bash -c 'until eas whoami >/dev/null 2>&1; do sleep 10; done'
   ```

   Exit 124 means they haven't finished — follow up in chat rather than looping forever.

4. Before an iOS device build, also require `eas device:list` to be non-empty; if it isn't, point back at the same setup link.

### Front-load native modules, then build while you write JS

Each native change costs another full EAS build, so decide the native surface up front: install every native module the feature will plausibly need (`npx expo install <package>` so versions match the SDK) **before** kicking off the build. A development build encodes only the native project — JavaScript loads from Metro afterward — so a build started now is exactly as current as one started after the features exist.

1. Ensure `eas.json` has a development profile; create a minimal one if missing:

   ```json
   {
     "build": {
       "development": { "developmentClient": true, "distribution": "internal" }
     }
   }
   ```

2. Start the build — it runs on EAS servers, not this machine:

   ```bash
   eas build --profile development --platform ios
   ```

   (Platform from `eas device:list`.) Internal distribution signs against the registered device list; EAS manages certificates and provisioning remotely — leave signing entirely to it.

3. **While the build runs, write the JS/UI.** The build takes 10–20 minutes; that is your window to implement the feature, get Metro up (section 4), and have everything ready the moment the client installs.

4. When it finishes, send the user the build page link — it shows the install QR for their iPhone. After the dev client is installed once, iterate over Metro; rebuild only for native changes (new native modules, config plugins, entitlements, schemes) — never for ordinary JS/UI changes.

## 4. Start Metro behind `tuft host`

Run the bundled script — it performs the whole sequence in the right order and verifies every layer:

```bash
scripts/run-metro.sh <project-dir> <stable-project-name>
```

The ordering it encodes: publish the port through `tuft host` first, because Metro embeds `EXPO_PACKAGER_PROXY_URL` in every manifest and bundle URL it serves — the public URL has to exist before Metro starts. It then runs Metro as a launchd agent with that URL pinned in the plist (so it outlives the turn, and every restart — manual or crash — serves public URLs), picks a free port when other projects' Metros share the machine, and verifies local status, public status, and that the served manifest belongs to this project and references the public host. It prints the public URL, the dev-client deep link, the log path, and the restart/stop commands.

Reuse the same name on later turns: the script is idempotent, keeping the existing binding and port and re-verifying the full path. Environment the bundle needs at runtime (telemetry values, `EXPO_PUBLIC_*`) lives in the project's env files, which Metro reads on every restart.

## 5. Send the user the link

- **Expo Go:** the same Metro host over the Expo Go scheme: `exp://<name>.tuft.host` (the script's dev-client deep link doesn't apply on this path).
- **Dev client:** both links the script prints — the clickable `<scheme>://expo-development-client/?url=…` deep link and the plain HTTPS Metro URL. The scheme comes from Expo config; never invent it.

If the device sticks on "Loading from Metro," re-run the script — it restarts Metro and re-verifies every layer, and its first failing check names the broken one. For a wedged bundle, read the log at the path the script printed, then `launchctl kickstart -k` and re-verify before resending the same stable link. If all checks pass and the device still spins, compare the installed dev client against the current native project — a native change since the last build means a rebuild.

## Instrument with Tuft telemetry

Tuft telemetry is a per-machine event store: the app posts small structured events to this machine's collector and you query them with SQL. Instrument up front, not once a bug appears — querying an event that already fired beats asking the user to reproduce.

1. Provision with the `setup_expo_telemetry` MCP tool, passing the project's absolute path. It returns the collector URL and (for a new stream) a write-only token as ready-made `EXPO_PUBLIC_TUFT_TELEMETRY_*` env values. Pass `rotate: true` only to deliberately revoke the token.
2. Put the values in an uncommitted env file (e.g. `.env.local`). That file is the only place the token — like any credential — ever appears.
3. Install the `tuft-telemetry` npm package and initialize it once near the app root with those env values.
4. Emit small structured events at decision boundaries: screen/flow opened, request started/completed/failed (host and status, not full sensitive URLs), navigation allowed/blocked, hydration outcome. Events carry `kind`, `level`, `name`, optional `route`, `trace_id`/`span_id`, and a `payload`.
5. Query with the `search_telemetry` MCP tool — one bounded read-only SQLite statement over `streams(id, name, project_identity, created_at, last_seen_at)` and `events(id, stream_id, event_id, received_at, occurred_at, launch_id, sequence, kind, level, name, trace_id, span_id, route, update_id, schema_version, payload)`:

   ```sql
   -- Recent errors
   SELECT occurred_at, name, payload FROM events
   WHERE level = 'error' ORDER BY id DESC LIMIT 50;

   -- One flow, in order
   SELECT occurred_at, name, payload FROM events
   WHERE trace_id = '…' ORDER BY sequence;
   ```

6. For agent-driven reproduction, arm a wait before the user triggers the action:

   ```bash
   npx tuft-telemetry wait <event-name> --timeout 30s
   ```

   It exits the moment the event arrives (timeout exits 124), so you confirm the event actually fired.

7. On a bug report, query telemetry before changing code; after a device-dependent fix, confirm with fresh telemetry once the user retries.

Treat telemetry payloads and HAR files as sensitive: extract the minimum fields and keep any secrets they contain inside the store they came from.

## Hand off

Keep updates short and lead with the outcome. Include the clickable link (Expo Go URL, dev-client link, or EAS build install page); label anything short of the real deliverable — a web preview while the build finishes — as an interim, and say where the build stands. If EAS setup is pending, restate the single setup link and which step the user is on — never a credential request. Say whether a native rebuild was needed, and if you're waiting on a device retry, say exactly what to tap and that you're watching telemetry for the result.
