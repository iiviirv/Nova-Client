# "App blocked to protect your device" on install

Users sideloading the APK see a Play Protect dialog:

> **App blocked to protect your device**
> Play Protect hasn't seen an app from this developer before. It may be unsafe.

## What this is, and what it is not

Read the wording carefully: **"hasn't seen an app from this developer before."**
This is not a malware detection and not a broken signature. Play Protect is
saying it has no *reputation* for the certificate that signed the APK.

It is a different problem from the earlier "unsafe app" warning, which was caused
by debug-signing and was fixed by signing releases with the real key. The
published APK is correctly signed today:

    Signer #1 certificate DN: CN=Innovate Northtech Inc., OU=Nova,
      O=Innovate Northtech Inc., L=Keswick, ST=Ontario, C=CA
    SHA-256: cd66399058465b7d43a55dbfd245b5544539d50de5c2bb9966826679c258e236

Verify any build with:

    apksigner verify --print-certs <apk>

## What actually clears it

Reputation accrues **to the signing key**, over time and installs. In rough order
of effect:

1. **Never rotate the signing key.** Every release must use `nova-release.jks`
   (alias `nova`). Changing keys resets reputation to zero and forces every user
   to uninstall and reinstall. This is the single most important rule here.
2. **Volume and time.** The warning fades as more devices install the same signed
   app without incident. Nothing to do but keep shipping the same key.
3. **Publishing on Google Play** is the definitive fix, and is blocked on the
   organization-account address problem (a VPN app needs an org account, and an
   org account publishes its address publicly). See
   [[nova-client-android-distribution]].
4. **IzzyOnDroid** does not remove the dialog by itself, but a listed app in a
   known repo is a legitimacy signal and gives users a route that does not feel
   like grabbing an APK from a link.

Signing scheme hygiene (v2 + v3, set in `android/app/build.gradle.kts`) is
correct to have but does **not** make this dialog go away. Do not claim it will.

## What to tell users

The dialog is dismissible, but the newer layout hides the escape hatch: the
button says **Got it**, and **Install anyway** is small text above it that is
easy to miss. Many users tap "Got it" and give up, so spell it out.

English:

> Android shows this for any app it has not seen from a developer before. It is
> not a virus warning. Tap **Install anyway** (the small text above the button),
> not "Got it". If you do not see it, tap the three dots or "More details" first.

Farsi (bidi-safe, Latin runs isolated):

> اندروید این پیام را برای هر برنامه‌ای که قبلا از سازنده‌اش چیزی ندیده نشان
> می‌دهد. این هشدار ویروس نیست. روی ⁦Install anyway⁩ بزنید (متن کوچک بالای دکمه)،
> نه روی ⁦Got it⁩. اگر آن را نمی‌بینید، اول روی سه نقطه یا ⁦More details⁩ بزنید.
