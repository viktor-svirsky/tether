# Tether

[![CI](https://github.com/viktor-svirsky/tether/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/viktor-svirsky/tether/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/viktor-svirsky/tether)](https://github.com/viktor-svirsky/tether/releases/latest)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue)
[![License: MIT](https://img.shields.io/github/license/viktor-svirsky/tether)](LICENSE)
[![Website](https://img.shields.io/badge/website-viktor--svirsky.github.io%2Ftether-0069b8)](https://viktor-svirsky.github.io/tether/)

<img src="Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="96" alt="Tether icon">

**Use your iPhone's data on any device, as the iPhone's own traffic instead of hotspot traffic.**

Lots of plans give the iPhone itself plenty of data, then cap, slow down or block Personal Hotspot. Tether makes every connection again on the iPhone itself, so your laptop's traffic counts as the phone's own. Windows, Mac, Linux, Android, iPad or a travel router: if it runs WireGuard, it works.

<img src="docs/sharing.png" width="260" alt="Tether sharing with an iPad and a Windows PC, with the speed and the list of devices"> <img src="docs/add-device.png" width="260" alt="Tether with the hotspot on and a QR code for the first device">

## What you get

- The free WireGuard app runs on Windows, macOS, Linux, Android, iPad and iPhone, and many travel routers (GL.iNet, UniFi Travel Router) have it built in. Connect a router and every device behind it is covered.
- Setup takes a minute. A phone or tablet scans a QR code, and a laptop opens a page on the hotspot and downloads its config, no camera needed.
- It's not only web pages. Video calls, games, streaming, downloads and SSH all go through.
- There's no account and nothing in the cloud. Traffic goes from your devices to your iPhone and out, and Tether talks to nothing else. It's free and open source (MIT).
- One shortcut turns on the hotspot and Tether together, from the Action button, a widget or Siri.

A device without WireGuard can still join the hotspot, but its traffic goes straight out as hotspot traffic and Tether doesn't help it. Tether isn't in the App Store, so you install it with SideStore or AltStore (a free Apple ID is enough). And a carrier that looks closely can still notice, see [Good to know](#good-to-know).

## Quick start

1. [Install Tether on your iPhone](#install-tether-on-your-iphone) with SideStore or AltStore, which you set up from a Windows PC or a Mac. Or build it yourself on a Mac. Already have SideStore or AltStore? [Add Tether in one tap](https://viktor-svirsky.github.io/tether/add/) from your iPhone.
2. Turn on Personal Hotspot and open Tether. It shows a QR code.
3. On the other device, install the free WireGuard app and join the hotspot. A Windows, Mac or Linux laptop downloads its config from `http://172.20.10.1`. An iPad or phone scans the code. Then turn the tunnel on ([details](#connect-a-device-with-wireguard)).

That's it. The device shows up in Tether as connected.

## Why this works

Carriers can tell when traffic comes from a device that's connected to your hotspot, and some plans block it or throttle it. Traffic that comes from the phone itself counts as phone traffic.

Tether is a small app that runs on your iPhone. Your laptop, tablet, phone or travel router still joins the hotspot, but instead of sending its traffic straight out, its WireGuard client hands it to Tether. Tether makes the connections itself, so they leave from the iPhone like its own traffic.

```
laptop, tablet, phone  ──hotspot──▶  Tether on iPhone  ──cellular──▶  internet
or router
(WireGuard client)
```

Inside, Tether runs a WireGuard server on UDP port 51820, on the hotspot address `172.20.10.1`. Each device connects with its WireGuard client, and everything goes through, calls and games included. WireGuard's own code decrypts the traffic and a small TCP/IP stack inside Tether ([gVisor](https://gvisor.dev)) makes each connection again from the iPhone. UDP behaves like a full-cone NAT, so calls and games can connect directly. No VPN entitlement or network extension is needed on the iPhone.

## Install Tether on your iPhone

You need an iPhone with iOS 17 or later and a plan with Personal Hotspot. Tether isn't in the App Store, so you install it yourself: with a signing app like SideStore or AltStore (easiest), or by building it on a Mac.

### With SideStore or AltStore

SideStore and AltStore install apps on your iPhone signed with your own Apple ID. A free Apple ID is enough.

1. Install SideStore or AltStore with their own guide: [SideStore](https://docs.sidestore.io), [AltStore](https://faq.altstore.io). It needs a computer for the setup.
2. On iOS 16 or later, turn on Developer Mode: Settings > Privacy & Security > Developer Mode. The iPhone restarts and asks you to confirm. Apps signed with your own Apple ID don't open without it.
3. Add Tether's source: on your iPhone, open [the add page](https://viktor-svirsky.github.io/tether/add/) and tap Add to SideStore or Add to AltStore. Or open Sources in SideStore or AltStore, tap + and paste this:

   ```
   https://github.com/viktor-svirsky/tether/releases/latest/download/source.json
   ```

4. Find Tether in Browse and install it. New releases show up there as updates, and an update keeps your devices.
5. Open Tether, then [connect a device](#connect-a-device-with-wireguard).

A free Apple ID has limits: 3 sideloaded apps at a time (SideStore or AltStore counts as one), and each app has to be refreshed every 7 days. SideStore and AltStore do that refresh for you, see their docs for what they need.

You can also skip the source: download `Tether.ipa` from the [latest release](https://github.com/viktor-svirsky/tether/releases/latest) and open it in SideStore or AltStore.

### With Feather, a paid certificate, or another signer

Download `Tether.ipa` from the [latest release](https://github.com/viktor-svirsky/tether/releases/latest) and sign it the way you sign other apps. A paid Apple Developer account has no 3-app limit, and its builds last a year instead of 7 days.

### Check the download

Each [release](https://github.com/viktor-svirsky/tether/releases) has an unsigned `Tether.ipa`, built by GitHub Actions from the release's commit. GitHub signs a record of that build, so with the [GitHub CLI](https://cli.github.com) this shows the file you downloaded is the one built here:

```sh
gh attestation verify Tether.ipa -R viktor-svirsky/tether
```

The release notes also list its SHA-256.

A signing app usually changes the bundle ID, so a Tether installed this way is a separate app from one you built with Xcode, with its own keys. Add your devices to it again.

### Build it yourself

You need a Mac with Xcode. A free Apple ID is enough.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go (`brew install xcodegen go`). `xcodegen generate` builds the WireGuard part with Go first, see `scripts/build-wireguard.sh`.
2. Open `project.yml` and set `DEVELOPMENT_TEAM` to your own team ID, and `APP_BUNDLE_ID` to something unique like `com.yourname.tether`. You'll find your team ID in Xcode under Settings > Accounts.
3. Build and install:

   ```sh
   xcodegen generate
   xcodebuild build -project Tether.xcodeproj -scheme Tether \
     -destination "id=<your-iphone-udid>" -derivedDataPath .build-dd -allowProvisioningUpdates
   xcrun devicectl device install app --device <your-iphone-udid> \
     .build-dd/Build/Products/Debug-iphoneos/Tether.app
   ```

   `xcrun devicectl list devices` shows your iPhone's UDID.

   If Tether is already on the iPhone, build it with the same bundle ID, or a second Tether installs next to it with new keys and every device has to be added again. `xcrun devicectl device info apps --device <your-iphone-udid>` shows the installed one, and `APP_BUNDLE_ID=<that id>` at the end of the `xcodebuild` line uses it.
4. The first time, iOS won't open the app until you trust your developer certificate: Settings > General > VPN & Device Management > your Apple ID > Trust.
5. Open Tether. It waits for Personal Hotspot and starts by itself when the hotspot is on. You can leave it in the background.

## Connect a device with WireGuard

This works for an iPad, an iPhone, a Mac, a Windows or Linux laptop, an Android phone or a travel router. Everything goes through, calls and games too, and nothing changes on other Wi-Fi.

Tether's main screen always shows a QR code for the next device, with a short step under it. There is no button to press. Tether has already made a key for that code. The first time a device connects with it, or downloads it from Tether's page, the device shows up in the Devices list by itself, as Device, Device 2 and so on, and the code changes to a new one for the next device. Tap a device to see if it is connected, remove it, or tap its name at the top to rename it.

- **iPad or iPhone:** install the free [WireGuard](https://apps.apple.com/app/id1441195209) app, then + > Create from QR code and scan the code on Tether's screen. Edit the tunnel and turn On-Demand on for Wi-Fi, only for your iPhone's hotspot name, then join the hotspot. The tunnel turns itself on at the hotspot and off everywhere else.
- **Windows, Mac, Linux or Android:** join the hotspot, keep Tether open on the iPhone, and open `http://172.20.10.1` in a browser. Type the `http://`, since some browsers try https first and fail. Download the config there and import it into WireGuard (Import Tunnel(s) from File on a Mac or Windows, `wg-quick up` on Linux). Each download gets a key of its own, so open the page on each device. The page hands out a config only while Tether is on screen, the same as the QR code. On a Mac, Share file under the code with AirDrop works too. Browser under the code shows the page's address.
- **Travel router** (a UniFi Travel Router, a GL.iNet): add a WireGuard client in the router's VPN settings from the shared file, connect the router to the iPhone by USB or the hotspot, and turn its VPN on. Some routers send their clients' traffic from the clients' own addresses instead of their tunnel address. Tether notices that by itself and lets the router's clients through, and its traffic covers every device behind it. On other networks, turn the router's VPN off.

Each device has its own key. Removing a device in Tether locks it out without touching the others.

## Start it from Shortcuts

Once no device has been on the hotspot for 10 minutes, iOS suspends Tether, and it has to be opened again before the hotspot comes back. Shortcuts can do that for you. Tether adds two actions to the Shortcuts app, with nothing to set up:

- **Start Tether** wakes Tether in the background, the same as opening it, but it stays off the screen. It shares as soon as a device joins Personal Hotspot in the next 10 minutes. (iOS only makes the hotspot's network while a device is on it, so that's when Tether can see it.)
- **Is Tether Sharing?** says whether Tether is sharing and how many devices are connected. It gives true or false, for an If.

You can also say "Start Tether" to Siri, find it in Spotlight, or put it on the Action button.

iOS has no automation for "Personal Hotspot turned on", so let one shortcut turn on both:

1. In Shortcuts, make a new shortcut named **Hotspot** with two actions: **Set Personal Hotspot** set to On, then **Start Tether**.
2. Run it instead of turning on the hotspot in Settings: from the Action button, a widget, or Siri ("Hotspot").
3. To have it run by itself, add an automation in Shortcuts > Automation that runs Hotspot and is set to Run Immediately. For example, when your car's Bluetooth connects, when you arrive somewhere you share from, or at a time of day.

## Good to know

- **It stops opening after 7 days** when signed with a free Apple ID. Tether says on its main screen when it has three days or less left. Refresh it in SideStore or AltStore, or build and install it again (step 3 above), before then. A paid certificate lasts longer. Your devices and settings stay.
- **Keep it running.** Tether plays silent audio so iOS doesn't suspend it in the background. It mixes with other audio, so your music keeps playing, and it picks up again after a call, Siri, or an audio reset. With no device on the hotspot for 10 minutes it stops, to save battery, and iOS suspends Tether. Open it again, or run Start Tether, before you turn the hotspot back on, and after a restart.
- **It only listens on the hotspot**, never on other Wi-Fi networks. WireGuard only lets in devices you added.
- **Devices reach what the iPhone reaches**, private networks included. With a VPN on the iPhone, your devices use it too, so its networks are open to them and to everyone behind a travel router you added.
- **The main screen** shows whether Tether is sharing, the QR code for the next device with Share file and Browser buttons under it, your devices with Connected or Not connected, and the current download and upload speed. To stop sharing, turn off Personal Hotspot.
- **The traffic leaves as your iPhone's.** If your iPhone runs a VPN, shared traffic goes through that VPN too.
- **Your carrier can still notice.** Tether hides where the traffic comes from, not what it is. A Mac's software updates or an iPad's apps still look like a Mac or an iPad to a carrier that looks closely. Many carrier contracts don't allow tethering workarounds, and a carrier can slow down or close a line that breaks them. Check yours. Using Tether is your call and your risk.
- **Not for the App Store.** Apple doesn't allow the silent-audio trick, so you sign and install Tether yourself.

## For developers

```
Sources/WireGuardServer.swift  runs the WireGuard server; WireGuardSetup.swift has the keys and configs
WireGuard/                   the WireGuard server in Go: wireguard-go plus a gVisor TCP/IP stack
scripts/build-wireguard.sh   builds WireGuard/ into TetherWG.xcframework (xcodegen runs it)
scripts/build-ipa.sh         builds the unsigned Tether.ipa; make_source.py writes source.json for it
scripts/next-version.sh      picks the next release version from the last tag
Sources/HotspotSession.swift finds the hotspot, starts the server, samples traffic (tested on the Mac)
Sources/Model.swift          runs the session on timers and feeds the screens
Sources/MainView.swift       the main screen; DevicesView.swift has the QR code and the device screen
Sources/ConfigPage.swift     the page on the hotspot that hands out the next device's config; ConfigPageServer.swift serves it
Sources/KeepAlive.swift      silent audio to stay alive in the background
Sources/Shortcuts.swift      the Start Tether and Is Tether Sharing? actions for Shortcuts and Siri
Sources/DemoMode.swift       fake app states for the UI tests (Debug builds only)
Tests/                       unit tests, run on the Mac
UITests/                     UI tests for every screen, run on the iOS Simulator
scripts/screenshots.sh       makes the two screenshots above, on an iPhone simulator
docs/index.html              the landing page at viktor-svirsky.github.io/tether, served by GitHub Pages from docs/
docs/add/index.html          the one-tap "Add to SideStore/AltStore" page, served by GitHub Pages from docs/
```

The file map at the top of Model.swift lists every source file.

Run the unit tests with `swift test` (after `scripts/build-wireguard.sh` or `xcodegen generate`, since they link the WireGuard server), and the WireGuard server's own with `go -C WireGuard test ./...`. They start the real server on your Mac and talk to it over loopback, so you don't need a device. [TESTING.md](TESTING.md) covers the simulator UI tests and the checks by hand.

To release, open Actions > Release > Run workflow on main and pick what goes up: patch, minor or major. `scripts/next-version.sh` works out the version from the last tag, `scripts/build-ipa.sh` builds `Tether.ipa`, `make_source.py` writes `source.json`, and the workflow publishes both as a GitHub release, which creates the tag. `python3 scripts/test_make_source.py` and `scripts/test-next-version.sh` test the scripts.

## License

MIT, see [LICENSE](LICENSE).

The WireGuard server is built from [wireguard-go](https://git.zx2c4.com/wireguard-go) (MIT), [gVisor](https://gvisor.dev) (Apache 2.0), [google/btree](https://github.com/google/btree) (Apache 2.0) and Go's `golang.org/x` packages (BSD). `WireGuard/go.mod` pins their versions, and Go downloads each one with its license. A built Tether app contains their code, so if you give a build to someone, include their licenses with it. `scripts/build-ipa.sh` collects them into `LICENSES.txt`, which each release has next to `Tether.ipa` and inside the app.
