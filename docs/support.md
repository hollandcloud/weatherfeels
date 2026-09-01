# Support

Thanks for using the app. This page is the support contact for the App Store listing.

## Getting help or reporting a bug

Open an issue: **https://github.com/hollandcloud/weatherfeels/issues**

It helps to include:

- Which device and OS version (Apple TV 4K, iPhone 15, macOS 26, and so on)
- Which display was on screen — Current Conditions, Radar, Hourly, and so on
- The city you had selected
- What you expected instead

## Things that are expected behaviour

**Forecasts are United States only.** The data comes from the US National Weather
Service, which does not cover other countries. Outside the US the displays have nothing
to show. There is no workaround; it is a limit of the data source, not a bug.

**A display can be skipped.** If your location has no data for something — no travel
cities nearby, no active hazards, no convective outlook today — that display is left out
of the rotation rather than shown empty.

**The CRT tube option is missing on some devices.** It needs a GPU that can run a Metal
shader through SwiftUI: roughly an A13 or M1 and later. On older hardware the option is
withheld rather than offered, because there it renders a black screen. An Apple TV HD
(the 2015 model) is affected; an Apple TV 4K is not. The Animated and Static scanline
modes work everywhere.

**Apple Music needs a subscription.** The Apple Music source plays a playlist from your
own library and requires an active subscription. Without one, choose the on-device files
or a music server instead.

**"Recent" instead of "Current" in the header.** The nearest reporting station has not
sent a new observation for over an hour. It usually resolves itself.

## Known limits

- An Apple TV HD (2015, A8) can run the app but is slow on the denser displays. The Apple
  TV 4K is the target.
- Radar is a regional composite from the Iowa Environmental Mesonet, not a national mosaic.
- Music from a server you host expects plain HTTP file listing; see the README.

## Privacy

See [the privacy policy](privacy.md). Short version: no accounts, no analytics, no
tracking, and the only thing that leaves your device is the coordinate needed to fetch
your forecast.

## Source

The app is open source under the MIT licence at
**https://github.com/hollandcloud/weatherfeels**.

It is an independent tribute to the local forecast units of the 1990s, and is not
affiliated with, endorsed by, or connected to The Weather Channel or NOAA.
