// The ads manifest: schema v1, validation, and the public projection.
//
// The app decodes `/ads.json` directly, and the same file can be served by any
// static web host, so the public shape here is a contract. Change it only together
// with the app, and bump `version` if it ever stops being backwards compatible.
//
// On disk the manifest is the same shape plus `"enabled": true|false` on every
// item. The public projection drops disabled items and the flag itself; a
// hand-written manifest without `enabled` counts every item as enabled.

import { readFile, stat } from 'node:fs/promises';

import { isValidFileName } from './names.mjs';

export const VERSION = 1;

export const LIMITS = {
	id: 64,
	tickerText: 120,
	business: 40,
	headline: 60,
	lines: 4,
	line: 48,
	phone: 24,
	footer: 48,
	clipTitle: 80,
	secondsMin: 4,
	secondsMax: 30,
};

export const THEMES = ['blue', 'red', 'green', 'gold', 'purple'];
export const IMAGE_MODES = ['beside', 'full'];

/** Defaults the app applies when a field is absent. The server never injects them. */
export const DEFAULTS = { imageMode: 'beside', theme: 'blue', seconds: 10 };

const ID_PATTERN = /^[A-Za-z0-9._-]+$/;
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

const SECTIONS = {
	ticker: ['id', 'text', 'enabled'],
	cards: ['id', 'business', 'headline', 'lines', 'phone', 'footer', 'image', 'imageMode', 'theme', 'seconds', 'enabled'],
	clips: ['id', 'title', 'file', 'enabled'],
};

const TOP_LEVEL = ['version', 'updated', 'ticker', 'cards', 'clips'];

const isPlainObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** Length in characters, not UTF-16 code units, so an emoji counts once. */
const characters = (value) => [...value].length;

/**
 * Validate one item of `section`. Returns `{ value, errors }`, where `value` is the
 * item normalised (strings trimmed, empty optional fields dropped) with the keys in
 * schema order, including `enabled` when it was present.
 */
export const validateItem = (section, item, prefix) => {
	const errors = [];
	const error = (field, message) => errors.push({ field: `${prefix}.${field}`, message });

	if (!isPlainObject(item)) {
		return { value: null, errors: [{ field: prefix, message: 'must be an object' }] };
	}

	const allowed = SECTIONS[section];
	for (const key of Object.keys(item)) {
		if (!allowed.includes(key)) error(key, 'is not a recognised field');
	}

	const value = {};

	/** A string field: trimmed, length-checked, and dropped when empty and optional. */
	const string = (key, { required = false, max }) => {
		const raw = item[key];
		if (raw === undefined || raw === null) {
			if (required) error(key, 'is required');
			return;
		}
		if (typeof raw !== 'string') {
			error(key, 'must be a string');
			return;
		}
		const trimmed = raw.trim();
		if (trimmed === '') {
			if (required) error(key, 'must not be empty');
			return;
		}
		if (CONTROL_CHARACTERS.test(trimmed)) {
			error(key, 'must not contain line breaks or control characters');
			return;
		}
		if (max !== undefined && characters(trimmed) > max) {
			error(key, `must be at most ${max} characters`);
			return;
		}
		value[key] = trimmed;
	};

	// `id` comes first in every section.
	string('id', { required: true, max: LIMITS.id });
	if (value.id !== undefined && !ID_PATTERN.test(value.id)) {
		error('id', 'may only use letters, digits, dots, dashes and underscores');
		delete value.id;
	}

	if (section === 'ticker') {
		string('text', { required: true, max: LIMITS.tickerText });
	}

	if (section === 'cards') {
		string('business', { required: true, max: LIMITS.business });
		string('headline', { max: LIMITS.headline });

		if (item.lines !== undefined && item.lines !== null) {
			if (!Array.isArray(item.lines)) {
				error('lines', 'must be an array of strings');
			} else {
				const lines = [];
				item.lines.forEach((line, index) => {
					if (typeof line !== 'string') {
						error(`lines[${index}]`, 'must be a string');
						return;
					}
					const trimmed = line.trim();
					if (trimmed === '') return;
					if (CONTROL_CHARACTERS.test(trimmed)) {
						error(`lines[${index}]`, 'must not contain line breaks or control characters');
					} else if (characters(trimmed) > LIMITS.line) {
						error(`lines[${index}]`, `must be at most ${LIMITS.line} characters`);
					}
					lines.push(trimmed);
				});
				if (lines.length > LIMITS.lines) {
					error('lines', `may have at most ${LIMITS.lines} entries`);
				}
				if (lines.length > 0) value.lines = lines;
			}
		}

		string('phone', { max: LIMITS.phone });
		string('footer', { max: LIMITS.footer });

		string('image', {});
		if (value.image !== undefined) {
			const name = value.image.startsWith('ads/images/') ? value.image.slice('ads/images/'.length) : null;
			if (!name || !isValidFileName(name, 'image')) {
				error('image', 'must be "ads/images/<file>" naming a .png, .jpg, .jpeg, .gif or .webp file');
				delete value.image;
			}
		}

		if (item.imageMode !== undefined && item.imageMode !== null) {
			if (!IMAGE_MODES.includes(item.imageMode)) error('imageMode', `must be one of ${IMAGE_MODES.join(', ')}`);
			else value.imageMode = item.imageMode;
		}
		if (item.theme !== undefined && item.theme !== null) {
			if (!THEMES.includes(item.theme)) error('theme', `must be one of ${THEMES.join(', ')}`);
			else value.theme = item.theme;
		}
		if (item.seconds !== undefined && item.seconds !== null) {
			const { seconds } = item;
			if (!Number.isInteger(seconds) || seconds < LIMITS.secondsMin || seconds > LIMITS.secondsMax) {
				error('seconds', `must be a whole number from ${LIMITS.secondsMin} to ${LIMITS.secondsMax}`);
			} else {
				value.seconds = seconds;
			}
		}
	}

	if (section === 'clips') {
		string('title', { max: LIMITS.clipTitle });
		string('file', { required: true });
		if (value.file !== undefined) {
			const name = value.file.startsWith('ads/clips/') ? value.file.slice('ads/clips/'.length) : null;
			if (!name || !isValidFileName(name, 'clip')) {
				error('file', 'must be "ads/clips/<file>" naming a .mp4, .m4v or .mov file');
				delete value.file;
			}
		}
	}

	if (item.enabled !== undefined) {
		if (typeof item.enabled !== 'boolean') error('enabled', 'must be true or false');
		else value.enabled = item.enabled;
	}

	return { value, errors };
};

/**
 * Validate a whole manifest as sent to `PUT /api/ads`.
 *
 * Returns `{ manifest, errors }`. The manifest is normalised and has `enabled` set
 * explicitly on every item; `updated` is left for the caller to stamp.
 */
export const validateManifest = (input) => {
	if (!isPlainObject(input)) {
		return { manifest: null, errors: [{ field: '(root)', message: 'must be a JSON object' }] };
	}

	const errors = [];
	for (const key of Object.keys(input)) {
		if (!TOP_LEVEL.includes(key)) errors.push({ field: key, message: 'is not a recognised field' });
	}
	if (input.version !== undefined && input.version !== VERSION) {
		errors.push({ field: 'version', message: `must be ${VERSION}` });
	}
	if (input.updated !== undefined && input.updated !== null && typeof input.updated !== 'string') {
		errors.push({ field: 'updated', message: 'must be a string' });
	}

	const manifest = { version: VERSION, updated: null, ticker: [], cards: [], clips: [] };
	const seen = new Map();

	for (const section of Object.keys(SECTIONS)) {
		const items = input[section];
		if (items === undefined || items === null) continue;
		if (!Array.isArray(items)) {
			errors.push({ field: section, message: 'must be an array' });
			continue;
		}
		items.forEach((item, index) => {
			const prefix = `${section}[${index}]`;
			const result = validateItem(section, item, prefix);
			errors.push(...result.errors);
			if (!result.value) return;

			const { id } = result.value;
			if (id !== undefined) {
				if (seen.has(id)) {
					errors.push({ field: `${prefix}.id`, message: `duplicates ${seen.get(id)}.id` });
				} else {
					seen.set(id, prefix);
				}
			}
			manifest[section].push({ ...result.value, enabled: result.value.enabled ?? true });
		});
	}

	return { manifest: errors.length ? null : manifest, errors };
};

/** ISO-8601 to the second, as in the schema's example. */
export const timestamp = (date = new Date()) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');

/**
 * An empty manifest, served before anything has been saved. `updated` is the epoch
 * rather than absent, so a decoder that treats it as required still succeeds.
 */
export const emptyManifest = () => ({
	version: VERSION,
	updated: timestamp(new Date(0)),
	ticker: [],
	cards: [],
	clips: [],
});

/**
 * Read the stored manifest. A missing file is an empty manifest; unparseable JSON
 * throws, with the parser's message, so the caller can decide how loud to be.
 */
export const readStoredManifest = async (file) => {
	let raw;
	let modified;
	try {
		[raw, { mtime: modified }] = await Promise.all([readFile(file, 'utf8'), stat(file)]);
	} catch (error) {
		if (error.code === 'ENOENT') return emptyManifest();
		throw error;
	}

	const parsed = JSON.parse(raw);
	if (!isPlainObject(parsed)) throw new SyntaxError('the top level must be a JSON object');

	const list = (value) => (Array.isArray(value) ? value : []);
	return {
		version: VERSION,
		updated: typeof parsed.updated === 'string' ? parsed.updated : timestamp(modified),
		ticker: list(parsed.ticker),
		cards: list(parsed.cards),
		clips: list(parsed.clips),
	};
};

/**
 * What `/ads.json` serves: enabled items only, without the `enabled` flag.
 *
 * Items that fail validation are left out rather than failing the whole response,
 * so one bad line in a hand-edited file does not take every ad down with it. Each
 * one is reported through `onInvalid`.
 */
export const publicManifest = (stored, onInvalid = () => {}) => {
	const result = { version: VERSION, updated: stored.updated, ticker: [], cards: [], clips: [] };
	const seen = new Set();
	for (const section of Object.keys(SECTIONS)) {
		stored[section].forEach((item, index) => {
			if (item?.enabled === false) return;
			const prefix = `${section}[${index}]`;
			const { value, errors } = validateItem(section, item, prefix);
			if (!errors.length && seen.has(value.id)) {
				errors.push({ field: `${prefix}.id`, message: 'duplicates an earlier id' });
			}
			if (errors.length) {
				onInvalid(errors);
				return;
			}
			seen.add(value.id);
			delete value.enabled;
			result[section].push(value);
		});
	}
	return result;
};

/** The stored manifest as the admin sees it: every item, with `enabled` explicit. */
export const adminManifest = (stored) => {
	const withFlag = (item) => (isPlainObject(item) ? { ...item, enabled: item.enabled ?? true } : item);
	return {
		version: VERSION,
		updated: stored.updated,
		ticker: stored.ticker.map(withFlag),
		cards: stored.cards.map(withFlag),
		clips: stored.clips.map(withFlag),
	};
};
