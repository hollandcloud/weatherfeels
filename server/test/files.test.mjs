// Ad images and clips: streamed upload, delete, range requests, path safety and
// the body size limit.

import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import {
	appMultipart, bytes, listDir, startServer, TOKEN,
} from './helpers.mjs';

/** Split a buffer into chunks, so it goes over the wire with chunked encoding. */
const chunked = (buffer, size = 16 * 1024) => {
	const parts = [];
	for (let i = 0; i < buffer.length; i += size) parts.push(buffer.subarray(i, i + size));
	return parts;
};

describe('ad file upload and delete', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN }); });
	after(() => server.close());

	for (const [kind, folder, name, type] of [
		['image', 'images', 'c-abc.png', 'image/png'],
		['image', 'images', 'c-abc 2.JPEG', 'image/jpeg'],
		['clip', 'clips', 'v-abc.mp4', 'video/mp4'],
		['clip', 'clips', 'v-abc.mov', 'video/quicktime'],
	]) {
		test(`${kind} ${name}: streamed upload, serve, list, delete`, async () => {
			const data = bytes(300_000, name.length);
			const encoded = encodeURIComponent(name);

			const put = await server.request({
				method: 'PUT', path: `/api/ads/${folder}/${encoded}`, token: TOKEN, chunks: chunked(data),
			});
			assert.equal(put.status, 201, put.text);
			assert.deepEqual(put.json, { ok: true, name, path: `ads/${folder}/${name}`, size: data.length });
			assert.deepEqual(await readFile(path.join(server.adsDir, folder, name)), data);

			const get = await server.request({ path: `/ads/${folder}/${encoded}` });
			assert.equal(get.status, 200);
			assert.equal(get.headers['content-type'], type);
			assert.equal(get.headers['access-control-allow-origin'], '*');
			assert.deepEqual(get.body, data);

			const list = await server.request({ path: '/api/ads/files', token: TOKEN });
			assert.ok(list.json[kind === 'image' ? 'images' : 'clips'].some((f) => f.name === name && f.size === data.length));

			const del = await server.request({ method: 'DELETE', path: `/api/ads/${folder}/${encoded}`, token: TOKEN });
			assert.equal(del.status, 200);
			assert.equal((await server.request({ path: `/ads/${folder}/${encoded}` })).status, 404);
			assert.equal((await server.request({ method: 'DELETE', path: `/api/ads/${folder}/${encoded}`, token: TOKEN })).status, 404);

			assert.deepEqual((await listDir(path.join(server.adsDir, folder))).filter((f) => f.startsWith('.')), [], 'no temporaries left');
		});
	}

	test('a replacement upload swaps the file in whole', async () => {
		await server.request({ method: 'PUT', path: '/api/ads/images/swap.png', token: TOKEN, body: bytes(1000, 1) });
		const next = bytes(2000, 2);
		await server.request({ method: 'PUT', path: '/api/ads/images/swap.png', token: TOKEN, body: next });
		assert.deepEqual(await readFile(path.join(server.adsDir, 'images', 'swap.png')), next);
	});

	test('the wrong kind of file is refused with 415', async () => {
		for (const route of ['/api/ads/images/x.svg', '/api/ads/images/x.mp4', '/api/ads/clips/x.avi', '/api/ads/clips/x.png', '/api/music/x.exe']) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ method: 'PUT', path: route, token: TOKEN, body: 'x' });
			assert.equal(res.status, 415, route);
		}
		assert.equal((await server.request({ path: '/ads/images/x.svg' })).status, 415);
	});

	test('names outside [A-Za-z0-9._ -] are refused', async () => {
		for (const name of ['caf%C3%A9.png', 'a%3Bb.png', 'a%22b.png', 'a%3Cscript%3E.png', '%20lead.png']) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ method: 'PUT', path: `/api/ads/images/${name}`, token: TOKEN, body: 'x' });
			assert.equal(res.status, 400, name);
		}
	});

	test('music: upload, list with sizes, and delete through the admin API', async () => {
		const data = bytes(1234);
		const put = await server.request({ method: 'PUT', path: '/api/music/Admin%20Track.mp3', token: TOKEN, body: data });
		assert.equal(put.status, 201);

		// One in a subfolder, as the app's own uploads are.
		const { body, contentType } = appMultipart('From App.mp3', bytes(10), '/music');
		await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': contentType }, body, token: TOKEN });

		const list = await server.request({ path: '/api/music', token: TOKEN });
		assert.deepEqual(list.json.tracks.map((t) => [t.name, t.size]), [['Admin Track.mp3', 1234], ['music/From App.mp3', 10]]);

		const del = await server.request({ method: 'DELETE', path: '/api/music/music/From%20App.mp3', token: TOKEN });
		assert.equal(del.status, 200);
		const del2 = await server.request({ method: 'DELETE', path: '/api/music/Admin%20Track.mp3', token: TOKEN });
		assert.equal(del2.status, 200);
		assert.deepEqual((await server.request({ path: '/playlist.json' })).json.availableFiles, []);

		const missing = await server.request({ method: 'DELETE', path: '/api/music/nope.mp3', token: TOKEN });
		assert.equal(missing.status, 404);
	});
});

describe('range requests on clips', () => {
	let server;
	const clip = bytes(10_000, 5);
	before(async () => {
		server = await startServer({ WS4K_TOKEN: TOKEN });
		await writeFile(path.join(server.adsDir, 'clips', 'reel.mp4'), clip);
	});
	after(() => server.close());

	const get = (range, method = 'GET') => server.request({ method, path: '/ads/clips/reel.mp4', headers: range ? { Range: range } : {} });

	test('a full request advertises range support', async () => {
		const res = await get();
		assert.equal(res.status, 200);
		assert.equal(res.headers['accept-ranges'], 'bytes');
		assert.equal(Number(res.headers['content-length']), clip.length);
	});

	test('AVPlayer\'s two-byte probe', async () => {
		const res = await get('bytes=0-1');
		assert.equal(res.status, 206);
		assert.equal(res.headers['content-range'], `bytes 0-1/${clip.length}`);
		assert.equal(Number(res.headers['content-length']), 2);
		assert.deepEqual(res.body, clip.subarray(0, 2));
	});

	test('a middle range, an open-ended range and a suffix range', async () => {
		const middle = await get('bytes=1000-1999');
		assert.equal(middle.status, 206);
		assert.deepEqual(middle.body, clip.subarray(1000, 2000));

		const open = await get('bytes=9000-');
		assert.equal(open.status, 206);
		assert.equal(open.headers['content-range'], `bytes 9000-9999/${clip.length}`);
		assert.deepEqual(open.body, clip.subarray(9000));

		const suffix = await get('bytes=-500');
		assert.equal(suffix.status, 206);
		assert.equal(suffix.headers['content-range'], `bytes 9500-9999/${clip.length}`);
		assert.deepEqual(suffix.body, clip.subarray(9500));
	});

	test('an end past the file is clamped to the last byte', async () => {
		const res = await get('bytes=9990-20000');
		assert.equal(res.status, 206);
		assert.equal(res.headers['content-range'], `bytes 9990-9999/${clip.length}`);
	});

	test('an unsatisfiable range is a 416', async () => {
		const res = await get(`bytes=${clip.length}-`);
		assert.equal(res.status, 416);
		assert.equal(res.headers['content-range'], `bytes */${clip.length}`);
		assert.equal((await get('bytes=500-100')).status, 416);
	});

	test('HEAD answers with headers only', async () => {
		const res = await get('bytes=0-99', 'HEAD');
		assert.equal(res.status, 206);
		assert.equal(Number(res.headers['content-length']), 100);
		assert.equal(res.body.length, 0);
	});
});

describe('path traversal', () => {
	let server;
	before(async () => {
		server = await startServer({ WS4K_TOKEN: TOKEN });
		// Bait one level up from every served directory.
		for (const name of ['secret.png', 'secret.mp4', 'secret.mp3']) {
			// eslint-disable-next-line no-await-in-loop
			await writeFile(path.join(server.root, name), 'TOP SECRET');
		}
		await writeFile(path.join(server.adsDir, 'images', '.hidden.png'), 'HIDDEN BAIT');
		await writeFile(path.join(server.adsDir, 'clips', '.hidden.mp4'), 'HIDDEN BAIT');
		await writeFile(path.join(server.musicDir, '.hidden.mp3'), 'HIDDEN BAIT');
	});
	after(() => server.close());

	const attempts = (ext) => [
		`../secret.${ext}`,
		`../../secret.${ext}`,
		`..%2Fsecret.${ext}`,
		`..%2F..%2Fsecret.${ext}`,
		`%2e%2e%2fsecret.${ext}`,
		`%2E%2E/secret.${ext}`,
		`..%5Csecret.${ext}`,
		`%2Fetc%2Fpasswd.${ext}`,
		`%2F..%2Fsecret.${ext}`,
		`.hidden.${ext}`,
		'..',
		'.',
		`sub%00.${ext}`,
	];

	const routes = [
		['GET', '/ads/images/', 'png'],
		['GET', '/ads/clips/', 'mp4'],
		['HEAD', '/ads/clips/', 'mp4'],
		['GET', '/music/', 'mp3'],
		['PUT', '/music/', 'mp3'],
		['PUT', '/api/ads/images/', 'png'],
		['DELETE', '/api/ads/images/', 'png'],
		['PUT', '/api/ads/clips/', 'mp4'],
		['DELETE', '/api/ads/clips/', 'mp4'],
		['PUT', '/api/music/', 'mp3'],
		['DELETE', '/api/music/', 'mp3'],
	];

	for (const [method, prefix, ext] of routes) {
		test(`${method} ${prefix}<traversal> is rejected`, async () => {
			for (const attempt of attempts(ext)) {
				// eslint-disable-next-line no-await-in-loop
				const res = await server.request({
					method, path: prefix + attempt, token: TOKEN, body: method === 'PUT' ? 'PWNED' : undefined,
				});
				assert.ok(res.status === 400 || res.status === 404, `${method} ${prefix}${attempt} answered ${res.status}`);
				assert.ok(!res.text.includes('TOP SECRET') && !res.text.includes('HIDDEN BAIT'), `${method} ${prefix}${attempt} leaked a file`);
			}
			// The bait is untouched and nothing new appeared beside it.
			assert.deepEqual(await listDir(server.root), ['ads', 'music', 'secret.mp3', 'secret.mp4', 'secret.png']);
			for (const name of ['secret.png', 'secret.mp4', 'secret.mp3']) {
				// eslint-disable-next-line no-await-in-loop
				assert.equal(await readFile(path.join(server.root, name), 'utf8'), 'TOP SECRET');
			}
		});
	}

	test('a multipart upload cannot escape through its path field or file name', async () => {
		const escape = appMultipart('evil.mp3', Buffer.from('PWNED'), '../../');
		const res = await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': escape.contentType }, body: escape.body, token: TOKEN });
		assert.equal(res.status, 400);

		const named = appMultipart('../../evil.mp3', Buffer.from('PWNED'), '/');
		const res2 = await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': named.contentType }, body: named.body, token: TOKEN });
		assert.equal(res2.status, 201);
		assert.equal(res2.json.file, 'evil.mp3', 'only the basename is used');
		assert.ok(!(await listDir(server.root)).includes('evil.mp3'));
	});
});

describe('body size limit', () => {
	let server;
	const MiB = 1024 * 1024;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN, WS4K_MAX_UPLOAD_MB: '1' }); });
	after(() => server.close());

	const noTemporaries = async () => {
		for (const dir of [server.musicDir, path.join(server.adsDir, 'images'), path.join(server.adsDir, 'clips')]) {
			// eslint-disable-next-line no-await-in-loop
			assert.deepEqual((await listDir(dir)).filter((f) => f.startsWith('.upload-')), [], `temporaries in ${dir}`);
		}
	};

	test('exactly the limit is accepted', async () => {
		const res = await server.request({ method: 'PUT', path: '/api/ads/clips/exact.mp4', token: TOKEN, body: bytes(MiB) });
		assert.equal(res.status, 201);
	});

	// A client announcing a 2 GB body, of which only the first kilobyte is ever sent:
	// the server must answer from the headers alone, without waiting for the rest.
	const HUGE = String(2 * 1024 * MiB);

	test('a declared length over the limit is refused before the body is read', async () => {
		for (const route of ['/api/ads/clips/big.mp4', '/api/ads/images/big.png', '/api/music/big.mp3']) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({
				method: 'PUT', path: route, token: TOKEN, headers: { 'Content-Length': HUGE }, body: bytes(1024),
			});
			assert.equal(res.status, 413, route);
			assert.match(res.json.error, /1 MB/);
		}
		const legacy = await server.request({
			method: 'PUT', path: '/music/big.mp3', token: TOKEN, headers: { 'Content-Length': HUGE }, body: bytes(1024),
		});
		assert.equal(legacy.status, 413);
		assert.equal(legacy.text, 'Upload too large');

		const { contentType } = appMultipart('big.mp3', Buffer.alloc(0));
		const multipart = await server.request({
			method: 'POST', path: '/upload', token: TOKEN, headers: { 'Content-Type': contentType, 'Content-Length': HUGE }, body: bytes(1024),
		});
		assert.equal(multipart.status, 413);
		assert.equal(multipart.text, 'Upload too large');
		await noTemporaries();
	});

	test('a client sending its whole oversized body still gets the 413, not a reset', async () => {
		for (let i = 0; i < 10; i += 1) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ method: 'PUT', path: '/api/ads/clips/over.mp4', token: TOKEN, body: bytes(MiB + 4096) });
			assert.equal(res.status, 413);
		}
		await noTemporaries();
	});

	test('with Expect: 100-continue, a refused upload is answered before any body is sent', async () => {
		const refused = await server.request({
			method: 'PUT', path: '/api/ads/clips/big.mp4', token: TOKEN, expectContinue: true, body: bytes(MiB + 1),
		});
		assert.equal(refused.status, 413);
		assert.equal(refused.continued, false, 'the server never asked for the body');

		const unauthorised = await server.request({
			method: 'PUT', path: '/api/ads/clips/small.mp4', token: 'wrong', expectContinue: true, body: bytes(1000),
		});
		assert.equal(unauthorised.status, 401);
		assert.equal(unauthorised.continued, false);

		const accepted = await server.request({
			method: 'PUT', path: '/api/ads/clips/small.mp4', token: TOKEN, expectContinue: true, body: bytes(1000),
		});
		assert.equal(accepted.status, 201);
		assert.equal(accepted.continued, true);

		const legacy = await server.request({
			method: 'PUT', path: '/music/small.mp3', token: TOKEN, expectContinue: true, body: bytes(1000),
		});
		assert.equal(legacy.status, 201);
		assert.equal(legacy.continued, true);
	});

	test('a streamed body that grows past the limit is cut off and cleaned up', async () => {
		for (const route of ['/api/ads/clips/stream.mp4', '/music/stream.mp3']) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ method: 'PUT', path: route, token: TOKEN, chunks: chunked(bytes(MiB + 200_000), 64 * 1024) });
			assert.equal(res.status, 413, route);
		}
		// Give the server a moment to finish unlinking.
		await new Promise((resolve) => { setTimeout(resolve, 50); });
		await noTemporaries();
		assert.ok(!(await listDir(path.join(server.adsDir, 'clips'))).includes('stream.mp4'));
		assert.ok(!(await listDir(server.musicDir)).includes('stream.mp3'));
	});

	test('JSON bodies are capped at 1 MB regardless of the upload limit', async () => {
		const big = JSON.stringify({ ticker: [{ id: 't', text: 'x'.repeat(MiB) }] });
		const declared = await server.request({
			method: 'PUT', path: '/api/ads', token: TOKEN, headers: { 'Content-Type': 'application/json' }, body: big,
		});
		assert.equal(declared.status, 413);

		const streamed = await server.request({
			method: 'PUT', path: '/api/ads', token: TOKEN, headers: { 'Content-Type': 'application/json' }, chunks: chunked(Buffer.from(big)),
		});
		assert.equal(streamed.status, 413);
	});

	test('the server keeps serving after refusing', async () => {
		assert.equal((await server.request({ path: '/health' })).status, 200);
	});
});
