# App Store submission

Everything needed to fill in the listing, plus a script to push it. Read
**Before you submit** first — there are two things in there that are decisions, not tasks.

```
Store/
  README.md                     this file
  privacy-policy.md             a policy to publish; the URL is required
  metadata/
    en-US/                      one file per App Store Connect field
      name.txt                  30 char limit   — 11 used
      subtitle.txt              30              — 28
      promotional_text.txt      170             — 149
      keywords.txt              100             — 77
      description.txt           4000            — 3061
      release_notes.txt         4000            — "First public release."
      support_url.txt           REQUIRED, empty — needs a real page
      marketing_url.txt         optional, empty
      privacy_policy_url.txt    REQUIRED, empty — publish privacy-policy.md first
    review-notes.md             paste into App Review Information
    app-privacy.md              the App Privacy questionnaire answers
  screenshots/
    tvos/     3840x2160         Apple TV
    iphone/   2868x1320         6.9" landscape
    ipad/     2752x2064         13" landscape
    mac/      2880x1800
```

## Before you submit

**1. The name.** "WeatherStar" is The Weather Channel's trademark for the hardware this
recreates, and the app reproduces its on-screen look closely. The name got through
reservation — that is an availability check, not a rights check — so review under
guideline 5.2.1, or a later trademark complaint, is a live risk rather than a
hypothetical one. The bundled fonts and weather icons came from `netbymatt/ws4kp` under
MIT, but that licence covers Matt Walsh's work, not the underlying design they derive
from. Options, roughly in order of safety:

- Rename to something evocative but not theirs, and describe it as "inspired by 1990s
  cable weather units". Costs the search term.
- Keep the name and submit as-is. It may well sail through; the downside is a rejection
  or a takedown after launch rather than a wasted afternoon.
- Ask TWC. Slow, and a "no" is worse than not having asked.

Everything in this directory works either way — only `name.txt`, the app's
`CFBundleDisplayName`, and the "WEATHER STAR 4000+" corner logo would change. The logo
is already swappable at build time via `WS4KLogoImageName` (see `project.yml`).

**2. "Open source" on the About screen.** The About section says "Open source, no
accounts, and no analytics or tracking of any kind." The repo is private, so the first
two words are not currently true. Either publish the source or drop those words — the
rest of the sentence is accurate and worth keeping.

## What still needs you

| Thing | Why it is not done |
|---|---|
| `ASC_ISSUER_ID` | Not on this machine. Users and Access → Integrations → App Store Connect API. Two keys are already in `~/.appstoreconnect/private_keys/` (`LFCSNDNP56`, `RJ5D99L9C9`) — say which one, or make a fresh App Manager key. |
| `support_url.txt` | Required by App Store Connect. Any stable page that can take a bug report. |
| `privacy_policy_url.txt` | Required. Publish `privacy-policy.md` somewhere stable and put the URL here. |
| tvOS and macOS platforms | The app record only has iOS. They must be added in App Store Connect by hand (App Store tab → **+** beside "iOS App"); there is no API for it. Until then those uploads are rejected with "no suitable application records were found". |
| Review contact phone | Apple requires a number in App Review Information. |
| Age rating questionnaire | Answer everything "None"; the app comes out 4+. Two minutes in the browser, and there is no sensible way to script it. |

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
