# Age rating answers

App Store Connect → your app → **Age Rating**. Target: **4+**.

Every content question is answered **None** / **No**. The app shows weather data, plays
music the user supplies, and has no other content.

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Profanity or crude humour | None |
| Mature or suggestive themes | None |
| Horror or fear themes | None |
| Medical or treatment information | None |
| Alcohol, tobacco or drug use or references | None |
| Simulated gambling | None |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Contests | None |
| Unrestricted web access | No |
| Gambling and contests | No |
| Age assurance | Not applicable |

## Two that deserve a moment's thought

**Medical or treatment information → None.** The app shows National Weather Service
hazard alerts, which can be life-safety information. That is not "medical or treatment
information" in Apple's sense, and answering otherwise would push the rating up for no
reason. Worth noting that the app does *not* claim to be an alerting system, and
upstream's warning about not relying on it in dangerous weather is a reasonable thing to
keep in mind if a reviewer ever asks.

**Unrestricted web access → No.** The app fetches from fixed API endpoints and, if the
user configures one, a music server they enter themselves. There is no browser, no
arbitrary link following, and no user-to-user content.
