// The original music endpoints must behave exactly as they did before v2: the app
// in the field and existing ws4kp installs depend on them.

import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import {
	appMultipart, bytes, startServer, TOKEN,
} from './helpers.mjs';

describe('music endpoints, no token configured', () => {
	let server;
	const track = bytes(4096);

	before(async () => {
		server = await startServer();
		await writeFile(path.join(server.musicDir, 'Catch the Sun.mp3'), track);
		await mkdir(path.join(server.musicDir, 'default'), { recursive: true });
		await writeFile(path.join(server.musicDir, 'default', 'Crisp day.m4a'), bytes(100));
		await writeFile(path.join(server.musicDir, 'notes.txt'), 'not audio');
		await writeFile(path.join(server.musicDir, '.hidden.mp3'), 'hidden');
	});
	after(() => server.close());

	test('GET /playlist.json lists audio, including subfolders, in the ws4kp shape', async () => {
		const res = await server.request({ path: '/playlist.json' });
		assert.equal(res.status, 200);
		assert.equal(res.headers['content-type'], 'application/json');
		assert.equal(res.headers['access-control-allow-origin'], '*');
		assert.deepEqual(res.json, { availableFiles: ['Catch the Sun.mp3', 'default/Crisp day.m4a'] });
	});

	test('GET /music/<file> streams the whole track', async () => {
		const res = await server.request({ path: '/music/Catch%20the%20Sun.mp3' });
		assert.equal(res.status, 200);
		assert.equal(res.headers['content-type'], 'audio/mpeg');
		assert.equal(res.headers['accept-ranges'], 'bytes');
		assert.equal(res.headers['access-control-allow-origin'], '*');
		assert.equal(Number(res.headers['content-length']), track.length);
		assert.deepEqual(res.body, track);
	});

	test('GET /music/<file> honours a byte range', async () => {
		const res = await server.request({ path: '/music/Catch%20the%20Sun.mp3', headers: { Range: 'bytes=100-199' } });
		assert.equal(res.status, 206);
		assert.equal(res.headers['content-range'], `bytes 100-199/${track.length}`);
		assert.deepEqual(res.body, track.subarray(100, 200));
	});

	test('GET /music/<subfolder>/<file> works', async () => {
		const res = await server.request({ path: '/music/default/Crisp%20day.m4a' });
		assert.equal(res.status, 200);
		assert.equal(res.headers['content-type'], 'audio/mp4');
	});

	test('GET /music/ answers 404 for a missing track and 400 for a non-audio one', async () => {
		assert.equal((await server.request({ path: '/music/missing.mp3' })).status, 404);
		assert.equal((await server.request({ path: '/music/notes.txt' })).status, 400);
	});

	test('a malformed percent-escape is a 400, not a crash', async () => {
		const res = await server.request({ path: '/music/%E0.mp3' });
		assert.equal(res.status, 400);
		const health = await server.request({ path: '/health' });
		assert.equal(health.status, 200);
	});

	test('POST /upload accepts the app\'s multipart upload, into its upload path', async () => {
		const data = bytes(70_000, 3);
		const { body, contentType } = appMultipart('New Song.mp3', data, '/music');
		const res = await server.request({
			method: 'POST', path: '/upload', headers: { 'Content-Type': contentType }, body,
		});
		assert.equal(res.status, 201);
		assert.deepEqual(res.json, { ok: true, file: 'music/New Song.mp3' });
		assert.equal(res.headers['access-control-allow-origin'], '*');
		assert.deepEqual(await readFile(path.join(server.musicDir, 'music', 'New Song.mp3')), data);

		const playlist = await server.request({ path: '/playlist.json' });
		assert.ok(playlist.json.availableFiles.includes('music/New Song.mp3'));
	});

	test('POST /upload rejects non-audio and missing file parts as before', async () => {
		const { body, contentType } = appMultipart('evil.sh', Buffer.from('#!/bin/sh'));
		const res = await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': contentType }, body });
		assert.equal(res.status, 415);

		const noBoundary = await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': 'text/plain' }, body: 'x' });
		assert.equal(noBoundary.status, 400);
	});

	test('PUT /music/<path> writes a raw body, creating subfolders', async () => {
		const data = bytes(5000, 9);
		const res = await server.request({ method: 'PUT', path: '/music/custom/Raw%20Put.mp3', body: data });
		assert.equal(res.status, 201);
		assert.deepEqual(res.json, { ok: true, file: 'custom/Raw Put.mp3' });
		assert.deepEqual(await readFile(path.join(server.musicDir, 'custom', 'Raw Put.mp3')), data);
	});

	test('PUT /music/<file> refuses non-audio with 415', async () => {
		const res = await server.request({ method: 'PUT', path: '/music/readme.txt', body: 'x' });
		assert.equal(res.status, 415);
	});

	test('uploads stay open when no token is configured, as before', async () => {
		const res = await server.request({ method: 'PUT', path: '/music/open.mp3', body: 'x' });
		assert.equal(res.status, 201);
	});

	test('GET /health keeps ok and tracks, adds the ad counts, and does not reveal the music folder', async () => {
		const res = await server.request({ path: '/health' });
		assert.equal(res.status, 200);
		assert.equal(res.json.ok, true);
		assert.equal(typeof res.json.tracks, 'number');
		assert.equal('musicDir' in res.json, false, 'an unauthenticated route has no use for a path on the host');
		assert.equal(res.json.ticker, 0);
		assert.equal(res.json.cards, 0);
		assert.equal(res.json.clips, 0);
	});

	test('OPTIONS on a public path still answers the open CORS preflight', async () => {
		const res = await server.request({ method: 'OPTIONS', path: '/upload' });
		assert.equal(res.status, 204);
		assert.equal(res.headers['access-control-allow-origin'], '*');
		assert.equal(res.headers['access-control-allow-methods'], 'GET, POST, PUT, OPTIONS');
	});
});

describe('music endpoints, token configured', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN }); });
	after(() => server.close());

	test('uploads without the token are refused with 401', async () => {
		const put = await server.request({ method: 'PUT', path: '/music/a.mp3', body: 'x' });
		assert.equal(put.status, 401);
		assert.equal(put.text, 'Unauthorized');

		const { body, contentType } = appMultipart('a.mp3', Buffer.from('x'));
		const post = await server.request({ method: 'POST', path: '/upload', headers: { 'Content-Type': contentType }, body });
		assert.equal(post.status, 401);
	});

	test('uploads with a wrong token are refused with 401', async () => {
		const res = await server.request({ method: 'PUT', path: '/music/a.mp3', body: 'x', token: 'nope' });
		assert.equal(res.status, 401);
	});

	test('uploads with the token succeed', async () => {
		const put = await server.request({ method: 'PUT', path: '/music/a.mp3', body: 'x', token: TOKEN });
		assert.equal(put.status, 201);

		const { body, contentType } = appMultipart('b.mp3', Buffer.from('y'));
		const post = await server.request({
			method: 'POST', path: '/upload', headers: { 'Content-Type': contentType }, body, token: TOKEN,
		});
		assert.equal(post.status, 201);
	});

	test('reading music never needs the token', async () => {
		assert.equal((await server.request({ path: '/playlist.json' })).status, 200);
		assert.equal((await server.request({ path: '/music/a.mp3' })).status, 200);
	});
});
