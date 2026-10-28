/**
 * Cross page flag: "the hosts file was regenerated"
 *
 * bindhosts.sh --action / --force-update rewrite the hosts file. The home page
 * has no cheap way to notice that by itself, so the hosts page sets this flag
 * when the run finishes and the home page consumes it on its next show.
 */

let stale = false;

/**
 * Flag that the hosts file was rewritten
 * @returns {void}
 */
export function markHostsStale() {
    stale = true;
}

/**
 * Read and clear the flag
 * @returns {boolean} true when the hosts file changed since the last check
 */
export function consumeHostsStale() {
    const value = stale;
    stale = false;
    return value;
}
