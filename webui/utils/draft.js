import { exec } from 'kernelsu-alt';
import { moduleDirectory } from './util.js';

/**
 * Wrapper around module/draft.sh
 *
 * The WebUI edits rule files in place, so there is no undo stack. draft.sh keeps
 * a snapshot taken before the first edit of a session, which lets us detect
 * unapplied changes and throw them away on request. The snapshot lives on disk
 * so it survives closing the WebUI.
 *
 * Hosts and proxy keep separate snapshots, fully independent. The current view
 * comes from setDraftView(), so callers do not pass it every time.
 */

let currentView = 'hosts';

/**
 * Tell the draft layer which view is being edited
 * @param {'hosts'|'proxy'} view
 * @returns {void}
 */
export function setDraftView(view) {
    currentView = view === 'proxy' ? 'proxy' : 'hosts';
}

const call = (action, view) => {
    const v = view === undefined ? currentView : view;
    return exec(`sh "${moduleDirectory}/draft.sh" ${action}${v ? ` ${v}` : ''}`);
};

/**
 * Whether there are edits in the current view that were never applied
 * @returns {Promise<boolean>}
 */
export async function isDirty() {
    try {
        const { stdout } = await call('status');
        return stdout.trim() === 'dirty';
    } catch {
        return false;
    }
}

/**
 * Flag that a rule file is about to be modified. Takes the snapshot on the
 * first call of a session, so the baseline always predates the edit.
 * @returns {Promise<void>}
 */
export async function markDirty() {
    try {
        await call('mark');
    } catch {
        // never block an edit because the snapshot failed
    }
}

/**
 * Throw away every unapplied edit in the current view and restore the snapshot
 * @returns {Promise<void>}
 */
export async function discardDraft() {
    await call('discard');
}

/**
 * Drop both snapshots, called once the edits have been applied
 * @returns {Promise<void>}
 */
export async function clearDraft() {
    await call('clear', '');
}
