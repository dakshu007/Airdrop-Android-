# Networking limitations and what users see

CrossDrop v1 needs both devices on the **same local network** with
device-to-device traffic allowed. That is the only supported path today.

| Situation | Effect | What the apps say / suggest |
|---|---|---|
| Different Wi-Fi networks, or one on mobile data | Devices cannot see each other | "Put both devices on the same Wi-Fi." |
| Guest network / "client isolation" / some office and hotel Wi-Fi | mDNS and direct TCP blocked; nothing appears, or connecting fails | Explain guest networks and suggest a home network or a phone hotspot that both join |
| macOS Local Network permission denied (macOS 15+) | Mac cannot browse or be reached | Point to System Settings › Privacy & Security › Local Network |
| macOS firewall "Block all incoming connections" | Android cannot connect to the Mac | Explain the firewall setting; never changed by the app |
| VPN with "block local network" | Discovery/connection fails | Suggest pausing the VPN or allowing local network access |
| Android battery saver / app killed | Receiving stops | Receiving runs in a visible foreground service; the Quick Settings tile can reopen it |
| Mac sleeps | Listener stops | The Mac app restarts advertising after wake |

Router-free transfer (Android Wi-Fi Direct ↔ Mac) is **not implemented**. macOS
has no public Wi-Fi Direct API compatible with Android, so this needs research
on real hardware before anything is promised.
