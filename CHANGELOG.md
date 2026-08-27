# Changelog

## v1.20.15-beta (2026-08-27)

- Added: support for AmneziaWG 3, the version built to survive the blocking that
  started catching AmneziaWG 2 in mid-2026. It varies packet sizes, padding and
  timings so a connection is harder to recognise by its statistics rather than by
  any single giveaway. Nothing to turn on: when your provider's server offers it,
  Nova uses it.

- Unchanged: servers running the older AmneziaWG keep working exactly as they did.
  Nova only sends the new settings when the server has asked for them.

## v1.20.14-beta (2026-08-27)

- Fixed: a single AmneziaWG server could stop the whole lightning test, leaving
  every server untested behind "Could not start the measuring core". It happened
  when Nova could not look up that server's address, which is exactly what
  happens when your panel is unreachable and the saved list is all you have, so
  it hit at the worst moment. That one server now shows as untested and the rest
  are measured as normal.

## v1.20.13-beta (2026-08-27)

- Fixed: testing servers got worse the more you used it. After a few tests, or a
  few server switches, Reality, Hysteria2 and Shadowsocks 2022 servers started
  reporting "no response" even though they worked, and only a longer timeout or a
  freshly opened app made it right again. Stopping a test cleared it from the
  screen while it was still running underneath, so the next test started a second
  one on top of the first. The two competed, and the servers that need a real
  handshake to open a connection were the ones that ran out of time. A new test
  now waits for the previous one to actually finish.

- Changed: connecting spends much less time on "Verifying". Nova waited three
  seconds before its first check and three between each one after, so a server
  already carrying traffic still sat there for three seconds, and a dead one took
  up to eighteen to say so. It now checks almost immediately and slows down only
  if the first answers do not come, so a working server turns green about as fast
  as it connects.

- Fixed: on iPhone, locking the screen during a lightning test could close the
  app. Testing now stops when Nova leaves the foreground, as the free server
  search already did. A tunnel keeps running with the screen off, as before.

## v1.20.12-beta (2026-08-27)

- Fixed: tapping a subscription's Telegram proxy opened a web page instead of
  adding the proxy to Telegram. It now hands the proxy straight to the Telegram
  app, and only falls back to the web page when there is no Telegram installed
  to take it.

- Added: a subscription can now ask for the SNI-block bypass to be on from the
  start, for a server the operator knows sits behind a network that blocks the
  domain. Your own switch still decides: once you have set it yourself, refreshing
  the subscription leaves it exactly as you left it.

## v1.20.11-beta (2026-08-26)

- Fixed: on Windows and macOS, xhttp servers from a subscription did not work.
  Two separate faults, both of them silent: a subscription's xhttp servers were
  left out of the pool entirely on desktop even though the same servers were
  measured and shown as choosable, and the rule that keeps the second core's own
  connection out of the tunnel was skipped whenever the server's name did not
  resolve. Either one leaves you looking at "Connected" with nothing loading.
  Phones were never affected, which is why the same subscription worked there.

- Added: a subscription can offer a Telegram proxy, and Nova now shows it. When
  yours includes one, a Telegram proxy row appears on the subscription card on
  the home screen and opens it. Nothing connects through it and it is not a Nova
  server; it is a shortcut, and it is absent when your subscription has none.

## v1.20.10-beta (2026-08-26)

- Fixed: AmneziaWG servers always read "no response" in the lightning test, even
  though connecting to the very same server worked. Nova was asking the core to
  time them the way it times every other server, and for this kind of server that
  request fails without the core even trying to connect. They are now measured
  over a real connection instead. Two servers that reported nothing before now
  answer in about 250 ms.

## v1.20.9-beta (2026-08-26)

- Fixed: on Android, a connection that never came up could leave Nova stuck on
  "Connecting" with no way out. Disconnect did nothing, closing the app and
  reopening it came straight back to the same screen, and the only thing that
  helped was restarting the phone. Nova gave up after thirty seconds but only
  changed what it said on screen, while the tunnel service kept running in the
  background. It now shuts that down properly, so a server that will not connect
  leaves you back at the start instead of stranded.

- Fixed: on iPhone, locking the screen while Nova was searching the free server
  list could close the app. The search kept dialling servers while the system was
  putting the app to sleep around it. Searching now stops when you leave the app
  and keeps whatever it had already measured.

- Fixed: on Windows, the tray icon's menu stayed open until you picked something
  from it. Clicking anywhere else left it on screen.

- Fixed: a server added on its own, rather than through a subscription, was never
  checked for whether traffic was really flowing, so the dashboard could sit on
  "Verifying" for as long as it was connected and never reach "No traffic".

## v1.20.8-beta (2026-08-25)

- Fixed: the Windows app refused to start on any PC without Microsoft's Visual
  C++ Redistributable installed, showing "the code execution cannot proceed
  because VCRUNTIME140_1.dll was not found". Windows was stopping the app before
  a line of Nova code ran, so nothing appeared in the logs. Nova now carries that
  runtime inside the download and no longer depends on what the machine already
  has.

- Fixed: on macOS, disconnecting could leave the tunnel up, and so could quitting
  Nova, with the core still carrying traffic after the window was gone. Once the
  elevated job was handed to the system launcher, the system was free to start it
  again the moment it ended, so killing the core simply brought it back. Nova now
  says plainly when it does not want a tunnel, and a restart in that state does
  nothing instead of dialling out again. The core is also forced down if it
  ignores the first request to stop, so "disconnected" on screen means it is.

- Fixed: on macOS, clicking Nova's Dock icon did nothing once the window had been
  closed. Getting back in meant finding Show Nova in the menu bar. The Dock icon
  brings the window back now, which is where anyone looks first.

- Added: Nova reopens at the size and position you left it, on macOS and Windows
  both. It used to return to the default place after every quit. A window saved
  on a screen that is no longer attached keeps its size and comes back somewhere
  you can reach it.

- Fixed: on Windows, the tray icon's menu flickered and re-drew about once a
  second while it was open, and would not close when you clicked away from it.
  The menu was being rebuilt on every traffic reading even though nothing it
  displays had changed. It is now rebuilt only when it actually differs.

- Changed: quitting on Windows is quicker. Disconnecting waited up to a second
  for a check that now runs three times a second, and quitting waits for the
  disconnect. Closing or crashing Nova on Windows also takes the tunnel down with
  it, which previously only happened on macOS.

- Fixed: on Android, the bottom of the speed test sat underneath the navigation
  bar, out of reach. Four other screens had the same problem: Radar, the
  Cloudflare tools, and both relay screens.

## v1.20.7-beta (2026-08-25)

- Changed: Nova now writes its DNS settings in the format current versions of
  the core expect. The old format still worked on phones but the desktop core
  refused to start on it, and the next core release removes it everywhere. This
  is the underlying cause of the macOS tunnel failures, fixed at the root
  rather than worked around.

- Fixed: the ad blocker answers blocked domains the same way it always did, an
  empty success, so apps stop asking instead of retrying.

- Changed: the speed test explanation now sits under the speed test rather than
  under the gaming results, where it read as if it described them.

## v1.20.6-beta (2026-08-25)

- Fixed: full-device mode on macOS, properly this time. The password prompt
  appeared, you typed it, macOS said yes, and then nothing happened. The core
  was being started in a way macOS shuts down again the moment it grants
  administrator rights, so it never ran and never left anything behind to say
  so. Nova now hands the job to the system's own launcher, which keeps it.

- Added: a gaming test on the speed test screen. It takes a hundred readings
  back to back and reports min, average, median, P95, max and jitter, plus how
  many packets were lost in a row rather than just how many in total, since a
  run of losses is what a game shows you as a freeze.

- Added: a playability score out of 100. It weighs steadiness far above
  distance, because reaching European servers from Iran costs 80 to 100 ms and
  that is normal, not a bad connection. Loss counts most, then jitter, then
  spikes, then raw ping. The breakdown is shown so you can see how the number
  was reached.

## v1.20.5-beta (2026-08-25)

- Fixed: full-device mode on macOS. The core would not start and Nova blamed
  administrator access, which was never the problem. The core needs one setting
  to accept the current DNS format, and the way Nova launched it with
  administrator rights could lose that setting on the way. Nova now writes what
  it is about to run to a file and runs the file, so there is nothing to lose.

- Changed: when full-device mode does fail, there is now always a log to read.
  Previously the core could die before writing anything, which is why this took
  three attempts to find: no log meant no reason, and Nova guessed the wrong one.

## v1.20.4-beta (2026-08-24)

- Fixed: Nova on a Mac installed from the DMG could not start full-device
  mode, and said it needed administrator access. It did not. A downloaded app
  has every file inside it quarantined, and Nova copies its core out of the
  bundle before running it, so macOS killed the copy on sight. With nothing in
  the log to go on, Nova guessed the admin prompt had been dismissed, which is
  why approving it never helped and why running the app as an administrator
  changed nothing either.

- Fixed: the speed test. Upload counted bytes handed to a buffer rather than
  bytes that reached the network, so it reported thousands of Mbit/s. Ping
  timed one cold connection, so it included the DNS and TLS setup and read
  roughly three times high. Both directions now run one at a time, for three
  seconds each, and only after the connection settles.

- Added: jitter and packet loss on the speed test. Latency is the average of
  twenty round trips and jitter is how much they move; loss is over a thousand
  probes, shown as a percentage. For a game these two decide more than raw
  speed does.

- Changed: refreshing the free list searches it again, on screen and stoppable,
  and stops once it has thirty servers of which at least five answer in under
  300ms. Thirty servers that all take two seconds is not a list anyone can use,
  so when the fast ones are missing it keeps looking.

- Fixed: with per-app routing on, the dashboard showed your own IP and country
  instead of the server's, because Nova itself was outside its own tunnel.

- Added: Nova Radar can hand its best addresses to the free list. With it on,
  each free server dials one of the five best addresses your last scan found
  instead of its own domain. Off unless you turn it on.

- Fixed: Radar scanned using the domain of whichever subscription was active,
  so scanning while on a panel you pay for pointed hundreds of handshakes at
  your own domain in a few seconds, which is exactly what gets a domain
  noticed and disrupted. Scans no longer touch it.

- Added: Nova on Linux.

- Changed: Nova's own links no longer appear on subscriptions you added
  yourself.

## v1.20.3-beta (2026-08-24)

- Removed: the automatic server test. It ran when a list refreshed, when you
  opened a subscription, and after a server switch, it regularly hung with no
  result, and it could not judge Reality, Hysteria2, SS2022 or mieru at all.
  Nothing tests a server now unless you ask it to.

- Changed: after a refresh every server reads "not tested" and the old readings
  are dropped, on screen and on disk. A lightning test's numbers then stay until
  you run another one, until the twelve-hour refresh, or until you save the list
  by hand.

- Fixed: the lightning test no longer fights the old background test for the same
  sockets, and starting a connection now stops a running test instead of putting a
  second core underneath it.

- Fixed: servers that need a real handshake to open a session (Reality, Hysteria2,
  SS2022, mieru) were being called dead. They all dial a bare VPS and pay a full
  handshake, while the ones that always passed ride a CDN edge and are up in a
  couple of hundred milliseconds; on one shared five-second budget the cheap ones
  finished and the rest were written off. The warm-up dial now gets its own,
  longer budget. The number you see is unchanged, still measured on a warm dial.

- Added: a server that does not answer now says so in the log, with its name,
  protocol and the actual reason. Previously a run where the ws servers passed and
  every Reality server failed logged nothing at all.

- Added: subscriptions show data used and remaining beside their name in the
  server list, and the figures survive a restart.

- Added: per-app proxy on Android. Send only the apps you pick through Nova, or
  everything except the ones you pick. Android is the only platform whose VPN
  layer supports this.

- Changed: Radar and the Cloudflare panel moved into Settings, under Cloudflare
  tools.

- Changed: first run offers the free servers or adding a config. Deploying a
  panel, signing in to one and connecting a VPS asked for an account, a login or
  a server that nobody has on first run, and two of them opened the same screen.
  Both are still in Settings and on the Servers page.

## v1.20.2-beta (2026-08-24)

- Fixed: the number beside Configs now counts the servers you can actually see.
  If you stopped the search after ten working servers it still said 144, which
  was the size of the pool being searched rather than your list.

- Changed: each device now searches the free list in its own order. Everyone was
  searching it in the same order and stopping at the same point, so everyone
  ended up on the same few servers while the rest went unused. Spreading that
  out keeps those servers alive longer. Your own order stays the same between
  visits, and subscriptions you added are untouched.

## v1.20.1-beta (2026-08-24)

- Fixed, desktop: the VPN core is now replaced when you update. Nova copies the
  core out of the app and runs that copy, and it only replaced the copy when the
  file size changed. Core updates are often the same size, so a fix could reach
  you in an update and never actually run, and reinstalling did not help either.
  One tester spent days on a crash that had been fixed a week earlier. This
  update replaces the copy for everyone, once.

- Fixed, desktop: when full-device mode cannot get administrator access, the
  error says what went wrong. It used to always say "approve the admin prompt",
  even for people who had already approved it.

## v1.20.0-beta (2026-08-23)

- Fixed: switching server no longer throws away your ping results. A switch is a
  disconnect followed by a connect, and both steps were wiping the list, so a
  full lightning test turned into a handful of live numbers with the rest blank.
  Your results now stay put, and the list still shows which server is carrying
  traffic.

- New: AmneziaWG servers arrive from a subscription, not only when you paste the
  link by hand. They sit in the list with everything else and take part in the
  ping test. If your provider puts AmneziaWG in your subscription, it will show
  up now.

- Fixed: when full-device mode fails on macOS, the message says what actually
  went wrong. It used to show the last few lines of the log, which is the tail
  of a crash trace, so the real reason was cut off.

## v1.19.0-beta (2026-08-23)

- Fixed: your ping results are kept. They were held in memory only, so closing
  the app threw away a test that takes a minute or two. On Android, leaving with
  the back button was enough to lose it.

- Fixed: lists stop re-testing themselves for no reason. A list is now updated
  when it is new, when it is more than 12 hours old, or when you press refresh,
  and at no other time. Switching server and connecting no longer start a fresh
  test. Settings, Test options has the setting and can turn it off.

- Changed: the free list stops once it has found 30 working servers, and shows
  only the servers that answered. Every row you see is one you can use, instead
  of half the list sitting on a spinner.

- Changed: the lightning button on the free list re-tests the servers on screen
  rather than the few hundred they were found among. Refresh is what searches
  again.

- Changed: the free list is now built only from WebSocket servers behind
  Cloudflare. Servers on other hosts, and Reality servers, test well and then
  fail or stop working within hours on Iranian networks, because nothing can be
  done for them once the address is noticed. Cloudflare addresses stay reachable
  and the SNI-block bypass answers the filtering they do get. This is already
  live and needs no update.

## v1.18.0-beta (2026-08-23)

- New: opening the free servers for the first time now shows what Nova is doing.
  These are shared servers and some are always gone, so the list is only worth
  showing once it has been checked. You get a live count of the working servers
  as they are found, and a stop button that keeps everything found so far.

- Fixed: the ping test can be stopped. Tapping the bolt while it is running ends
  it, and leaving the server list ends it too. On a slow connection a full sweep
  can take minutes, and there was no way out of it.

- Fixed: opening a server list no longer re-downloads it and re-tests every
  server every single time. That happens when the saved list is more than half a
  day old, and the refresh button still checks whenever you ask. Your test
  results stay put in between.

- Fixed: a server that does not answer is asked again at the end of the run,
  once the rest have finished. Running the whole test two or three times used to
  be the way to get those servers back.

- Removed: servers hosted inside Iran are no longer published to the free list.
  A server inside the country carries your traffic through the very place you
  are trying to get past. This one is already live and needs no update.

## v1.17.1-beta (2026-08-23)

- Fixed: the ping test on the free servers spun for ever and never showed a
  number. One server carrying a setting the core does not recognise stopped
  every server in the list from being tested, not just itself, and 88 of the 200
  in a test run carried it. The same thing could stop a connection from starting
  at all.

  Two settings were involved, both copied straight from the server link into the
  core: an Xray-only encryption flow, and a browser fingerprint of "unsafe" that
  the SNI-block bypass sets. Nova now translates what it can and drops what it
  cannot, so a server Nova does not understand fails on its own instead of
  taking the list down with it.

  Worth updating for if you use the free servers: on 1.17.0 the ping test cannot
  work at all.

## v1.17.0-beta (2026-08-22)

- New: servers behind Cloudflare keep working after their address is filtered.
  A public subscription hands out its servers by name, and those names get
  filtered within days while the Cloudflare addresses behind them keep working.
  Nova now finds an address that is reachable from your own network and dials
  those servers through it, sending the name only as the TLS name. That is also
  what switches the SNI-block bypass on for them: it only ever applied to a
  server already given as an address, so a server given by name used to get no
  bypass at all and died with its name.

  Your device finds its own address rather than being given one, because which
  addresses are clean depends on the network you are on. It is looked for in
  the background, kept for half a day and then checked again. A server that is
  not actually behind Cloudflare is left exactly as your provider wrote it, and
  subscriptions without the bypass turned on are untouched.

## v1.16.1-beta (2026-08-22)

The whole round of testing feedback, plus free servers built in, by the Nova
team. (1.16.0 carried these too but was withdrawn within the hour over the
resolver fix at the end of this list, so this is the release that has them.)

**New**

- Free servers, built in. A fresh install now opens on a working Connect
  button: Nova ships its own server list, already selected, with the SNI-block
  bypass on. Servers that answer nothing are hidden automatically, and anything
  that is not encrypted never makes the list. You can still add your own
  subscription, and the free list stays available underneath it.
- Proxy mode on Android and iPhone. Nova serves a local SOCKS5/HTTP proxy on
  127.0.0.1 instead of tunnelling the whole phone, so only the apps you point
  at it go through Nova, and another VPN can be running at the same time. The
  address is on the dashboard, and the port is yours to change (Settings >
  Routing).
- Nova lives in the menu bar on Mac and the notification area on Windows.
  Closing the window keeps the tunnel running, and the tray menu can connect,
  disconnect and quit without opening it.
- Tap any server's ping to test just that one.
- Settings gained two of its own screens: Server owner (your panel address and
  its shortcut) and Test options (what the ping test measures, moved out of
  Routing where nobody found it).

**Fixed**

- The lightning test now reports the latency you actually have. Two things were
  wrong: it timed the first dial, so mieru and NaiveProxy reported the one-off
  cost of building their session forever, and the test quietly ran over https,
  which added a TLS handshake to every measurement. Measured against a real
  subscription, mieru went from 422ms to 207ms and a clean IP from 251ms to
  134ms, both now matching what the same servers measure from inside the
  tunnel. Each server also gets its full timeout starting when its own test
  starts, so the end of a long list is no longer cut off, and a server that
  misses once gets a second chance before it is called dead.
- (Mac) Nova no longer keeps the machine out of idle. A helper process sat at
  around 5% CPU for as long as the full-device tunnel was up, holding the CPU
  at full clock and the laptop about 20C hotter. It is gone. The live traffic
  readout also stops polling when no window is on screen.
- (iPhone) Turning the VPN off in iPhone Settings now turns it off. It used to
  come straight back, so the only way to stop Nova was inside the app and a
  second VPN could not take over. Settings > Routing has an opt-in for anyone
  who wants the old behaviour.
- The country and flag next to a server are only ever learned while the tunnel
  is up, so a reading taken after disconnecting can no longer label a server
  with your own country.
- The country on the dashboard no longer changes on its own. Nova asks several
  location services and they disagree: one exit was called Sweden, Finland and
  Lebanon by three of them. A country now stands for as long as the exit does.
- The ping on the dashboard is the core's own figure now, measured through the
  tunnel, instead of a probe from outside it that read far too high.
- Refresh means refresh: it fetches the current servers and takes no pings, and
  opening a subscription of more than 50 servers no longer probes them all.
- The Configs tab shows the servers inside your current subscription rather
  than repeating the Servers tab, and its count is the servers you can choose
  between rather than the lines in the subscription.
- (Android) Long Settings pages no longer end underneath the navigation
  buttons.
- The connected dashboard fits without scrolling: the timer and Secure fold
  into the ring and the dial draws in.
- "Connect your VPS" left the + menu; it lives on the empty-servers screen,
  where someone with nothing yet actually meets it.
- Fixed (Android and iPhone): the lightning test reported "no response" for
  every server whose address is a name rather than a number, which is most of
  them. The change above that made the testing core start faster had dropped
  its resolver, and on a phone there is no other one, so it could not look the
  addresses up. Connecting was never affected, only the test. Servers given as
  a bare IP, like the free list, still worked, which is how it got past us.

## v1.15.1-beta (2026-08-20)

- Fixed (Android): the new app icon in 1.15.0 was mirrored. It is the right
  way round again and matches the icon you already had.

## v1.15.0-beta (2026-08-19)

Proxy mode you can actually use, ping settings you can change, and updates
you can see, by the Nova team.

- New (Mac and Windows): with the full-device tunnel off, the dashboard now
  shows a Proxy mode card while connected: Nova's local SOCKS5/HTTP address
  (tap to copy), whether the system proxy points at Nova, and a button to
  set or clear it. Settings > Routing gained "Set system proxy
  automatically" for people who would rather point chosen apps at the port
  themselves.
- Fixed (Mac): connecting in proxy mode waited on the admin prompt, so the
  app could sit on "Connecting..." while the tunnel was already up. It
  connects first now and sets the system proxy in the background. Mac also
  sets the web and secure-web proxies, not only SOCKS, and a declined
  prompt is reported honestly instead of being shown as set.
- New: Settings > Routing > URL test. The test address, the per-server
  timeout (5s by default, and the lightning test now stops waiting that
  long after the last answer), how often auto-select re-tests, and how much
  faster a server must be before auto switches.
- Fixed: the update check ran once a day, so a user two releases behind
  could hear nothing. It runs every three hours and on returning to the
  app, and Settings > Check for updates now really checks and answers,
  showing the new version when there is one.
- Fixed (Android): the app icon was a small mark inside a tile in themed
  launchers, because it shipped only a legacy icon. It is a proper adaptive
  icon now, with a themed (monochrome) version, and fills the shape like
  other apps.
- Changed: the subscription card's ping is the best-server figure, so it
  shows only when the server choice is on Auto.

## v1.14.0-beta (2026-08-19)

Hysteria2 works, the lightning test reaches iPhone, and server names stay
yours, by the Nova team.

- Fixed: Hysteria2 (and TUIC) servers never connected, with or without
  salamander obfuscation. The client was handing the QUIC dialer a browser
  TLS fingerprint it cannot use. Verified against a real Hysteria2 server
  with salamander.
- New: "Test all servers through the core" on iPhone too. It now runs on
  Android, iPhone, Mac and Windows.
- Changed: the server list shows your servers' own names again instead of a
  guessed city. The flag is remembered across refreshes and restarts, and
  once you connect through a server its real exit country replaces any
  guess for good.
- Changed: pings are measured over plain http inside the tunnel (one TLS
  handshake fewer per test), so the numbers are roughly half what they were
  and closer to what other clients show for the same server.
- Settings: Radar, Cloudflare and Google relay entries removed. Stats: the
  Worker usage card removed.
- Fixed: Settings showed an old version number in its footer.
- A pasted hysteria2://, vmess:// or tuic:// link is labelled as such.

## v1.13.2-beta (2026-08-19)

A small follow-up to 1.13.1 from a full emulator pass, by the Nova team.

- Fixed: on the very first server switch after a fresh install the
  connection could fail with a rule-set read error. The bundled rule files
  are now written atomically, a switch cannot race a write, and the one
  case that still slips through retries on its own.
- Fixed: "Test all servers through the core" on Android fetched its rule
  lists from GitHub, which is blocked in Iran; it uses the bundled ones now,
  like the tunnel.
- The add dialog shows why an AmneziaWG entry was refused right under the
  field, and it scrolls, so the Save button no longer sits on top of the
  protocol pills when the keyboard is open.

## v1.13.1-beta (2026-08-19)

Quick fixes for what you reported on 1.13 within the first hours, by the Nova
team.

- Fixed: the panel page showed "HTTP 401" instead of your panel's login. A
  panel that asks for a username and password now gets a sign-in dialog, and
  only a real dead page (404, server error) shows the error view. A missing
  icon or blocked tracker on the page no longer counts as a failure either.
- Fixed: importing an AmneziaWG file accepted any file and could take the app
  down. The picker is limited to text files, oversized or non-conf files are
  refused with a message, and an entry that does not parse cannot be saved.
  Pasting a conf into the add dialog now keeps its line breaks.
- Fixed: after updating, the dashboard kept offering the previous version
  ("1.12 is available"). Versions are compared properly now.
- Fixed (Android): a burst of server switches could freeze the app for a few
  seconds ("isn't responding"). Network callbacks no longer block the main
  thread while the core is starting or stopping.
- Test all servers through the core now includes xhttp servers, run on the
  Xray core for the test, so they get a real number instead of "not
  testable".

## v1.13.0-beta (2026-08-19)

Test every server through the core, AmneziaWG working on Mac and Windows, and
a stuck "connecting" state put right, by the Nova team.

- New: a lightning button in the server list tests every server through the
  core itself (Android, Mac and Windows). Servers that could only be called
  "not testable" before (Reality, obfuscated Hysteria2, Shadowsocks 2022, a
  clean-IP server behind an SNI block) now get a real number, measured the
  way a tunnel would use them, and a dead one says "no response". Results
  fill in live. Disconnect first; it needs the tunnel down.
- Fixed: AmneziaWG servers whose Endpoint is a domain name failed on Mac and
  Windows while working on Android. The desktop apps now resolve the address
  the same way the phone does.
- Fixed: on Windows, full-device mode reported "approve the UAC prompt" for
  every failure, even when you had approved it or were running as
  administrator. The real reason is shown now, and a user folder with a
  space in its name no longer breaks the start.
- Fixed: Windows was still carrying the AmneziaWG disconnect crash that was
  fixed on the other platforms last release.
- Fixed: after switching servers quickly a few times (or toggling the SNI
  bypass), the app could sit on "connecting" and, on Android, leave the VPN
  icon on with nothing flowing until a force close. Start and stop are now
  strictly ordered and a switch mid-connect is handled cleanly.
- Fixed: deleting an AmneziaWG config could make your other servers vanish
  from the list until a restart. They were never deleted; a filter was left
  behind. Deleting now asks for confirmation and names the profile.
- New: Settings > Panel lets you set your panel's address, and an optional
  "Panel" tab on the dashboard opens it in one tap. On Windows the panel
  opens in your browser instead of a blank page that could not be closed.
  A page that fails to load now says so and offers Retry.

## v1.12.0-beta (2026-08-19)

A crash fixed, the Mac and Windows apps catching up with the phone, and the
Nova subscription working properly, by the Nova team.

- Fixed a crash: disconnecting an AmneziaWG server closed the app. On Android
  it simply vanished; on Mac it showed a "close of closed channel" error. Both
  are gone.
- The Nova subscription now loads its servers. Importing the panel's own Nova
  link saved the address but showed no servers until you removed part of the
  URL by hand. It works as given now.
- On Windows, links from the panel now open Nova. They did nothing before.
- On Mac and Windows, choosing a specific server is respected. Picking Germany
  used to still send you out through whichever server was fastest, which was
  often a different country.
- On Mac and Windows, the dashboard now names the server you are connected
  through instead of showing a bare address and port.
- On Mac and Windows, servers that could not be measured from outside (Reality,
  obfuscated Hysteria2, Shadowsocks 2022, xhttp) now show a real ping while
  you are connected, measured through the tunnel itself.
- Full-device mode works on Mac again. It failed to start with a "bad tun name"
  error on every Mac.
- The log is quieter about network changes. Switching between Wi-Fi and
  cellular no longer fills it with red errors for what is a normal handover.
- iPhone: a proper opening screen instead of a white flash, and the
  disconnect alert no longer fires every time the phone sleeps.
- Mac: the download is one file for both Intel and Apple Silicon.

## v1.11.0-beta (2026-08-18)

A status notification, a home-screen widget, a new protocol, and a lighter touch
on your battery, by the Nova team.

- Nova now shows a status notification while it is connected, with the server
  you are on and a one-tap Disconnect. Before, the app ran with no notification
  at all, which made it hard to tell whether you were protected.
- New home-screen widget on Android: see at a glance whether Nova is connected,
  and tap it to open the app.
- New protocol: mieru. Subscriptions that offer mieru servers now work in Nova.
- The app is easier on your battery. Nova no longer checks your exit address or
  redraws the traffic graph while it is in the background, so a long connection
  costs less power.
- A cleaner look throughout: a calmer dashboard, tidier cards, and a clearer
  server list where long server names are no longer cut off.
- The opening screen now carries the Nova name and motto in English and Farsi,
  and no longer flashes white before the app loads.
- On iPhone, Nova now tells you if the connection drops unexpectedly, so you are
  not left unprotected without knowing.
- You can now import an AmneziaWG .conf file straight from the Add screen, and
  panel links (nova://) open Nova instead of failing in Safari.

## v1.10.0-beta (2026-08-17)

Faster connects, cleaner logs, and broader server support, by the Nova team.

- The first connection is quicker. The app no longer waits on a slow round of
  server checks before the tunnel comes up, so tapping connect gets you online
  sooner, especially on a blocked or slow network.
- AmneziaWG configs that use a domain name for the server now connect. Before, a
  config whose endpoint was a domain (not a plain IP address) failed to start;
  the app now resolves it for you.
- Subscriptions with xhttp servers now work: those servers join the auto-select
  pool and show a live ping like everything else, and Reality xhttp servers are
  supported too. On macOS this works in the app's proxy mode as well (whole-device
  tunnel support for xhttp on desktop is still to come; Windows and Linux get the
  second core in a later build).
- The logs are cleaner. The core's routine "blocked" lines (for example QUIC being
  steered onto TCP, which is normal) no longer show up as scary red errors; turn on
  "Detailed core log" if you want to see everything. On Android and iOS the Logs
  screen now also shows the second core's own messages.
- "Deploy your own panel" now hands you to the Nova Telegram bot, which sets up a
  free panel on your own Cloudflare account in a couple of minutes, instead of an
  in-app sign-in.
- Smaller fixes: the "Connected via" line and manual server pin are steadier, and
  the Cloudflare screen is clearer about signing in to manage your panel.

## v1.9.0-beta (2026-08-16)

Clearer server pings, by the Nova team.

- The server list now puts the servers with a real, live ping at the top (fastest
  first), so you can see and pick a working server at a glance instead of scrolling
  past a wall of "not testable" entries.
- With the SNI-block bypass on, the clean-IP servers (the ones that actually get
  through) now fill the measured set first, so more of your live pings are for
  servers that work.

## v1.8.0-beta (2026-08-15)

Server list and dashboard improvements, by the Nova team.

- The server list opens instantly now. If your subscription's address is blocked,
  the app shows your saved servers right away and refreshes in the background,
  instead of sitting on a loading spinner.
- When connected, every server in the list shows a live ping measured through the
  tunnel, and a green dot marks the one carrying traffic. A server that was tested
  but did not answer now reads "no response" instead of "not testable".
- The dashboard shows a live line with the exact server you are connected through,
  and "Secure" appears sooner after you connect.
- The refresh button re-checks your servers and reconnects to the best one.
- Nova now checks once a day for a new version and shows a small note when one is
  available; there is also a "Check for updates" link in Settings.
- A cleaner look: the Add button is now a floating button over the server list,
  and some secondary items were tidied away from the dashboard.

## v1.7.0-beta (2026-08-15)

Two fixes for restricted networks, by the Nova team.

- When the SNI-block bypass is on and connected, the server list now shows a live
  ping for each server (measured through the tunnel) and a green dot on the one
  actually carrying traffic, so you can finally see which servers work and which
  one you are on.
- A failed subscription refresh no longer wipes your servers. If the panel can't
  be reached (its domain is blocked), the app keeps your saved servers and shows
  a small note instead of an error, so you can still connect. The list updates on
  its own the moment the panel is reachable again, without dropping your
  connection.

## v1.6.0-beta (2026-08-15)

Exact-match the anti-censorship fragmentation, by the Nova team.

- The SNI-block bypass now splits the connection handshake into the exact same
  packet sizes as PattNG, byte for byte, instead of an approximation. On the
  strictest networks the approximation was not enough; this should behave the
  same as PattNG there. It is still off by default and only on the clean-IP
  servers, and turns itself on when nothing else connects.

## v1.5.1-beta (2026-08-15)

SNI-block bypass fixes from tester feedback, by the Nova team.

- The server list no longer says "blocked" for every server when the SNI-block
  bypass is on. The test it runs cannot reproduce the bypass, so it now says
  those servers are tested when you connect, instead of a false blocked.
- SNI-block bypass on Windows. The handshake fragmentation it used has a step
  that a normal Windows install cannot perform, so it never connected. Windows
  now uses the part that works, which is also the part that matters for hiding
  the server name.

## v1.5.0-beta (2026-08-15)

For the networks that block the worker domain itself, by the Nova team.

- SNI-block bypass, for networks that have started blocking the workers.dev
  and pages.dev domains themselves. Nova can now run the profile that testers
  found gets through in PattNG: plain TLS with a fixed cipher list instead of a
  browser fingerprint, and a fragmented handshake, on the clean-IP servers only.
  It stays off by default. If every server in a subscription fails to carry
  traffic, Nova turns it on for that subscription by itself, reconnects, and
  tells you; there is also a switch at the top of the server list. Links from
  cf-optimizor (fp=unsafe, cs, fm) import as-is, and a hardened Nova server
  re-shares in that same format so it pastes into PattNG.

## v1.4.0-beta (2026-08-15)

Every platform on the same code, and a cleaner app, by the Nova team.

- A modernized interface. The dashboard, server list, node list, settings and
  first-run screens were reworked around one clear focus per screen, with
  colour reserved for state and the measured verdict the most legible thing on
  a server row. Nothing animates while the app is idle any more, which is a
  real battery win: the connect orb used to repaint sixty times a second all
  day.
- Windows and macOS get the same VPN core as the phone. The desktop core had
  been an older stock build with no WireGuard, no NaiveProxy and no AmneziaWG in
  it, so those servers failed on desktop while working on Android. Both desktop
  cores are now built from the same source and patch as the Android one.
- iOS now requires iOS 15 or later, ahead of Apple's 2027 requirement.
- NaiveProxy servers work now. Nova Server has always been able to create one,
  and the phone app's VPN core could always run it, but the app could not read
  the link, so a NaiveProxy server appeared in no client at all. On desktop it
  says plainly that this build's core cannot run it, instead of the core dying
  at startup.
- A subscription no longer loses servers in silence. If it contains something
  Nova cannot run, the server list says how many and what kind, so a short list
  is explained instead of looking like configs went missing.

## v1.3.0-beta (2026-08-14)

An honesty update, by the Nova team. Nova now tells you what it actually knows
about your servers instead of guessing, and shows you what it and the VPN core
are doing.

- The server you pick is the server you get. If the one you chose connects but
  carries no traffic, Nova now tells you and stays on your choice instead of
  quietly connecting through a different one while the list still showed yours
  as selected. If your server has disappeared from the subscription, it says
  that too, rather than switching in silence.
- Ping numbers are real now. Nova used to show the time it took to open a
  connection, which succeeds against Cloudflare's network for any address at
  all, so every config looked healthy even on a network where none of them
  worked. Each server is now tested by actually talking to it, and where
  possible by sending a real request through it and waiting for the answer. A
  server that cannot be tested from outside says so instead of borrowing a
  number it did not earn.
- Server locations are honest. A config sent with a clean Cloudflare address
  used to be labelled with wherever that address happened to resolve, which is
  not where your traffic comes out. Those now show the name the panel gave them
  and say they are fronted, and configs that use a domain get a real flag,
  which they never used to.
- New Logs screen in Settings, with Nova's own log and the VPN core's log kept
  separate. Copying strips passwords, UUIDs and subscription tokens first, so a
  log is safe to send to support. Detailed core logging is a switch on that
  screen, off by default.
- AmneziaWG now actually works in Nova. The app has been building correct
  AmneziaWG configurations all along and handing them to a core that did not
  have the protocol in it, so a server's AmneziaWG worked in the official
  Amnezia apps and not here. Nova's core is now built with AmneziaWG.
- Nova also checks its own core before it tries. If a build ever ships without
  AmneziaWG again, it says so instead of connecting to nothing.
- The VPN core is now included for every processor type the app runs on. Older
  32-bit phones and x86 devices were installing an app that had no core for
  them, so they could open Nova and never connect. The download is larger
  because of it.

## v1.2.0-beta (2026-07-21)

A big anti-censorship update, by the Nova team.

- More protocols: SOCKS, HTTP, and plain WireGuard join VLESS, VMess, Trojan, Shadowsocks (including 2022), Hysteria2, and AmneziaWG import.
- Google relay upgrades: import your whole relay setup from one link or QR, a domain-fronting mode that reaches Google's edge even when the relay's own address is blocked, and a full-tunnel option that carries real traffic through Google to your own VPS when everything else is down.
- Find a working setup: when the block stops your usual setup, Nova tests each TLS fingerprint on your real network, measures which get through, and keeps the fastest.
- Anti-censorship tuning you can see: the Routing screen shows which TLS fingerprint is protecting you and lets you override it (Chrome, Firefox, Safari, iOS, Edge, Randomized) or leave it on Auto.
- Speed test: measure your real download and upload speed in the Stats tab.
- Hysteria2 speed boost (Brutal) for better throughput on throttled networks; set your line speed in Routing.
- Now targets Android 15.
- Builds: Android APK, macOS (Apple Silicon) DMG and zip, and Windows portable ZIP.

## v1.1.1-beta (2026-07-16)

Connectivity and panel fixes, by the Nova team.

- Cloudflare connect fixed: the in-app Cloudflare sign-in and API calls could fail with a TLS handshake error. Requests now run real TLS with the correct hostname, so connecting and deploying a panel work reliably.
- Panel password now saves in the app: right after deploying a new panel, setting the admin password could fail because the fresh worker was not serving its certificate yet. Nova now waits out that warm-up and retries, and if it still cannot reach the panel it tells you to finish setup in a browser.
- Android VPN routing fixed: outbound sockets were binding to the tunnel interface on Android 9 and newer, which broke Cloudflare-direct calls and slowed browsing. Traffic now uses the real Wi-Fi or cellular link.
- Android live speed meter: the dashboard now shows real upload and download speeds instead of staying at 0.
- Builds: Android and macOS (Apple Silicon) refreshed for this release. The Windows build carries over from v1.1.0-beta pending a fresh Windows build.

## v1.1.0-beta (2026-07-13)

- Redesigned node list with per-node location, SNI, and TLS fingerprint
- Search your nodes by name, country, protocol, address, or SNI
- Free-service header and community links
- Route every .ir domain direct so Iranian sites always load
- Farsi localization for the Routing and Servers screens

## v1.0.0-beta (2026-07-10)

First public beta of Nova Client.

- Proxy client with profiles, subscriptions, and routing controls, powered by a sing-box core
- Nova Radar: built-in Cloudflare clean-IP scanner (fetch, scan, TCP + TLS verify, latency sort, one-tap apply)
- Bilingual UI: English and Farsi (RTL)
- Dark-first Nova design language
- Builds: Android APK, macOS (Apple Silicon) DMG and zip, Windows zip
