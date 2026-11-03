# Security

Please report a security problem privately: open the repo's Security tab and press "Report a vulnerability". Don't open a public issue for it.

Tether runs a WireGuard server on your iPhone. The reports that matter most are a way to reach that server or the traffic through it without the keys, a way to read the keys off the phone, and a release `Tether.ipa` that doesn't match its source.

While Tether is on screen and Add a device is open, or closed less than 10 minutes ago, its page on the hotspot (`http://172.20.10.1`, or the iPhone's IPv6 address on an IPv6-only hotspot) hands the next device's config to anyone on the hotspot. A way to get a config at any other time, from anywhere but the hotspot, or a code that still connects after that window, is a security problem.

Fixes go into the latest release only.
