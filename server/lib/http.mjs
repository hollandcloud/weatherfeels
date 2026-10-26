// HTTP plumbing shared by every route: responses, bodies, files and ranges.

import { randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { open, rename, stat, unlink } from 'node:fs/promises';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

/** An error that maps straight onto a response. */
export class HttpError extends Error {
	constructor(status, message, { headers = {}, details } = {}) {
		super(message);
		this.status = status;
		this.headers = headers;
		this.details = details;
	}
}

/**
 * Public, read-only resources may be fetched cross-origin, as ws4kp's are.
 * Nothing under /api/ ever gets this.
 */
export const OPEN_CORS = { 'Access-Control-Allow-Origin': '*' };

const BASE_HEADERS = { 'X-Content-Type-Options': 'nosniff' };

export const sendJson = (res, status, body, headers = {}) => {
	const payload = JSON.stringify(body);
	res.writeHead(status, {
		...BASE_HEADERS,
		'Content-Type': 'application/json',
		'Content-Length': Buffer.byteLength(payload),
		...headers,
	});
	res.end(payload);
};

export const sendText = (res, status, body, headers = {}) => {
	res.writeHead(status, {
		...BASE_HEADERS,
		'Content-Type': 'text/plain; charset=utf-8',
		'Content-Length': Buffer.byteLength(body),
		...headers,
	});
	res.end(body);
};

/** `decodeURIComponent` that returns null instead of throwing on bad escapes. */
export const safeDecode = (value) => {
	try {
		return decodeURIComponent(value);
	} catch {
		return null;
	}
};

const megabytes = (bytes) => {
	const mb = bytes / (1024 * 1024);
	return Number.isInteger(mb) ? `${mb} MB` : `${mb.toFixed(1)} MB`;
};

const tooLarge = (limit) => new HttpError(413, `Body is larger than the ${megabytes(limit)} limit`);

/** Reject a body up front when its declared length is already over the limit. */
const checkDeclaredLength = (req, limit) => {
	const declared = req.headers['content-length'];
	if (declared !== undefined && Number(declared) > limit) throw tooLarge(limit);
};

/**
 * Tell a client that sent `Expect: 100-continue` to go ahead with its body.
 *
 * The server only says so once a handler has decided to read the body. A request
 * refused before that point (401, 413, 415) is answered without the client ever
 * sending a byte of it, which is what makes a refused 2 GB `curl -T` instant.
 */
export const allowBody = (req) => {
	if (req.sendContinue) {
		const send = req.sendContinue;
		req.sendContinue = null;
		send();
	}
};

// How much of an unwanted body is read and thrown away before an early error
// response is sent.
const DRAIN_BYTES = 16 * 1024 * 1024;
const DRAIN_MS = 10_000;

/**
 * Before answering a request whose body has not been read, read and discard what
 * is left of it — within limits.
 *
 * Node closes the connection when a response finishes before its request has, and
 * the kernel resets a connection that still has unread data waiting. A client
 * that is busy sending would then lose the 413 it was sent and see only
 * "connection reset". Draining first means a modestly oversized body gets a clean
 * answer; past DRAIN_BYTES or DRAIN_MS the answer goes out regardless, and the
 * connection with it. A body declared bigger than DRAIN_BYTES is not waited for
 * at all: it would never finish in time, so waiting only delays the answer.
 */
export const drainBody = (req) => new Promise((resolve) => {
	// A client still waiting for 100 Continue will never send the body.
	if (req.complete || req.destroyed || req.sendContinue || Number(req.headers['content-length']) > DRAIN_BYTES) {
		resolve();
		return;
	}
	let drained = 0;
	const done = () => {
		clearTimeout(timer);
		req.off('data', onData);
		resolve();
	};
	const onData = (chunk) => {
		drained += chunk.length;
		if (drained > DRAIN_BYTES) done();
	};
	const timer = setTimeout(done, DRAIN_MS);
	timer.unref();
	req.on('data', onData);
	req.once('end', done);
	req.once('close', done);
	req.once('error', done);
	req.resume();
});

/**
 * Consume a request body chunk by chunk, enforcing `limit` as the bytes arrive.
 *
 * The request is never destroyed here: tearing it down would close the socket
 * before the error response could be written, and the client would see a reset
 * instead of a 413. Once something goes wrong the rest of the body is left
 * flowing, for the error handler to drain before it answers.
 */
const consumeBody = (req, limit, { onChunk, onEnd, onAbort }) => new Promise((resolve, reject) => {
	allowBody(req);
	let received = 0;
	let settled = false;

	const fail = (error) => {
		if (settled) return;
		settled = true;
		req.off('data', onData);
		req.resume();
		onAbort?.();
		reject(error);
	};

	const onData = (chunk) => {
		received += chunk.length;
		if (received > limit) {
			fail(tooLarge(limit));
			return;
		}
		try {
			onChunk(chunk);
		} catch (error) {
			fail(error);
		}
	};

	req.on('data', onData);
	req.once('end', () => {
		if (settled) return;
		Promise.resolve(onEnd(received)).then((value) => {
			if (settled) return;
			settled = true;
			resolve(value);
		}, fail);
	});
	req.once('error', () => fail(new HttpError(400, 'Upload failed')));
	req.once('close', () => {
		if (!req.complete) fail(new HttpError(400, 'Upload was interrupted'));
	});
});

/** Read a JSON body of at most `limit` bytes. */
export const readJsonBody = async (req, limit) => {
	checkDeclaredLength(req, limit);
	const chunks = [];
	const raw = await consumeBody(req, limit, {
		onChunk: (chunk) => chunks.push(chunk),
		onEnd: () => Buffer.concat(chunks).toString('utf8'),
	});
	try {
		return JSON.parse(raw);
	} catch (error) {
		throw new HttpError(400, 'Body is not valid JSON', {
			details: { fields: [{ field: '(body)', message: error.message }] },
		});
	}
};

/**
 * Stream a request body to `destination`, never holding it in memory.
 *
 * The bytes go to a hidden temporary file in the same directory and are renamed
 * into place only once complete, so a failed or oversized upload never leaves a
 * truncated file behind or clobbers the one it was replacing. Same directory
 * matters: a rename across devices, such as between Docker volumes, would fail.
 */
export const receiveFile = async (req, destination, limit) => {
	checkDeclaredLength(req, limit);

	const temporary = path.join(path.dirname(destination), `.upload-${randomUUID()}.part`);
	const out = createWriteStream(temporary, { flags: 'wx' });
	let outError = null;
	out.on('error', (error) => { outError = error; });

	// Unlink only once the stream has closed: if the file is still being opened, an
	// earlier unlink would run first and the open would then recreate it.
	let discarded = false;
	const discard = () => {
		if (discarded) return;
		discarded = true;
		const remove = () => unlink(temporary).catch(() => {});
		if (out.closed) {
			remove();
		} else {
			out.once('close', remove);
			out.destroy();
		}
	};

	try {
		return await consumeBody(req, limit, {
			onChunk: (chunk) => {
				if (outError) throw outError;
				if (!out.write(chunk)) {
					req.pause();
					out.once('drain', () => req.resume());
				}
			},
			onEnd: (received) => new Promise((resolve, reject) => {
				if (outError) return reject(outError);
				out.once('error', reject);
				out.end(() => {
					rename(temporary, destination).then(() => resolve(received), reject);
				});
				return undefined;
			}),
			onAbort: discard,
		});
	} catch (error) {
		discard();
		throw error;
	}
};

/**
 * Write a file atomically: temporary file, fsync, rename.
 *
 * Readers either see the old file or the new one, never half of either.
 */
export const writeFileAtomic = async (destination, contents) => {
	const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}-${randomUUID()}.tmp`);
	const handle = await open(temporary, 'wx', 0o644);
	try {
		await handle.writeFile(contents);
		await handle.sync();
	} finally {
		await handle.close();
	}
	try {
		await rename(temporary, destination);
	} catch (error) {
		await unlink(temporary).catch(() => {});
		throw error;
	}
};

/**
 * Parse a single-range `Range` header against a file of `size` bytes.
 *
 * Returns `{ start, end }` for a satisfiable range, `null` for an unsatisfiable one
 * (416), and `undefined` when the header should be ignored and the whole file sent,
 * which is what RFC 9110 asks for with multiple or malformed ranges.
 */
export const parseRange = (header, size) => {
	const match = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
	if (!match || (match[1] === '' && match[2] === '')) return undefined;

	if (match[1] === '') {
		// Suffix range: the last N bytes.
		const length = Number(match[2]);
		if (length === 0 || size === 0) return null;
		return { start: Math.max(0, size - length), end: size - 1 };
	}

	const start = Number(match[1]);
	const requestedEnd = match[2] === '' ? size - 1 : Number(match[2]);
	if (start >= size || start > requestedEnd) return null;
	return { start, end: Math.min(requestedEnd, size - 1) };
};

/**
 * Send a file, honouring range requests so AVPlayer can seek and probe.
 *
 * `target` must already be validated; this only checks it is a regular file.
 */
export const streamFile = async (req, res, target, type, headers = {}) => {
	let info;
	try {
		info = await stat(target);
	} catch {
		return sendText(res, 404, 'Not found', headers);
	}
	if (!info.isFile()) return sendText(res, 404, 'Not found', headers);

	const common = {
		...BASE_HEADERS,
		'Content-Type': type,
		'Accept-Ranges': 'bytes',
		'Last-Modified': info.mtime.toUTCString(),
		...headers,
	};
	const head = req.method === 'HEAD';

	const range = req.headers.range ? parseRange(req.headers.range, info.size) : undefined;
	if (range === null) {
		res.writeHead(416, { ...common, 'Content-Range': `bytes */${info.size}`, 'Content-Length': 0 });
		return res.end();
	}

	if (range) {
		res.writeHead(206, {
			...common,
			'Content-Length': range.end - range.start + 1,
			'Content-Range': `bytes ${range.start}-${range.end}/${info.size}`,
		});
		if (head) return res.end();
		return pipeline(createReadStream(target, { start: range.start, end: range.end }), res).catch(() => {});
	}

	res.writeHead(200, { ...common, 'Content-Length': info.size });
	if (head) return res.end();
	return pipeline(createReadStream(target), res).catch(() => {});
};
