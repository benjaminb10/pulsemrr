<p align="center"><img src="docs/icon.png" width="128" alt="PulseMRR icon"></p>

<h1 align="center">PulseMRR</h1>

<p align="center"><b>A native Mac notification for every Stripe sale.</b><br>
All your Stripe accounts in one menu bar app: sales, subscribers, cancellations, failed payments, today's takings and MRR.<br>
Free, open source, no server. Your keys never leave your Mac.</p>

<p align="center">
  <a href="https://github.com/benjaminb10/pulsemrr/releases/latest"><b>Download for macOS</b></a> ·
  <a href="https://encorescreen.com/support">Support the project ☕</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/panel-dark.png">
    <img src="docs/panel-light.png" width="400" alt="PulseMRR menu bar panel: today's takings, yesterday, 7 days, MRR, a week chart, a table of projects and the latest activity">
  </picture>
</p>

## What it does

- **A notification for what matters**, each one switchable: new sale, new subscriber, trial started, trial converted, cancellation scheduled, subscription ended, failed payment, refund, dispute, payout, new customer. Money coming in plays a cash register sound.
- **Every Stripe account in one place.** Add as many as you run, each with its project's logo (taken from your Stripe branding or your website) or an emoji.
- **Today, yesterday, 7 days and MRR** at a glance, with a bar chart of the week and a table per project.
- **One currency.** Accounts in dollars and euros add up in the currency you pick, at the day's ECB rate. Hover a total to see the original amounts.
- **A daily recap** at the hour you choose: the day's total against yesterday, sales, new subscribers, cancellations, and your best project.
- **Click a notification** to open the payment, subscription or dispute in your Stripe dashboard.
- **English and French**, following your Mac's language.

## Install

1. Download `PulseMRR.dmg` from the [latest release](https://github.com/benjaminb10/pulsemrr/releases/latest) and drag PulseMRR to Applications. It's signed and notarized by Apple.
2. Open it: a `$` icon appears in your menu bar. Allow notifications when macOS asks.
3. Click the icon, then **Add a Stripe account…**, and paste a key.

Needs macOS 13 Ventura or later.

### Which key to use

A **restricted key** with read access is all PulseMRR needs. In Stripe: **Developers › API keys › Create restricted key**, then set **Read** on:

- Events
- Charges
- Customers
- Subscriptions
- Payouts

and leave everything else at None. A secret key (`sk_live_…`) works too, but PulseMRR never needs more than reading.

## Privacy

- **No server.** PulseMRR talks to Stripe's API directly from your Mac, every 30 seconds (you can change it).
- **Read only.** Every call is a `GET`: PulseMRR never creates, changes or deletes anything in Stripe.
- **Keys stay in your Keychain**, never in a file, never sent anywhere but `api.stripe.com`.
- **Other requests:** the day's exchange rates from [frankfurter.app](https://frankfurter.app) (ECB data), and your project's favicon from Google's favicon service when your Stripe account has no icon.

## Build from source

```bash
git clone https://github.com/benjaminb10/pulsemrr
cd pulsemrr
SKIP_NOTARIZE=1 ./build.sh
open build/PulseMRR.app
```

No Xcode project: `build.sh` compiles the Swift sources with `swiftc` into a universal app (Apple Silicon and Intel). It signs with your *Developer ID Application* identity when you have one, ad-hoc otherwise.

`PulseMRR --demo-snapshot out.png` draws the panel with made-up projects, as in the screenshot above.

## Also by me

- [Encore Screen](https://encorescreen.com): turn an old Mac, iPhone, iPad or Android into a wireless extra screen.
- [Encore Mods](https://github.com/benjaminb10/encore-mods): small mods for Claude Code.

## License

[MIT](LICENSE) © Benjamin Benoudis. PulseMRR is not affiliated with Stripe.
