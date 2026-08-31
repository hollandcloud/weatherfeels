# App Store: owned app offers no download on iOS

Report prepared 31 August 2026 for Apple Developer Support / App Store Connect support.

Paste the section between the fences into the support form. Everything after it is the
supporting evidence, worth attaching or quoting if they ask.

---

**App:** weatherfeels
**Apple ID:** 6797599321
**Bundle ID:** net.hlnd.weatherstar
**SKU:** net.hlnd.ws4kp
**Affected version:** 1.1, build 20260830.1, released 2026-08-30 23:05 UTC
**Storefront:** United States (143441) — the app is available in the United States only

**Summary**

On iOS, the product page renders the offer button as a disabled "Purchased" and no
download ever begins. Roughly half the people who have tried to install it are affected;
the rest install normally. All of them are on the United States storefront. The condition
has persisted for more than 16 hours and survives signing out of Media & Purchases,
rebooting, and signing back in. The app is not in Hidden Purchases for the affected
accounts, and it is not installed on the affected devices.

A device log capture shows the App Store never attempts the download at all. It finds the
purchase in the account's history, determines the app is not installed, renders the button
as "Purchased", and stops. No request is made to any commerce endpoint.

**What I have verified is correct**

- App Store Connect reports iOS 1.1 as READY_FOR_SALE with `downloadable: true`.
- Build 20260830.1 is attached to that version, `processingState` VALID, not expired.
- The price schedule is valid: base territory USA, free tier, no start or end date.
- Territory availability is United States, and every affected user is on the US storefront.
- The public catalog is correct and lists the affected hardware explicitly. From
  `https://itunes.apple.com/lookup?id=6797599321&country=us`:
  `version 1.1`, `minimumOsVersion 17.0`, `price 0.0 USD`, `fileSizeBytes 16361472`,
  and `supportedDevices` containing `iPhone17Pro-iPhone17Pro`.
- The reporting device is an iPhone 17 Pro (iPhone18,1) running iOS 27.0, far above the
  app's 17.0 minimum, and is listed by name in `supportedDevices`.

**What I have ruled out**

Device or OS incompatibility; hidden purchases; storage; Screen Time restrictions; stale
App Store client state; territory availability; a conflicting TestFlight build (the app has
one beta tester and no beta build was installed on the device); and an existing or partial
installation.

**What I need**

An explanation of why the entitlement or catalog service returns no downloadable iOS offer
for accounts that already own this app, and a correction to whatever record is responsible.

---

## Evidence

### Capture method

`idevicesyslog` against the device over USB, filtered to `appstored`, `itunesstored`,
`storekitd`, `AppStore`, `installd`, `storedownloadd`, `amsaccountsd` and `akd`. 103,013
lines over roughly one minute, spanning several taps on the "Purchased" button.

### The account owns the app

```
appstored[205] <Notice>: [PurchaseHistoryManager] Purchase History query for
account: 107055079 completed with 1 results from query: <private>
```

Account `hollandkevin@icloud.com`, DSID 107055079, storefront `143441-1,29`, active.

### The app is not installed, and no beta build is present

```
<ASDAppQuery> {isAppClip == 0 AND isStoreApp == 1 AND storeItemID IN {6797599321}}:
  Query complete, returning 0 results
<ASDAppQuery> {isAppClip == 0 AND isBetaApp == 1 AND storeItemID IN {6797599321}}:
  Query complete, returning 0 results
```

Independently confirmed with `xcrun devicectl device info apps`, which lists no bundle
matching `net.hlnd.weatherstar`.

### The button resolves to a terminal "Purchased" state

```
AppStore(JetEngine) <Debug>: string(forKey:with:using:),
  key: OfferButton.Title.Purchased, lookupStrategy: dataSourceThenNative
```

Note this is `OfferButton.Title.Purchased` and not the redownload title. The button is
drawn disabled; nothing happens on tap.

### The purchase parameters are well formed

```
buyParams = "productType=C&price=0&salableAdamId=6797599321
             &pricingParameters=STDQ&pg=default&appExtVrsId=890539237"
```

### No commerce request is ever made

Every host contacted during the capture, with request counts:

| Host | Requests | Purpose |
|---|---|---|
| `xp.apple.com` | 55 | metrics |
| `amp-api-edge.apps.apple.com` | 18 | catalog metadata |
| `amp-account.itunes.apple.com` | 5 | account |

There is no request to `buy.itunes.apple.com` or any other commerce host, no
`storedownloadd` activity, and no install request to `installd` for this bundle. This is
the core of the report: the client is not failing a download, it is declining to ask for
one.

### Catalog request the client made

```
https://amp-api-edge.apps.apple.com/v1/catalog/us/apps/6797599321
  ?platform=iphone&additionalPlatforms=appletv,ipad,mac,realityDevice,watch
```

The response renders a correct product page — name, subtitle, icon, "Version 1.1 · 16h
ago", screenshots, and a compatibility row reading "iPhone, iPad, Mac, Apple TV" — while
the offer resolves to "Purchased" with no download.

## A pattern worth investigating

The split is close to half, and every affected user is on the US storefront, so it is not
territory. The reporter had acquired the macOS build of the same app record several hours
before attempting the iOS install, which means an existing purchase record was present
across the universal purchase. It is worth checking whether the affected accounts are
exactly those that already owned the app — through an earlier version, or on another
platform of the same record — and the unaffected ones are first-time acquisitions. That
would point at the redownload entitlement rather than the listing.
