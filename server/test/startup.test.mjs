// `node server.mjs` itself: the entry point a user, Docker and systemd all run.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const ENTRY = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'server.mjs');

const run = async (env) => {
	const root = await mkdtemp(path.join(os.tmpdir(), 'ws4k-companion-startup-'));
	const child = spawn(process.execPath, [ENTRY], {
		env: {
			PATH: process.env.PATH,
			WS4K_PORT: '0',
			WS4K_MUSIC_DIR: path.join(root, 'music'),
			WS4K_ADS_DIR: path.join(root, 'ads'),
			...env,
		},
		stdio: ['ignore', 'pipe', 'pipe'],
	});
	let output = '';
	child.stdout.on('data', (chunk) => { output += chunk; });
	child.stderr.on('data', (chunk) => { output += chunk; });

	const port = await new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`server did not start:\n${output}`)), 10_000);
		// Wait for the last line of the banner, not just the first: stdout can arrive
		// in more than one chunk.
		const check = () => {
			const match = /listening on http:\/\/0\.0\.0\.0:(\d+)/.exec(output);
			if (match && /Admin (page|is disabled)/.test(output)) {
				clearTimeout(timer);
				resolve(Number(match[1]));
			}
		};
		child.stdout.on('data', check);
		child.once('exit', (code) => reject(new Error(`server exited with ${code}:\n${output}`)));
	});

	const stop = async () => {
		const exited = new Promise((resolve) => { child.once('exit', resolve); });
		child.kill('SIGTERM');
		const code = await exited;
		await rm(root, { recursive: true, force: true });
		return code;
	};
	return { root, port, output: () => output, stop };
};

test('starts from the environment, creates its folders, and stops cleanly', async () => {
	const token = 'startup-secret-token-value-42';
	const server = await run({ WS4K_TOKEN: token });
	try {
		const res = await fetch(`http://127.0.0.1:${server.port}/health`);
		assert.equal(res.status, 200);
		assert.equal((await res.json()).ok, true);

		for (const dir of ['music', 'ads/images', 'ads/clips']) {
			// eslint-disable-next-line no-await-in-loop
			assert.ok((await stat(path.join(server.root, dir))).isDirectory(), dir);
		}

		const admin = await fetch(`http://127.0.0.1:${server.port}/api/ads`, { headers: { Authorization: `Bearer ${token}` } });
		assert.equal(admin.status, 200);
		await fetch(`http://127.0.0.1:${server.port}/api/ads`, { headers: { Authorization: 'Bearer wrong' } });

		assert.ok(!server.output().includes(token), 'the token is never printed');
		assert.match(server.output(), /Admin page/);
	} finally {
		assert.equal(await server.stop(), 0);
	}
});

test('says plainly that admin is off when no token is set', async () => {
	const server = await run({});
	try {
		assert.match(server.output(), /Admin is disabled until WS4K_TOKEN is set/);
		const res = await fetch(`http://127.0.0.1:${server.port}/api/ads`);
		assert.equal(res.status, 403);
	} finally {
		await server.stop();
	}
});

test('refuses to start with a nonsense limit', async () => {
	const child = spawn(process.execPath, [ENTRY], {
		env: { PATH: process.env.PATH, WS4K_PORT: '0', WS4K_MAX_UPLOAD_MB: 'lots' },
		stdio: ['ignore', 'pipe', 'pipe'],
	});
	let output = '';
	child.stderr.on('data', (chunk) => { output += chunk; });
	const code = await new Promise((resolve) => { child.once('exit', resolve); });
	assert.notEqual(code, 0);
	assert.match(output, /WS4K_MAX_UPLOAD_MB must be a positive number/);
});
