# App Review notes

Paste the block below into **App Review Information → Notes** for each platform.
Sign-in is not required, so leave the demo account fields empty.

---

No account, sign-in, or purchase is needed. Everything is available on first launch.

LOCATION IS OPTIONAL, AND THE APP DOES NOT ARGUE FOR IT. The second onboarding
screen says what the app needs a location for and offers one button, "Continue",
which opens the system prompt. There is no Skip on that screen and no other way
past it, so the prompt is always reached. Either answer is fine: allow, and the
forecast follows the device; decline, and the same screen becomes a search field
for choosing a US city by name or ZIP code. Nothing in the app is gated on
granting access, and the app never asks again after the first answer.

FORECASTS ARE UNITED STATES ONLY. Weather comes from the US National Weather
Service, which only covers US locations. If you are reviewing from outside the
United States, please pick a US city so the displays have data: open Settings,
choose "Choose a location…", and search for "Tampa" or any US city or ZIP code.
Location permission is optional — a city can always be chosen by hand.

HOW TO REACH SETTINGS

• Apple TV: swipe up on the remote to bring up the controls, then select the gear.
  The first row of Settings is "Close Settings".
• iPhone / iPad: tap anywhere to bring up the controls, then tap the gear. Held
  upright, the picture is drawn on a television and the gear is the first of the
  four buttons on the front of the cabinet, below the screen.
• Mac: Command-comma, or tap for the controls.

NEW IN THIS VERSION: THE TELEVISION. On a screen taller than it is wide, the
picture is drawn on a CRT standing in a dark room rather than stretched up the
screen. On iPhone and iPad that is portrait; on a Mac it is any window taller than
it is wide. The four buttons on the cabinet are, left to right: Settings, previous
display, next display, and a power button that blanks the picture and lights the
lamp beside it. The power button does not quit the app; pressing it again brings
the picture back. The app opens in landscape, where the picture fills the screen as
it did before, and rotates freely from there.

MUSIC IS OPTIONAL AND OFF BY DEFAULT. The Apple Music source plays a playlist
from the reviewer's own library and needs an active Apple Music subscription; if
there is none, the app simply plays nothing and the weather is unaffected. The
other two sources are files on the device and a folder on a server the user
hosts themselves. No music is bundled or streamed by us.

WHAT THE APP DOES WITH LOCATION. Coordinates are sent to api.weather.gov to
fetch the forecast grid for that point, and to the Iowa Environmental Mesonet to
fetch the radar tile for that region. Nothing is stored on a server of ours — we
do not operate one — and nothing is used for advertising or analytics.

ATTRIBUTION. This is an independent tribute to the local forecast units that
cable systems ran in the 1990s. It is not affiliated with, endorsed by, or
connected to The Weather Channel or NOAA, and says so on the About screen and in
the App Store description. Weather data and convective outlooks are US
Government public domain works. The layout was ported from the open-source
project netbymatt/ws4kp (MIT licence).

---

## Fields to set alongside the notes

| Field | Value |
|---|---|
| Sign-in required | No |
| Demo account | not applicable |
| Contact first / last name | Kevin Holland |
| Contact phone | 844-247-4274 |
| Contact email | hollandkevin@icloud.com |
| Notes | the block above |
| Attachment | none needed |
| Age rating | 4+ — see `age-rating.md` |

## Historical: the reply sent for the 1.0 rejection

Kept as a record, not as a task. Submission 736a60ac-8426-4a48-bd6a-6420b1f2c161,
guideline 5.1.1(iv), was answered with the text below and 1.0 went on sale. The
reviewer notes above no longer mention that rejection: pointing a reviewer of a
later version at a resolved complaint against a shipped one invites a second look
at something already settled. The substance — that location is optional and the
prompt is never deferred — is still in the notes on its own merits.

---

Thank you — both points are fixed in this build.

The onboarding screen that precedes the location prompt now has a single button
labelled "Continue", and it always opens the system permission request. The button
that previously read "Use this device's location" is gone, as is the "Skip" button
that allowed the request to be deferred; there is no longer any way past that screen
other than the prompt itself.

Either answer is fully supported. If access is granted, the forecast follows the
device. If it is declined, the same screen becomes a search field for choosing a US
city by name or ZIP code, and every feature of the app works exactly as it does with
access granted. Nothing is gated on granting permission, and the app does not ask
again after the first answer.

For completeness, the phrase "Use this device's location" has also been removed from
the Settings picker, which now reads "This device" and "A place I choose".
