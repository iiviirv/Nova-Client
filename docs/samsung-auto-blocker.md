# Samsung Auto Blocker: "Unknown app blocked"

**Short answer: there is nothing Nova can change in the app to avoid this.**
It is a device setting on Samsung phones, not a property of the APK, and no
signature, target SDK, manifest flag or install method gets around it.

## What the user sees

> **Unknown app blocked**
> To keep your phone and data safe, Auto Blocker prevents the installation of
> unknown apps. You can only install apps from authorized sources such as the
> Play Store or Galaxy Store.
> To remove this protection, go to Settings > Security and privacy > Auto Blocker.

## What it actually is

Auto Blocker ships on One UI 6.1 and later and is **on by default** on newer
Samsung devices. When it is on, Samsung refuses every install that does not come
from an installer it considers authorized: the Play Store, the Galaxy Store, and
Samsung's own updater. It does not inspect the app. A Play-signed, notarised,
perfectly ordinary APK is blocked exactly the same way Nova's is, because the
check is on where the install came from, not what is being installed.

This is separate from the older "Install unknown apps" per-source permission and
from Play Protect (see [`play-protect-warning.md`](./play-protect-warning.md)),
and turning either of those off does not help.

## What the user can do

1. **Turn Auto Blocker off** (their choice, on their device):
   Settings > Security and privacy > Auto Blocker > off. The install then
   proceeds with the ordinary "Install unknown apps" prompt.
2. **Use Obtainium**, which the site and the release posts already point at.
   Obtainium is itself installed the same way, so Auto Blocker has to be off
   once to get it, but after that updates come without the block.

## What actually removes the block for everyone

A store listing. Auto Blocker's whole definition of "authorized source" is the
Play Store and the Galaxy Store, so:

- **Google Play** is the real unlock, and it is currently held up on the
  organization account, not on anything technical (see
  [`android-release-signing.md`](./android-release-signing.md) and the
  Play org-account note: a personal Play account publishes the developer's home
  address, and a VPN app requires an organization account).
- **Galaxy Store** is the narrower, faster option: it is Samsung's own store, it
  satisfies Auto Blocker on exactly the devices that have Auto Blocker, and it
  has its own developer account and review. Worth considering on its own merits,
  because Samsung devices are where this complaint comes from.

Until one of those exists, the honest support answer is option 1 or 2 above,
said plainly rather than implying a future app update will fix it.
