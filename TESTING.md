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
- The hotspot lifecycle in `HotspotSession`, round by round: the server starts when the hotspot appears and stops when it goes or changes, a failed start is tried again, a setup problem shows before a start problem and a stale start error clears with the hotspot, a refused device list restarts the server, a rename or removal that couldn't be saved says so until a change saves, the config page starting and stopping with the server and starting again after a failure, the 10-minute keep-alive wait on and off screen, the background claim and read of who is connected, and the speeds.
- The config page: what it reads from a request (only the request line, the path without the query), the headers on every answer (no caching, no sniffing, no scripts, closed after it), the config handed out only while Tether is on screen, a download listing the device and making a new key for the next one, and a download that couldn't be saved handing out nothing. The real listener runs on loopback: one answer per connection, a request in pieces, a head over 8 KB, a connection that sends nothing, a port in use, and a restart on the same port.
- Notifications (`Notifier` and `NoticePoster`): a device told by name when it connects, and when it leaves only once it has been gone 3 minutes, one device at most once in 5 minutes, nothing on screen and nothing told again that the screen showed, the hotspot going told as each connected device disconnecting after 3 minutes (its network also goes when the last device leaves, so Tether can't tell the two apart), WireGuard stopping told after a minute with the devices that were connected, the build expiring told once a day, a notice that waits 3 minutes ahead while Tether shares and is pushed back every minute, so it shows only if Tether stops (taken away when sharing stops, its switch goes off, or Tether launches again), a switch for each kind, and permission asked on screen when something happens there that would be told in the background, once, with nothing posted before that or after a no.
- The ready device (let in but not listed until it connects, then listed and replaced by a new one), the build expiry warning, when the keep-alive sound plays, how bytes and speeds read, and what the Shortcuts actions say.

The WireGuard server has its own Go tests. CI runs them at full size, then again under the race detector:

```sh
go -C WireGuard test ./...
go -C WireGuard test -race ./...
```

CI also fuzzes the UDP replies for 30 s and checks for known vulnerabilities. Locally:

```sh
go -C WireGuard test -run '^$' -fuzz FuzzReplyPackets -fuzztime 30s ./...
go -C WireGuard run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...
```

The fuzz test sends any payload from the internet through `replyPackets` and checks the fragments are valid IPv4 that put the datagram back together exactly. `govulncheck` fails only when Tether's code can reach a known vulnerability.

They run a real WireGuard client (wireguard-go with its own netstack) against the server over loopback: TCP and UDP through the tunnel, an unknown key getting nothing, sharing off, a removed device locked out and its connections closed, a router's clients sending from their own private addresses (and a plain device or a public address refused), Close during UDP traffic (a deadlock once), full-cone UDP (a reply from an address the device never contacted gets through, the way a call connects), and replies bigger than the tunnel MTU arriving in IPv4 fragments. The client's netstack refuses to send to 127.0.0.1, so the tests dial a documentation address (198.51.100.7) and swap the server's dialer to reach the local test listeners.

Scenario tests run many devices at once, the way people use Tether:

- `many_test.go`: eight devices downloading and pinging together, and a travel router next to direct devices.
- `traffic_test.go`: uploads and downloads both ways with checksums, a page-load burst, a DNS storm, a call next to a big download, the biggest unfragmented UDP, and a reconnect from the same port right after the host closed.
- `failure_test.go`: far ends that refuse, never answer, close or reset mid-transfer, half-closes both ways, a network that comes up late, and a device sending as another.
- `lifecycle_test.go`: the hotspot going off and on, a device roaming to a new port, sleep and wake, the same config on two devices, devices added and removed while others stream, nothing left behind, and 253 devices configured.

Under `-race` gVisor runs about a hundred times slower, so the busiest tests do less then (`raceEnabled`, see `race_test.go`), and the scenarios whose goroutines meet the way other tests' already do don't run at all (`fullSizeOnly`). The run without `-race` does every test at full size.

Measurements that depend on this computer's speed, or wait on real WireGuard retries, run only with `LOAD=1` and without `-race`:

```sh
LOAD=1 go -C WireGuard test -run TestLoad -v ./...
LOAD=1 DEVICES=32 go -C WireGuard test -run TestLoadManyDevices -v ./...
```

They print throughput and fairness with `DEVICES` devices, ping times while another device downloads (`STREAMS`), memory with devices at their connection cap (`EACH`), a far end that never answers, and two cases that need 15 s of WireGuard retries. Both ends run on this computer, so they show the server's limits here, not the iPhone's.

## 2. UI tests on the simulator

```sh
xcodegen generate
xcodebuild test -project Tether.xcodeproj -scheme Tether \
  -destination "platform=iOS Simulator,name=<a simulator>" -derivedDataPath .build-sim -only-testing:TetherUITests
```

XCUITests in `UITests/` walk every screen and flow of the app: the status card, the speed and the device list on the main screen, Add a device (the button, and the sheet with its steps, code, shared file and the page's address), one device's screen (Connected or not, renaming, removing with a confirmation, and saying when either couldn't be saved), the WireGuard problem section, the Settings sheet behind the gear (a switch for each kind, all on, a switch that stays off, the Allow button before Tether asked, what it says when notifications are off in Settings, the version, the source link and when the build stops opening), the permission question on screen and one notice posted in the background through the real notification center (the test taps Allow if the simulator asks), the system accessibility audit, large text and dark mode. They need no device and no network. A demo launch never connects a device, so claiming the ready device is covered by the unit tests, and the sheet's waiting and connected steps by two demos that follow a listed device.

Run them on the oldest and the newest iOS you can, since iOS versions differ in small ways (section headers in capitals or not, a dialog with or without Cancel). Actions > UI tests runs them on iOS 18.5 on an iPhone SE, the smallest screen, and on the newest iOS GitHub's runners have. iOS 17, the oldest Tether supports, isn't available as a simulator for Xcode 27 or on GitHub's runners, so check it on a phone. For an iOS that GitHub's runners don't have yet, run the command above on a Mac with that simulator (`xcodebuild -downloadPlatform iOS` downloads the newest).

A simulator has no Personal Hotspot and nothing to share, so each test launches the app with `-TetherDemo <scenario>` (see `Sources/DemoMode.swift`). The scenarios are fixed fake states: `waiting`, `noDevices`, `sharing` (devices iPad connected and Windows PC not, and a speed), `wireGuardLocked` (the Keychain is locked: WireGuard shows its problem and there is no QR code), `wireGuardLockedWaiting` (the same with the hotspot off: the problem shows from launch), `wireGuardNeedsReset` (the saved WireGuard keys can't be read, so only "Start over with new keys" gets past it, and then the QR code appears), `wireGuardUnsaved` (a first launch whose new keys can't be saved: no QR code and WireGuard isn't running), `qrCodeUnsaved` (sharing, but nothing can be saved: the section for the next device says why there's no code, and a device's screen says a rename or removal couldn't be saved), `expiring` (sharing, two days before the build stops opening), `notificationsOff` (sharing, with notifications off for Tether in Settings), `notifying` (sharing, it asks for permission on screen through the real notification center, and leaving the screen posts one notice) `notificationsScreen` (sharing, opened on the Settings sheet with notifications allowed, for the screenshot) `addDeviceScreen` (the hotspot on and no device, opened on the Add a device sheet, for the screenshot), and `addDeviceWaiting` and `addDeviceDone` (sharing, opened on the sheet as if the Windows PC, not connected, or the iPad, connected, had just claimed the code). The notification switches of a demo launch live in their own UserDefaults, emptied at each launch. The WireGuard setup lives in an in-memory store in a demo launch, never the Keychain. In a demo launch the app starts no server, audio, watcher or sampler. The code is `#if DEBUG`, so a Release build does not contain it. A launch without the argument is the real app, and `NormalLaunchTests` checks that.

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
| Media services reset | Connect the iPad, send Tether to the background, then Settings > Developer > Reset Media Services > Reset All Media Services. Browse from the iPad for 10 minutes | The iPad stays online the whole time |
| WireGuard | Tap Add a device, scan the QR code with WireGuard on the iPad, turn the tunnel on, browse and call | Steps 2 and 3 tick and say the device is connected, a Done button shows, pages and calls work, and the iPad is listed as Connected |
| Config page | Join the iPad to the hotspot. Keep Tether on screen, open `http://172.20.10.1` in Safari on the iPad, download the config and import it in WireGuard (+ > Create from file or archive), then turn the tunnel on | The page loads, the iPad is listed as a new device right after the download and the QR code changes, then it shows as Connected and pages load. With Tether in the background the page says to open Tether, and the download link is gone |
| Travel router | Share the file from Add a device, import it in the router's WireGuard client, connect the router to the iPhone, join a laptop to the router's Wi-Fi and browse | The router is listed as Connected in Tether and pages load. Tether finds the router by itself, with nothing to set |
| Connected check | Keep Add a device open while you download the config on a laptop from the page, then turn its tunnel on | Step 2 ticks right after the download and step 3 waits with a spinner, then ticks within a few seconds of the tunnel coming on |
| Idle WireGuard device | Connect the iPad with WireGuard, then leave it alone for 2 minutes | Tether still shows it as Connected. Turn its tunnel off: within 3 minutes it shows Not connected |
| Battery overnight | Leave the hotspot on and the iPad connected overnight, then open Settings > Battery | Tether is no longer the top app by a wide margin |
| Battery, nothing to share | Open Tether, then leave the iPhone in airplane mode overnight | Tether is near the bottom of Settings > Battery |
| Hotspot after a long gap | Wait more than 10 minutes with the hotspot off, open Tether, then turn the hotspot on in Settings | Tether starts sharing without being opened again |
| Shortcut after a long gap | Wait more than 10 minutes with the hotspot off and Tether in the background, then run a shortcut with Set Personal Hotspot (On) and Start Tether | Tether doesn't come on screen and the action says it's ready. Join the iPad: its tunnel connects. Lock the iPhone for 15 minutes: the iPad is still online |
| Notifications | Add the iPad with Tether on screen and allow notifications when asked. Lock the iPhone, turn the iPad's tunnel off, and once "iPad disconnected" shows, wait 5 minutes and turn it on again. Then turn off Personal Hotspot and wait 4 minutes | The question shows as the iPad connects. On the lock screen, "iPad disconnected" shows 3 to 6 minutes after the tunnel goes off, "iPad connected" within 30 seconds of it going on, and "iPad disconnected" 3 minutes after the hotspot goes. With Tether on screen nothing shows |
| Tether stopped | Share with the iPad connected and notifications allowed, then go to the home screen and stop Tether from Xcode (Debug > Detach and kill, or the stop button) | "Tether stopped sharing" shows about 3 minutes later. Opening Tether again takes it away, and turning off Personal Hotspot first means it never shows |
| Is Tether Sharing? | Run it with the hotspot off, then on with the iPad connected | It says waiting, then sharing with 1 device |

## Things we learned the hard way

- **A test build replaces the installed Tether.** Build it with the same bundle ID as the installed copy, or it installs next to it with new WireGuard keys, and every device has to be added again.
- **A media services reset is only reported to an app that uses audio again.** When the media server dies, the silent sound stops, and an app in the background without sound is suspended within seconds. `mediaServicesWereReset` comes only after the app touches audio, so waiting for it waits forever. `KeepAlive` asks for background time as soon as the services are lost, and starts a new player every second until one plays. Killing `audiomxd` alone (`pymobiledevice3 developer dvt kill`) is not the same test: Tether survives that even without the fix, so use the Settings button.
