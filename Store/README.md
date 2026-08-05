# App Store submission

Everything needed to fill in the listing, plus a script to push it. Read
**Before you submit** first — there are two things in there that are decisions, not tasks.

```
Store/
  README.md                     this file
  metadata/
    en-US/                      one file per App Store Connect field
      name.txt                  30 char limit   — 11 used
      subtitle.txt              30              — 28
      promotional_text.txt      170             — 149
      keywords.txt              100             — 77
      description.txt           4000            — 3061
      release_notes.txt         4000            — "First public release."
      support_url.txt           docs/support.md in this repo
      privacy_policy_url.txt    docs/privacy.md in this repo
      marketing_url.txt         the repo itself
    review-notes.md             paste into App Review Information
    app-privacy.md              the App Privacy questionnaire answers
    age-rating.md               the age-rating questionnaire answers
  screenshots/
    tvos/     3840x2160         Apple TV
    iphone/   2868x1320         6.9", landscape — the app locks landscape on a phone
    ipad/     2064x2752         13", portrait — the app has a real portrait layout on iPad
    mac/      2880x1800         window at 1440x810 (16:9), padded to a size Apple accepts

docs/
  privacy.md                    the published privacy policy
  support.md                    the published support page
```

## Before you submit

**1. The artwork still carries the mark.** The name is settled — "ws4kp nostalgia" — but
the app icon *is* the WEATHER STAR 4000+ badge, and so is the corner logo on every
display, which means it is in all 23 screenshots. An icon reading WEATHER STAR 4000+
under a name chosen to avoid it defeats the point of the rename, and the icon is the most
visible surface there is: search results, product page, and the device itself.

**Decided: the badge stays as it is.** Kevin's call, made with the trade-off in front of
him. So the position going into review is a name that avoids the mark, a description that
never uses it except to disclaim, and artwork that still shows it. If that draws a
5.2.1 rejection or a complaint later, the badge is the thing to change, and it is not
much work: `Tools/MakeIcons.swift` draws it from three lines of text, the corner logo
already has the `WS4KLogoImageName` hook, and the screenshot harness can re-shoot the set
in about twenty minutes. A generated `WS4KP / NOSTALGIA` alternative has been rendered and
checked once already, so that route is proven if it is ever wanted.

Being free and open source helps the underlying position considerably: it puts this in
the same posture as `ws4kp` itself, whose defence is that it is "a free, non-profit work
by fans". That was the one thing a paid listing could not claim.

**Why the rename was recommended.** What the research found:

- **No USPTO registration for "WeatherStar" in TWC's name turned up.** The only live
  `WEATHER STAR` registration found belongs to Larson Manufacturing, for doors and
  windows — an unrelated class, so no help either way. Absence of a registration is
  *not* absence of rights: US trademark rights arise from use, and TWC has used
  WeatherSTAR as a product name since the 1980s. Upstream `ws4kp` states it plainly:
  "The WeatherSTAR 4000 unit and technology is owned by The Weather Channel."
- **`ws4kp`'s defence does not transfer.** It describes itself as "a free, non-profit
  work by fans". A paid app in a commercial storefront has none of that posture, which
  is the part that makes a fan tribute tolerable.
- **A directly comparable app is already live and shipping.** `RetroWeather TV` by Dave
  Davis is on the App Store for iPhone, iPad and Apple TV, in the Weather category,
  monetised — and does the same 1990s cable-weather aesthetic. It got there by:
  - using a name with no trademark in it;
  - describing the look in period language rather than brand names — "beveled-box
    aesthetic", "scrolling tickers", "smooth jazz", "faithful to the '90s broadcast
    look" — with its subtitle "90s Weather & Smooth Jazz";
  - carrying an explicit line: "RetroWeather is an independent app and is not affiliated
    with any broadcast network, weather service trademark, or media company."

That is a tested-in-review template, and this listing already follows most of it: the
description never names TWC except to disclaim, and it closes with a non-affiliation
sentence. The name and the corner logo are the parts still carrying the mark.

What changes on a rename, all of it mechanical:

| Where | Now |
|---|---|
| `Store/metadata/en-US/name.txt` | WeatherStar |
| `description.txt` | opens "WeatherStar puts a continuous…" |
| `CFBundleDisplayName` in all three `Apps/*/Info.plist` | WeatherStar |
| The corner logo artwork | "WEATHER STAR 4000+" — already swappable at build time via `WS4KLogoImageName`, see `project.yml` |
| App Store Connect app name | needs changing in the browser |

The repo itself can stay as it is. A public, MIT, disclaimed fan port is the same
posture `ws4kp` has held for years; it is the paid storefront listing that changes the
calculus.

**Assets, separately from the name.** These came out better than expected. The bundled
music is AI-generated by `ws4kp`'s author specifically to be, in his words,
"unencumbered by copyright" — so there is no rights holder to clear. The fonts and
weather icons are fan re-creations by Nick Smith, Charles Abel and Malek Masoud, not
TWC's own files, and `ws4kp` states its background graphics were drawn from scratch.
Worth knowing when answering the content-rights question: nothing in the bundle is a
copy of a TWC file. The fonts' own licence terms are not formally stated anywhere,
which is the one loose end.

**2. "Open source" on the About screen.** The About section says "Open source, no
accounts, and no analytics or tracking of any kind." The repo is private, so the first
two words are not currently true. Either publish the source or drop those words — the
rest of the sentence is accurate and worth keeping.

## What still needs you

| Thing | Why it is not done |
|---|---|
| `ASC_ISSUER_ID` | Not on this machine. Users and Access → Integrations → App Store Connect API. Two keys are already in `~/.appstoreconnect/private_keys/` (`LFCSNDNP56`, `RJ5D99L9C9`) — say which one, or make a fresh App Manager key. |
| tvOS and macOS platforms | The app record only has iOS. They must be added in App Store Connect by hand (App Store tab → **+** beside "iOS App"); there is no API for it. Until then those uploads are rejected with "no suitable application records were found". |
| Review contact phone | **Still outstanding.** App Store Connect will not take a blank phone number in App Review Information — it is a required field rather than one that can be skipped. A free Google Voice number does the job, or use a company line. It is only ever used if a reviewer needs to reach you. |

Settled since the first draft:

- **Free, no in-app purchases, no subscription.** The description says so, and it matters
  for more than the pricing page — see the name section above.
- **Name** — "ws4kp nostalgia". Applied to `name.txt`, the description, and
  `CFBundleDisplayName` on all three platforms; the startup screen now reads "ws4kp /
  nostalgia" via `WS4KStartupTitle`. The two usage strings no longer name the app at all,
  since they read fine as "This app uses your location…".
- **Contact** — hollandkevin@icloud.com, phone 844-247-4274.
- **Age rating** — everything answered "None", which produces 4+. Recorded in
  `metadata/age-rating.md`; the questionnaire itself still has to be clicked through in
  the browser, there is no API for it.
- **Support and privacy URLs** — both now point into this repo, at `docs/support.md`
  and `docs/privacy.md`. That is why the repo has to be public: Apple checks that both
  URLs load for an anonymous visitor.

## Pushing it

```sh
export ASC_KEY_ID=RJ5D99L9C9          # or the other one
export ASC_ISSUER_ID=<uuid>

Tools/asc.py status                    # read-only. run this first.
Tools/asc.py text                      # name, subtitle, description, keywords, URLs
Tools/asc.py screenshots               # replaces each set rather than appending
```

`status` is not just a sanity check — it is how two unknowns get resolved. It prints
which platforms exist on the record, and it prints the `screenshotDisplayType` ASC
reports for any set that already exists. Two of the four constants in `Tools/asc.py`
(`APP_IPHONE_67` for the 6.9" slot, `APP_IPAD_PRO_3GEN_129` for the 13" slot) are
educated guesses — Apple has renamed these before. Check them against `status` before
running `screenshots`, and correct `DISPLAY_TYPES` if they disagree.

Builds still go up through `Tools/archive.sh`; this script only handles the listing.

## How the screenshots were made

`Tools/shoot.sh` equivalents live in the session scratchpad rather than the repo, but the
method is worth recording:

- One display is enabled at a time in the app's preferences and the app relaunched, so
  each shot is of a known display rather than whatever the rotation happened to be on.
- Preferences are written with `simctl spawn <dev> defaults`, not by editing the plist.
  Editing the file looks like it works and does not: `cfprefsd` holds the app's
  preferences cached and flushes its copy back over the edit.
- Three frames per display, four seconds apart. Several displays scroll, and a frame
  caught mid-scroll has the column header sitting on the first row.
- iOS and iPadOS shots are captured portrait and rotated 90° in `sips`. The app locks
  landscape, so a portrait simulator renders it sideways; a 90° rotation is lossless and
  lands exactly on the App Store pixel sizes.
- Tampa, Florida, chosen for the location: coastal radar has something on it, and the
  city name is short enough not to truncate in the ticker.

The images are raw device captures, no frames or captions. That is allowed, and honest.
If you want captioned marketing frames later, these are the source material.
