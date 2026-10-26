#!/usr/bin/env node
// Companion server for WeatherStar.
//
// Serves your own music, plus the optional nostalgic extras — ticker ads, local ad
// cards and a clip reel — to the iOS/iPadOS/tvOS/macOS apps, and gives you a web
// page at /admin to manage all of it. An Apple TV has no file picker, so this is
// how it gets anything that is yours.
//
// Deliberately dependency-free: it runs on plain Node (20 or newer) with no install
// step, which makes it easy to drop onto a NAS, a Raspberry Pi or a small VPS.
//
//   node server.mjs
//   WS4K_PORT=8080 WS4K_MUSIC_DIR=./music WS4K_ADS_DIR=./ads WS4K_TOKEN=secret node server.mjs
//
// Public endpoints:
//   GET  /playlist.json      { "availableFiles": [...] }  — same shape as ws4kp
//   GET  /music/<file>       streams a track, with range support for seeking
//   GET  /ads.json           enabled ads only, manifest schema v1
//   GET  /ads/images/<file>  ad card images
//   GET  /ads/clips/<file>   clip reel videos, with range support
//   GET  /health             { ok, tracks, ticker, cards, clips, musicDir }
//
// Uploads (bearer token when WS4K_TOKEN is set, open otherwise, as before):
//   POST /upload             multipart/form-data: `file`, optional `path`
//   PUT  /music/<file>       raw body upload, for WebDAV-style clients
//
// Admin (always requires WS4K_TOKEN; switched off entirely without it):
//   GET  /admin              the web UI
//   /api/music, /api/ads, /api/ads/files, /api/ads/images/<file>, /api/ads/clips/<file>
//
// See README.md beside this file for the details.

import { createCompanionServer } from './lib/app.mjs';
import { configFromEnv } from './lib/config.mjs';

const config = configFromEnv();
const server = createCompanionServer(config);
await server.prepare();

server.listen(config.port, () => {
	const { port } = server.address();
	console.log(`WeatherStar companion server listening on http://0.0.0.0:${port}`);
	console.log(`Serving music from ${config.musicDir}`);
	console.log(`Serving ads from ${config.adsDir}`);
	console.log(`Uploads are capped at ${Math.round(config.maxUploadBytes / (1024 * 1024))} MB.`);
	if (config.token) {
		console.log('Uploads require a bearer token.');
		console.log(`Admin page: http://<this host>:${port}/admin`);
		if (config.token.length < 16) {
			console.warn('WS4K_TOKEN is short. Use a long random value, e.g. `openssl rand -hex 32`.');
		}
	} else {
		console.log('Uploads are open (set WS4K_TOKEN to require one).');
		console.log('Admin is disabled until WS4K_TOKEN is set.');
	}
});

const shutdown = () => {
	server.close(() => process.exit(0));
	server.closeAllConnections();
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
