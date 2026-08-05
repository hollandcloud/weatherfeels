# App Privacy answers

App Store Connect → your app → **App Privacy**. These answers apply to all four
platforms; the questionnaire is per-app, not per-platform.

## Data collection

**Do you or your third-party partners collect data from this app? → Yes**

Answering "No" would be wrong, even though we run no server. Apple counts data as
collected when it is transmitted off the device, and the whole app works by sending a
coordinate to weather.gov. One disclosure covers it.

### Location → Coarse Location

Precise Location is *not* collected: the app rounds to the NWS forecast grid, and a
city chosen by hand is stored as the city's own coordinates.

| Question | Answer |
|---|---|
| Used for | App Functionality |
| Linked to the user's identity | No |
| Used for tracking | No |

Nothing else is collected. Specifically **not**: contact info, identifiers,
usage data, diagnostics, purchases, search history, or any media. There are no
analytics, crash-reporting, advertising or attribution SDKs in the app at all —
worth stating plainly because reviewers see very few apps that can say it.

## Music library

Reading the user's Apple Music library is **not** data collection: track titles stay
on the device and are never transmitted. Nothing to declare, but the usage string
already tells the user, and the review notes repeat it.

## Tracking

**Does this app track users? → No.** No ATT prompt, no IDFA, no
`NSUserTrackingUsageDescription`, no third-party analytics.

## Privacy policy URL

Required for every app. A policy is drafted in `Store/privacy-policy.md` — it needs
publishing at a stable HTTPS URL before submission. **Needed from you.**

## Export compliance

`ITSAppUsesNonExemptEncryption = false` is already in each Info.plist, so the
upload will not stop to ask. The claim is accurate: the app uses HTTPS via the
system's own networking and ships no cryptography of its own.

## Content rights

App Store Connect asks whether the app contains, shows, or accesses third-party
content. **Answer Yes**, and be ready to say what it is:

- Forecast, alert and outlook data from NOAA / the National Weather Service — US
  Government works, public domain.
- Radar composites from the Iowa Environmental Mesonet (Iowa State University),
  used per their public access terms.
- Layout, fonts, weather icons and background artwork ported from
  `netbymatt/ws4kp` by Matt Walsh, MIT licence.

See the naming and artwork note in `Store/README.md` before you answer this one.
