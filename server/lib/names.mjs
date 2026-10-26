// File names and the kinds of file each directory accepts.
//
// Every name a client supplies to a new route passes through `checkFileName`. It
// rejects rather than sanitises: a request that names a path, a hidden file or an
// unexpected character is refused outright, so there is never a question of what
// the server "meant" to write.

import path from 'node:path';

import { HttpError } from './http.mjs';

export const AUDIO_TYPES = {
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

export const KINDS = {
	music: { label: 'audio', types: AUDIO_TYPES },
	image: {
		label: 'image',
		types: {
			'.png': 'image/png',
			'.jpg': 'image/jpeg',
			'.jpeg': 'image/jpeg',
			'.gif': 'image/gif',
			'.webp': 'image/webp',
		},
	},
	clip: {
		label: 'video',
		types: {
			'.mp4': 'video/mp4',
			'.m4v': 'video/x-m4v',
			'.mov': 'video/quicktime',
		},
	},
};

export const MAX_NAME_LENGTH = 128;

const SAFE_NAME = /^[A-Za-z0-9._ -]+$/;

/** Whether `name` is acceptable for `kind`, without throwing. */
export const isValidFileName = (name, kind) => {
	try {
		checkFileName(name, kind);
		return true;
	} catch {
		return false;
	}
};

/**
 * Validate a decoded, client-supplied file name for `kind`.
 *
 * Returns `{ name, type }`. Throws a 400 for anything path-like or unsafe, and a
 * 415 for a safe name with the wrong extension.
 */
export const checkFileName = (name, kind) => {
	const { label, types } = KINDS[kind];

	if (typeof name !== 'string' || name.length === 0) {
		throw new HttpError(400, 'A file name is required');
	}
	// A name that is not its own basename is a path. Refuse it rather than quietly
	// keeping the last component.
	if (name.includes('/') || name.includes('\\') || name.includes('\0') || path.basename(name) !== name) {
		throw new HttpError(400, 'File name must not contain a path');
	}
	if (name.startsWith('.') || name.includes('..')) {
		throw new HttpError(400, 'Hidden files and ".." are not allowed');
	}
	if (!SAFE_NAME.test(name) || name !== name.trim()) {
		throw new HttpError(400, 'File names may only use letters, digits, spaces, dots, dashes and underscores');
	}
	if (name.length > MAX_NAME_LENGTH) {
		throw new HttpError(400, `File names may be at most ${MAX_NAME_LENGTH} characters`);
	}

	const type = types[path.extname(name).toLowerCase()];
	if (!type) {
		const allowed = Object.keys(types).join(', ');
		throw new HttpError(415, `Unsupported ${label} type; use one of ${allowed}`);
	}
	return { name, type };
};

/**
 * Join a validated name onto `dir`, and confirm the result really is a direct
 * child of it. `checkFileName` already guarantees this; the check is here so a
 * future change to the name rules cannot quietly open a hole.
 */
export const resolveInside = (dir, name) => {
	const target = path.resolve(dir, name);
	if (path.dirname(target) !== path.resolve(dir)) throw new HttpError(400, 'Invalid path');
	return target;
};
