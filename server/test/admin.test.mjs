// Admin access control, the admin page's headers, and CORS on the admin API.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { startServer, TOKEN } from './helpers.mjs';

const ADMIN_HTML = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'admin', 'admin.html');

/** Every admin route, with a method that would otherwise do something. */
const ADMIN_ROUTES = [
	['GET', '/api/ads'],
	['PUT', '/api/ads', '{}'],
	['GET', '/api/music'],
	['PUT', '/api/music/track.mp3', 'x'],
	['DELETE', '/api/music/track.mp3'],
	['GET', '/api/ads/files'],
	['PUT', '/api/ads/images/a.png', 'x'],
	['DELETE', '/api/ads/images/a.png'],
	['PUT', '/api/ads/clips/a.mp4', 'x'],
	['DELETE', '/api/ads/clips/a.mp4'],
	['GET', '/api/not-a-route'],
];

describe('admin with no token configured', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: '' }); });
	after(() => server.close());

	test('every admin route answers 403 with a clear reason, whatever is sent', async () => {
		for (const [method, route, body] of ADMIN_ROUTES) {
			for (const token of [undefined, 'anything', '']) {
				// eslint-disable-next-line no-await-in-loop
				const res = await server.request({ method, path: route, body, token });
				assert.equal(res.status, 403, `${method} ${route}`);
				assert.equal(res.json.code, 'admin-disabled', `${method} ${route}`);
				assert.match(res.json.error, /WS4K_TOKEN/);
			}
		}
	});

	test('nothing was written by those attempts', async () => {
		const files = await server.request({ path: '/ads.json' });
		assert.deepEqual([files.json.ticker, files.json.cards, files.json.clips], [[], [], []]);
	});

	test('the admin page itself still loads, so it can explain how to turn admin on', async () => {
		const res = await server.request({ path: '/admin' });
		assert.equal(res.status, 200);
		assert.match(res.text, /WS4K_TOKEN/);
	});
});

describe('admin with a token configured', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN }); });
	after(() => server.close());

	test('no Authorization header is a 401', async () => {
		for (const [method, route, body] of ADMIN_ROUTES) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ method, path: route, body });
			assert.equal(res.status, 401, `${method} ${route}`);
			assert.equal(res.headers['www-authenticate'], 'Bearer');
		}
	});

	test('a wrong token is a 401', async () => {
		for (const token of ['wrong', `${TOKEN}x`, TOKEN.slice(0, -1), ' ']) {
			// eslint-disable-next-line no-await-in-loop
			const res = await server.request({ path: '/api/ads', token });
			assert.equal(res.status, 401, JSON.stringify(token));
		}
		const basic = await server.request({ path: '/api/ads', headers: { Authorization: `Basic ${TOKEN}` } });
		assert.equal(basic.status, 401);
		const bare = await server.request({ path: '/api/ads', headers: { Authorization: TOKEN } });
		assert.equal(bare.status, 401);
	});

	test('the right token is let in', async () => {
		const res = await server.request({ path: '/api/ads', token: TOKEN });
		assert.equal(res.status, 200);
		assert.equal(res.json.version, 1);
	});

	test('the admin API sends no CORS headers, even on a preflight', async () => {
		const get = await server.request({ path: '/api/ads', token: TOKEN, headers: { Origin: 'https://evil.example' } });
		assert.equal(get.headers['access-control-allow-origin'], undefined);

		const denied = await server.request({ path: '/api/ads', headers: { Origin: 'https://evil.example' } });
		assert.equal(denied.headers['access-control-allow-origin'], undefined);

		const preflight = await server.request({
			method: 'OPTIONS',
			path: '/api/ads',
			headers: { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'PUT' },
		});
		assert.equal(preflight.headers['access-control-allow-origin'], undefined);
		assert.equal(preflight.headers['access-control-allow-methods'], undefined);
	});

	test('the token never appears in the server log', async () => {
		await server.request({ path: '/api/ads', token: 'a-wrong-guess' });
		await server.request({ path: '/api/ads', token: TOKEN });
		assert.ok(!server.logs.join('\n').includes(TOKEN));
	});
});

describe('the admin page', () => {
	let server;
	let html;
	before(async () => {
		server = await startServer({ WS4K_TOKEN: TOKEN });
		html = await readFile(ADMIN_HTML, 'utf8');
	});
	after(() => server.close());

	test('is served with a strict Content-Security-Policy that pins the inline code by hash', async () => {
		const res = await server.request({ path: '/admin' });
		assert.equal(res.status, 200);
		assert.equal(res.headers['content-type'], 'text/html; charset=utf-8');
		assert.equal(res.text, html);

		const csp = res.headers['content-security-policy'];
		assert.ok(csp, 'CSP header present');
		assert.ok(!csp.includes('unsafe-inline'));
		assert.ok(!csp.includes('unsafe-eval'));
		assert.match(csp, /default-src 'none'/);
		assert.match(csp, /frame-ancestors 'none'/);

		const hash = (tag) => {
			const body = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(html)[1];
			return `'sha256-${createHash('sha256').update(body).digest('base64')}'`;
		};
		assert.ok(csp.includes(`script-src ${hash('script')}`), 'script hash matches');
		assert.ok(csp.includes(`style-src ${hash('style')}`), 'style hash matches');

		assert.equal(res.headers['x-frame-options'], 'DENY');
		assert.equal(res.headers['cache-control'], 'no-store');
		assert.equal(res.headers['x-content-type-options'], 'nosniff');
	});

	test('is self-contained: no external scripts, styles or fonts', () => {
		assert.ok(!/<script[^>]+src=/i.test(html));
		assert.ok(!/<link[^>]+stylesheet/i.test(html));
		assert.ok(!/https?:\/\//i.test(html.replace(/<!--[\s\S]*?-->/g, '')), 'no absolute URLs');
	});

	test('never renders text as HTML', () => {
		for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function']) {
			assert.ok(!html.includes(sink), `admin.html must not use ${sink}`);
		}
		assert.ok(!/\son[a-z]+="/i.test(html), 'no inline event handler attributes');
		assert.ok(!/\sstyle="/i.test(html), 'no inline style attributes, which the CSP would block');
	});

	test('keeps the token in sessionStorage, never localStorage', () => {
		assert.ok(html.includes('sessionStorage'));
		assert.ok(!html.includes('localStorage'));
	});
});
