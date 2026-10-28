import { exec } from 'kernelsu-alt';
import { showPrompt, reboot, basePath, moduleDirectory, setDeveloperOption, developerOption, fetchText, updateUIVisibility } from '../../utils/util.js';
import { setupDocsMenu } from '../../utils/docs.js';
import { getString } from '../../utils/language.js';
import { consumeHostsStale } from '../../utils/hostsState.js';
import modes from './modes.json';

let clickCount = 0, clickTimeout = 0;

/**
 * Update the status elements with data from specified files.
 * If the file is not found, it attempts to set up the link and retries.
 * @returns {Promise<void>}
 */
function updateStatus() {
    const status = [
        { element: 'status-text', key: 'description', file: 'module.prop' },
        { element: 'version-text', key: 'version', file: 'module.prop' },
        { element: 'mode-btn', key: 'mode', file: 'mode.sh' },
    ]

    const fetchStatus = async (item) => {
        try {
            const data = await fetchText("link/MODDIR/" + item.file, `${moduleDirectory}/${item.file}`);
            let value = data.match(new RegExp(`${item.key}=(.*)`))[1].replace('status: ', '');
            if (item.element === 'mode-btn') {
                value = getString("mode_button", value);
            }
            document.getElementById(item.element).textContent = value;
        } catch (error) {
            console.error(`Error fetching status for ${item.element}:`, error);
            document.getElementById(item.element).textContent = 'Unknown';
        }
    };

    status.reduce(async (promise, item) => {
        await promise;
        return await fetchStatus(item);
    }, Promise.resolve()).catch(error => {
        console.error("Error updating status:", error);
    });
}

/**
 * Developer option entrance, status box click event
 * Click 5 times in 2 seconds to enable developer option
 * @returns {void}
 */
function setupDevOtp() {
    const statusBox = document.getElementById("status-box");
    statusBox.onclick = async () => {
        clickCount++;
        clearTimeout(clickTimeout);
        clickTimeout = setTimeout(() => {
            clickCount = 0;
        }, 2000);
        if (clickCount === 5) {
            clickCount = 0;
            if (!developerOption) {
                setDeveloperOption(true);
                showPrompt(getString('global_dev_opt'));
            } else {
                showPrompt(getString('global_dev_opt_true'));
            }
        }
    };
}

/**
 * Check if developer option is enabled
 * Allow open mode menu if developer option is enabled
 * @returns {Promise<void>}
 */
async function checkDevOption() {
    if (developerOption) return;
    try {
        await fetchText('link/PERSISTENT_DIR/mode_override.sh', `${basePath}/mode_override.sh`);
        setDeveloperOption(true);
    } catch {
        setDeveloperOption(false);
    }
}

/**
 * Update radio button state based on current mode
 * @returns {Promise<void>}
 */
async function updateModeSelection() {
    let currentMode;
    const result = await exec(`cat ${basePath}/mode_override.sh`);
    if (result.errno === 0) {
        currentMode = result.stdout.trim().match(/mode=(\d+)/)?.[1] || null;
    } else {
        currentMode = null;
    }
    document.querySelectorAll("#mode-options md-radio").forEach((radio) => {
        radio.checked = radio.value === currentMode;
    });
}

/**
 * Save mode option
 * @param {string} mode - Mode to save
 * @returns {Promise<void>}
 */
async function saveModeSelection(mode) {
    let command;
    if (mode === "reset") {
        command = `rm -f ${basePath}/mode_override.sh`;
    } else {
        command = `echo "mode=${mode}" > ${basePath}/mode_override.sh`;
    }
    const result = await exec(command);
    if (result.errno === 0) {
        document.getElementById("mode-menu").close();
        showPrompt(getString('global_reboot_now'), true, 5000, getString('global_reboot'), reboot);
        await updateModeSelection();
    } else {
        console.error("Error saving mode selection:", result.stderr);
    }
}

// Open mode menu if developer option is enabled
function setupModeBtn() {
    const modeBtn = document.getElementById("mode-btn");
    const modeMenu = document.getElementById("mode-menu");
    const modeOptions = document.getElementById("mode-options");

    modes.forEach(mode => {
        const label = document.createElement('label');
        label.className = 'custom-radio';
        label.innerHTML = `
            <md-radio name="mode" value="${mode.value}"></md-radio>
            <div class="radio-label">
                <div class="radio-label-title">
                    <span>${getString("mode_button", mode.value)}</span>
                </div>
                <small>${mode.description}</small>
            </div>
        `;
        modeOptions.appendChild(label);
    });

    modeOptions.addEventListener('change', (event) => {
        saveModeSelection(event.target.value);
    });

    document.getElementById("reset-mode").onclick = () => saveModeSelection("reset");

    modeBtn.addEventListener('click', (e) => {
        if (!developerOption) return;
        e.stopImmediatePropagation();
        modeMenu.show();
        updateModeSelection();
    });
}

/**
 * Query box
 * Load hosts dynamically to avoid long loading time due to big hosts file
 * Load 30 each time, and load more when scroll to the bottom
 */
let hostLines = [], originalHostLines = [], currentIndex = 0, initialHeight = 0;
const batchSize = 30;

// ---- Source index ---------------------------------------------------------
// The hosts file is a merged result and carries no origin info. Checking every
// line against the big cache/sources.txt would stall the query page, so do the
// opposite: downloaded content is the overwhelming majority, treat it as SRC by
// default and only check two small sets — domains the user wrote explicitly and
// domains declared by the proxy rules.
// Source tags. Adding a new one only needs a value here: rendering derives the
// lowercase CSS class (.src-badge.xxx) and search derives the "#xxx" keyword.
const SOURCE_TAGS = ['SRC', 'PXY'];
const [TAG_SRC, TAG_PXY] = SOURCE_TAGS;

let proxyDomains = new Set();
let userDomains = new Set();
let userProxyRules = new Set();
let sourceIndexOk = false;

/**
 * Build the source index from the small rule files in a single exec call.
 * @returns {Promise<void>}
 */
async function loadSourceIndex() {
    const nextProxy = new Set();
    const nextUser = new Set();
    const nextProxyRules = new Set();
    let ok = false;

    // proxy side: lines starting with a digit are hosts lines and their domains
    // go into proxyDomains; the rest are mock / forward / block rules kept whole
    try {
        const { stdout } = await exec(
            `cat "${basePath}/proxy/custom.txt" "${basePath}/proxy/imported/"*.txt 2>/dev/null`);
        (stdout || "").split("\n").forEach(raw => {
            const line = raw.replace(/^disabled\|/, "").trim();
            if (!line || line.startsWith("#")) return;
            const parts = line.split(/\s+/);
            if (/^[0-9]/.test(parts[0])) {
                parts.slice(1).forEach(d => nextProxy.add(d.toLowerCase()));
            } else {
                nextProxyRules.add(line);
            }
        });
        ok = true;
    } catch {
        // ignore when the proxy directory does not exist yet
    }

    // hosts side: domains the user wrote; their presence means "do not tag"
    try {
        const { stdout } = await exec(
            `cat "${basePath}/hosts/custom.txt" "${basePath}/hosts/imported/"*.txt ` +
            `"${basePath}/hosts/whitelist.txt" "${basePath}/hosts/blacklist.txt" 2>/dev/null`);
        (stdout || "").split("\n").forEach(raw => {
            const line = raw.replace(/^disabled\|/, "").trim();
            if (!line || line.startsWith("#")) return;
            const parts = line.split(/\s+/);
            if (parts.length < 2) return;
            parts.slice(1).forEach(d => nextUser.add(d.toLowerCase()));
        });
        ok = true;
    } catch {
        // ignore
    }

    proxyDomains = nextProxy;
    userDomains = nextUser;
    userProxyRules = nextProxyRules;
    sourceIndexOk = ok;
}

/**
 * Determine the origin of a hosts line
 * @param {string[]} domains - domains on that line
 * @returns {string|null} a value from SOURCE_TAGS, null means user-written
 */
function sourceOf(domains) {
    if (!sourceIndexOk) return null;
    const list = domains.map(d => d.toLowerCase());
    if (list.some(d => proxyDomains.has(d))) return TAG_PXY;
    if (list.some(d => userDomains.has(d))) return null;
    return TAG_SRC;
}

/**
 * Origin tag for one line of the proxy product
 * @param {string} raw - raw product line
 * @returns {string|null} null means user-written, do not tag
 */
function proxySourceOf(raw) {
    if (!sourceIndexOk) return null;
    if (userProxyRules.has(raw)) return null;
    return TAG_SRC;
}


/**
 * Get hosts from hosts.txt and display them in the UI
 * @returns {Promise<void>}
 */
async function getHosts() {
    if (queryMode !== 'hosts') return;
    const hostList = document.querySelector('.host-list-item');
    hostList.innerHTML = '';

    const response = await fetch('link/hosts.txt', { cache: 'no-store' });
    // Both queries share one list container; a stale response must not paint
    // over the other view after the user switched tabs.
    if (queryMode !== 'hosts') return;
    if (!response.ok) {
        hostList.innerHTML = getString('global_unsupported');
        return;
    }
    const hostsText = await response.text();

    hostLines = hostsText
        .trim()
        .split('\n')
        .filter(line => line.trim() && !line.startsWith('#')) // Remove empty/comment lines
        .map(line => line.trim().split(/\s+/))
        .filter(parts => parts.length >= 2); // Ensure valid entries

    // Store the original data
    originalHostLines = [...hostLines];

    currentIndex = 0;
    loadMoreHosts(() => {
        initialHeight = hostList.offsetHeight;
    });

    // Scroll down to load more
    hostList.onscroll = () => {
        // Reset position
        document.querySelectorAll('.scrollable-list').forEach(el => {
            el.scrollTo({ left: 0, behavior: 'smooth' });
        });

        // Existing scroll to load more functionality
        const scrollTop = hostList.scrollTop;
        const hostListHeight = hostList.clientHeight;
        const scrollHeight = hostList.scrollHeight;

        if (scrollTop + hostListHeight >= scrollHeight - initialHeight) {
            loadMoreHosts();
        }
    };
}

/**
 * Load more hosts on scroll to the bottom
 * @param {Function} [callback] - Optional callback function to execute after loading more hosts
 * @returns {void}
 */
function loadMoreHosts(callback) {
    const hostList = document.querySelector('.host-list-item');
    for (let i = 0; i < batchSize && currentIndex < hostLines.length; i++, currentIndex++) {
        const [hostIp, ...domains] = hostLines[currentIndex];
        const dataType = hostIp === "0.0.0.0" ? "block" : "custom";

        // The two localhost lines are infrastructure, not any source.
        // Everything else is tagged SRC / PXY; the badge takes its own line and
        // is only rendered when there is a source, never as a placeholder.
        const isLocalhost = domains.every(d => d === "localhost");
        const src = isLocalhost ? null : sourceOf(domains);
        const badge = src
            ? `<span class="src-badge ${src.toLowerCase()}">${src}</span>`
            : "";

        // Same test sourceOf applies for SRC: not declared by the proxy rules and
        // not written by the user. Recomputed here so the button does not depend
        // on the badge result, which is null whenever the source index failed.
        const isDownloaded = !domains.some(d => proxyDomains.has(d.toLowerCase()))
                          && !domains.some(d => userDomains.has(d.toLowerCase()));
        // Downloaded rules cannot be removed from here: a rebuild re-fetches them.
        // Same treatment as proxy-declared hosts rows, no button and no swipe.
        const hasButton = dataType !== 'custom' && !isDownloaded;

        const hostItem = document.createElement('div');
        hostItem.className = 'scrollable-list';
        hostItem.setAttribute('data-type', dataType);

        // Add remove button if dataType is not 'custom'
        hostItem.innerHTML = `
            <div class="host-list-row">
                <div class="host-ip">
                    <span class="host-ip-text">${hostIp}</span>
                    ${badge}
                </div>
                <div class="host-domain">${domains.join(' ')}</div>
            </div>
            ${hasButton ? `
            <md-filled-icon-button class="remove-btn">
                <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M277.37-111.87q-37.78 0-64.39-26.61t-26.61-64.39v-514.5h-45.5v-91H354.5v-45.5h250.52v45.5h214.11v91h-45.5v514.5q0 37.78-26.61 64.39t-64.39 26.61H277.37Zm78.33-168.37h85.5v-360h-85.5v360Zm163.1 0h85.5v-360h-85.5v360Z"/></svg></md-icon>
            </md-filled-icon-button>
            ` : ''}
        `;

        // Add event listener to remove button if it exists
        if (hasButton) {
            const removeBtn = hostItem.querySelector('.remove-btn');
            removeBtn.onclick = (e) => handleRemove(e, domains);
        }
        if (hasButton) hostItem.onclick = () => {
            const isRTL = document.documentElement.getAttribute('dir') === 'rtl';
            hostItem.scrollTo({
                left: isRTL ? -hostItem.scrollWidth : hostItem.scrollWidth,
                behavior: 'smooth'
            });
        };
        hostList.appendChild(hostItem);
        hostList.appendChild(document.createElement("md-divider"));
    }

    if (callback) requestAnimationFrame(callback);
}

/**
 * Handle remove host
 * @param {Event} event - Click event
 * @param {string[]} domains - Domains to remove
 * @returns {Promise<void>}
 */
async function handleRemove(event, domains) {
    const hostList = document.querySelector('.host-list-item');
    const result = await exec(`sh ${moduleDirectory}/bindhosts.sh --whitelist ${domains.join(' ')}`);
    if (result.errno === 0) {
        // Find and remove the element directly
        const hostItem = event.target.closest('.host-list-row');
        if (hostItem) {
            hostList.removeChild(hostItem);
        }
        showPrompt(getString('query_remove_prompt', domains.join(' ')));
    } else {
        console.error("Error removing host:", result.stderr);
        showPrompt(getString('query_remove_error', domains.join(' ')), false);
    }
}

/**
 * Setup search functionality
 * @returns {void}
 */
// ---- Host / Proxy query ---------------------------------------------------
// The hosts query reads the generated hosts file; the proxy query reads the
// merged product. They share one search box, but the proxy side is read-only
// and offers no delete button.

let queryMode = 'hosts';
let proxyRules = [];

const PROXY_ACTION_ORDER = { mock: 0, forward: 1, block: 2 };

/**
 * Read and render the proxy product
 * @returns {Promise<void>}
 */
async function getProxyRules() {
    if (queryMode !== 'proxy') return;
    const hostList = document.querySelector('.proxy-list-item');
    hostList.innerHTML = '';

    // The product file survives a disable, but its rules are not in effect, so hide them
    const state = await fetchText('link/PERSISTENT_DIR/rules_state', `${basePath}/rules_state`).catch(() => '');
    const enabled = (state || '').split('\n').some(line => line.trim() === 'proxy=1');
    if (!enabled) {
        proxyRules = [];
        renderProxyRules(proxyRules);
        return;
    }

    const text = await fetchText('link/PERSISTENT_DIR/proxy.rules', `${basePath}/proxy.rules`).catch(() => '');
    if (queryMode !== 'proxy') return;

    proxyRules = text.split('\n')
        .map(line => line.trim())
        .filter(line => line && !line.startsWith('#'))
        .map(line => {
            const action = line.split(/\s+/)[0];
            const rest = line.slice(action.length).trim();
            return { action, rest, raw: line };
        })
        .filter(rule => rule.action in PROXY_ACTION_ORDER)
        .sort((a, b) =>
            PROXY_ACTION_ORDER[a.action] - PROXY_ACTION_ORDER[b.action]
            || a.rest.localeCompare(b.rest)
        );

    renderProxyRules(proxyRules);
}

/**
 * Render the proxy rule list
 * @param {{action: string, rest: string}[]} rules
 * @returns {void}
 */
function renderProxyRules(rules) {
    const hostList = document.querySelector('.proxy-list-item');
    hostList.innerHTML = '';

    if (rules.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'proxy-rule-row';
        empty.textContent = getString('query_proxy_empty');
        hostList.appendChild(empty);
        return;
    }

    rules.forEach(rule => {
        const row = document.createElement('div');
        row.className = 'proxy-rule-row';

        // Action and source tag share one column, the tag sits below the action
        const col = document.createElement('div');
        col.className = 'proxy-action-col';

        const badge = document.createElement('span');
        badge.className = 'proxy-rule-action';
        badge.dataset.action = rule.action;
        badge.textContent = rule.action;
        col.appendChild(badge);

        // Lines from downloaded rule sets get SRC; user-written ones stay untagged
        const srcTag = proxySourceOf(rule.raw);
        if (srcTag) {
            const src = document.createElement('span');
            src.className = `src-badge ${srcTag.toLowerCase()}`;
            src.textContent = srcTag;
            col.appendChild(src);
        }

        row.appendChild(col);

        const text = document.createElement('span');
        text.className = 'proxy-rule-path';
        text.textContent = rule.rest;

        row.appendChild(text);
        hostList.appendChild(row);
        // Match the hosts query page: every row is followed by a divider
        hostList.appendChild(document.createElement("md-divider"));
    });
}

/**
 * Header follows the query target.
 * A hosts row reads `127.0.0.1  api.example.com`, labelled "IP | Domain".
 * A proxy row reads `[mock] /run-front/...`, labelled "Action | Path".
 */
const QUERY_HEADERS = {
    hosts: ['query_host_ip', 'query_host_domain'],
    proxy: ['query_proxy_action', 'query_proxy_path'],
};

/**
 * Switch the header labels and column-width mode
 * @param {'hosts'|'proxy'} mode
 * @returns {void}
 */
function setQueryHeaders(mode) {
    const [leftKey, rightKey] = QUERY_HEADERS[mode];
    const left = document.querySelector('.host-list-header-ip');
    const right = document.querySelector('.host-list-header-domain');
    if (left) {
        left.setAttribute('data-i18n', leftKey);
        left.textContent = getString(leftKey);
    }
    if (right) {
        right.setAttribute('data-i18n', rightKey);
        right.textContent = getString(rightKey);
    }

    // The proxy first column is a content-sized action badge, not the fixed hosts width
    const header = document.querySelector('.host-list-header');
    if (header) header.classList.toggle('proxy-mode', mode === 'proxy');
}

/**
 * Switch the query target
 * @param {'hosts'|'proxy'} mode
 * @returns {void}
 */
function switchQueryMode(mode) {
    queryMode = mode;
    document.getElementById('query-tab-hosts').classList.toggle('active', mode === 'hosts');
    document.getElementById('query-tab-proxy').classList.toggle('active', mode === 'proxy');

    setQueryHeaders(mode);

    const inputBox = document.getElementById('query-input');
    if (inputBox) inputBox.value = '';

    // Each view owns its own list container, so nothing can leak between them.
    document.querySelector('.host-list-item').hidden = mode !== 'hosts';
    document.querySelector('.proxy-list-item').hidden = mode !== 'proxy';

    if (mode === 'proxy') {
        getProxyRules();
    } else {
        getHosts();
    }
}

function setupQueryInput() {
    // Build the source index first, or the first batch renders untagged
    loadSourceIndex().then(getHosts);

    document.getElementById('query-tab-hosts').onclick = () => switchQueryMode('hosts');
    document.getElementById('query-tab-proxy').onclick = () => switchQueryMode('proxy');
    const hostList = document.querySelector('.host-list-item');
    const inputBox = document.getElementById('query-input');
    const searchBtn = document.querySelector('.search-btn');
    const clearBtn = document.querySelector('.clear-btn');

    // Search functionality
    searchBtn.onclick = () => {
        const query = inputBox.value.trim().toLowerCase();
        // "#src" / "#pxy" filter by source; keywords derive from SOURCE_TAGS
        const tag = SOURCE_TAGS.find(t => `#${t.toLowerCase()}` === query);

        // proxy side matches the whole line as a substring, read-only
        if (queryMode === 'proxy') {
            hostList.scrollTo(0, 0);
            renderProxyRules(!query
                ? proxyRules
                : proxyRules.filter(rule => tag
                    ? proxySourceOf(rule.raw) === tag
                    : rule.raw.toLowerCase().includes(query)));
            return;
        }

        if (!query) getHosts();

        // Always search from the original data
        const filteredHosts = originalHostLines.filter(([hostIp, ...domains]) => {
            if (tag) {
                const isLocalhost = domains.every(d => d === "localhost");
                return !isLocalhost && sourceOf(domains) === tag;
            }
            return hostIp.toLowerCase().includes(query) || domains.some(domain => domain.toLowerCase().includes(query));
        });

        // Clear current list
        hostList.scrollTo(0, 0);
        hostList.innerHTML = '';
        currentIndex = 0;
        hostLines = filteredHosts;
        loadMoreHosts();
    };

    // Search on enter
    inputBox.onkeypress = (event) => {
        if (event.key === 'Enter') searchBtn.click();
    };

    // Update clear button visibility on any input change
    inputBox.oninput = () => {
        clearBtn.style.display = inputBox.value.length > 0 ? 'flex' : 'none';
    };

    // Clear search functionality
    clearBtn.onclick = async () => {
        inputBox.value = '';
        clearBtn.style.display = 'none';
        await getHosts();
    };
}

// Lifecycle: Initial mount to DOM
export function mount() {
    setupDevOtp();
    setupModeBtn();
    setupQueryInput();
    setupDocsMenu();
}

// Lifecycle: Each time page becomes visible
export function onShow() {
    updateUIVisibility();
    document.getElementById('mode-btn').classList.add('show');
    updateStatus();
    checkDevOption();
    // only reload the query list when hosts was actually regenerated
    if (consumeHostsStale()) loadSourceIndex().then(getHosts);
}

// Lifecycle: Each time page is hidden
export function onHide() {
    document.getElementById('mode-btn').classList.remove('show');
    document.querySelectorAll('.fab-container').forEach(c => c.classList.remove('show', 'inTerminal'));
}
