// The music library: the original companion-server endpoints.
//
// The app and existing ws4kp installs depend on these exactly as they are —
// `/playlist.json`, `/music/<file>`, `POST /upload` and `PUT /music/<file>` — so
// their paths, shapes and status codes are unchanged. Subfolders are part of that
// contract: the app's default upload path is `/music`, which lands tracks in a
// `music/` folder inside the music directory, and the playlist lists them there.

import { createWriteStream, mkdirSync } from 'node:fs';
import { mkdir, readdir, stat, unlink } from 'node:fs/promises';
import path from 'node:path';

import {
	allowBody, drainBody, HttpError, OPEN_CORS, receiveFile, safeDecode, sendJson, sendText, streamFile,
} from './http.mjs';
import { AUDIO_TYPES } from './names.mjs';

export const isAudio = (name) => Object.hasOwn(AUDIO_TYPES, path.extname(name).toLowerCase());

/**
 * Split a raw (still percent-encoded) URL path into decoded segments, or return
 * null if any segment is malformed, hidden, `..`, or smuggles a separator.
 *
 * Hidden names are refused because the playlist never lists them: nothing a
 * legitimate client asks for starts with a dot, and the upload temporaries do.
 */
export const decodeSegments = (raw) => {
	const segments = [];
	for (const part of raw.split('/')) {
		if (part === '') continue;
		const segment = safeDecode(part);
		if (segment === null || segment.startsWith('.') || /[/\\\0]/.test(segment)) return null;
		segments.push(segment);
	}
	return segments;
};

export const createMusic = (config) => {
	const MUSIC_DIR = config.musicDir;

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

	/** Audio files under MUSIC_DIR, recursing so `custom/` subfolders work. */
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

	/** Tracks with their sizes, for the admin page. */
	const listTracksWithSizes = async () => {
		const names = await listTracks();
		const tracks = await Promise.all(names.map(async (name) => {
			try {
				const info = await stat(path.join(MUSIC_DIR, name));
				return { name, size: info.size, modified: info.mtime.toISOString() };
			} catch {
				return null;
			}
		}));
		return tracks.filter(Boolean);
	};

	// -------------------------------------------------------------------------
	// Streaming a track

	const streamTrack = async (req, res, relative) => {
		const segments = decodeSegments(relative);
		const target = segments && safeJoin(segments.join('/'));
		if (!target || !isAudio(target)) return sendText(res, 400, 'Bad request');

		const type = AUDIO_TYPES[path.extname(target).toLowerCase()] ?? 'application/octet-stream';
		return streamFile(req, res, target, type, OPEN_CORS);
	};

	// -------------------------------------------------------------------------
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

			// Drain (within limits) and then respond, never the other way round:
			// destroying the request, or answering with body still unread, can abort
			// the socket so the client sees no status at all.
			drainBody(req).then(() => {
				sendText(res, status, message);
				resolve();
			});
		};

		if (Number(req.headers['content-length']) > config.maxUploadBytes) {
			fail(413, 'Upload too large');
			return;
		}
		allowBody(req);

		// The handler must stay synchronous: an `async` listener would let the `end`
		// event fire before the last chunk finished being processed, so the response
		// could be sent before the file part was recognised. Directory creation uses the
		// sync API for the same reason.
		req.on('data', (chunk) => {
			if (finished) return;
			received += chunk.length;
			if (received > config.maxUploadBytes) return fail(413, 'Upload too large');

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
				sendText(res, 400, 'No file part found');
				return resolve();
			}

			const respond = () => {
				sendJson(res, 201, {
					ok: true,
					file: path.relative(MUSIC_DIR, destination),
				}, OPEN_CORS);
				resolve();
			};

			// Respond only once the bytes are actually on disk, so a client that
			// immediately re-reads the playlist sees the new track.
			if (writeStream && !writeStream.writableFinished) {
				writeStream.once('finish', respond);
				writeStream.once('error', () => {
					sendText(res, 500, 'Could not write file');
					resolve();
				});
				writeStream.end();
				return undefined;
			}

			return respond();
		});

		req.on('error', () => fail(400, 'Upload failed'));
	});

	/**
	 * Raw PUT upload, for WebDAV-style clients.
	 *
	 * Errors are thrown as the same plain-text responses this endpoint has always
	 * given, for the router to send once it has drained the body.
	 */
	const handlePutUpload = async (req, res, relative) => {
		const segments = decodeSegments(relative);
		if (!segments) throw new HttpError(400, 'Invalid path');

		const base = segments.pop() ?? '';
		if (!isAudio(base)) throw new HttpError(415, 'Unsupported file type');

		const directory = safeJoin(segments.join('/'));
		if (!directory) throw new HttpError(400, 'Invalid path');
		await mkdir(directory, { recursive: true });

		const destination = path.join(directory, base);
		try {
			await receiveFile(req, destination, config.maxUploadBytes);
		} catch (error) {
			if (error instanceof HttpError && error.status === 413) throw new HttpError(413, 'Upload too large');
			throw new HttpError(400, 'Upload failed');
		}
		return sendJson(res, 201, { ok: true, file: path.relative(MUSIC_DIR, destination) }, OPEN_CORS);
	};

	return {
		listTracks,
		listTracksWithSizes,
		safeJoin,
		streamTrack,
		handleMultipartUpload,
		handlePutUpload,
	};
};
