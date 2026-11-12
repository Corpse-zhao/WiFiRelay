# WiFiRelay

CarPlay companion for jailbroken iPhones (roothide / rootless).

When the phone joins an internet-less WiFi hotspot (car head unit / wireless
CarPlay box), iOS may treat that hotspot as the primary route and black-hole
all traffic. WiFiRelayD (root daemon) actively probes the hotspot every few
seconds; if it has no real internet, a pf anchor blocks all **non-local**
outbound traffic on that interface (the local CarPlay subnet stays open), so
iOS's own captive check fails, the WiFi gets demoted to "no internet", and
cellular takes over routing + DNS automatically.

- Config: `/var/mobile/Documents/WiFiRelay/config.plist` (`Enabled`, `ProbeIntervalSec`)
- Log:    `/var/mobile/Documents/WiFiRelay/relay.log`
- Daemon: `/usr/bin/WiFiRelayD` (LaunchDaemon `com.corpsezhao.wifirelay`, RunAtLoad + KeepAlive)
