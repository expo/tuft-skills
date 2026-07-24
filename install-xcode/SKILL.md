---
name: install-xcode
description: Install a specific Xcode version on a Mac using the xcodes CLI, handing the Apple ID sign-in (password + 2FA) to the user through a shared live terminal. Use when a task needs Xcode/simulators and the machine doesn't have the right version, or the user asks to install/upgrade Xcode.
---

# Install Xcode

Install Xcode non-interactively where possible, and hand exactly one step — the Apple ID sign-in — to the user via a shared terminal. Never ask the user to paste Apple credentials into chat.

## 0. Check the platform

Xcode only runs on macOS. Check `uname -s` first — if it prints `Linux`, stop: this machine cannot install Xcode. Tell the user they need to use EAS (Expo Application Services) to build for iOS from this machine instead.

## 1. Check what's needed

- Already installed? `ls /Applications | grep -i xcode` and `xcodebuild -version`. If the right version is present, stop.
- **Pick the version the work actually needs, not the newest.** For repo work, match CI: look for `.xcode-version`, or `grep -rn 'Xcode_\|xcode-select --switch' .github/workflows/` in the target repo (e.g. expo/expo pins the version in `ios-unit-tests.yml`). Fall back to latest release.
- Disk: Xcode needs ~20 GB installed plus ~8 GB for a simulator runtime, and unxip needs headroom. Check `df -h /` and don't start below ~50 GB free.

## 2. Get the xcodes CLI

Prefer the prebuilt binary — `brew install xcodesorg/made/xcodes` builds from source and fails on machines with stale Command Line Tools (error: `xcbuild ... does not exist`), which is likely on a box that doesn't have Xcode yet:

```sh
curl -sL -o /tmp/xcodes.zip https://github.com/XcodesOrg/xcodes/releases/latest/download/xcodes.zip
cd /tmp && unzip -o -q xcodes.zip && chmod +x xcodes
mkdir -p /tmp/cbin && mv /tmp/xcodes /tmp/cbin/xcodes   # or /usr/local/bin if sudo works
```

`brew install aria2` (optional) makes downloads much faster; xcodes uses it automatically when present.

Verify: `/tmp/cbin/xcodes version` and `/tmp/cbin/xcodes list | tail` (the list works unauthenticated; confirm your target version appears).

## 3. Try unattended first

If this machine has installed Xcode via xcodes before, the Apple ID session is already in the keychain and no sign-in is needed:

```sh
export PATH="/tmp/cbin:/opt/homebrew/bin:$PATH"
xcodes install <VERSION> --directory /Applications --experimental-unxip < /dev/null
```

If it completes, skip to step 6. If it prints `Apple ID: Missing username or a password`, continue.

## 4. Hand sign-in to the user via a shared terminal

Apple requires an Apple ID for every Xcode download; app-specific passwords do **not** work (xcodes needs a real session with 2FA). Don't collect credentials in chat — share a terminal:

1. Call the `share_terminal` tool. It returns a browser URL and a tmux socket/session for prepping.
2. Pre-type (don't run) the install command so the user only presses Enter and answers prompts:
   ```sh
   tmux -S '<SOCKET>' send-keys -t '<SESSION>' 'clear; export PATH="/tmp/cbin:/opt/homebrew/bin:$PATH"; echo "Press Enter, then sign in with your Apple ID (2FA appears here)"' Enter
   tmux -S '<SOCKET>' send-keys -t '<SESSION>' 'xcodes install <VERSION> --directory /Applications --experimental-unxip'
   ```
3. Send the user the URL with instructions: press Enter, sign in, answer the 2FA prompt in the terminal. Mention that credentials stay between them and the prompt, the session persists in the machine keychain (future installs are unattended), and the link should be treated as sensitive.

## 5. Monitor without nagging

Poll the terminal, not the user: `tmux -S '<SOCKET>' capture-pane -t '<SESSION>' -p | tail`. The phases are: sign-in → `Downloading Xcode <VERSION>` (long; ~3 GB) → `Unarchiving Xcode (This can take a while)` → `xcodes requires superuser privileges` (see below) → done. Check every few minutes (scheduled wakeups, not tight loops). If the pane shows an auth error, tell the user and have them retry in the same terminal.

**Sudo:** near the end xcodes asks for the *macOS account* password (enable dev mode, license). If you have passwordless sudo you can pre-empt this; otherwise the user types the machine password in the same terminal — tell them which password it wants, it's a common point of confusion after just typing an Apple ID password.

## 6. Post-install

```sh
sudo xcode-select --switch /Applications/Xcode-<VERSION>.app
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS        # simulator runtime, ~8 GB — only if iOS sim work is needed
xcodebuild -version                     # verify
xcrun simctl list devices | head        # verify simulators exist
```

## 7. Clean up

- Ask the user to confirm they're done in the terminal, then rotate/kill the shared terminal link.
- Delete `/tmp/xcodes.zip`. Keep the xcodes binary for future installs.
- Report the installed version and remaining disk space.
