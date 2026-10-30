# Testing

There are three layers. Run them in order, because a failure lower down explains a failure higher up.

## 1. Unit tests on the Mac

```sh
scripts/build-wireguard.sh   # once, and after a change in WireGuard/. xcodegen runs it too
swift test
```

They need no device and no internet. They cover:

- WireGuard keys and configs: key pairs, address allocation, the client config text, and a Keychain error never replacing the saved server key.
- WireGuardServer.swift through the C API into the real Go server (the xcframework's macOS slice): start and stop, a bad address or a port in use coming back as an error, short keys refused before Go reads them, and peers Go refuses.
- The server's counters: no device counting as connected before its first handshake, and traffic totals that never go backwards across restarts.
- The ready device (let in but not listed until it connects, then listed and replaced by a new one), the build expiry warning, when the keep-alive sound plays, how bytes and speeds read, and what the Shortcuts actions say.

The WireGuard server has its own Go tests:

```sh
go -C WireGuard test -race ./...
```

CI also fuzzes the UDP replies for 30 s and checks for known vulnerabilities. Locally:

```sh
go -C WireGuard test -run '^$' -fuzz FuzzReplyPackets -fuzztime 30s ./...
go -C WireGuard run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...
```

The fuzz test sends any payload from the internet through `replyPackets` and checks the fragments are valid IPv4 that put the datagram back together exactly. `govulncheck` fails only when Tether's code can reach a known vulnerability.

They run a real WireGuard client (wireguard-go with its own netstack) against the server over loopback: TCP and UDP through the tunnel, an unknown key getting nothing, sharing off, a removed device locked out and its connections closed, a router's clients sending from their own private addresses (and a plain device or a public address refused), Close during UDP traffic (a deadlock once), full-cone UDP (a reply from an address the device never contacted gets through, the way a call connects), and replies bigger than the tunnel MTU arriving in IPv4 fragments. The client's netstack refuses to send to 127.0.0.1, so the tests dial a documentation address (198.51.100.7) and swap the server's dialer to reach the local test listeners.

## 2. UI tests on the simulator

```sh
xcodegen generate
xcodebuild test -project Tether.xcodeproj -scheme Tether \
  -destination "platform=iOS Simulator,name=<a simulator>" -derivedDataPath .build-sim -only-testing:TetherUITests
```

XCUITests in `UITests/` walk every screen and flow of the app: the status card, the speed and the device list on the main screen, the QR code section (code, shared file, steps, the header), one device's screen (Connected or not, renaming, removing with a confirmation), the WireGuard problem section, the system accessibility audit, large text and dark mode. They need no device and no network. A demo launch never connects a device, so claiming the ready device is covered by the unit tests, not here.

Run them on the oldest and the newest iOS you can, since iOS versions differ in small ways (section headers in capitals or not, a dialog with or without Cancel). Actions > UI tests runs them on iOS 18.5 on an iPhone SE, the smallest screen, and on the newest iOS GitHub's runners have. iOS 17, the oldest Tether supports, isn't available as a simulator for Xcode 27 or on GitHub's runners, so check it on a phone. For an iOS that GitHub's runners don't have yet, run the command above on a Mac with that simulator (`xcodebuild -downloadPlatform iOS` downloads the newest).

A simulator has no Personal Hotspot and nothing to share, so each test launches the app with `-TetherDemo <scenario>` (see `Sources/DemoMode.swift`). The scenarios are fixed fake states: `waiting`, `noDevices`, `sharing` (devices iPad connected and MacBook not, and a speed), `wireGuardLocked` (the Keychain is locked: WireGuard shows its problem and there is no QR code), `wireGuardLockedWaiting` (the same with the hotspot off: the problem shows from launch), `wireGuardNeedsReset` (the saved WireGuard keys can't be read, so only "Start over with new keys" gets past it, and then the QR code appears), `wireGuardUnsaved` (a first launch whose new keys can't be saved: no QR code and WireGuard isn't running), `qrCodeUnsaved` (sharing, but the code for the next device can't be saved, so the section says why instead of showing one) and `expiring` (sharing, two days before the build stops opening). The WireGuard setup lives in an in-memory store in a demo launch, never the Keychain. In a demo launch the app starts no server, audio, watcher or sampler. The code is `#if DEBUG`, so a Release build does not contain it. A launch without the argument is the real app, and `NormalLaunchTests` checks that.

## 3. By hand, with someone on the other end

These need another person or a game account, so they aren't scripted.

| Test | How | It passes when |
|---|---|---|
| FaceTime audio | Call someone from the iPad and talk for 2 minutes | You both hear each other and it doesn't drop |
| FaceTime video | The same, with video | The picture doesn't freeze for 5 seconds or more |
| WhatsApp or Telegram call | Voice call from the iPad for 2 minutes | It connects within 10 seconds and doesn't drop |
| Online game | Play one real-time match | The ping stays steady and you don't get disconnected |
| iPhone locked | Repeat one call with the iPhone screen locked | Same as unlocked |
| Music on the iPhone | Play music on the iPhone, then browse from the iPad | Music keeps playing and the iPad stays online |
| Call on the iPhone | Take a phone call on the iPhone, hang up, browse from the iPad | The iPad is still online after the call |
| WireGuard | Scan the QR code on Tether's main screen with WireGuard on the iPad, turn the tunnel on, browse and call | Pages and calls work, the iPad is listed as Connected, and the QR code changes to a new one |
| Travel router | Share the file from Tether's main screen, import it in the router's WireGuard client, connect the router to the iPhone, join a laptop to the router's Wi-Fi and browse | The router is listed as Connected in Tether and pages load. Tether finds the router by itself, with nothing to set |
| Connected check | Keep Tether's main screen open while you scan the QR code on an iPad and turn the tunnel on | The iPad shows up in the Devices list as Connected within a few seconds, and the code is replaced |
| Idle WireGuard device | Connect the iPad with WireGuard, then leave it alone for 2 minutes | Tether still shows it as Connected. Turn its tunnel off: within 3 minutes it shows Not connected |
| Battery overnight | Leave the hotspot on and the iPad connected overnight, then open Settings > Battery | Tether is no longer the top app by a wide margin |
| Battery, nothing to share | Open Tether, then leave the iPhone in airplane mode overnight | Tether is near the bottom of Settings > Battery |
| Hotspot after a long gap | Wait more than 10 minutes with the hotspot off, open Tether, then turn the hotspot on in Settings | Tether starts sharing without being opened again |
| Shortcut after a long gap | Wait more than 10 minutes with the hotspot off and Tether in the background, then run a shortcut with Set Personal Hotspot (On) and Start Tether | Tether doesn't come on screen and the action says it's ready. Join the iPad: its tunnel connects. Lock the iPhone for 15 minutes: the iPad is still online |
| Is Tether Sharing? | Run it with the hotspot off, then on with the iPad connected | It says waiting, then sharing with 1 device |

## Things we learned the hard way

- **A test build replaces the installed Tether.** Build it with the same bundle ID as the installed copy, or it installs next to it with new WireGuard keys, and every device has to be added again.
