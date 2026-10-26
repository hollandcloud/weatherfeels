# weatherfeels companion server

One small, self-hosted server for the weatherfeels WeatherStar app. It holds:

- **music** the app plays behind the forecast;
- **ticker ads**, lines that crawl along the bottom of the screen;
- **local ad cards**, full-screen "local business" ads in WeatherStar style;
- a **clip reel** of short videos played as an ad break.

You manage all of it from a web page at `/admin`, on a phone or a desktop. The ads
are a nostalgic extra and are off by default in the app.

It is plain Node (20 or newer) with **no dependencies**: nothing to `npm install`,
so it runs as-is on a NAS, a Raspberry Pi or a small VPS.

- [Quick start](#quick-start): Docker, plain Node, systemd
- [Point the app at it](#point-the-app-at-it)
- [Configuration](#configuration)
- [Endpoints](#endpoints)
- [The ads manifest](#the-ads-manifest-schema-v1)
- [Static hosting](#static-hosting)
- [Security](#security)
- [Development](#development)

---

## Quick start

Whichever way you run it, set `WS4K_TOKEN` to a long random secret. **Without a
token the admin page and API are switched off entirely.** To make one:

```bash
openssl rand -hex 32
```

### Docker Compose

```bash
cd server
echo "WS4K_TOKEN=$(openssl rand -hex 32)" > .env    # keep this file private
docker compose up -d
```

Open `http://<host>:8080/admin` and sign in with the token from `.env`. Music and
ads live in the named volumes `weatherfeels-companion_music` and
`weatherfeels-companion_ads`. To use host folders instead (handy on a NAS), see
the comments in [`docker-compose.yml`](docker-compose.yml).

### Docker

```bash
cd server
docker build -t weatherfeels-companion .
docker run -d --name weatherfeels-companion --restart unless-stopped \
  -p 8080:8080 \
  -e WS4K_TOKEN="your-long-random-token" \
  -v ws4k-music:/data/music -v ws4k-ads:/data/ads \
  weatherfeels-companion
```

The image is `node:22-alpine`, runs as the unprivileged `node` user (uid 1000),
and has a health check on `/health`. If you bind-mount host folders, make them
writable by uid 1000: `chown -R 1000:1000 /path/to/folder`.

### Plain Node

```bash
cd server
WS4K_TOKEN="your-long-random-token" node server.mjs
# or: WS4K_TOKEN=… npm start
```

With no other settings it listens on port 8080 and keeps music in `server/music/`
and ads in `server/ads/`.

### systemd

[`weatherfeels-companion.service`](weatherfeels-companion.service) is a hardened
unit that runs the server as a throwaway user and keeps its files in
`/var/lib/weatherfeels-companion`:

```bash
sudo cp -r server /opt/weatherfeels-companion
sudo cp /opt/weatherfeels-companion/weatherfeels-companion.service /etc/systemd/system/
sudo install -m 600 /dev/null /etc/weatherfeels-companion.env
echo "WS4K_TOKEN=$(openssl rand -hex 32)" | sudo tee /etc/weatherfeels-companion.env >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now weatherfeels-companion
journalctl -u weatherfeels-companion -f
```

The token lives in `/etc/weatherfeels-companion.env`, readable only by root, so it
never appears in the unit file or in `systemctl show`.

---

## Point the app at it

In the app, open **Settings → Companion server** and enter the server's base URL,
for example `http://nas.local:8080` — the address only, with no path. The app
finds `/playlist.json`, `/ads.json` and the files from there.

Builds that predate the ads feature call this setting **Music server**, under
Settings → Music. If uploads from the app should work, put the same token in its
**Access token** field.

The app never needs the token to *read*: music, ads and clips are public to
anything that can reach the server. The token only guards changes.

---

## Configuration

Everything is set with environment variables, and everything has a default.

| Variable | Default | Purpose |
|---|---|---|
| `WS4K_PORT` | `8080` | Port to listen on, on all interfaces. |
| `WS4K_MUSIC_DIR` | `<server dir>/music` | Where tracks are kept. Subfolders are listed too. |
| `WS4K_ADS_DIR` | `<server dir>/ads` | Where `ads.json`, `images/` and `clips/` are kept. Created if missing. |
| `WS4K_TOKEN` | *(unset)* | Bearer token for admin and uploads. **Unset means admin is off.** |
| `WS4K_MAX_UPLOAD_MB` | `500` | Largest upload accepted, in megabytes, for every upload route. |
| `WS4K_MAX_UPLOAD` | *(unset)* | Older byte-count form of the limit, still honoured when `WS4K_MAX_UPLOAD_MB` is not set. |

JSON bodies (the ads manifest) are always capped at 1 MB.

---

## Endpoints

### Public — no token

| Endpoint | Returns |
|---|---|
| `GET /playlist.json` | `{ "availableFiles": [...] }`, the same shape ws4kp serves, paths relative to `/music/` |
| `GET /music/<file>` | A track, with range requests for seeking |
| `GET /ads.json` | The public ads manifest: **enabled items only**, without the `enabled` flag |
| `GET /ads/images/<file>` | An ad card image: `.png`, `.jpg`/`.jpeg`, `.gif`, `.webp` |
| `GET /ads/clips/<file>` | A clip: `.mp4`, `.m4v`, `.mov`, with range requests (AVPlayer needs them) |
| `GET /health` | `{ ok, tracks, ticker, cards, clips }`; the ad counts are of enabled items |

These send `Access-Control-Allow-Origin: *`, as ws4kp does. Media routes also
answer `HEAD`.

### Uploads from the app — token when one is set

These are the original endpoints and behave exactly as before, including being
**open when no token is configured**, which existing installs rely on.

| Endpoint | Purpose |
|---|---|
| `POST /upload` | `multipart/form-data`: `file`, plus an optional `path` folder |
| `PUT /music/<path>` | Raw-body upload, for WebDAV-style clients |

### Admin — always needs the token

Send `Authorization: Bearer <token>`. Without a configured token every admin
route answers `403` with `{"error": "...", "code": "admin-disabled"}`; with one, a
missing or wrong token gets `401`. Errors are JSON: `{ "error": "message" }`.

| Endpoint | Purpose |
|---|---|
| `GET /admin` | The web admin page |
| `GET /api/music` | `{ tracks: [{ name, size, modified }], maxUploadBytes }` |
| `PUT /api/music/<file>` | Upload a track (raw streamed body) to the top of the music folder |
| `DELETE /api/music/<path>` | Delete a track; `<path>` must be one `/playlist.json` lists |
| `GET /api/ads` | The full stored manifest, disabled items included, `enabled` explicit |
| `PUT /api/ads` | Replace the manifest (see validation below); returns the saved manifest |
| `GET /api/ads/files` | `{ images: [...], clips: [...], maxUploadBytes }`, each `{ name, path, size, modified }` |
| `PUT /api/ads/images/<file>` | Upload an image (raw streamed body) |
| `PUT /api/ads/clips/<file>` | Upload a clip (raw streamed body) |
| `DELETE /api/ads/images/<file>`, `DELETE /api/ads/clips/<file>` | Delete a file |

Uploads are streamed straight to disk, never held in memory, so a large clip is
fine on a Pi. Each lands in a hidden temporary file and is renamed into place only
when complete, so a failed upload never leaves half a file or damages the one it
was replacing. Clients that send `Expect: 100-continue` (curl does for large
files) are refused *before* sending the body when the token is wrong or the file
too big.

For example, with curl:

```bash
TOKEN=your-long-random-token
curl -T reel.mp4 -H "Authorization: Bearer $TOKEN" http://nas.local:8080/api/ads/clips/v-reel.mp4
curl -H "Authorization: Bearer $TOKEN" http://nas.local:8080/api/ads
```

---

## The ads manifest (schema v1)

The app decodes `/ads.json` directly, so this shape is a contract.

```json
{
  "version": 1,
  "updated": "2026-10-26T15:00:00Z",
  "ticker": [ { "id": "t-abc", "text": "VISIT GULF COAST MARINE  555-0142" } ],
  "cards": [ {
    "id": "c-abc",
    "business": "Gulf Coast Marine",
    "headline": "Boat Repair & Detailing",
    "lines": ["Outboards serviced", "Free estimates"],
    "phone": "555-0142",
    "footer": "Open 7 days",
    "image": "ads/images/c-abc.png",
    "imageMode": "beside",
    "theme": "blue",
    "seconds": 10
  } ],
  "clips": [ { "id": "v-abc", "title": "Classic spot", "file": "ads/clips/v-abc.mp4" } ]
}
```

| Field | Required | Rules |
|---|---|---|
| `version` | — | Always `1`. |
| `updated` | — | ISO-8601 time of the last save. The server sets it. |
| *every item* `id` | **yes** | Up to 64 of `A–Z a–z 0–9 . _ -`; unique across the whole manifest. |
| ticker `text` | **yes** | Up to 120 characters. |
| card `business` | **yes** | Up to 40 characters. |
| card `headline` | — | Up to 60 characters. |
| card `lines` | — | Up to 4 strings of up to 48 characters each. |
| card `phone` | — | Up to 24 characters. |
| card `footer` | — | Up to 48 characters. |
| card `image` | — | `ads/images/<file>`, an image name as below. |
| card `imageMode` | — | `beside` or `full`. The app treats absent as `beside`. |
| card `theme` | — | `blue`, `red`, `green`, `gold` or `purple`. Absent means `blue`. |
| card `seconds` | — | Whole number from 4 to 30. Absent means 10. |
| clip `file` | **yes** | `ads/clips/<file>`, a clip name as below. |
| clip `title` | — | Up to 80 characters. |

`image` and `file` are paths relative to the server root, so the app resolves them
against the same base URL it fetched `/ads.json` from. Characters are counted as
Unicode code points, so `☀` is one. No text may contain line breaks or other
control characters. The server never fills in defaults: an absent optional field
stays absent, and the app applies the defaults above.

### Stored and public forms

On disk the manifest is `ads.json` in `WS4K_ADS_DIR`. It is the same shape, plus
`"enabled": true|false` on every item. `GET /ads.json` serves only enabled items
and removes the flag. A hand-written manifest without any `enabled` flags counts
every item as enabled.

If a hand-edited file has a bad item, that item is left out of `/ads.json` (with a
warning in the log) and the rest are served. If the file is not valid JSON at all,
`/ads.json` serves an empty manifest and the admin page reports the problem.

### Validation

`PUT /api/ads` checks every rule above, rejects unknown fields, and saves nothing
unless the whole manifest is valid. Leading and trailing spaces are trimmed, and
empty optional fields and blank `lines` entries are dropped. A rejection is a
`400` listing every problem:

```json
{
  "error": "The manifest is not valid",
  "fields": [
    { "field": "cards[0].business", "message": "is required" },
    { "field": "ticker[2].text", "message": "must be at most 120 characters" }
  ]
}
```

A valid manifest is written atomically (temporary file, `fsync`, rename), so the
app never reads a half-written one.

---

## Static hosting

The app reads the manifest and files identically from any web server, so you can
publish ads without running this server at all — on GitHub Pages, S3, Netlify, a
NAS's built-in web server, anything that serves files:

```
<site root>/
  ads.json            ← the public manifest
  ads/
    images/c-abc.png
    clips/v-abc.mp4
```

Point the app at `https://<site root>` as usual. The easiest way to build that
folder is from a running companion server:

```bash
mkdir -p site/ads
curl -o site/ads.json http://nas.local:8080/ads.json     # enabled items only
cp -r "$WS4K_ADS_DIR/images" "$WS4K_ADS_DIR/clips" site/ads/
```

Or write `ads.json` by hand following the schema; leave out `enabled` and every
item is shown. Two things to check on a static host: it must serve `.mp4`, `.m4v`
and `.mov` with range requests (almost all do), and with a sensible video content
type. Music works the same way: a `music/` folder with a `playlist.json` beside
it, in the shape above.

---

## Security

The server is designed to be safe to expose, but treat it like any small web app.

- **Use HTTPS if it is reachable from the internet.** The token travels in a
  header and would be readable on plain HTTP. Put the server behind a reverse proxy
  that terminates TLS. With [Caddy](https://caddyserver.com) that is two lines:

  ```
  ws4k.example.com {
      reverse_proxy 127.0.0.1:8080
  }
  ```

  For large clip uploads through nginx, raise `client_max_body_size`.
- **Keep the token secret, and make it long.** Anyone with it can change what every
  app pointed at this server shows. Use `openssl rand -hex 32`; the server warns at
  start-up if the token is short. Change it by restarting with a new value. It is
  never logged.
- **No token, no admin.** Admin is switched off unless `WS4K_TOKEN` is set; it is
  never open. The token is compared in constant time.
- **Mind the original upload routes.** For compatibility, `POST /upload` and
  `PUT /music/…` stay open when no token is set, as they always have. If the server
  is reachable by anyone you do not trust, set a token.
- **Everything readable is public.** Music, ads, clips and `/health` need no token.
  Do not put anything private in these folders. `/health` used to include the music
  folder's path on the host; v2 leaves it out, since nothing reads it and it tells a
  stranger where the files live.
- **File names are checked, not cleaned up.** Every admin route accepts only a bare
  name of `A–Z a–z 0–9 . _ - space` with the right extension for its folder, and
  refuses `..`, separators, absolute paths and hidden files with a `400`. Paths are
  resolved and checked to stay inside their folder. The admin page tidies names
  before uploading, so this rarely shows.
- **The admin page renders text only as text,** never as HTML, and is served with a
  strict `Content-Security-Policy` that allows only its own inline script and
  style, pinned by hash, plus `X-Frame-Options: DENY`. The token is kept in
  `sessionStorage`, so it is forgotten when the tab closes.
- **No CORS on the admin API.** Other websites cannot call it from a visitor's
  browser.
- **Bodies are capped** by `WS4K_MAX_UPLOAD_MB`, and JSON at 1 MB, whether or not
  the client declares a length.

---

## Development

```bash
cd server
npm test        # node --test test/*.test.mjs
```

The tests start real servers on ephemeral ports against temporary folders and
need nothing installed. Layout:

| Path | What |
|---|---|
| `server.mjs` | Entry point: reads the environment and listens |
| `lib/app.mjs` | Routing, authentication, the ads and admin endpoints |
| `lib/music.mjs` | The original music endpoints |
| `lib/manifest.mjs` | Schema v1, validation, the public projection |
| `lib/http.mjs` | Responses, streamed uploads, ranges, body limits |
| `lib/names.mjs` | File-name rules and types per folder |
| `lib/config.mjs` | Environment variables |
| `admin/admin.html` | The admin page: one file, inline CSS and JS, no frameworks |
| `test/` | `node --test` suites |
