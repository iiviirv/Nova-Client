# Battery optimization audit (client-side)

The core (sing-box/xray) dominates power while connected and is out of scope
here. This covers the Flutter/native client work that wakes the CPU or the radio
when it does not need to.

## Findings

Periodic timers found (`Timer.periodic` / repeating animations):

| Source | Interval | Runs when | Verdict |
| --- | --- | --- | --- |
| `conn_info_controller.dart` exit-IP poll | 6 s | while connected | probes the network every 6 s even when backgrounded |
| `dashboard_screen.dart` `_ticker` | 1 s | dashboard visible | drives the live speed/uptime readout |
| `stats_screen.dart` `_ticker` | 1 s | stats tab | samples traffic |
| `desktop_proxy_controller.dart` traffic poll | 1 s | connected (desktop) | laptop battery, lower priority |
| `nova_connect_orb.dart` motion | continuous | dashboard visible | `repeat()` spins forever, even idle |
| `radar_sweep.dart` | continuous | `widget.active` | already gated on active |
| `cloudflare_controller.dart` deploy poll | 1 s | during a deploy | transient, fine |

Flutter vsync-driven `AnimationController`s pause automatically when the app is
backgrounded (the engine stops producing frames), so the continuous animations
do not burn power off-screen. `Timer.periodic`, however, keeps firing in the
background because the VPN keeps the process alive, so timer-driven network work
is the real waste.

## Done

- **`conn_info_controller.dart`**: the 6 s exit-IP/geo poll now pauses while the
  app is backgrounded (via `AppLifecycleListener`) and refreshes once + resumes
  on foreground. Over a multi-hour tunnel this removes hundreds of background
  network probes that nobody was looking at.

## Deferred (files under a concurrent UI restyle; apply after it lands)

- **`dashboard_screen.dart` `_ticker`**: gate the 1 s tick on
  `AppLifecycleState.resumed` and only run it while connected (a disconnected
  dashboard has nothing changing to tick).
- **`nova_connect_orb.dart`**: only `repeat()` the motion while connecting or
  connected; keep it static when idle. Both a calmer look and less foreground
  churn.
- **`stats_screen.dart` `_ticker`**: confirm it cancels when the tab is not the
  visible one (an `IndexedStack` keeps it alive), and pause on background.

## Native (noted, not yet changed)

- Android `NovaVpnService` forwards the core's per-second status stream to the
  Flutter engine even when the app is backgrounded. The core produces it either
  way; the cost is the JNI + event-channel dispatch. Could pause forwarding when
  the app is backgrounded, but that risks missing a state transition, so left as
  is for now.
