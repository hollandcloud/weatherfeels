// The ads manifest: the public projection the app decodes, and strict validation
// of what the admin saves.

import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import { listDir, startServer, TOKEN } from './helpers.mjs';

const putManifest = (server, manifest, extra = {}) => server.request({
	method: 'PUT',
	path: '/api/ads',
	token: TOKEN,
	headers: { 'Content-Type': 'application/json' },
	body: typeof manifest === 'string' ? manifest : JSON.stringify(manifest),
	...extra,
});

const fieldsOf = (res) => (res.json?.fields ?? []).map((f) => f.field);

describe('public manifest', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN }); });
	after(() => server.close());

	test('with nothing saved, /ads.json is an empty v1 manifest', async () => {
		const res = await server.request({ path: '/ads.json' });
		assert.equal(res.status, 200);
		assert.equal(res.headers['access-control-allow-origin'], '*');
		assert.equal(res.json.version, 1);
		assert.equal(typeof res.json.updated, 'string');
		assert.deepEqual([res.json.ticker, res.json.cards, res.json.clips], [[], [], []]);
	});

	test('only enabled items are served, and `enabled` is stripped', async () => {
		await writeFile(path.join(server.adsDir, 'ads.json'), JSON.stringify({
			version: 1,
			updated: '2026-10-26T15:00:00Z',
			ticker: [
				{ id: 't-on', text: 'VISIT GULF COAST MARINE  555-0142', enabled: true },
				{ id: 't-off', text: 'HIDDEN', enabled: false },
				{ id: 't-implicit', text: 'NO FLAG MEANS ENABLED' },
			],
			cards: [
				{
					id: 'c-abc',
					business: 'Gulf Coast Marine',
					headline: 'Boat Repair & Detailing',
					lines: ['Outboards serviced', 'Free estimates'],
					phone: '555-0142',
					footer: 'Open 7 days',
					image: 'ads/images/c-abc.png',
					imageMode: 'beside',
					theme: 'blue',
					seconds: 10,
					enabled: true,
				},
				{ id: 'c-off', business: 'Closed Down', enabled: false },
			],
			clips: [
				{ id: 'v-abc', title: 'Classic spot', file: 'ads/clips/v-abc.mp4', enabled: true },
				{ id: 'v-off', file: 'ads/clips/v-off.mp4', enabled: false },
			],
		}));

		const res = await server.request({ path: '/ads.json' });
		assert.equal(res.status, 200);
		assert.deepEqual(res.json, {
			version: 1,
			updated: '2026-10-26T15:00:00Z',
			ticker: [
				{ id: 't-on', text: 'VISIT GULF COAST MARINE  555-0142' },
				{ id: 't-implicit', text: 'NO FLAG MEANS ENABLED' },
			],
			cards: [{
				id: 'c-abc',
				business: 'Gulf Coast Marine',
				headline: 'Boat Repair & Detailing',
				lines: ['Outboards serviced', 'Free estimates'],
				phone: '555-0142',
				footer: 'Open 7 days',
				image: 'ads/images/c-abc.png',
				imageMode: 'beside',
				theme: 'blue',
				seconds: 10,
			}],
			clips: [{ id: 'v-abc', title: 'Classic spot', file: 'ads/clips/v-abc.mp4' }],
		});
		assert.ok(!res.text.includes('enabled'));

		const health = await server.request({ path: '/health' });
		assert.deepEqual(
			[health.json.ticker, health.json.cards, health.json.clips],
			[2, 1, 1],
		);
	});

	test('the admin manifest includes disabled items, with `enabled` explicit', async () => {
		const res = await server.request({ path: '/api/ads', token: TOKEN });
		assert.equal(res.status, 200);
		assert.deepEqual(res.json.ticker.map((t) => [t.id, t.enabled]), [['t-on', true], ['t-off', false], ['t-implicit', true]]);
		assert.equal(res.json.cards.length, 2);
		assert.equal(res.json.clips.length, 2);
	});

	test('an invalid item in a hand-written file is skipped, not fatal', async () => {
		await writeFile(path.join(server.adsDir, 'ads.json'), JSON.stringify({
			ticker: [{ id: 't-1', text: 'FINE' }, { id: 't-2' }, { text: 'no id' }],
			cards: [{ id: 'c-1', business: 'Fine', theme: 'chartreuse' }],
		}));
		const res = await server.request({ path: '/ads.json' });
		assert.equal(res.status, 200);
		assert.deepEqual(res.json.ticker, [{ id: 't-1', text: 'FINE' }]);
		assert.deepEqual(res.json.cards, []);
		assert.deepEqual(res.json.clips, []);
		assert.equal(typeof res.json.updated, 'string');
	});

	test('a corrupt ads.json serves an empty manifest rather than an error', async () => {
		await writeFile(path.join(server.adsDir, 'ads.json'), '{ not json');
		const res = await server.request({ path: '/ads.json' });
		assert.equal(res.status, 200);
		assert.deepEqual([res.json.ticker, res.json.cards, res.json.clips], [[], [], []]);

		const admin = await server.request({ path: '/api/ads', token: TOKEN });
		assert.equal(admin.status, 500);
		assert.match(admin.json.error, /ads\.json/);
	});
});

describe('PUT /api/ads', () => {
	let server;
	before(async () => { server = await startServer({ WS4K_TOKEN: TOKEN }); });
	after(() => server.close());

	const valid = {
		version: 1,
		ticker: [{ id: 't-abc', text: 'VISIT GULF COAST MARINE  555-0142', enabled: true }],
		cards: [{
			id: 'c-abc',
			business: 'Gulf Coast Marine',
			headline: 'Boat Repair & Detailing',
			lines: ['Outboards serviced', 'Free estimates'],
			phone: '555-0142',
			footer: 'Open 7 days',
			image: 'ads/images/c-abc.png',
			imageMode: 'full',
			theme: 'purple',
			seconds: 12,
			enabled: false,
		}],
		clips: [{ id: 'v-abc', title: 'Classic spot', file: 'ads/clips/v-abc.mp4' }],
	};

	test('a valid manifest is saved atomically and stamped', async () => {
		const res = await putManifest(server, valid);
		assert.equal(res.status, 200);
		assert.match(res.json.updated, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
		assert.equal(res.json.clips[0].enabled, true, 'a missing flag is saved as enabled');

		const onDisk = JSON.parse(await readFile(path.join(server.adsDir, 'ads.json'), 'utf8'));
		assert.deepEqual(onDisk, res.json);
		assert.deepEqual(await listDir(server.adsDir), ['ads.json', 'clips', 'images'], 'no temporary files left behind');

		const pub = await server.request({ path: '/ads.json' });
		assert.deepEqual(pub.json.cards, [], 'the disabled card is not public');
		assert.deepEqual(pub.json.clips, [{ id: 'v-abc', title: 'Classic spot', file: 'ads/clips/v-abc.mp4' }]);
	});

	test('values exactly at every limit are accepted', async () => {
		const res = await putManifest(server, {
			ticker: [{ id: 't-max', text: 'X'.repeat(120) }, { id: 't-emoji', text: '☀'.repeat(120) }],
			cards: [
				{
					id: 'c-max',
					business: 'B'.repeat(40),
					headline: 'H'.repeat(60),
					lines: ['L'.repeat(48), 'L'.repeat(48), 'L'.repeat(48), 'L'.repeat(48)],
					phone: 'P'.repeat(24),
					footer: 'F'.repeat(48),
					seconds: 4,
				},
				{ id: 'c-min', business: 'Min', seconds: 30 },
			],
		});
		assert.equal(res.status, 200, JSON.stringify(res.json));
	});

	test('strings are trimmed and empty optional fields dropped', async () => {
		const res = await putManifest(server, {
			cards: [{ id: 'c-trim', business: '  Shop  ', headline: '   ', lines: ['a', '', '  '] }],
		});
		assert.equal(res.status, 200);
		assert.deepEqual(res.json.cards[0], { id: 'c-trim', business: 'Shop', lines: ['a'], enabled: true });
	});

	test('bad input is rejected with a field error for each problem', async () => {
		const before = await readFile(path.join(server.adsDir, 'ads.json'), 'utf8');
		const res = await putManifest(server, {
			version: 2,
			extra: true,
			ticker: [
				{ text: 'no id' },
				{ id: 't-1' },
				{ id: 't-2', text: 'X'.repeat(121) },
				{ id: 't-3', text: 'line\nbreak' },
				{ id: 'bad id!', text: 'x' },
				{ id: 't-5', text: 'x', enabled: 'yes' },
			],
			cards: [
				{ id: 'c-1' },
				{ id: 'c-2', business: 'B'.repeat(41), headline: 'H'.repeat(61), phone: 'P'.repeat(25), footer: 'F'.repeat(49) },
				{ id: 'c-3', business: 'x', lines: ['a', 'b', 'c', 'd', 'e'] },
				{ id: 'c-4', business: 'x', lines: ['L'.repeat(49)] },
				{ id: 'c-5', business: 'x', imageMode: 'left', theme: 'pink', seconds: 3 },
				{ id: 'c-6', business: 'x', seconds: 31 },
				{ id: 'c-7', business: 'x', seconds: 7.5 },
				{ id: 'c-8', business: 'x', image: 'ads/images/../../etc/passwd.png' },
				{ id: 'c-9', business: 'x', image: '/etc/passwd' },
				{ id: 'c-10', business: 'x', lines: 'not an array' },
				{ id: 'c-11', business: 'x', colour: 'red' },
				{ id: 't-1', business: 'duplicate id' },
			],
			clips: [
				{ id: 'v-1', title: 'no file' },
				{ id: 'v-2', file: 'ads/clips/x.avi' },
				{ id: 'v-3', file: 'ads/images/x.png' },
				{ id: 'v-4', file: 'ads/clips/x.mp4', title: 'T'.repeat(81) },
			],
		});

		assert.equal(res.status, 400);
		assert.equal(typeof res.json.error, 'string');
		const fields = fieldsOf(res);
		for (const expected of [
			'version',
			'extra',
			'ticker[0].id',
			'ticker[1].text',
			'ticker[2].text',
			'ticker[3].text',
			'ticker[4].id',
			'ticker[5].enabled',
			'cards[0].business',
			'cards[1].business',
			'cards[1].headline',
			'cards[1].phone',
			'cards[1].footer',
			'cards[2].lines',
			'cards[3].lines[0]',
			'cards[4].imageMode',
			'cards[4].theme',
			'cards[4].seconds',
			'cards[5].seconds',
			'cards[6].seconds',
			'cards[7].image',
			'cards[8].image',
			'cards[9].lines',
			'cards[10].colour',
			'cards[11].id',
			'clips[0].file',
			'clips[1].file',
			'clips[2].file',
			'clips[3].title',
		]) {
			assert.ok(fields.includes(expected), `expected an error for ${expected}; got ${fields.join(', ')}`);
		}
		for (const field of res.json.fields) assert.equal(typeof field.message, 'string');

		assert.equal(await readFile(path.join(server.adsDir, 'ads.json'), 'utf8'), before, 'nothing was written');
	});

	test('a body that is not a JSON object is rejected', async () => {
		const notJson = await putManifest(server, '{ nope');
		assert.equal(notJson.status, 400);
		assert.deepEqual(fieldsOf(notJson), ['(body)']);

		const array = await putManifest(server, '[]');
		assert.equal(array.status, 400);

		const wrongSection = await putManifest(server, { ticker: {} });
		assert.equal(wrongSection.status, 400);
		assert.deepEqual(fieldsOf(wrongSection), ['ticker']);
	});
});
