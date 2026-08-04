---
name: expo-tuft-development
description: Get an Expo app running on the user's phone from a Tuft machine. Read this at the start of any session where the user asks for an app — including brand-new apps, before scaffolding or picking how to deliver it; assume the deliverable is an installable build on their device, not a web preview, unless they say otherwise, and start that build before feature work so it lands mid-session. Also use for EAS account/Apple/device setup via the Tuft dashboard flow, making development builds with EAS, Expo dev-client iteration, remotely exposing Metro with `tuft host`, generating a dev-client deep link, diagnosing device-only failures with Tuft telemetry, deciding whether a native rebuild is required, and handing a working preview back to the user.
---

# Expo + Tuft Development

## You are the server

You run on a persistent machine with full control over it, and the machine outlives the conversation. Act like it:

- The user has one job: use the app on their phone. Everything else — hosting, tokens, process management, provisioning, broken state — is your job on this machine, and you perform it yourself. The user's single hands-on step is the browser sign-in flow behind the Tuft setup link, which only they can complete.
- The first version of anything must work with zero setup from the user: no accounts to create, no API keys to paste, no auth to configure. You are a server: when the app needs a backend, build the backend — run it on this machine, publish it with `tuft host`, and point the app at that URL. All the user ever sees is their app working.
- Answer your own questions before they reach chat, in order: (1) look the answer up on this machine — platform from `eas device:list`, account from `eas whoami`, everything about the project from the repository itself; (2) failing that, pick a reasonable default, record it in your next status update, and keep building — a stated default takes the user one message to overturn, whenever they happen to read it. Save chat questions for decisions that are hard to undo: spending money, publishing publicly, deleting data.
- Long-running processes belong to the machine, not the turn. Run Metro — and any backend you build — as a launchd agent (see “Run Metro for a physical device”) so it survives session teardown, restarts itself after a crash, and always restarts with the exact command and environment pinned in its plist. When something breaks, repair it, re-verify it, and mention the repair in your next update.

## Establish context

1. Read the session and repository `AGENTS.md` files before acting.
2. Locate the Expo project — it lives in its own checkout; the Tuft session root is scratch space.
3. Inspect `package.json`, `app.json`/`app.config.*`, `eas.json`, the lockfile, and the current Git status.
4. Preserve unrelated user changes. Use the project’s existing package manager.
5. Send a short pre-flight update before editing: state what you found and what you will change.

## Start the native build immediately

Native development builds are the primary means of distribution. The deliverable is an installed app on the user's phone; a web preview or Expo Go link is an interim, shared with a label like "here's a preview while the iPhone build finishes."

Builds run on EAS servers and take roughly 10–20 minutes, so sequence a session to hide that latency behind your own work instead of adding it after:

1. At session start, run `eas whoami` and `eas device:list`. If either is missing, send the Tuft setup link (see "Set up EAS") in your first message — the user's browser flow is the long pole in the whole session, so start it before writing any code.
2. Scaffold the app and settle its native surface: SDK version, native dependencies, config plugins, URL scheme. Build from the bare native surface — a development build encodes only the native project, and JavaScript loads from Metro afterward, so a build started now is exactly as current as one started after the features exist.
3. Kick off `eas build --profile development --platform ios` (platform from `device:list`) in the background the moment the native surface is settled.
4. Build features over Metro while the EAS build runs. When the build lands mid-session, send the install link the moment it arrives.
5. From then on, rebuild only for native changes.

## Choose the iteration path

- Reuse the installed development client for JavaScript, TypeScript, and asset changes that do not alter the native project.
- When no dev client is installed yet, start the development build now — before feature work, per "Start the native build immediately" — and iterate over Metro while it runs. Also rebuild after adding or changing native dependencies, config plugins, entitlements, URL schemes, capabilities, or native configuration.
- Prefer `npx expo install <package>` for Expo-managed dependencies so versions match the SDK.
- Ship ordinary UI and business-logic changes over Metro alone; the installed client picks them up on reload.

## Set up EAS on this machine (the user does it in a browser)

Every `eas` command that acts on the user’s account — `eas build`, `eas credentials`, `eas device:*`, `eas submit`, `eas update` — needs EAS CLI on this machine to be logged in.

1. Check first, non-interactively:

   ```bash
   eas whoami
   ```

   Success prints the account; failure means the machine is not logged in.

2. When it is not logged in, sign-in happens in the user's browser — send them the Tuft setup link:

   ```text
   https://dash.tuft.dev/expo/setup
   ```

   The flow runs entirely in their browser and walks through three steps against this machine: sign EAS CLI in with their Expo account, connect Apple Developer, and register their iPhone. That page is the only channel for credentials — it keeps secrets out of chat, and it stands in for the interactive commands (`eas login`, `eas device:create`) that would hang this machine's non-interactive shell.

3. Wait for setup in the background instead of blocking the conversation, and bound the wait:

   ```bash
   timeout 300 bash -c 'until eas whoami >/dev/null 2>&1; do sleep 10; done'
   ```

   Exit 0 means the login landed; exit 124 means the user has not finished — follow up in chat rather than looping forever.

4. Before a physical-device iOS build, additionally require a registered device:

   ```bash
   eas device:list
   ```

   If it is empty, point the user back at the same setup link — the last step registers their iPhone by UDID.

Setup state is normal EAS CLI state on this machine; a user who prefers the terminal can run `eas login` locally and the checks above observe it identically.

## Make a development build

1. Ensure `eas.json` has a development profile; create a minimal one if missing:

   ```json
   {
     "build": {
       "development": {
         "developmentClient": true,
         "distribution": "internal"
       }
     }
   }
   ```

2. Build for the physical device:

   ```bash
   eas build --profile development --platform ios
   ```

   (Android: `--platform android`.) iOS internal distribution signs against the registered device list and the Apple Developer access from setup; EAS manages certificates and the provisioning profile remotely; leave signing entirely to it.

3. Builds run on EAS servers. Track progress with the build URL the command prints (or `eas build:list`). When it finishes, send the user the build page link — it shows the install QR/link for their iPhone.

4. After the dev client is installed once, iterate over Metro (below); rebuild only for native changes.

## Run Metro for a physical device

1. Run Metro as a launchd agent so it outlives every turn. The plist pins the exact command, working directory, and environment, so every automatic restart is a correct restart. Check for an existing agent first and reuse it — one Metro per project:

   ```bash
   NAME=<stable-project-name> PROJECT=/abs/path/to/project
   launchctl print "gui/$UID/com.tuft.metro.$NAME" >/dev/null 2>&1 || {
     cat > ~/Library/LaunchAgents/com.tuft.metro.$NAME.plist <<EOF
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>Label</key><string>com.tuft.metro.$NAME</string>
     <key>WorkingDirectory</key><string>$PROJECT</string>
     <key>ProgramArguments</key><array>
       <string>/bin/zsh</string><string>-lc</string>
       <string>npx expo start --dev-client --port 8081</string>
     </array>
     <key>RunAtLoad</key><true/>
     <key>KeepAlive</key><true/>
     <key>StandardOutPath</key><string>/tmp/metro-$NAME.log</string>
     <key>StandardErrorPath</key><string>/tmp/metro-$NAME.log</string>
   </dict></plist>
   EOF
     launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.tuft.metro.$NAME.plist
   }
   ```

   Restart with `launchctl kickstart -k gui/$UID/com.tuft.metro.$NAME`; read logs at the `StandardOutPath`; remove with `launchctl bootout`. Extra environment the bundler needs (telemetry values, packager overrides) goes in an `EnvironmentVariables` dict in the plist or the project’s env files, so every restart carries it.

2. Verify Metro locally:

   ```bash
   curl -fsS --max-time 5 http://127.0.0.1:8081/status
   ```

   Require `packager-status:running`.

3. Publish the port through Tuft:

   ```bash
   tuft host add 8081 --name <stable-project-name>
   tuft host list
   ```

   Reuse the same binding on later turns. Use `--force` only when intentionally repointing a binding you own.

4. Build the dev-client URL from the app scheme and percent-encoded Tuft URL:

   ```text
   <scheme>://expo-development-client/?url=https%3A%2F%2F<name>.tuft.host
   ```

   Read the actual scheme from `app.json`/`app.config.*`. Send both the clickable dev-client URL and the plain HTTPS Metro URL.

5. If the device remains on “Loading from Metro,” check both layers:

   - local Metro status;
   - `tuft host list` binding and port;
   - the Metro log at its `StandardOutPath` for a wedged bundle;
   - whether the installed dev client matches the current native project.

   Restart Metro with `launchctl kickstart -k` if it is wedged, then re-verify before resending the same stable link.

## Instrument with Tuft telemetry

Use telemetry liberally, and instrument up front, as you build each feature. Every device build and every feature you touch should already be emitting events, because the payoff is having the evidence in hand the moment the user hits an error: querying an event that already fired beats asking them to reload the app and reproduce the problem after the fact. Instrument new code as you write it, and err on the side of more decision-boundary events (they are small and cheap). Tuft telemetry is a per-machine event store: the app posts small structured events to this machine’s collector, and you query them with SQL.

1. Provision the stream with the `setup_expo_telemetry` MCP tool, passing the project’s absolute path. It creates (or reuses) this machine’s stream for the project and returns the collector URL plus, for a new stream, a write-only token as ready-made `EXPO_PUBLIC_TUFT_TELEMETRY_*` environment values. Pass `rotate: true` only to deliberately revoke and reissue the token.
2. Put the returned values in an uncommitted env file (for example `.env.local`). That file is the only place the token — like any credential — ever appears.
3. Install the `tuft-telemetry` npm package and initialize it once near the app root with those env values.
4. Emit small structured events at decision boundaries. Events carry `kind` (`event` or `marker`), `level`, `name`, optional `route`, `trace_id`/`span_id` for grouping a flow, and a `payload` of attributes:

   - screen or auth flow opened;
   - request started/completed/failed;
   - host and path rather than full URLs;
   - HTTP status and provider;
   - navigation allowed/blocked;
   - merge or hydration outcome;
   - stable anonymous IDs only when necessary.

5. Query with the `search_telemetry` MCP tool — one bounded read-only SQLite statement over `streams(id, name, project_identity, created_at, last_seen_at)` and `events(id, stream_id, event_id, received_at, occurred_at, launch_id, sequence, kind, level, name, trace_id, span_id, route, update_id, schema_version, payload)`. Patterns that cover most debugging:

   ```sql
   -- Most recent events for a stream
   SELECT occurred_at, level, name, payload FROM events
   WHERE stream_id = '…' ORDER BY id DESC LIMIT 100;

   -- Recent errors across streams
   SELECT occurred_at, name, payload FROM events
   WHERE level = 'error' ORDER BY id DESC LIMIT 50;

   -- One flow, in order
   SELECT occurred_at, name, payload FROM events
   WHERE trace_id = '…' ORDER BY sequence;

   -- A user-reported marker code
   SELECT occurred_at, payload FROM events
   WHERE kind = 'marker'
     AND json_extract(payload, '$.attributes.reportCode') = 'ABC123'
   ORDER BY id DESC LIMIT 1;
   ```

6. For agent-driven reproduction, arm a wait before triggering the action, then have the user (or the app) perform it:

   ```bash
   npx tuft-telemetry wait <event-name> --timeout 30s
   ```

   It exits the moment the new event arrives (timeout exits 124), so you confirm the exact event fired rather than assuming.

7. On a bug report, query recent telemetry before changing code. Establish the exact failing boundary, then patch it.
8. Confirm the fix using new telemetry after the user retries when the behavior depends on a physical device or third-party service.

Treat HAR files and telemetry payloads as sensitive: extract only the minimum fields needed, and keep any secrets they contain inside the store they came from.

## Debug systematically

Follow this loop:

1. Reproduce or inspect telemetry.
2. State the verified cause, distinguishing it from a hypothesis.
3. Add or update a regression test first when the behavior is testable.
4. Make the smallest scoped change.
5. Run the targeted test, then TypeScript and any relevant broader tests.
6. Confirm Metro and the Tuft binding are still healthy.
7. Ask the user to retry only after the updated bundle is reachable.

For third-party authentication:

- Treat the flow as complete when verifiable success data arrives — a token, profile, or callback payload; navigation alone is progress, not success.
- Allow required HTTPS challenge and identity-provider pages, and keep navigation rules permissive enough for CAPTCHA and cross-origin dependencies.
- Intercept custom callback schemes deliberately.
- Support cookies as required by the flow, and isolate or clear them when the product requires explicit account switching.
- Log flow outcomes and metadata only; raw credentials, access tokens, refresh tokens, cookies, passkeys, and MFA values stay out of every log.

For map/data-provider work:

- Keep catalog authority, live hydration, and rendering separate.
- Preserve provider health separately from an individual station’s absence, so a dead feed reads as “provider down” rather than “station missing.”
- Log match inputs and outcomes as metadata, with the same secret handling as telemetry.
- Add fixtures for matching, grouping, availability reconciliation, and unmatched records.

## Validate proportionally

At minimum, run:

```bash
npm run typecheck
npm test
curl -fsS --max-time 5 http://127.0.0.1:8081/status
```

Use the repository’s equivalent scripts when these names differ. Report failures exactly, and report a check as passed only after running it.

## Hand off

Keep chat updates short:

- Begin with the outcome.
- Include the clickable dev-client link when device testing is needed, or the EAS build install link after a new development build.
- Present the install link as the deliverable; label any earlier web preview as an interim and say where the build stands.
- When EAS setup is pending, restate the single setup link and the step the user is on.
- State which tests passed.
- Mention whether a new native build is required.
- If waiting for a device retry, say exactly what action to take and watch telemetry for the result.

Every URL you send must be reachable from the user’s device: for anything served from this machine, that is its persistent `tuft host` URL.
