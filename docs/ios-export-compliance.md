# iOS export compliance

`ios/Runner/Info.plist` declares:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This is correct, and the reasoning is worth writing down because it is easy to
talk yourself out of it.

## Why false is the right answer

The key asks whether the app uses **non-exempt** encryption. Nova uses plenty of
encryption, but its cryptography comes from sing-box and Xray, which are
publicly available open-source implementations, and publicly available
encryption source code is exempt under the EAR. So the app uses encryption, and
none of it is non-exempt. False.

Every Nova build distributed so far has declared this, and comparable clients
that are published on the App Store carrying the same cores declare it too.

## The mistake, and how it surfaced

This was briefly changed to `true`, on the reasoning that shipping Reality,
Shadowsocks ciphers and obfuscation meant Nova was not using "standard" Apple
cryptography and therefore could not be exempt.

That reasoning conflated two different things: *encryption Apple did not write*
and *encryption outside the exemptions*. The exemptions are not a list of
Apple's frameworks; publicly available open-source implementations are exempt
however exotic the protocol.

Apple rejected it in two stages, which is what made the error obvious:

1. With `true`, upload fails with error **90592**, "Invalid Export Compliance
   Code ... the key value [] doesn't match the app's export compliance
   documentation". `true` expects an `ITSEncryptionExportComplianceCode` from a
   declaration on file, and the API confirms Nova has zero
   `appEncryptionDeclarations`.
2. With the key removed entirely, the upload succeeds but the build cannot be
   distributed at all: adding it to a TestFlight group returns "Build is not
   assignable" and submitting for beta review returns
   **MISSING_EXPORT_COMPLIANCE**.

Only the exempt answer lets a build reach testers.

## If a build is ever stuck without a declaration

A build uploaded without the key can be answered after the fact, without
rebuilding, by patching the build:

```
PATCH /v1/builds/{id}   {"data":{"type":"builds","id":"...",
                         "attributes":{"usesNonExemptEncryption": false}}}
```

That is what unblocked build 98. It returns 200 and the build becomes
assignable immediately.

## What this does not cover

Nothing here is legal advice, and the classification is the company's to stand
behind. If Nova ever ships cryptography that is **not** publicly available (an
in-house cipher, an unpublished obfuscation), this answer stops being true and
the whole question has to be revisited.
