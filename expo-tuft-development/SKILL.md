---
name: expo-tuft-development
description: Develop, build, run, and debug Expo applications on a physical device through a Tuft machine. Use for EAS account/Apple/device setup via the Tuft dashboard flow, making development builds with EAS, Expo dev-client iteration, remotely exposing Metro with `tuft host`, generating a dev-client deep link, diagnosing device-only failures with Tuft telemetry, deciding whether a native rebuild is required, and handing a working preview back to the user.
---

# Expo + Tuft Development

## Establish context

1. Read the session and repository `AGENTS.md` files before acting.
2. Locate the Expo project; do not assume the Tuft session root is the repository.
3. Inspect `package.json`, `app.json`/`app.config.*`, `eas.json`, the lockfile, and the current Git status.
4. Preserve unrelated user changes. Use the project’s existing package manager.
5. Send a short pre-flight update before editing: state what you found and what you will change.

## Choose the iteration path

- Reuse the installed development client for JavaScript, TypeScript, and asset changes that do not alter the native project.
- Make a new development build (see “Make a development build”) when no dev client is installed yet, or after adding or changing native dependencies, config plugins, entitlements, URL schemes, capabilities, or native configuration.
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

1. Start Metro in dev-client mode on a stable port:

   ```bash
   npx expo start --dev-client --port 8081
   ```

   Run it in a durable terminal/process managed by the environment. Do not rely on a foreground shell that disappears when the turn ends.

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
   - Metro process output for a wedged bundle;
   - whether the installed dev client matches the current native project.

   Restart Metro if it is wedged, then re-verify before resending the same stable link.

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
- When EAS setup is pending, restate the single setup link and what step the user is on — never a credential request.
- State which tests passed.
- Mention whether a new native build is required.
- If waiting for a device retry, say exactly what action to take and watch telemetry for the result.

Do not expose `localhost`, LAN, or `exp.direct` URLs to a remote user when a persistent `tuft host` URL is available.
