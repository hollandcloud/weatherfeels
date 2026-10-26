// Shared test helpers: a server on an ephemeral port against temporary
// directories, and a raw HTTP client that sends paths exactly as written.

import { mkdtemp, readdir, rm } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { createCompanionServer } from '../lib/app.mjs';
import { configFromEnv } from '../lib/config.mjs';

export const TOKEN = 'test-token-0123456789abcdef';

/**
 * Start a server. `env` overrides the environment it would read, so a test can
 * set `WS4K_TOKEN`, `WS4K_MAX_UPLOAD_MB` and so on exactly as a user would.
 */
export const startServer = async (env = {}) => {
	const root = await mkdtemp(path.join(os.tmpdir(), 'ws4k-companion-test-'));
	const config = configFromEnv({
		WS4K_PORT: '0',
		WS4K_MUSIC_DIR: path.join(root, 'music'),
		WS4K_ADS_DIR: path.join(root, 'ads'),
		...env,
	});
	const logs = [];
	const logger = {
		log: (...args) => logs.push(args.join(' ')),
		warn: (...args) => logs.push(args.join(' ')),
		error: (...args) => logs.push(args.map((a) => a?.stack ?? String(a)).join(' ')),
	};
	const server = createCompanionServer(config, { logger });
	await server.prepare();
	await new Promise((resolve) => { server.listen(0, '127.0.0.1', resolve); });
	const { port } = server.address();

	return {
		port,
		root,
		config,
		logs,
		musicDir: config.musicDir,
		adsDir: config.adsDir,
		request: (options) => request(port, options),
		async close() {
			server.closeAllConnections();
			await new Promise((resolve) => { server.close(resolve); });
			await rm(root, { recursive: true, force: true });
		},
	};
};

/**
 * Make one request with node:http, which (unlike fetch) never normalises `..` or
 * percent-escapes out of the path, so traversal attempts reach the server intact.
 *
 * `body` is sent in one piece; `chunks` are written one by one with chunked
 * transfer encoding. The promise resolves as soon as a complete response arrives,
 * even if the server answered before the body was fully sent — which is exactly
 * what a 413 does.
 *
 * With `expectContinue`, the body is held back until the server answers
 * `100 Continue`; the result's `continued` says whether it ever did.
 */
export const request = (port, {
	method = 'GET', path: target = '/', headers = {}, body, chunks, token, expectContinue = false,
} = {}) => new Promise((resolve, reject) => {
	const allHeaders = { ...headers };
	if (token) allHeaders.Authorization = `Bearer ${token}`;
	if (body !== undefined && allHeaders['Content-Length'] === undefined) {
		allHeaders['Content-Length'] = Buffer.byteLength(body);
	}
	if (expectContinue) allHeaders.Expect = '100-continue';

	const req = http.request({ host: '127.0.0.1', port, method, path: target, headers: allHeaders, agent: false });
	let responded = false;
	let continued = false;

	if (expectContinue) {
		req.on('continue', () => {
			continued = true;
			req.end(body);
		});
	}

	req.on('response', (res) => {
		responded = true;
		const parts = [];
		res.on('data', (chunk) => parts.push(chunk));
		res.on('end', () => {
			const buffer = Buffer.concat(parts);
			let json;
			try {
				json = JSON.parse(buffer.toString('utf8'));
			} catch {
				json = undefined;
			}
			resolve({
				status: res.statusCode, headers: res.headers, body: buffer, text: buffer.toString('utf8'), json, continued,
			});
			req.destroy();
		});
		res.on('error', () => {});
	});
	// Once the server has answered, a reset while we were still sending is expected.
	req.on('error', (error) => { if (!responded) reject(error); });

	if (expectContinue) {
		// Send the headers now; the body waits for `continue`.
		req.flushHeaders();
	} else if (chunks) {
		(async () => {
			for (const chunk of chunks) {
				if (responded || req.destroyed) return;
				const ok = req.write(chunk);
				// eslint-disable-next-line no-await-in-loop
				if (!ok) await new Promise((r) => { req.once('drain', r); req.once('close', r); });
			}
			if (!responded && !req.destroyed) req.end();
		})().catch(() => {});
	} else if (body !== undefined && allHeaders['Content-Length'] > Buffer.byteLength(body)) {
		// Declared longer than what we send: leave the request open and wait for the
		// server to answer on the headers alone.
		req.write(body);
	} else {
		req.end(body);
	}
});

/** Everything in a directory, including hidden files, or [] if it is missing. */
export const listDir = async (dir) => {
	try {
		return (await readdir(dir)).sort();
	} catch {
		return [];
	}
};

/** A multipart body shaped exactly like the app's MusicTransfer sends. */
export const appMultipart = (fileName, data, uploadPath = '/music') => {
	const boundary = 'ws4k-3F2504E0-4F89-11D3-9A0C-0305E82C3301';
	const body = Buffer.concat([
		Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="path"\r\n\r\n${uploadPath}\r\n`),
		Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: audio/mpeg\r\n\r\n`),
		data,
		Buffer.from(`\r\n--${boundary}--\r\n`),
	]);
	return { body, contentType: `multipart/form-data; boundary=${boundary}` };
};

/** Deterministic bytes, so a range can be checked against the exact slice. */
export const bytes = (length, seed = 7) => {
	const buffer = Buffer.alloc(length);
	for (let i = 0; i < length; i += 1) buffer[i] = (i * 31 + seed) % 256;
	return buffer;
};
