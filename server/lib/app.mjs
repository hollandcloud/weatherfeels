// The companion server: routing, authentication and the ads endpoints.
//
// `createCompanionServer(config)` returns an unstarted `http.Server`, so tests can
// run it on an ephemeral port against temporary directories.

import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, readdir, stat, unlink } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';

import { SERVER_ROOT } from './config.mjs';
import {
	drainBody, HttpError, OPEN_CORS, readJsonBody, receiveFile, safeDecode, sendJson, sendText, streamFile, writeFileAtomic,
} from './http.mjs';
import {
	adminManifest, publicManifest, readStoredManifest, timestamp, validateManifest,
} from './manifest.mjs';
import { createMusic, decodeSegments } from './music.mjs';
import { checkFileName, KINDS, resolveInside } from './names.mjs';

const sha256 = (value) => createHash('sha256').update(value).digest();

/** Constant-time string comparison. Hashing first makes the lengths equal. */
export const safeEqual = (a, b) => timingSafeEqual(sha256(String(a)), sha256(String(b)));

// ---------------------------------------------------------------------------
// The admin page

/**
 * Load the admin page and build its Content-Security-Policy.
 *
 * The page is one self-contained file with a single inline <style> and <script>.
 * Rather than allow inline code wholesale, the policy names those two blocks by
 * hash, so nothing injected into the page — were anything ever to be — could run.
 */
export const loadAdminPage = (file = path.join(SERVER_ROOT, 'admin', 'admin.html')) => {
	const html = readFileSync(file, 'utf8');
	const block = (tag) => {
		const matches = [...html.matchAll(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, 'g'))];
		if (matches.length !== 1) throw new Error(`admin.html must contain exactly one <${tag}> block`);
		return `'sha256-${createHash('sha256').update(matches[0][1], 'utf8').digest('base64')}'`;
	};
	const csp = [
		"default-src 'none'",
		`script-src ${block('script')}`,
		`style-src ${block('style')}`,
		"img-src 'self' blob:",
		"media-src 'self' blob:",
		"connect-src 'self'",
		"base-uri 'none'",
		"form-action 'none'",
		"frame-ancestors 'none'",
	].join('; ');
	return { html, csp };
};

// ---------------------------------------------------------------------------
// The server

export const createCompanionServer = (config, { logger = console } = {}) => {
	const music = createMusic(config);
	const adminPage = loadAdminPage();

	const ADS_DIR = config.adsDir;
	const MANIFEST = path.join(ADS_DIR, 'ads.json');
	const ADS_FOLDERS = {
		image: { dir: path.join(ADS_DIR, 'images'), url: 'ads/images/' },
		clip: { dir: path.join(ADS_DIR, 'clips'), url: 'ads/clips/' },
	};

	// --- Authentication ------------------------------------------------------

	/** The original upload endpoints: open when no token is set, as they always were. */
	const uploadAllowed = (req) => !config.token || safeEqual(req.headers.authorization ?? '', `Bearer ${config.token}`);

	/** Admin is never open: no token configured means no admin at all. */
	const requireAdmin = (req) => {
		if (!config.token) {
			throw new HttpError(403, 'Admin is disabled because WS4K_TOKEN is not set. Set it on the server and restart to use /admin.', {
				details: { code: 'admin-disabled' },
			});
		}
		const header = req.headers.authorization ?? '';
		const match = /^Bearer (.+)$/.exec(header);
		// Compare even when the header is malformed, so timing says nothing about why.
		const valid = safeEqual(match ? match[1] : '', config.token);
		if (!match || !valid) {
			throw new HttpError(401, 'A valid admin token is required', { headers: { 'WWW-Authenticate': 'Bearer' } });
		}
	};

	// --- Manifest ------------------------------------------------------------

	const warnedAbout = new Set();
	const warnOnce = (message) => {
		if (warnedAbout.has(message)) return;
		warnedAbout.add(message);
		logger.warn(message);
	};

	/** The stored manifest for public use: never throws, so the app always gets JSON. */
	const loadPublic = async () => {
		let stored;
		try {
			stored = await readStoredManifest(MANIFEST);
		} catch (error) {
			warnOnce(`ads.json could not be read, serving no ads: ${error.message}`);
			return publicManifest({ updated: timestamp(new Date(0)), ticker: [], cards: [], clips: [] });
		}
		return publicManifest(stored, (errors) => {
			warnOnce(`ads.json: skipping an invalid item (${errors.map((e) => `${e.field} ${e.message}`).join('; ')})`);
		});
	};

	const loadForAdmin = async () => {
		try {
			return await readStoredManifest(MANIFEST);
		} catch (error) {
			throw new HttpError(500, `ads.json on the server could not be read: ${error.message}. Fix or remove the file.`);
		}
	};

	// Saves run one at a time so two quick saves cannot interleave their renames.
	let saving = Promise.resolve();
	const saveManifest = (manifest) => {
		const run = saving.then(() => writeFileAtomic(MANIFEST, `${JSON.stringify(manifest, null, '\t')}\n`));
		saving = run.catch(() => {});
		return run;
	};

	// --- Ad files ------------------------------------------------------------

	const listAdFiles = async (kind) => {
		const { dir, url } = ADS_FOLDERS[kind];
		let entries;
		try {
			entries = await readdir(dir, { withFileTypes: true });
		} catch {
			return [];
		}
		const files = await Promise.all(entries
			.filter((entry) => entry.isFile() && !entry.name.startsWith('.'))
			.filter((entry) => Object.hasOwn(KINDS[kind].types, path.extname(entry.name).toLowerCase()))
			.map(async (entry) => {
				try {
					const info = await stat(path.join(dir, entry.name));
					return { name: entry.name, path: url + entry.name, size: info.size, modified: info.mtime.toISOString() };
				} catch {
					return null;
				}
			}));
		return files.filter(Boolean).sort((a, b) => a.name.localeCompare(b.name));
	};

	/** Decode and validate the file-name part of a route, or throw. */
	const fileFromRoute = (raw, kind) => {
		const name = safeDecode(raw);
		if (name === null) throw new HttpError(400, 'Malformed file name');
		return checkFileName(name, kind);
	};

	const serveAdFile = async (req, res, raw, kind) => {
		let file;
		try {
			file = fileFromRoute(raw, kind);
		} catch (error) {
			if (error instanceof HttpError) return sendText(res, error.status, error.message, OPEN_CORS);
			throw error;
		}
		const target = resolveInside(ADS_FOLDERS[kind].dir, file.name);
		return streamFile(req, res, target, file.type, OPEN_CORS);
	};

	const uploadAdFile = async (req, res, raw, kind) => {
		const { name } = fileFromRoute(raw, kind);
		const { dir, url } = ADS_FOLDERS[kind];
		await mkdir(dir, { recursive: true });
		const size = await receiveFile(req, resolveInside(dir, name), config.maxUploadBytes);
		return sendJson(res, 201, { ok: true, name, path: url + name, size });
	};

	const deleteAdFile = async (res, raw, kind) => {
		const { name } = fileFromRoute(raw, kind);
		try {
			await unlink(resolveInside(ADS_FOLDERS[kind].dir, name));
		} catch (error) {
			if (error.code === 'ENOENT') throw new HttpError(404, 'No such file');
			throw error;
		}
		return sendJson(res, 200, { ok: true, deleted: ADS_FOLDERS[kind].url + name });
	};

	// --- Admin API -----------------------------------------------------------

	const adminRoutes = async (req, res, pathname) => {
		requireAdmin(req);
		const { method } = req;

		if (pathname === '/api/music') {
			if (method !== 'GET') throw new HttpError(405, 'Method not allowed');
			return sendJson(res, 200, { tracks: await music.listTracksWithSizes(), maxUploadBytes: config.maxUploadBytes });
		}

		if (pathname.startsWith('/api/music/')) {
			const rest = pathname.slice('/api/music/'.length);

			if (method === 'PUT') {
				// New tracks from the admin page go to the top of the music directory,
				// under the same strict name rules as every other admin upload.
				if (rest.includes('/')) throw new HttpError(400, 'File name must not contain a path');
				const { name } = fileFromRoute(rest, 'music');
				await mkdir(config.musicDir, { recursive: true });
				await receiveFile(req, resolveInside(config.musicDir, name), config.maxUploadBytes);
				return sendJson(res, 201, { ok: true, file: name });
			}

			if (method === 'DELETE') {
				// Tracks can live in subfolders (the app uploads into one), so a path is
				// accepted here — but only one the playlist itself lists, which rules out
				// anything hidden, outside the directory, or not audio.
				const segments = decodeSegments(rest);
				const relative = segments?.join('/');
				if (!segments || segments.length === 0) throw new HttpError(400, 'Invalid track name');
				const tracks = await music.listTracks();
				if (!tracks.includes(relative)) throw new HttpError(404, 'No such track');
				const target = music.safeJoin(relative);
				if (!target) throw new HttpError(400, 'Invalid track name');
				await unlink(target);
				return sendJson(res, 200, { ok: true, deleted: relative });
			}

			throw new HttpError(405, 'Method not allowed');
		}

		if (pathname === '/api/ads') {
			if (method === 'GET') return sendJson(res, 200, adminManifest(await loadForAdmin()));
			if (method === 'PUT') {
				const body = await readJsonBody(req, config.maxJsonBytes);
				const { manifest, errors } = validateManifest(body);
				if (errors.length) {
					throw new HttpError(400, 'The manifest is not valid', { details: { fields: errors } });
				}
				manifest.updated = timestamp();
				await mkdir(ADS_DIR, { recursive: true });
				await saveManifest(manifest);
				return sendJson(res, 200, manifest);
			}
			throw new HttpError(405, 'Method not allowed');
		}

		if (pathname === '/api/ads/files') {
			if (method !== 'GET') throw new HttpError(405, 'Method not allowed');
			const [images, clips] = await Promise.all([listAdFiles('image'), listAdFiles('clip')]);
			return sendJson(res, 200, { images, clips, maxUploadBytes: config.maxUploadBytes });
		}

		for (const [kind, prefix] of [['image', '/api/ads/images/'], ['clip', '/api/ads/clips/']]) {
			if (pathname.startsWith(prefix)) {
				const rest = pathname.slice(prefix.length);
				if (rest.includes('/')) throw new HttpError(400, 'File name must not contain a path');
				if (method === 'PUT') return uploadAdFile(req, res, rest, kind);
				if (method === 'DELETE') return deleteAdFile(res, rest, kind);
				throw new HttpError(405, 'Method not allowed');
			}
		}

		throw new HttpError(404, 'No such admin endpoint');
	};

	// --- Router --------------------------------------------------------------

	const isAdminPath = (pathname) => pathname === '/api' || pathname.startsWith('/api/');

	/**
	 * The path exactly as sent, still percent-encoded. Routes decode their own
	 * parameters; normalising first (as `new URL` does with `..` and `%2e%2e`) would
	 * hide a traversal attempt instead of rejecting it.
	 */
	const rawPathname = (req) => {
		let target = req.url ?? '/';
		if (!target.startsWith('/')) {
			// Absolute-form, as some proxies send it.
			try {
				target = new URL(target).pathname;
			} catch {
				return null;
			}
		}
		return target.split(/[?#]/, 1)[0];
	};

	const route = async (req, res) => {
		const pathname = rawPathname(req);
		if (pathname === null) return sendText(res, 400, 'Bad request');
		const { method } = req;
		const read = method === 'GET' || method === 'HEAD';

		if (method === 'OPTIONS') {
			// No CORS for the admin API: it is for the same-origin admin page only.
			if (isAdminPath(pathname)) {
				res.writeHead(204, { Allow: 'GET, PUT, DELETE' });
				return res.end();
			}
			res.writeHead(204, {
				'Access-Control-Allow-Origin': '*',
				'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
				'Access-Control-Allow-Headers': 'Authorization, Content-Type',
			});
			return res.end();
		}

		if (method === 'GET' && pathname === '/health') {
			const [tracks, ads] = await Promise.all([music.listTracks(), loadPublic()]);
			return sendJson(res, 200, {
				ok: true,
				tracks: tracks.length,
				ticker: ads.ticker.length,
				cards: ads.cards.length,
				clips: ads.clips.length,
				musicDir: config.musicDir,
			}, OPEN_CORS);
		}

		// Same response shape ws4kp's server returns, so the app treats either
		// identically and an existing install works as a source unchanged.
		if (method === 'GET' && pathname === '/playlist.json') {
			return sendJson(res, 200, { availableFiles: await music.listTracks() }, OPEN_CORS);
		}

		if (method === 'GET' && pathname === '/ads.json') {
			return sendJson(res, 200, await loadPublic(), { ...OPEN_CORS, 'Cache-Control': 'no-cache' });
		}

		if (read && pathname.startsWith('/music/')) {
			return music.streamTrack(req, res, pathname.slice('/music/'.length));
		}

		if (read && pathname.startsWith('/ads/images/')) {
			return serveAdFile(req, res, pathname.slice('/ads/images/'.length), 'image');
		}

		if (read && pathname.startsWith('/ads/clips/')) {
			return serveAdFile(req, res, pathname.slice('/ads/clips/'.length), 'clip');
		}

		// Errors on the upload routes are thrown rather than sent, so the handler can
		// drain the unread body first; the plain-text responses are unchanged.
		if (method === 'POST' && pathname === '/upload') {
			if (!uploadAllowed(req)) throw new HttpError(401, 'Unauthorized');
			const contentType = req.headers['content-type'] ?? '';
			const boundary = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
			if (!boundary) throw new HttpError(400, 'Expected multipart/form-data');
			return music.handleMultipartUpload(req, res, boundary[1] ?? boundary[2]);
		}

		if (method === 'PUT' && pathname.startsWith('/music/')) {
			if (!uploadAllowed(req)) throw new HttpError(401, 'Unauthorized');
			return music.handlePutUpload(req, res, pathname.slice('/music/'.length));
		}

		if (read && (pathname === '/admin' || pathname === '/admin/')) {
			res.writeHead(200, {
				'Content-Type': 'text/html; charset=utf-8',
				'Content-Length': Buffer.byteLength(adminPage.html),
				'Content-Security-Policy': adminPage.csp,
				'Cache-Control': 'no-store',
				'Referrer-Policy': 'no-referrer',
				'X-Content-Type-Options': 'nosniff',
				'X-Frame-Options': 'DENY',
			});
			return res.end(method === 'HEAD' ? undefined : adminPage.html);
		}

		if (isAdminPath(pathname)) {
			return adminRoutes(req, res, pathname);
		}

		throw new HttpError(404, 'Not found');
	};

	const handle = async (req, res) => {
		try {
			await route(req, res);
		} catch (error) {
			const pathname = rawPathname(req) ?? '';
			const status = error instanceof HttpError ? error.status : 500;
			if (status === 500) logger.error(error);
			if (res.headersSent) {
				res.destroy();
				return;
			}
			const known = error instanceof HttpError;
			const message = known ? error.message : 'Server error';
			const headers = known ? error.headers : {};
			// Anything refused before its body was read (a 401, 413, 415…) drains
			// the rest, within limits, so the client reliably sees the answer.
			await drainBody(req);
			if (isAdminPath(pathname)) {
				sendJson(res, status, { error: message, ...(known ? error.details : {}) }, headers);
			} else {
				sendText(res, status, message, headers);
			}
		}
	};

	const server = http.createServer(handle);

	// With a listener here Node no longer sends `100 Continue` by itself: a body
	// reader does, through `allowBody`, once it has decided to accept the body.
	server.on('checkContinue', (req, res) => {
		req.sendContinue = () => res.writeContinue();
		handle(req, res);
	});

	// Uploads of large clips over a slow uplink can take longer than Node's default
	// five-minute request timeout. Headers must still arrive promptly, and a socket
	// that goes quiet for two minutes is dropped, so a stalled client cannot hold a
	// connection open forever.
	server.requestTimeout = 0;
	server.headersTimeout = 60_000;
	server.timeout = 120_000;

	server.prepare = async () => {
		await mkdir(config.musicDir, { recursive: true });
		await mkdir(ADS_FOLDERS.image.dir, { recursive: true });
		await mkdir(ADS_FOLDERS.clip.dir, { recursive: true });
	};

	return server;
};
