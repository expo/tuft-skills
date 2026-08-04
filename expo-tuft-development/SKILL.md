---
name: expo-tuft-development
description: Get an Expo app running on the user's phone from a Tuft machine. Read this at the start of any session where the user asks for an app — including brand-new apps, before scaffolding or picking how to deliver it; assume the deliverable is an installable build on their device, not a web preview, unless they say otherwise, and start that build before feature work so it lands mid-session. Also use for EAS account/Apple/device setup via the Tuft dashboard flow, making development builds with EAS, Expo dev-client iteration, remotely exposing Metro with `tuft host`, generating a dev-client deep link, diagnosing device-only failures with Tuft telemetry, deciding whether a native rebuild is required, and handing a working preview back to the user.
---

# Expo + Tuft Development

## You are the server

You run on a persistent machine with full control over it, and the machine outlives the conversation. Act like it:

- The user has one job: use the app on their phone. Everything else — hosting, tokens, process management, provisioning, broken state — is your job on this machine. Never hand the user a task you can perform yourself; the one exception is the browser sign-in flow behind the Tuft setup link, which only they can complete.
- The first version of anything must work with zero setup from the user: no accounts to create, no API keys to paste, no auth to configure. That is not a reason to fake it with sample data — you are a server. When the app needs a backend, build the backend: run it on this machine, publish it with `tuft host`, and point the app at that URL. The user never needs to know what infrastructure exists; they just see their app working.
- Do not send a question to chat until you have tried, in order: (1) look the answer up on this machine — platform from `npx eas-cli device:list`, account from `npx eas-cli whoami`, everything about the project from the repository itself; (2) pick a reasonable default, record it in your next status update, and keep building — a stated default takes the user one message to overturn, whenever they happen to read it. Questions are only for decisions that are hard to undo: spending money, publishing publicly, deleting data.
- Long-running processes belong to the machine, not the turn. Run Metro — and any backend you build — as a launchd agent (see “Run Metro for a physical device”) so it survives session teardown, restarts itself after a crash, and always restarts with the exact command and environment pinned in its plist. When something breaks, repair it and re-verify; never report a process broken and stop there.

## Establish context

1. Read the session and repository `AGENTS.md` files before acting.
2. Locate the Expo project; do not assume the Tuft session root is the repository.
3. Inspect `package.json`, `app.json`/`app.config.*`, `eas.json`, the lockfile, and the current Git status.
4. Preserve unrelated user changes. Use the project’s existing package manager.
5. Send a short pre-flight update before editing: state what you found and what you will change.

## Start the native build immediately

Native development builds are the primary means of distribution. The deliverable is an installed app on the user's phone; a web preview or Expo Go link is at most a labeled interim — "here's a preview while the iPhone build finishes" — never "the build."

Builds run on EAS servers and take roughly 10–20 minutes, so sequence a session to hide that latency behind your own work instead of adding it after:

1. At session start, run `npx eas-cli whoami` and `npx eas-cli device:list`. If either is missing, send the Tuft setup link (see "Set up EAS") in your first message — the user's browser flow is the long pole in the whole session, so start it before writing any code.
2. Scaffold the app and settle its native surface: SDK version, native dependencies, config plugins, URL scheme. Do not wait for features — a development build only encodes the native project; JavaScript loads from Metro afterward, so building early never ships a stale app.
3. Kick off `eas build --profile development --platform ios` (platform from `device:list`, not from asking) in the background the moment the native surface is settled.
4. Build features over Metro while the EAS build runs. When the build lands mid-session, send the install link immediately rather than saving it for the final summary.
5. From then on, rebuild only for native changes.

## Choose the iteration path

- Reuse the installed development client for JavaScript, TypeScript, and asset changes that do not alter the native project.
- When no dev client is installed yet, start the development build now — before feature work, per "Start the native build immediately" — and iterate over Metro while it runs. Also rebuild after adding or changing native dependencies, config plugins, entitlements, URL schemes, capabilities, or native configuration.
- Prefer `npx expo install <package>` for Expo-managed dependencies so versions match the SDK.
- Do not rebuild merely to deliver ordinary UI or business-logic changes.

## Set up EAS on this machine (the user does it in a browser)

Every `eas` command that acts on the user’s account — `eas build`, `eas credentials`, `eas device:*`, `eas submit`, `eas update` — needs EAS CLI on this machine to be logged in.

1. Check first, non-interactively:

   ```bash
   npx eas-cli whoami
   ```

   Success prints the account; failure means the machine is not logged in.

2. When it is not logged in, never ask for Expo or Apple credentials in chat, and never run `eas login` or `eas device:create` — they prompt interactively and will hang or fail. Instead send the user the Tuft setup link:

   ```text
   https://dash.tuft.dev/expo/setup
   ```

   The flow runs entirely in their browser and walks through three steps against this machine: sign EAS CLI in with their Expo account, connect Apple Developer, and register their iPhone.

3. Wait for setup in the background instead of blocking the conversation, and bound the wait:

   ```bash
   timeout 300 bash -c 'until npx eas-cli whoami >/dev/null 2>&1; do sleep 10; done'
   ```

   Exit 0 means the login landed; exit 124 means the user has not finished — follow up in chat rather than looping forever.

4. Before a physical-device iOS build, additionally require a registered device:

   ```bash
   npx eas-cli device:list
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

   (Android: `--platform android`.) iOS internal distribution signs against the registered device list and the Apple Developer access from setup; EAS manages certificates and the provisioning profile remotely — do not hand-manage credentials.

3. Builds run on EAS servers. Track progress with the build URL the command prints (or `eas build:list`). When it finishes, send the user the build page link — it shows the install QR/link for their iPhone.

4. After the dev client is installed once, iterate over Metro (below); rebuild only for native changes.

## Run Metro for a physical device

1. Run Metro as a launchd agent, never as a foreground shell that dies with the turn. The plist pins the exact command, working directory, and environment, so every automatic restart is a correct restart. Check for an existing agent first and reuse it — one Metro per project:

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

   Restart with `launchctl kickstart -k gui/$UID/com.tuft.metro.$NAME`; read logs at the `StandardOutPath`; remove with `launchctl bootout`. Extra environment the bundler needs (telemetry values, packager overrides) goes in an `EnvironmentVariables` dict in the plist or the project’s env files — never typed ad hoc into a shell, where the next restart loses it.

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

   Read the actual scheme from Expo configuration; never invent it. Send both the clickable dev-client URL and the plain HTTPS Metro URL.

5. If the device remains on “Loading from Metro,” check both layers:

   - local Metro status;
   - `tuft host list` binding and port;
   - the Metro log at its `StandardOutPath` for a wedged bundle;
   - whether the installed dev client matches the current native project.

   Restart Metro with `launchctl kickstart -k` if it is wedged, then re-verify before resending the same stable link.

## Instrument with Tuft telemetry

Use telemetry liberally, and instrument up front — not just once a bug appears. Every device build and every feature you touch should already be emitting events, because the payoff is having the evidence in hand the moment the user hits an error: querying an event that already fired beats asking them to reload the app and reproduce the problem after the fact. Instrument new code as you write it, and err on the side of more decision-boundary events (they are small and cheap). Tuft telemetry is a per-machine event store: the app posts small structured events to this machine’s collector, and you query them with SQL.

1. Provision the stream with the `setup_expo_telemetry` MCP tool, passing the project’s absolute path. It creates (or reuses) this machine’s stream for the project and returns the collector URL plus, for a new stream, a write-only token as ready-made `EXPO_PUBLIC_TUFT_TELEMETRY_*` environment values. Pass `rotate: true` only to deliberately revoke and reissue the token.
2. Put the returned values in an uncommitted env file (for example `.env.local`). Never paste or commit the token — or any password, cookie, authorization code, or session credential.
3. Install the `tuft-telemetry` npm package and initialize it once near the app root with those env values.
4. Emit small structured events at decision boundaries. Events carry `kind` (`event` or `marker`), `level`, `name`, optional `route`, `trace_id`/`span_id` for grouping a flow, and a `payload` of attributes:

   - screen or auth flow opened;
   - request started/completed/failed;
   - host and path, but not full sensitive URLs;
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

Treat HAR files and telemetry payloads as sensitive. Extract only the minimum fields needed and never reproduce secrets in chat, source code, logs, fixtures, or commits.

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

- Complete only after receiving verifiable success data, not merely because navigation changed.
- Allow required HTTPS challenge and identity-provider pages; avoid brittle host allowlists when the provider uses CAPTCHA or cross-origin dependencies.
- Intercept custom callback schemes deliberately.
- Support cookies as required by the flow, but isolate or clear them when the product requires explicit account switching.
- Never log raw credentials, access tokens, refresh tokens, cookies, passkeys, or MFA values.

For map/data-provider work:

- Keep catalog authority, live hydration, and rendering separate.
- Preserve provider health separately from an individual station’s absence; a failed feed must not create false “station missing” warnings.
- Log match inputs and outcomes without logging credentials.
- Add fixtures for matching, grouping, availability reconciliation, and unmatched records.

## Validate proportionally

At minimum, run:

```bash
npm run typecheck
npm test
curl -fsS --max-time 5 http://127.0.0.1:8081/status
```

Use the repository’s equivalent scripts when these names differ. Report failures exactly; do not claim unrun checks passed.

## Hand off

Keep chat updates short:

- Begin with the outcome.
- Include the clickable dev-client link when device testing is needed, or the EAS build install link after a new development build.
- If you share a web preview before the native build lands, label it as an interim preview and say where the build stands — never present it as the deliverable.
- When EAS setup is pending, restate the single setup link and what step the user is on — never a credential request.
- State which tests passed.
- Mention whether a new native build is required.
- If waiting for a device retry, say exactly what action to take and watch telemetry for the result.

Do not expose `localhost`, LAN, or `exp.direct` URLs to a remote user when a persistent `tuft host` URL is available.
