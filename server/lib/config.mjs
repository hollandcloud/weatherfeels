// Configuration, read once from the environment.
//
// Everything has a default, so `node server.mjs` with no variables set serves the
// `music/` and `ads/` folders beside it on port 8080, with admin switched off.

import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** The `server/` directory, which holds the default music and ads folders. */
export const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const MiB = 1024 * 1024;

/** JSON bodies (the ads manifest) are small; anything bigger is a mistake or abuse. */
export const MAX_JSON_BYTES = 1 * MiB;

const DEFAULT_MAX_UPLOAD_MB = 500;

const positiveNumber = (name, raw) => {
	const value = Number(raw);
	if (!Number.isFinite(value) || value <= 0) {
		throw new Error(`${name} must be a positive number, got "${raw}"`);
	}
	return value;
};

/**
 * Build a config object from environment variables.
 *
 * `WS4K_MAX_UPLOAD` (bytes) predates `WS4K_MAX_UPLOAD_MB` and is still honoured when
 * it is the only one set, so an existing install keeps the limit it chose.
 */
export const configFromEnv = (env = process.env) => {
	const rawPort = env.WS4K_PORT;
	const port = rawPort === undefined || rawPort === '' ? 8080 : Number(rawPort);
	if (!Number.isInteger(port) || port < 0 || port > 65535) {
		throw new Error(`WS4K_PORT must be a port number, got "${rawPort}"`);
	}

	let maxUploadBytes = DEFAULT_MAX_UPLOAD_MB * MiB;
	if (env.WS4K_MAX_UPLOAD_MB) {
		maxUploadBytes = Math.floor(positiveNumber('WS4K_MAX_UPLOAD_MB', env.WS4K_MAX_UPLOAD_MB) * MiB);
	} else if (env.WS4K_MAX_UPLOAD) {
		maxUploadBytes = Math.floor(positiveNumber('WS4K_MAX_UPLOAD', env.WS4K_MAX_UPLOAD));
	}

	return {
		port,
		musicDir: path.resolve(env.WS4K_MUSIC_DIR || path.join(SERVER_ROOT, 'music')),
		adsDir: path.resolve(env.WS4K_ADS_DIR || path.join(SERVER_ROOT, 'ads')),
		token: env.WS4K_TOKEN ?? '',
		maxUploadBytes,
		maxJsonBytes: MAX_JSON_BYTES,
	};
};
