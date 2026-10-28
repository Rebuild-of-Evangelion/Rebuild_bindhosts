import { exec, spawn } from 'kernelsu-alt';
import { showPrompt, basePath, moduleDirectory, filePaths, fetchText, updateUIVisibility } from '../../utils/util.js';
import { getString } from '../../utils/language.js';
import { isDirty, markDirty, discardDraft, clearDraft, setDraftView } from '../../utils/draft.js';
import { markHostsStale } from '../../utils/hostsState.js';
import { Compartment, EditorState } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { EditorView, highlightActiveLineGutter, keymap, lineNumbers } from '@codemirror/view';
import { FileSelector } from '../../utils/file_selector.js';
import { setupDocsMenu } from '../../utils/docs.js';

// the rule lists rendered on this page, in display order
const RULE_FILE_TYPES = ["custom", "sources", "blacklist", "whitelist", "sources_whitelist"];

// Uncommitted input per view. Both views share the same input elements, so
// without isolation whatever is half-typed in Hosts leaks into Proxy.
const pendingInput = { hosts: {}, proxy: {} };

// ---- Hosts / Proxy dual view ----------------------------------------------
// Both views share one set of sections; only the files and placeholders differ.
// Proxy has no dedicated whitelist/blacklist files: those are views filtered out
// of proxy/custom.txt by action.

const VIEW_FILES = {
    hosts: {
        custom: 'hosts/custom.txt',
        sources: 'hosts/sources.txt',
        blacklist: 'hosts/blacklist.txt',
        whitelist: 'hosts/whitelist.txt',
        sources_whitelist: 'hosts/sources_whitelist.txt',
    },
    proxy: {
        custom: 'proxy/custom.txt',
        sources: 'proxy/sources.txt',
        blacklist: 'proxy/custom.txt',
        whitelist: 'proxy/custom.txt',
        sources_whitelist: 'proxy/custom.txt',
    },
};

const VIEW_PLACEHOLDERS = {
    hosts: {
        sources: 'https://adaway.org/hosts.txt',
        sources_whitelist: 'https://example.com/whitelist_txt',
        whitelist: 's.youtube.com',
        blacklist: 'online-casino.com',
        custom: '93.184.215.14 example.com',
    },
    proxy: {
        sources: 'https://example.com/proxy_rules.txt',
        whitelist: 'forward /run-front/*',
        blacklist: 'block /api/ads/*',
        custom: 'mock /run-front/common/update {"code":0}',
    },
};

let currentView = 'hosts';

// Applied state from rules_state; the checkboxes only hold the desired state
let appliedState = { hosts: true, proxy: false };

/**
 * Read rules_state
 * @returns {Promise<{hosts: boolean, proxy: boolean}>}
 */
async function readRulesState() {
    const { stdout } = await exec(`cat "${basePath}/rules_state" 2>/dev/null`);
    const get = (key, fallback) => {
        const m = stdout.match(new RegExp(`^${key}=(\\d)`, 'm'));
        return m ? m[1] === '1' : fallback;
    };
    return { hosts: get('hosts', true), proxy: get('proxy', false) };
}

/**
 * Push the current view's desired state into the checkboxes
 * @returns {void}
 */
function syncCheckboxes() {
    const h = document.getElementById('check-hosts');
    const p = document.getElementById('check-proxy');
    if (h) h.checked = appliedState.hosts;
    if (p) p.checked = appliedState.proxy;
}

/**
 * Current checkbox value = desired state
 * @returns {{hosts: boolean, proxy: boolean}}
 */
function pendingState() {
    const h = document.getElementById('check-hosts');
    const p = document.getElementById('check-proxy');
    // Fall back to the applied state when the control is missing; a read failure must never disable hosts
    return {
        hosts: h ? !!h.checked : appliedState.hosts,
        proxy: p ? !!p.checked : appliedState.proxy,
    };
}

/**
 * Switch between the Hosts and Proxy views
 * @param {'hosts'|'proxy'} view
 * @returns {void}
 */
function applyView(view) {
    // Stash the current view's input first (already empty right after a submit)
    RULE_FILE_TYPES.forEach(fileType => {
        const input = document.getElementById(`${fileType}-input`);
        if (input) pendingInput[currentView][fileType] = input.value;
    });

    currentView = view;
    // Draft snapshots are per view; tell the draft layer which side we are editing
    setDraftView(view);

    Object.assign(filePaths, VIEW_FILES[view]);

    document.getElementById('tab-hosts').classList.toggle('active', view === 'hosts');
    document.getElementById('tab-proxy').classList.toggle('active', view === 'proxy');

    // proxy has no "source whitelist" section
    const swBox = document.getElementById('sources-whitelist-box');
    if (swBox) swBox.style.display = view === 'proxy' ? 'none' : '';

    RULE_FILE_TYPES.forEach(fileType => {
        const input = document.getElementById(`${fileType}-input`);
        if (!input) return;
        // Restore the target view's own input and swap the placeholder
        input.value = pendingInput[view][fileType] || "";
        if (VIEW_PLACEHOLDERS[view][fileType]) {
            input.placeholder = VIEW_PLACEHOLDERS[view][fileType];
        }
    });

    updateDisabledLook();
    reloadAllLists();
}

/**
 * Grey out and lock the content when the current view is disabled
 * @returns {void}
 */
function updateDisabledLook() {
    const page = document.getElementById('page-hosts');
    if (!page) return;
    const enabled = currentView === 'hosts' ? appliedState.hosts : appliedState.proxy;
    page.classList.toggle('rules-view-disabled', !enabled);
    page.querySelectorAll('textarea, input').forEach(el => {
        el.disabled = !enabled;
    });
}

/**
 * In the proxy view, split entries by action into whitelist / blacklist / custom
 * @param {string[]} lines
 * @param {string} fileType
 * @returns {string[]}
 */
function filterForView(lines, fileType) {
    if (currentView !== 'proxy') return lines;
    const isForward = l => /^(disabled\|)?forward\s/.test(l);
    const isBlock = l => /^(disabled\|)?block\s/.test(l);
    if (fileType === 'whitelist') return lines.filter(isForward);
    if (fileType === 'blacklist') return lines.filter(isBlock);
    if (fileType === 'custom') return lines.filter(l => !isForward(l) && !isBlock(l));
    return lines;
}

/**
 * Read a file and display its content in the UI
 * Exclude # pattern
 * Create empty file if file not found
 * @param {string} fileType - Type of hosts file ('custom', 'sources', 'blacklist', etc.)
 * @returns {Promise<void>}
 */
async function loadFile(fileType) {
    const content = await fetchText('link/PERSISTENT_DIR/' + filePaths[fileType], `${basePath}/${filePaths[fileType]}`).catch(() => "");
    const lines = content
        .split("\n")
        .map(line => line)
        .filter(line => line && !line.startsWith("#"));
    displayHostsList(lines, fileType);
}

/**
 * Display hosts list in the UI
 * Create list item with remove button, edit button on custom file
 * @param {string[]} lines - Array of host entries to display
 * @param {string} fileType - Type of hosts file ('custom', 'sources', 'blacklist', etc.)
 * @throws {Error} When DOM elements are not found
 * @returns {void}
 */
function displayHostsList(lines, fileType) {
    lines = filterForView(lines, fileType);
    const listElement = document.getElementById(`${fileType}-list`);
    listElement.innerHTML = "";
    
    // "show more" option
    const showInitialLimit = 4;
    const minItemsForShowMore = 6; // Only show "Show More" when there are at least 6 items
    const hasMoreItems = lines.length >= minItemsForShowMore;
    const initialLines = hasMoreItems ? lines.slice(0, showInitialLimit) : lines;
    
    // Function to create list items
    const createListItem = (line) => {
        // Free favicon provided by GitHub@twentyhq/favicon
        const item = line.split('#');
        // imported rule sets are whole files: they are disabled via a ".disabled" filename suffix
        const isDisabled = fileType === 'import_custom'
            ? line.endsWith('.disabled')
            : line.startsWith('disabled|');
        const url = fileType === 'import_custom'
            ? line.replace(/\.disabled$/, '')
            : item[0].trim().replace(/^disabled\|/, '');
        const name = item[1]?.trim() || '';

        let domain = url.split(/\s+/).pop();
        try {
            if (!domain.startsWith("http")) domain = "http://" + domain;
            domain = new URL(domain).hostname;
        } catch {
            domain = domain.split(/[/:?#]/)[0];
        }
        const faviconUrl = `https://twenty-icons.com/${domain}`;
        // Proxy rules are paths, not domains, so a favicon makes no sense
        const showFavicon = fileType !== "import_custom"
            && !(currentView === 'proxy' && ['custom', 'whitelist', 'blacklist'].includes(fileType));

        const listItem = document.createElement("div");
        listItem.className = 'scrollable-list';
        listItem.innerHTML = `
            <!-- Favicon and link text -->
            <div class="link-box">
                ${showFavicon ? `<div class="favicon-wrapper">
                    <div class="favicon-loader"></div>
                    <img class="favicon-img favicon" src="${faviconUrl}" />
                </div>` : ""}
                <div class="link-text">${name || url}</div>

                <!-- Checkbox: enable/disable this rule (or this whole imported rule set) -->
                <md-checkbox></md-checkbox>
            </div>

            <!-- Edit and delete buttons -->
            <div class="link-button">
                ${fileType === "import_custom" ? `<md-filled-icon-button class="edit-btn">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" height="22px" viewBox="0 -960 960 960" width="22px" fill="#ffffff"><path d="M200-200h57l391-391-57-57-391 391v57Zm-80 80v-170l528-527q12-11 26.5-17t30.5-6q16 0 31 6t26 18l55 56q12 11 17.5 26t5.5 30q0 16-5.5 30.5T817-647L290-120H120Zm640-584-56-56 56 56Zm-141 85-28-29 57 57-29-28Z"/></svg></md-icon>
                </md-filled-icon-button>` : ""}
                <md-filled-icon-button class="delete-btn" id="${fileType === "import_custom" ? "file-delete" : "line-delete"}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" height="22px" viewBox="0 -960 960 960" width="22px" fill="#ffffff"><path d="M277.37-111.87q-37.78 0-64.39-26.61t-26.61-64.39v-514.5h-45.5v-91H354.5v-45.5h250.52v45.5h214.11v91h-45.5v514.5q0 37.78-26.61 64.39t-64.39 26.61H277.37Zm78.33-168.37h85.5v-360h-85.5v360Zm163.1 0h85.5v-360h-85.5v360Z"/></svg></md-icon>
                </md-filled-icon-button>
            </div>
        `;
        // Click to show remove button
        listElement.appendChild(listItem);
        listItem.addEventListener('click', (e) => {
            if (e.target.tagName === 'MD-CHECKBOX') return;
            const isRTL = document.documentElement.getAttribute('dir') === 'rtl';
            listItem.scrollTo({ 
                left: isRTL ? -listItem.scrollWidth : listItem.scrollWidth,
                behavior: 'smooth'
            });
        });

        if (fileType !== "import_custom") {
            listItem.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                document.getElementById('edit-hosts-link').value = url;
                document.getElementById('edit-hosts-name').value = name;

                const dialog = document.getElementById('edit-hosts-dialog');
                dialog.dataset.currentLine = line;
                dialog.dataset.fileType = fileType;
                dialog.dataset.isDisabled = isDisabled ? "true" : "false";
                dialog.show();
            });
        }
        const deleteLine = listItem.querySelector("#line-delete");
        const deleteFile = listItem.querySelector("#file-delete");
        const editFile = listItem.querySelector(".edit-btn");
        const img = listItem.querySelector(".favicon-img");
        // Wait for favicon to load
        if (img) {
            const loader = listItem.querySelector(".favicon-loader");
            img.onload = () => {
                loader.style.display = "none";
                img.style.display = "block";
            };
            img.onerror = () => {
                loader.style.display = "none";
                listItem.querySelector(".favicon-wrapper").innerHTML = `<svg class="favicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M80-120v-720h400v160h400v560H80Zm80-80h80v-80h-80v80Zm0-160h80v-80h-80v80Zm0-160h80v-80h-80v80Zm0-160h80v-80h-80v80Zm160 480h80v-80h-80v80Zm0-160h80v-80h-80v80Zm0-160h80v-80h-80v80Zm0-160h80v-80h-80v80Zm160 480h320v-400H480v80h80v80h-80v80h80v80h-80v80Zm160-240v-80h80v80h-80Zm0 160v-80h80v80h-80Z"/></svg>`;
            };
        }
        // Checkbox: toggle enabled/disabled for this entry
        const checkbox = listItem.querySelector("md-checkbox");
        if (checkbox) {
            checkbox.checked = !isDisabled;
            checkbox.addEventListener('change', async () => {
                await markDirty();
                // imported rule sets are files, so toggle by renaming with a .disabled suffix
                if (fileType === 'import_custom') {
                    const from = `${basePath}/${importDir()}/${isDisabled ? url + '.disabled' : url}`;
                    const to = `${basePath}/${importDir()}/${isDisabled ? url : url + '.disabled'}`;
                    exec(`mv -f "${from}" "${to}"`).then(({ errno }) => {
                        if (errno !== 0) showPrompt(getString('global_save_fail'), false);
                        getCustomHostsList();
                    });
                    return;
                }
                const command = isDisabled ? `s,${line},${line.replace(/^disabled\|/, '')},` : `s,${line},disabled|${line},`;
                exec(`sed -i '${command}' ${basePath}/${filePaths[fileType]}`).then((result) => {
                    loadFile(fileType);
                });
            });
        }
        const removeEntry = () => {
            const next = listItem.nextElementSibling;
            if (next && next.tagName === 'MD-DIVIDER') {
                next.remove();
            } else {
                const prev = listItem.previousElementSibling;
                if (prev && prev.tagName === 'MD-DIVIDER') {
                    prev.remove();
                }
            }
            listItem.remove();
        };

        // Remove line from file
        if (deleteLine) {
            deleteLine.onclick = async () => {
                await markDirty();
                await exec(`
                    filtered=$(grep -vxF '${line}' ${basePath}/${filePaths[fileType]})
                    echo "$filtered" > ${basePath}/${filePaths[fileType]}
                `);
                removeEntry();
            };
        }
        // Remove file
        if (deleteFile) {
            deleteFile.onclick = async () => {
                // `line` is the real filename on disk (may end with .disabled), `url` is the display name
                const remove = await removeCustomHostsFile(url);
                if (remove) {
                    await markDirty();
                    await exec(`rm -f "${basePath}/${importDir()}/${line}"`);
                    removeEntry();
                }
            };
        }
        // Edit file
        if (editFile) {
            editFile.onclick = () => {
                fileNameEditor(line);
            };
        }
        return listItem;
    };

    // Display initial items
    initialLines.forEach((line, index) => {
        createListItem(line);
        if (index < initialLines.length - 1) {
            listElement.appendChild(document.createElement("md-divider"));
        }
    });

    // Add "Show More" button
    if (hasMoreItems) {
        listElement.appendChild(document.createElement("md-divider"));
        const showMoreItem = document.createElement("div");
        showMoreItem.className = "show-more-item";
        // Special styling to make it visually distinct
        showMoreItem.innerHTML = getString('global_show_all', lines.length - showInitialLimit);
        listElement.appendChild(showMoreItem);
        // Remove the "Show More" button and show remaining items
        showMoreItem.onclick = () => {
            listElement.removeChild(showMoreItem);
            const remainingLines = lines.slice(showInitialLimit);
            remainingLines.forEach((line, index) => {
                createListItem(line);
                if (index < remainingLines.length - 1) {
                    listElement.appendChild(document.createElement("md-divider"));
                }
            });
        };
    }

}

/**
 * Handle adding input to the file
 * @param {string} fileType - Type of hosts file ('custom', 'sources', 'blacklist', etc.)
 * @param {string} prompt - Prompt message to display
 * @returns {Promise<void>}
 */
async function handleAdd(fileType, prompt) {
    const inputElement = document.getElementById(`${fileType}-input`);
    const inputValue = inputElement.value.trim();
    console.log(`Input value for ${fileType}: "${inputValue}"`);
    if (inputValue === "") return;
    const inputLines = inputValue.split('\n').map(line => line.trim()).filter(line => line !== "");
    try {
        const fileContent = await fetchText('link/PERSISTENT_DIR/' + filePaths[fileType], `${basePath}/${filePaths[fileType]}`).catch(() => "");
        const existingLines = fileContent.split('\n').map(line => line.trim()).filter(line => line !== "");

        let wroteAny = false;
        for (const line of inputLines) {
            if (existingLines.includes(line)) {
                showPrompt(getString(prompt, line), false, 2000);
                continue;
            }
            if (!wroteAny) {
                await markDirty();
                wroteAny = true;
            }
            await exec(`echo "${line}" >> ${basePath}/${filePaths[fileType]}`);
        }
        inputElement.value = ""; // Clear input if add successful
        loadFile(fileType);
    } catch(error) {
        console.error(`Failed to process input for ${fileType}: ${error}`);
    }
}

/**
 * Remove custom hosts file with confirmation
 * @param {string} fileName - Name of the file to remove
 * @returns {Promise<boolean>}
 */
function removeCustomHostsFile(fileName) {
    const dialog = document.getElementById("confirmation-dialog");
    const cancelButton = document.getElementById("dialog-cancel-btn");
    const removeButton = document.getElementById("dialog-remove-btn");

    document.getElementById("confirmation-file-name").textContent = fileName;

    // Show dialog
    dialog.show();

    return new Promise((resolve) => {
        dialog.onclose = () => {
            resolve(dialog.returnValue === 'remove');
            dialog.onclose = null;
        };

        cancelButton.onclick = () => {
            dialog.returnValue = 'cancel';
            dialog.close();
        };
        removeButton.onclick = () => {
            dialog.returnValue = 'remove';
            dialog.close();
        }
    });
}

// Help event listener
export let activeOverlay = null;
/**
 * Setup help menu event listeners to open and close help overlays
 * @returns {void}
 */
function setupHelpMenu() {
    const helpButtons = document.querySelectorAll(".help-btn");
    const overlays = document.querySelectorAll(".overlay");
    helpButtons.forEach(button => {
        button.onclick = () => {
            const type = button.dataset.type;
            const overlay = document.getElementById(`${type}-help`);
            if (overlay) {
                if (overlay.tagName === 'MD-DIALOG') {
                    overlay.show();
                    // Setup close button inside dialog
                    const closeBtn = overlay.querySelector('.close-btn');
                    if (closeBtn) closeBtn.onclick = () => overlay.close();
                } else {
                    openOverlay(overlay);
                }
            }
        };
    });
    overlays.forEach(overlay => {
        const closeButton = overlay.querySelector(".close-btn");
        
        if (closeButton) {
            closeButton.onclick = () => closeOverlay(overlay);
        }
        overlay.onclick = (e) => {
            if (e.target === overlay) closeOverlay(overlay);
        };
    });
    function openOverlay(overlay) {
        if (activeOverlay) closeOverlay(activeOverlay);
        activeOverlay = overlay;
        overlay.style.display = "flex";
        document.body.style.overflow = "hidden";
        setTimeout(() => overlay.style.opacity = "1", 10);
    }
    function closeOverlay(overlay) {
        document.body.style.overflow = "";
        overlay.style.opacity = "0";
        setTimeout(() => {
            overlay.style.display = "none";
            activeOverlay = null;
        }, 200);
    }
}

/**
 * Handle touch screen textarea experience: force single direction scroll, snap line
 * @returns {void}
 */
function setupInputEvent() {
    const inputBoxes = document.querySelectorAll('.input-box');

    inputBoxes.forEach(inputBox => {
        let startX, startY, isScrollingX, isScrollingY;
        const lineHeight = parseFloat(window.getComputedStyle(inputBox).lineHeight);

        inputBox.addEventListener('touchstart', (event) => {
            const touch = event.touches[0];
            startX = touch.clientX;
            startY = touch.clientY;
            isScrollingX = false;
            isScrollingY = false;
            document.body.style.overflow = "hidden";
        });
        inputBox.addEventListener('touchmove', (event) => {
            const touch = event.touches[0];
            const deltaX = touch.clientX - startX;
            const deltaY = touch.clientY - startY;
            // Only allow X or Y scroll in a single touchmove event
            if (Math.abs(deltaX) > Math.abs(deltaY)) {
                if (!isScrollingX) {
                    isScrollingX = true;
                    isScrollingY = false;
                }
                if (isScrollingY) event.preventDefault();
            } else {
                if (!isScrollingY) {
                    isScrollingY = true;
                    isScrollingX = false;
                    inputBox.scrollTo({ left: 0, behavior: 'smooth' });
                }
                if (isScrollingX) event.preventDefault();
            }
        });
        inputBox.addEventListener('touchend', () => {
            isScrollingX = false;
            isScrollingY = false;
            document.body.style.overflow = "";
            // Snap to the nearest line
            const scrollTop = inputBox.scrollTop;
            const nearestLine = Math.round(scrollTop / lineHeight) * lineHeight;
            inputBox.scrollTo({ top: nearestLine, behavior: 'smooth' });
        });
        inputBox.addEventListener('focus', () => {
            const wrapper = inputBox.closest('.input-box-wrapper');
            wrapper.classList.add('focus');
            inputBox.style.padding = '0 9px';
            setTimeout(() => {
                inputBox.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }, 300);
        });
        inputBox.addEventListener('blur', () => {
            const wrapper = inputBox.closest('.input-box-wrapper');
            wrapper.classList.remove('focus');
            inputBox.style.paddingLeft = '10px';
        });
    });
}

/**
 * Attach event listeners to the add buttons
 * @returns {void}
 */
function attachAddButtonListeners() {
    // id - input id, type - file type, fail - prompt message
    const elements = [
        { id: "custom-input", type: "custom", fail: "custom_prompt_fail" },
        { id: "sources-input", type: "sources", fail: "source_prompt_fail" },
        { id: "blacklist-input", type: "blacklist", fail: "blacklist_prompt_fail" },
        { id: "whitelist-input", type: "whitelist", fail: "whitelist_prompt_fail" },
        { id: "sources_whitelist-input", type: "sources_whitelist", fail: "sources_whitelist_prompt_fail" }
    ];
    elements.forEach(({ id, type, fail }) => {
        const inputElement = document.getElementById(id);
        const buttonElement = document.getElementById(`${type}-add`);
        inputElement.addEventListener('keypress', (e) => {
            if (e.key === "Enter") {
                handleAdd(type, fail);
                inputElement.blur();
            }
        });
        buttonElement.addEventListener('click', () => handleAdd(type, fail));
    });
}

let actionRunning = false, isTerminalOpen = false;

/**
 * Run bindhosts.sh with and display output in fake terminal
 * @param {String} args - argument for bindhosts.sh
 * @returns {Promise<void>}
 */
function runBindhosts(args, onExit) {
    const terminal = document.getElementById('action-terminal');
    const terminalContent = document.getElementById('action-terminal-content');
    const backButton = document.querySelector('.back-button');
    const FabContainer = document.querySelector('.action-container');
    const closeBtn = document.getElementById('close-terminal');

    closeBtn.onclick = () => closeTerminal();
    backButton.onclick = () => closeTerminal();

    if (!actionRunning) {
        actionRunning = true;
        terminalContent.innerHTML = '';
        const output = spawn("sh", [`${moduleDirectory}/bindhosts.sh`, ...String(args).split(/\s+/)]);
        output.stdout.on('data', (data) => appendOutput(data));
        output.stderr.on('data', (data) => appendOutput(data));
        output.on('exit', () => {
            if (isTerminalOpen) {
                closeBtn.classList.add('show');
                FabContainer.classList.add('show');
            }
            actionRunning = false;
            if (onExit) onExit();
        });
    }

    // Append output to terminal
    const appendOutput = (output) => {
        const p = document.createElement('p');
        p.className = 'action-terminal-output';
        p.textContent = output;
        terminalContent.appendChild(p);
        terminal.scrollTo({ top: terminal.scrollHeight, behavior: 'smooth' });
    };

    const closeTerminal = () => {
        if (!isTerminalOpen) return;
        terminal.close();
        // Back on the Rules page, restore the header switcher
        document.getElementById('rules-switcher')?.classList.add('show');
        setTimeout(() => {
            isTerminalOpen = false;
        }, 100);
    }

    // Open output terminal
    setTimeout(() => {
        isTerminalOpen = true;
        terminal.open();
        // The terminal slides out below the header and cannot cover it, so hide the switcher
        document.getElementById('rules-switcher')?.classList.remove('show');
        closeBtn.classList.remove('show');
        backButton.onclick = () => closeTerminal();
    }, 50);
}

/**
 * Find out custom hosts list and display it
 * @returns {void}
 */
// Imported rule files live under each view's imported/, keeping their original names
function importDir() {
    return currentView === 'proxy' ? 'proxy/imported' : 'hosts/imported';
}

/**
 * On a name clash append _2 / _3 and so on, picking the first free name
 * @param {string} dir - imported directory (relative to basePath)
 * @param {string} fileName - original file name
 * @returns {Promise<string>}
 */
async function uniqueName(dir, fileName) {
    const { stdout } = await exec(`ls -1 "${basePath}/${dir}" 2>/dev/null`);
    const existing = new Set((stdout || "").split("\n").map(x => x.trim()).filter(Boolean));
    if (!existing.has(fileName)) return fileName;

    // .disabled is a state suffix, so the counter goes before the real extension
    let name = fileName;
    let suffix = "";
    if (name.endsWith(".disabled")) {
        suffix = ".disabled";
        name = name.slice(0, -9);
    }
    const dot = name.lastIndexOf(".");
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const ext = dot > 0 ? name.slice(dot) : "";

    for (let i = 2; i < 1000; i++) {
        const candidate = `${stem}_${i}${ext}${suffix}`;
        if (!existing.has(candidate)) return candidate;
    }
    return `${stem}_${Date.now()}${ext}${suffix}`;
}

function getCustomHostsList() {
    const dir = importDir();
    // ls fails when the directory is missing; treat that as an empty list rather
    // than returning early, or the view keeps the previous view's content.
    exec(`ls -1 "${basePath}/${dir}" 2>/dev/null`)
        .then(({ stdout }) => {
            const lines = (stdout || "").split("\n").filter(line => line.trim());
            displayHostsList(lines, "import_custom");
        });
}

/**
 * Import custom hosts with file selector
 * @returns {void}
 */
async function importCustomHost() {
    const filePath = await FileSelector.getFilePath("txt");
    if (filePath) {
        // The file name is irrelevant; only the content matters:
        //   Hosts view: the file must not contain any proxy rule line
        //   Proxy view: the file must contain at least one proxy rule line
        const scan = await exec(`
            prox=$(grep -cE '^[[:space:]]*(disabled\\|)?(mock|forward|block)[[:space:]]' "${filePath}" 2>/dev/null)
            echo \${prox:-0}
        `);
        const proxyCount = parseInt((scan.stdout || "0").trim(), 10) || 0;
        if (currentView === 'proxy' && proxyCount === 0) {
            showPrompt(getString('import_reject_in_proxy'), false);
            return;
        }
        if (currentView === 'hosts' && proxyCount > 0) {
            showPrompt(getString('import_reject_in_hosts'), false);
            return;
        }

        const fileName = filePath.split('/').pop().replace(/ /g, '_');
        const dir = importDir();
        const finalName = await uniqueName(dir, fileName);
        const destPath = `${basePath}/${dir}/${finalName}`;
        await markDirty();
        const result = await exec(`
            cp -f "${filePath}" "${destPath}"
            chmod 644 "${destPath}"
        `);
        if (result.errno === 0) {
            showPrompt(getString('global_saved', destPath));
            await new Promise(resolve => setTimeout(resolve, 100));
            getCustomHostsList();
        } else {
            showPrompt(getString('global_save_fail'), false);
            console.error('Error copying file:', result.stderr);
        }
    }
}

/**
 * Setup dev editor for system files
 * @returns {void}
 */
function setupDevEditor() {
    const header = document.querySelector('.box-header.import');
    const helpBtn = header.querySelector('.help-btn');
    if (!helpBtn) return;

    const editBtn = document.createElement('md-outlined-icon-button');
    editBtn.className = 'dev-edit-btn';
    editBtn.innerHTML = `
        <md-icon><svg xmlns="http://www.w3.org/2000/svg" height="22px" viewBox="0 -960 960 960" width="22px"><path d="M200-200h57l391-391-57-57-391 391v57Zm-80 80v-170l528-527q12-11 26.5-17t30.5-6q16 0 31 6t26 18l55 56q12 11 17.5 26t5.5 30q0 16-5.5 30.5T817-647L290-120H120Zm640-584-56-56 56 56Zm-141 85-28-29 57 57-29-28Z"/></svg></md-icon>
    `;
    editBtn.onclick = async () => {
        const fileName = "_demo";
        const content = `::1 localhost ip6-localhost ip6-loopback\n0.0.0.0 test.com\n`;
        const fileNameInput = document.getElementById('file-name-input');
        setEditorValue(content);
        fileNameInput.value = fileName;
        openFileEditor(fileName);
    };
    header.insertBefore(editBtn, helpBtn);
}

/**
 * Open file name editor
 * @param {string} fileName - Current file name
 * @returns {Promise<void>}
 */
async function fileNameEditor(fileName) {
    const fileNameInput = document.getElementById('file-name-input');
    const rel = `${importDir()}/${fileName}`;
    fileNameInput.value = fileName.replace(/\.txt$/, "");
    // Editor support for file smaller than 128KB
    const result = await exec(`[ $(wc -c < "${basePath}/${rel}") -lt 131072 ] || exit 1`);
    if (result.errno === 0) {
        const content = await fetchText(`link/PERSISTENT_DIR/${rel}`, `${basePath}/${rel}`).catch(() => "");
        setEditorValue(content);
        openFileEditor(rel);
    } else {
        // Only rename is supported for large files
        openFileEditor(rel, false);
        showPrompt(getString('global_file_too_large'));
    }
}

let setupEditor = false;
let codeEditor;
let lineWrappingEnabled = false;
const lineWrapping = new Compartment();

const editorTheme = EditorView.theme({
    '&': {
        height: '100%',
        width: '100%',
        boxSizing: 'border-box',
        direction: 'ltr',
        color: 'var(--md-sys-color-on-surface)',
        backgroundColor: 'var(--md-sys-color-surface-container-high)',
    },
    '.cm-gutters': {
        color: 'var(--md-sys-color-outline)',
        backgroundColor: 'var(--md-sys-color-surface-container-low)',
        borderRight: '1px solid var(--md-sys-color-outline-variant)',
    },
    '.cm-activeLineGutter': {
        color: 'var(--md-sys-color-on-surface)',
        backgroundColor: 'var(--md-sys-color-surface-container)',
    },
    '.cm-scroller': {
        width: '100%',
        minWidth: '0',
    },
    '.cm-content': {
        flex: '1 1 auto',
        minWidth: '0',
        caretColor: 'var(--md-sys-color-primary)',
    },
    '.cm-cursor, .cm-dropCursor': {
        borderLeftColor: 'var(--md-sys-color-primary)',
    },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': {
        backgroundColor: 'var(--md-sys-color-secondary-container) !important',
    },
});

/**
 * Set the editor content before or after CodeMirror has been initialized.
 * @param {string} content - File content to display
 * @returns {void}
 */
function setEditorValue(content) {
    if (codeEditor) {
        codeEditor.dispatch({
            changes: { from: 0, to: codeEditor.state.doc.length, insert: content },
        });
        return;
    }
    document.getElementById('edit-input').textContent = content;
}

/**
 * Enable or disable CodeMirror's visual line wrapping.
 * @param {boolean} enabled - Whether lines should wrap to the editor width
 * @returns {void}
 */
function setLineWrapping(enabled) {
    lineWrappingEnabled = enabled;
    codeEditor.dispatch({
        effects: lineWrapping.reconfigure(enabled ? EditorView.lineWrapping : []),
    });

    const lineWrapButton = document.getElementById('line-wrap-btn');
    lineWrapButton.selected = enabled;
    codeEditor.requestMeasure();
}
/**
 * Open file editor
 * @param {string} lastFileName - Name of the last file edited
 * @param {boolean} openEditor - Whether to open the file editor, false goes to file name editor only
 * @returns {void}
 */
function openFileEditor(lastFileName, openEditor = true) {
    const backButton = document.querySelector('.back-button');
    const saveButton = document.getElementById('save-btn');
    const lineWrapButton = document.getElementById('line-wrap-btn');
    const editor = document.getElementById('edit-content');
    const bodyContent = document.getElementById('page-hosts');
    const editorInput = document.getElementById("edit-input");
    const fileNameInput = document.getElementById('file-name-input');

    if (!setupEditor) {
        setupEditor = true;
        fileNameInput.addEventListener('input', adjustFileNameWidth);
        saveButton.onclick = saveFile;
        lineWrapButton.onclick = () => setLineWrapping(!lineWrappingEnabled);
        const initialContent = editorInput.textContent;
        editorInput.replaceChildren();
        codeEditor = new EditorView({
            state: EditorState.create({
                doc: initialContent,
                extensions: [
                    lineNumbers(),
                    highlightActiveLineGutter(),
                    history(),
                    keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
                    lineWrapping.of([]),
                    editorTheme,
                ],
            }),
            parent: editorInput,
        });
    }

    // Adjust width of fileName dynamically
    function adjustFileNameWidth() {
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        ctx.font = window.getComputedStyle(fileNameInput).font;
        const textWidth = ctx.measureText(fileNameInput.value).width;
        const maxWidth = window.innerWidth * 0.8 - 150;
        fileNameInput.style.width = `${Math.min(Math.ceil(textWidth) + 2, maxWidth)}px`;
    }
    adjustFileNameWidth();

    // Show editor
    document.body.classList.add('editor-active');
    bodyContent.style.overflowY = 'hidden';

    // Open file editor
    if (openEditor) {
        editor.open();
        requestAnimationFrame(() => codeEditor.requestMeasure());
        backButton.onclick = () => closeEditor();

        // Handle system file editor UI
        const isSystemFile = Object.values(filePaths).includes(lastFileName);
        const fileNameEditor = document.querySelector('.file-name-editor');
        const spans = fileNameEditor.querySelectorAll('span');
        if (isSystemFile) {
            spans.forEach(span => span.style.display = 'none');
            fileNameInput.readOnly = true;
            fileNameInput.style.width = 'auto';
        } else {
            spans.forEach(span => span.style.display = 'inline');
            fileNameInput.readOnly = false;
            adjustFileNameWidth();
        }
    } else {
        setTimeout(() => fileNameInput.focus(), 1000);
    }

    // Alternative way to close about docs with back button
    const closeEditor = () => {
        // Check if editor is actually active
        if (!editor.classList.contains('open') && !document.body.classList.contains('editor-active')) return;
        
        editor.close();
        document.body.classList.remove('editor-active');
        bodyContent.style.overflowY = 'auto';
        document.querySelectorAll('.box li').forEach(li => {
            li.scrollTo({ left: 0, behavior: 'smooth' });
        });
        codeEditor.scrollTo(0, 0);
    }

    // Save file
    async function saveFile() {
        const newFileName = fileNameInput.value;
        const content = codeEditor.state.doc.toString().trim();
        if (newFileName === "") {
            showPrompt(getString('global_file_name_empty'), false);
            return;
        }
        let command;
        const isSystemFile = Object.values(filePaths).includes(lastFileName);
        if (isSystemFile) {
            // Save system file directly
            command = `
                cat << 'HostEditorEOF' > ${basePath}/${lastFileName}
${content}
HostEditorEOF
                chmod 644 ${basePath}/${lastFileName}`;
        } else if (openEditor) {
            // Save custom file
            command = `
                [ ! -f ${basePath}/${lastFileName} ] || rm -f ${basePath}/${lastFileName}
                cat << 'HostEditorEOF' > ${basePath}/${importDir()}/${newFileName}.txt
${content}
HostEditorEOF
                chmod 644 ${basePath}/${importDir()}/${newFileName}.txt`;
        } else {
            // Rename file
            command = `mv -f ${basePath}/${importDir()}/${lastFileName} ${basePath}/${importDir()}/${newFileName}.txt`;
        }
        await markDirty();
        const result = await exec(command);
        if (result.errno === 0) {
            showPrompt(getString('global_saved', `${basePath}/${importDir()}/${newFileName}.txt`));
        } else {
            showPrompt(getString('global_save_fail'), false);
            console.error("Failed to save file:", result.stderr);
        }
        getCustomHostsList();
        closeEditor();
    }
}

/**
 * Setup rename dialog
 */
function setupRenameDialog() {
    const regex = /[$<>[\]{}`]/;
    const renameDialog = document.getElementById('edit-hosts-dialog');
    renameDialog.querySelectorAll('md-outlined-text-field').forEach(el => {
        el.oninput = () => {
            const value = el.value;
            el.value = value.replace(regex, '');
        }
    });
    renameDialog.querySelector('.close-btn').onclick = () => renameDialog.close();
    document.getElementById('edit-hosts-confirm').onclick = async () => {
        const currentLine = renameDialog.dataset.currentLine;
        const fileType = renameDialog.dataset.fileType;
        const isDisabled = renameDialog.dataset.isDisabled === "true";

        const newLink = renameDialog.querySelector('#edit-hosts-link').value;
        const newName = renameDialog.querySelector('#edit-hosts-name').value;
        let newLine = `${isDisabled ? 'disabled\|' : ''}${newLink}`;
        if (newName) newLine += ` # ${newName}`;
        const command = `s,${currentLine},${newLine},`;

        await markDirty();
        exec(`sed -i '${command}' ${basePath}/${filePaths[fileType]}`).then(() => {
            loadFile(fileType);
        });
        renameDialog.close();
    };
}


// Lifecycle: Initial mount to DOM
export function mount() {
    attachAddButtonListeners();
    setupHelpMenu();
    setupDocsMenu();
    setupInputEvent();
    setupRenameDialog();
    if (import.meta.env.DEV) setupDevEditor();

    // Event listeners for action buttons
    const actionBtn = document.getElementById("action-btn");
    const forceUpdateButton = document.getElementById('force-update-btn');
    const importBtn = document.getElementById("import-custom-button");

    // a successful run rewrites hosts: drop the draft and let the home page know
    const afterHostsRun = async () => {
        clearDraft();
        markHostsStale();
        appliedState = await readRulesState();
        syncCheckboxes();
        updateDisabledLook();
    };

    actionBtn.onclick = () => {
        const st = pendingState();
        runBindhosts(`--action --hosts ${st.hosts ? 1 : 0} --proxy ${st.proxy ? 1 : 0}`, afterHostsRun);
    };
    forceUpdateButton.onclick = () => runBindhosts("--force-update", afterHostsRun);
    importBtn.onclick = () => importCustomHost();

    document.getElementById('tab-hosts').onclick = () => applyView('hosts');
    document.getElementById('tab-proxy').onclick = () => applyView('proxy');

    setupDraftDialog();
}

/**
 * Wire the "unapplied changes" dialog
 * @returns {void}
 */
function setupDraftDialog() {
    const scrim = document.getElementById('draft-scrim');
    if (!scrim) return;

    document.getElementById('draft-keep-btn').onclick = () => {
        scrim.classList.remove('show');
    };

    document.getElementById('draft-discard-btn').onclick = async () => {
        scrim.classList.remove('show');
        await discardDraft();
        clearPendingInputs();
        syncCheckboxes();
        reloadAllLists();
        showPrompt(getString('draft_discarded'));
    };
}

/**
 * Drop text that was typed into the add boxes / rename dialog but never submitted,
 * so "discard" really leaves nothing behind
 * @returns {void}
 */
function clearPendingInputs() {
    RULE_FILE_TYPES.forEach(fileType => {
        const input = document.getElementById(`${fileType}-input`);
        if (input) input.value = "";
    });

    ['edit-hosts-link', 'edit-hosts-name'].forEach(id => {
        const field = document.getElementById(id);
        if (field) field.value = "";
    });
}

/**
 * Whether something was typed into an add box but never submitted with the "+" button
 * @returns {boolean}
 */
function hasPendingInput() {
    return RULE_FILE_TYPES.some(fileType => {
        const input = document.getElementById(`${fileType}-input`);
        return !!input && input.value.trim() !== "";
    });
}

/**
 * Reload every rule list on the page
 * @returns {void}
 */
function reloadAllLists() {
    RULE_FILE_TYPES.forEach(loadFile);
    getCustomHostsList();
}

/**
 * Ask what to do with edits that were never applied
 * @returns {Promise<void>}
 */
async function promptUnappliedChanges() {
    const scrim = document.getElementById('draft-scrim');
    if (!scrim) return;
    // typed-but-not-submitted text counts as an unapplied change too
    // Uncommitted checkbox changes are excluded here: onShow rolls them back to
    // the applied state, so the UI never shows "checked but not in effect".
    const dirty = (await isDirty()) || hasPendingInput();
    if (!dirty) return;

    document.getElementById('draft-dialog-text').textContent = getString('draft_dialog_message');
    document.getElementById('draft-keep-btn').textContent = getString('draft_dialog_keep');
    document.getElementById('draft-discard-btn').textContent = getString('draft_dialog_discard');
    scrim.classList.add('show');
}

// Lifecycle: Each time page becomes visible
export async function onShow() {
    updateUIVisibility();

    // Replace the header title with the Hosts | Proxy switcher
    const title = document.getElementById('title');
    const switcher = document.getElementById('rules-switcher');
    if (title) title.style.display = 'none';
    if (switcher) switcher.classList.add('show');

    // Read the applied state before syncing the checkboxes: uncommitted toggles
    // are discarded on re-entry, keeping the UI equal to what is in effect.
    appliedState = await readRulesState();
    syncCheckboxes();
    applyView(currentView);

    promptUnappliedChanges();
}

// Lifecycle: Each time page is hidden
export function onHide() {
    document.querySelectorAll('.fab-container').forEach(c => c.classList.remove('show', 'inTerminal'));
    document.getElementById('save-btn')?.classList.remove('show');
    document.getElementById('line-wrap-btn')?.classList.remove('show');

    // Restore the plain title when leaving this page
    const title = document.getElementById('title');
    const switcher = document.getElementById('rules-switcher');
    if (title) title.style.display = '';
    if (switcher) switcher.classList.remove('show');
}
