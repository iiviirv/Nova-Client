# iOS export compliance, and why the declaration changed

`ios/Runner/Info.plist` used to carry:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

That is the declaration for an app that uses no encryption at all, or only the
standard encryption Apple's own frameworks provide. Nova is neither. It ships
sing-box and Xray, and implements Reality, Shadowsocks ciphers and traffic
obfuscation. None of that is Apple-provided standard cryptography, and hiding
proprietary cryptographic behaviour from a network observer is the entire
product.

So the value is now `true`. That is not a formality: the previous answer was a
false statement on an export compliance question, and the cost of the correct
answer is paperwork rather than risk.

## What App Store Connect will now ask

With `true`, each submission asks a short series of questions. For Nova the
answers are:

| Question | Answer |
| --- | --- |
| Does your app use encryption? | Yes |
| Does it qualify for any of the exemptions? | No |
| Does it implement any encryption algorithms other than, or in addition to, those in Apple's operating system? | **Yes** |
| Is your app a mass market product? | Yes, it is free and publicly available |

The third answer is the one that matters and the one that makes the previous
`false` wrong. Do not be tempted by the exemption question: the exemptions cover
apps that merely call HTTPS, not apps that carry their own cipher suites.

## What has to be filed outside App Store Connect

Answering these questions is not the whole obligation. A mass market
cryptographic product is generally self-classified under **ECCN 5D992.c**, and
US exporters self-classifying under 5D992.c file an **annual self-classification
report** with BIS by 1 February covering the previous calendar year.

This is a legal filing about the company, not a build step, and it is Vahid's to
make or to take advice on. It is written down here because it is the part that
is easy to miss once the App Store questions stop appearing.

France has historically required a separate declaration for cryptographic
products distributed there. Check whether that still applies before relying on
this note.

## What this does not change

Nothing in how Nova works, and nothing a user sees. The binary is identical; only
the declaration about it is now accurate.
