# Brainbox Runner

A macOS menu-bar app that connects to a brainbox API and executes session
work on the host's Docker daemon and/or UTM. It is the "compute side" of
the agent-bound brainbox architecture: the API is the orchestrator, and
runners are the workers.

## Topology

```
┌─────────── Laptop ─────────────┐         ┌──── Remote box ────┐
│  Brainbox Runner.app           │         │  brainbox API      │
│   ├─ docker capability         ────────▶ │  (orchestrator)    │
│   ├─ utm capability            │         │                    │
│   └─ secret_authority cap.     │         │  Brainbox Runner   │
│      (your creds live here)    │         │   └─ docker        │
│                                │         │                    │
│  Wails app (UI) ───────────────────────▶ │  (executes on      │
│                                │         │   remote Docker)   │
└────────────────────────────────┘         └────────────────────┘
```

Recommended setup for someone working both locally and remotely:

- **One brainbox API** on a stable always-on host (your remote box).
- **Brainbox Runner** on each Mac with compute you want to use.
  - Laptop runner advertises `docker` + `utm` and is the `secret_authority`
    (it has your credentials).
  - Remote runners advertise `docker` only.
- **Wails app** points at the remote API. Sees every registered runner.
  Dispatch a session and pick which runner gets it.

When the laptop is offline, no sessions can start anywhere — the
credentials need an authorising agent to seal them. That's by design.

## Install

```
brew install --cask neverprepared/ink-bunny/brainbox-runner
```

Or download the latest DMG from the
[Releases](https://github.com/neverprepared/phantom-ink/releases) page.

## First-run setup

1. Launch **Brainbox Runner**. Without an API key, Settings opens
   automatically.
2. In the **Wails app**: Settings → Runners → **+ pair a runner**.
   Copy the token.
3. Back in the runner: **Credentials** tab → **Pair with a brainbox
   API…** → paste the API URL + token → **Pair**.

The menu bar icon flips to a green dot once registration succeeds.

## Settings

- **API tab**: API URL, runner name (`mbp`, `mac-mini-1`, etc. — keep
  it ASCII-simple), tags.
- **Capabilities tab**:
  - **docker / utm** — what backends this runner advertises. The API
    routes session work to runners whose capabilities match the
    backend the session asks for.
  - **secret authority** — enable only on the Mac that holds your
    plaintext credentials (typically your laptop). Active credential
    sealing lands in a follow-up release; for now this just advertises
    the role so the API can give clear errors when a registered
    authority is offline.
- **Credentials tab**: API key paste + pairing.
- **General tab**: Launch at login (uses macOS `SMAppService`), log
  verbosity, version.

## Menu bar

- Green dot — connected and idle
- Yellow dot — busy with work
- Red dot — disconnected (settings missing or API unreachable; the
  menu shows the underlying error)
- Pause dot — manually paused; resume from the menu

Quick actions in the menu: Reconnect (when disconnected), Pause/Resume,
Open dashboard, Copy runner name, Settings.

## Logs

The runner logs to OSLog under subsystem
`com.neverprepared.brainbox-runner`. View live with:

```
log stream --predicate 'subsystem == "com.neverprepared.brainbox-runner"' --info
```

Or open **Console.app** and filter by that subsystem.

## Building from source

Requires a recent Xcode and `xcodegen`:

```
cd app/runner
xcodegen generate
open BrainboxRunner.xcodeproj    # then ⌘R
```

For an unsigned local build you can also use `xcodebuild` from the
command line — see `.github/workflows/runner-ci.yml`. Signed,
notarized DMGs are produced on tag push via
`.github/workflows/runner-release.yml`.

## Architecture notes

- The runner shells out to the `docker` CLI rather than linking a
  Swift Docker SDK — `docker` is what's already on every Mac that
  has Docker Desktop.
- UTM is driven via `osascript`, matching the `mcp-utm` approach.
- The bundle delivery flow (when a session uses `delivery=bundle`):
  `docker exec brainbox-init keygen` inside the new container, read
  the recipient pubkey out, POST the API's `/api/credentials/seal-request`
  to get sealed bytes back (the API relays to the secret authority),
  stream the bytes in via `docker exec -i`, run `brainbox-init apply`.
- The secret authority role in the runner currently advertises the
  capability but doesn't yet drain the credential queue — that's
  phase 2. Run `brainbox cc poll` from the brainbox CLI to bridge
  for now.
