#!/usr/bin/env node
// Companion music server for WeatherStar.
//
// Serves a ws4kp-compatible playlist and accepts uploads from the iOS/iPadOS/macOS
// apps, so an Apple TV — which has no file picker — can stream your own music.
//
// Deliberately dependency-free: it runs on plain Node with no install step, which
// makes it easy to drop onto a NAS or a Raspberry Pi.
//
//   node server.mjs
//   WS4K_PORT=8080 WS4K_MUSIC_DIR=./music WS4K_TOKEN=secret node server.mjs
//
// Endpoints:
//   GET  /playlist.json      { "availableFiles": [...] }  — same shape as ws4kp
//   GET  /music/<file>       streams a track, with range support for seeking
//   POST /upload             multipart/form-data: `file`, optional `path`
//   PUT  /music/<file>       raw body upload, for WebDAV-style clients
//   GET  /health             { ok: true, tracks: N }

import { createReadStream, createWriteStream, mkdirSync } from 'node:fs';
import { mkdir, readdir, stat, unlink } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.WS4K_PORT ?? 8080);
const MUSIC_DIR = path.resolve(process.env.WS4K_MUSIC_DIR ?? path.join(HERE, 'music'));
// When set, uploads must present `Authorization: Bearer <token>`.
const TOKEN = process.env.WS4K_TOKEN ?? '';
// Uploads larger than this are rejected outright rather than buffered.
const MAX_UPLOAD_BYTES = Number(process.env.WS4K_MAX_UPLOAD ?? 100 * 1024 * 1024);

const AUDIO_EXTENSIONS = new Set([
	'.mp3', '.m4a', '.aac', '.aif', '.aiff', '.wav', '.caf', '.flac', '.alac', '.mp4',
]);

const MIME_TYPES = {
	'.mp3': 'audio/mpeg',
	'.m4a': 'audio/mp4',
	'.mp4': 'audio/mp4',
	'.alac': 'audio/mp4',
	'.aac': 'audio/aac',
	'.wav': 'audio/wav',
	'.aif': 'audio/aiff',
	'.aiff': 'audio/aiff',
	'.caf': 'audio/x-caf',
	'.flac': 'audio/flac',
};

// ---------------------------------------------------------------------------
// Helpers

const json = (res, status, body) => {
	const payload = JSON.stringify(body);
	res.writeHead(status, {
		'Content-Type': 'application/json',
		'Content-Length': Buffer.byteLength(payload),
		'Access-Control-Allow-Origin': '*',
	});
	res.end(payload);
};

const text = (res, status, body) => {
	res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
	res.end(body);
};

/**
 * Resolve a client-supplied name to a path inside MUSIC_DIR.
 *
 * Returns null when the result would escape the directory — this is the only thing
 * standing between the server and a path-traversal write, so it rejects rather than
 * sanitising.
 */
const safeJoin = (...parts) => {
	const candidate = path.resolve(MUSIC_DIR, ...parts.map((part) => part.replace(/^[/\\]+/, '')));
	const root = MUSIC_DIR.endsWith(path.sep) ? MUSIC_DIR : MUSIC_DIR + path.sep;
	if (candidate !== MUSIC_DIR && !candidate.startsWith(root)) return null;
	return candidate;
};

const isAudio = (name) => AUDIO_EXTENSIONS.has(path.extname(name).toLowerCase());

/** Audio files under MUSIC_DIR, recursing one level so `custom/` subfolders work. */
const listTracks = async (dir = MUSIC_DIR, prefix = '', depth = 0) => {
	let entries;
	try {
		entries = await readdir(dir, { withFileTypes: true });
	} catch {
		return [];
	}

	const files = [];
	for (const entry of entries) {
		if (entry.name.startsWith('.')) continue;
		if (entry.isDirectory()) {
			if (depth >= 2) continue;
			// eslint-disable-next-line no-await-in-loop
			files.push(...await listTracks(
				path.join(dir, entry.name),
				`${prefix}${entry.name}/`,
				depth + 1,
			));
		} else if (isAudio(entry.name)) {
			files.push(prefix + entry.name);
		}
	}
	return files.sort();
};

const requireToken = (req) => {
	if (!TOKEN) return true;
	const header = req.headers.authorization ?? '';
	return header === `Bearer ${TOKEN}`;
};

// ---------------------------------------------------------------------------
// Streaming a track

const streamTrack = async (req, res, relative) => {
	const target = safeJoin(decodeURIComponent(relative));
	if (!target || !isAudio(target)) return text(res, 400, 'Bad request');

	let info;
	try {
		info = await stat(target);
	} catch {
		return text(res, 404, 'Not found');
	}
	if (!info.isFile()) return text(res, 404, 'Not found');

	const type = MIME_TYPES[path.extname(target).toLowerCase()] ?? 'application/octet-stream';
	const range = req.headers.range;

	// Range support lets AVPlayer seek without refetching the whole file.
	if (range) {
		const match = /^bytes=(\d*)-(\d*)$/.exec(range);
		if (match) {
			const start = match[1] ? Number(match[1]) : 0;
			const end = match[2] ? Number(match[2]) : info.size - 1;
			if (start >= info.size || end >= info.size || start > end) {
				res.writeHead(416, { 'Content-Range': `bytes */${info.size}` });
				return res.end();
			}
			res.writeHead(206, {
				'Content-Type': type,
				'Content-Length': end - start + 1,
				'Content-Range': `bytes ${start}-${end}/${info.size}`,
				'Accept-Ranges': 'bytes',
				'Access-Control-Allow-Origin': '*',
			});
			return pipeline(createReadStream(target, { start, end }), res).catch(() => {});
		}
	}

	res.writeHead(200, {
		'Content-Type': type,
		'Content-Length': info.size,
		'Accept-Ranges': 'bytes',
		'Access-Control-Allow-Origin': '*',
	});
	return pipeline(createReadStream(target), res).catch(() => {});
};

// ---------------------------------------------------------------------------
// Uploads

/**
 * Minimal multipart/form-data parser, streaming the file part straight to disk.
 *
 * Only what the app sends is supported: one file part plus an optional `path`
 * field. Buffering an entire audio file in memory would be wasteful on a NAS, so
 * the body is scanned for the boundary as it arrives.
 */
const handleMultipartUpload = (req, res, boundary) => new Promise((resolve) => {
	const delimiter = Buffer.from(`--${boundary}`);
	let buffer = Buffer.alloc(0);
	let state = 'preamble';
	let received = 0;
	let writeStream = null;
	let destination = null;
	let subdirectory = '';
	let pendingFieldName = null;

	let finished = false;

	const fail = (status, message) => {
		if (finished) return;
		finished = true;

		if (writeStream) {
			writeStream.destroy();
			if (destination) unlink(destination).catch(() => {});
		}

		// Send the response before tearing anything down — destroying the request
		// first would abort the socket and the client would see no status at all.
		text(res, status, message);
		// Drain the rest of the body so the connection closes cleanly.
		req.resume();
		resolve();
	};

	// The handler must stay synchronous: an `async` listener would let the `end`
	// event fire before the last chunk finished being processed, so the response
	// could be sent before the file part was recognised. Directory creation uses the
	// sync API for the same reason.
	req.on('data', (chunk) => {
		if (finished) return;
		received += chunk.length;
		if (received > MAX_UPLOAD_BYTES) return fail(413, 'Upload too large');

		buffer = Buffer.concat([buffer, chunk]);

		// Process as many complete segments as the buffer holds.
		for (;;) {
			if (state === 'preamble' || state === 'headers') {
				const headerEnd = buffer.indexOf('\r\n\r\n');
				const boundaryAt = buffer.indexOf(delimiter);

				if (state === 'preamble') {
					if (boundaryAt === -1) return;
					buffer = buffer.subarray(boundaryAt + delimiter.length);
					state = 'headers';
					// eslint-disable-next-line no-continue
					continue;
				}

				if (headerEnd === -1) return;
				const headers = buffer.subarray(0, headerEnd).toString('utf8');
				buffer = buffer.subarray(headerEnd + 4);

				const nameMatch = /name="([^"]+)"/i.exec(headers);
				const fileMatch = /filename="([^"]*)"/i.exec(headers);
				pendingFieldName = nameMatch?.[1] ?? null;

				if (fileMatch && fileMatch[1]) {
					// Only the basename is honoured; a client-supplied directory in the
					// filename is ignored so it cannot redirect the write.
					const base = path.basename(fileMatch[1]);
					if (!isAudio(base)) return fail(415, 'Unsupported file type');

					const dir = safeJoin(subdirectory);
					if (!dir) return fail(400, 'Invalid path');
					mkdirSync(dir, { recursive: true });

					destination = safeJoin(subdirectory, base);
					if (!destination) return fail(400, 'Invalid path');
					writeStream = createWriteStream(destination);
					state = 'file';
				} else {
					state = 'field';
				}
				// eslint-disable-next-line no-continue
				continue;
			}

			const boundaryAt = buffer.indexOf(delimiter);

			if (state === 'field') {
				if (boundaryAt === -1) return;
				const value = buffer.subarray(0, boundaryAt).toString('utf8').replace(/\r\n$/, '');
				if (pendingFieldName === 'path') {
					// Strip leading slashes; safeJoin rejects anything that escapes.
					subdirectory = value.replace(/^\/+/, '');
				}
				buffer = buffer.subarray(boundaryAt + delimiter.length);
				state = 'headers';
				// eslint-disable-next-line no-continue
				continue;
			}

			if (state === 'file') {
				if (boundaryAt === -1) {
					// Hold back enough bytes that a boundary split across chunks is not
					// written into the file.
					const keep = delimiter.length + 4;
					if (buffer.length > keep) {
						writeStream.write(buffer.subarray(0, buffer.length - keep));
						buffer = buffer.subarray(buffer.length - keep);
					}
					return;
				}
				writeStream.write(buffer.subarray(0, Math.max(0, boundaryAt - 2)));
				buffer = buffer.subarray(boundaryAt + delimiter.length);
				writeStream.end();
				state = 'headers';
				// eslint-disable-next-line no-continue
				continue;
			}

			return;
		}
	});

	req.on('end', () => {
		if (finished) return resolve();
		finished = true;
		if (!destination) {
			text(res, 400, 'No file part found');
			return resolve();
		}

		const respond = () => {
			json(res, 201, {
				ok: true,
				file: path.relative(MUSIC_DIR, destination),
			});
			resolve();
		};

		// Respond only once the bytes are actually on disk, so a client that
		// immediately re-reads the playlist sees the new track.
		if (writeStream && !writeStream.writableFinished) {
			writeStream.once('finish', respond);
			writeStream.once('error', () => {
				text(res, 500, 'Could not write file');
				resolve();
			});
			writeStream.end();
			return undefined;
		}

		return respond();
	});

	req.on('error', () => fail(400, 'Upload failed'));
});

/** Raw PUT upload, for WebDAV-style clients. */
const handlePutUpload = async (req, res, relative) => {
	const base = path.basename(decodeURIComponent(relative));
	if (!isAudio(base)) return text(res, 415, 'Unsupported file type');

	const directory = safeJoin(path.dirname(decodeURIComponent(relative)));
	if (!directory) return text(res, 400, 'Invalid path');
	await mkdir(directory, { recursive: true });

	const destination = path.join(directory, base);
	try {
		await pipeline(req, createWriteStream(destination));
	} catch {
		await unlink(destination).catch(() => {});
		return text(res, 400, 'Upload failed');
	}
	return json(res, 201, { ok: true, file: path.relative(MUSIC_DIR, destination) });
};

// ---------------------------------------------------------------------------
// Router

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);
	const { pathname } = url;

	if (req.method === 'OPTIONS') {
		res.writeHead(204, {
			'Access-Control-Allow-Origin': '*',
			'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
			'Access-Control-Allow-Headers': 'Authorization, Content-Type',
		});
		return res.end();
	}

	try {
		if (req.method === 'GET' && pathname === '/health') {
			const tracks = await listTracks();
			return json(res, 200, { ok: true, tracks: tracks.length, musicDir: MUSIC_DIR });
		}

		// Same response shape ws4kp's server returns, so the app treats either
		// identically and an existing install works as a source unchanged.
		if (req.method === 'GET' && pathname === '/playlist.json') {
			return json(res, 200, { availableFiles: await listTracks() });
		}

		if (req.method === 'GET' && pathname.startsWith('/music/')) {
			return streamTrack(req, res, pathname.slice('/music/'.length));
		}

		if (req.method === 'POST' && pathname === '/upload') {
			if (!requireToken(req)) return text(res, 401, 'Unauthorized');
			const contentType = req.headers['content-type'] ?? '';
			const boundary = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
			if (!boundary) return text(res, 400, 'Expected multipart/form-data');
			return handleMultipartUpload(req, res, boundary[1] ?? boundary[2]);
		}

		if (req.method === 'PUT' && pathname.startsWith('/music/')) {
			if (!requireToken(req)) return text(res, 401, 'Unauthorized');
			return handlePutUpload(req, res, pathname.slice('/music/'.length));
		}

		return text(res, 404, 'Not found');
	} catch (error) {
		console.error(error);
		return text(res, 500, 'Server error');
	}
});

await mkdir(MUSIC_DIR, { recursive: true });

server.listen(PORT, () => {
	console.log(`WeatherStar music server listening on http://0.0.0.0:${PORT}`);
	console.log(`Serving music from ${MUSIC_DIR}`);
	console.log(TOKEN ? 'Uploads require a bearer token.' : 'Uploads are open (set WS4K_TOKEN to require one).');
});

const shutdown = () => server.close(() => process.exit(0));
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
