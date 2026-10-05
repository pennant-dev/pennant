// Pennant for Chrome. Pennant, on this Mac, works in tabs of its own here: in a Chrome window of its own, behind
// yours, with your sign-ins. It clicks and types with Chrome's own input (the debugger), so your pointer, keyboard and
// tabs stay yours. It only ever acts in tabs it opened.
//
// The link is a WebSocket to Pennant on this Mac only (127.0.0.1:7339); Pennant accepts nothing but this extension.

const PORT = 7339;
const VERSION = chrome.runtime.getManifest().version;
// Stamped by Pennant in the copy Chrome loads, so Pennant can tell when that copy has changed and reload it.
const BUILD = 'source';
let socket = null;
let pingTimer = null;
// Pennant's window and the tabs it opened, kept across the service worker's restarts.
let state = { windowId: null, tabs: [], groupId: null };
const attached = new Set();

async function loadState() {
  const saved = await chrome.storage.session.get('pennant');
  if (saved.pennant) state = saved.pennant;
}
function saveState() { chrome.storage.session.set({ pennant: state }); }

// MARK: Link

function connect() {
  if (socket && socket.readyState <= 1) return;
  try { socket = new WebSocket(`ws://127.0.0.1:${PORT}/`); } catch { socket = null; return; }
  socket.onopen = () => {
    const chromeVersion = (navigator.userAgent.match(/Chrome\/(\d+)/) || [])[1];
    send({ event: 'hello', version: VERSION, build: BUILD, browser: chromeVersion ? `Chrome ${chromeVersion}` : 'Chrome' });
    clearInterval(pingTimer);
    // A message every 20 seconds keeps this worker (and the link) alive.
    pingTimer = setInterval(() => send({ event: 'ping' }), 20000);
  };
  socket.onmessage = (e) => {
    let message;
    try { message = JSON.parse(e.data); } catch { return; }
    if (message.id && message.action) run(message);
  };
  socket.onclose = () => { socket = null; clearInterval(pingTimer); };
  socket.onerror = () => {};
}

function send(obj) {
  if (socket && socket.readyState === 1) socket.send(JSON.stringify(obj));
}

chrome.alarms.create('pennant-link', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
loadState().then(connect);

async function run({ id, action, params }) {
  try {
    const fn = actions[action];
    if (!fn) throw new Error(`Pennant's extension doesn't know “${action}”; update it.`);
    await loadState();
    const result = await fn(params || {});
    send({ id, ok: true, result });
  } catch (e) {
    send({ id, ok: false, error: String((e && e.message) || e) });
  }
}

// MARK: Pennant's window and tabs

async function pennantWindow() {
  if (state.windowId !== null) {
    try { await chrome.windows.get(state.windowId); return state.windowId; } catch { state.windowId = null; state.groupId = null; }
  }
  // Opened without focus: it sits behind the owner's own windows.
  const w = await chrome.windows.create({ focused: false, type: 'normal', width: 1280, height: 900, url: 'about:blank' });
  state.windowId = w.id;
  state.groupId = null;
  saveState();
  return w.id;
}

async function ownTab(tab) {
  const id = Number(tab);
  if (!state.tabs.includes(id)) throw new Error(`Tab ${tab} isn't one of Pennant's tabs.`);
  try { await chrome.tabs.get(id); } catch {
    state.tabs = state.tabs.filter((t) => t !== id);
    saveState();
    throw new Error(`Tab ${tab} was closed.`);
  }
  return id;
}

// Only the active tab of a window takes input reliably: Pennant's tab is made active in Pennant's window, which
// doesn't bring the window forward.
async function focusTab(id) {
  const t = await chrome.tabs.get(id);
  if (!t.active) await chrome.tabs.update(id, { active: true });
  return id;
}

async function addToGroup(tabId, windowId) {
  try {
    if (state.groupId !== null) { await chrome.tabs.group({ groupId: state.groupId, tabIds: [tabId] }); return; }
  } catch { state.groupId = null; }
  state.groupId = await chrome.tabs.group({ tabIds: [tabId], createProperties: { windowId } });
  await chrome.tabGroups.update(state.groupId, { title: 'Pennant', color: 'purple' });
  saveState();
}

async function settled(id, timeout = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    const t = await chrome.tabs.get(id);
    if (t.status === 'complete') break;
    await sleep(200);
  }
  await sleep(300);
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function describe(id) {
  const t = await chrome.tabs.get(id);
  return { tab: id, title: t.title || '', url: t.url || t.pendingUrl || '' };
}

// MARK: Chrome's own input

async function cdp(tabId, method, params = {}) {
  if (!attached.has(tabId)) {
    try { await chrome.debugger.attach({ tabId }, '1.3'); } catch (e) {
      if (!String(e.message || e).includes('Already attached')) throw e;
    }
    attached.add(tabId);
  }
  letGoWhenIdle(tabId);
  return chrome.debugger.sendCommand({ tabId }, method, params);
}

// Chrome shows its debugging bar while Pennant is attached, so a tab Pennant has stopped using is let go after a minute.
const idleTimers = new Map();
function letGoWhenIdle(tabId) {
  clearTimeout(idleTimers.get(tabId));
  idleTimers.set(tabId, setTimeout(() => {
    idleTimers.delete(tabId);
    if (attached.delete(tabId)) chrome.debugger.detach({ tabId }).catch(() => {});
  }, 60000));
}
chrome.debugger.onDetach.addListener((source) => attached.delete(source.tabId));
chrome.tabs.onRemoved.addListener((id) => {
  attached.delete(id);
  if (state.tabs.includes(id)) { state.tabs = state.tabs.filter((t) => t !== id); saveState(); }
});

async function inPage(tabId, func, args = []) {
  const [{ result }] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return result;
}

async function mouse(id, x, y, button = 'left', count = 1) {
  await cdp(id, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  for (let n = 1; n <= count; n++) {
    await cdp(id, 'Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, clickCount: n });
    await cdp(id, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, clickCount: n });
  }
}

const KEYS = {
  enter: ['Enter', 'Enter', 13, '\r'], return: ['Enter', 'Enter', 13, '\r'], escape: ['Escape', 'Escape', 27], esc: ['Escape', 'Escape', 27],
  tab: ['Tab', 'Tab', 9], backspace: ['Backspace', 'Backspace', 8], delete: ['Delete', 'Delete', 46], space: [' ', 'Space', 32, ' '],
  arrowup: ['ArrowUp', 'ArrowUp', 38], up: ['ArrowUp', 'ArrowUp', 38], arrowdown: ['ArrowDown', 'ArrowDown', 40], down: ['ArrowDown', 'ArrowDown', 40],
  arrowleft: ['ArrowLeft', 'ArrowLeft', 37], left: ['ArrowLeft', 'ArrowLeft', 37], arrowright: ['ArrowRight', 'ArrowRight', 39], right: ['ArrowRight', 'ArrowRight', 39],
  pageup: ['PageUp', 'PageUp', 33], pagedown: ['PageDown', 'PageDown', 34], home: ['Home', 'Home', 36], end: ['End', 'End', 35],
};

async function pressKeys(id, keys) {
  const parts = keys.toLowerCase().split('+').map((s) => s.trim()).filter(Boolean);
  let modifiers = 0;
  const commands = [];
  for (const p of parts.slice(0, -1)) {
    if (p === 'alt' || p === 'option') modifiers |= 1;
    else if (p === 'ctrl' || p === 'control') modifiers |= 2;
    else if (p === 'cmd' || p === 'command' || p === 'meta') modifiers |= 4;
    else if (p === 'shift') modifiers |= 8;
  }
  const last = parts[parts.length - 1] || '';
  let [key, code, vk, text] = KEYS[last] || [last, last.length === 1 ? `Key${last.toUpperCase()}` : last, last.length === 1 ? last.toUpperCase().charCodeAt(0) : 0, last.length === 1 ? last : undefined];
  // On a Mac the editing shortcuts are commands, not text.
  if (modifiers & 4) {
    const map = { a: 'selectAll', c: 'copy', v: 'paste', x: 'cut', z: 'undo' };
    if (map[last]) commands.push(map[last]);
    text = undefined;
  }
  if (modifiers & 8 && text) text = text.toUpperCase();
  const base = { modifiers, key, code, windowsVirtualKeyCode: vk };
  await cdp(id, 'Input.dispatchKeyEvent', { type: text ? 'keyDown' : 'rawKeyDown', ...base, text, unmodifiedText: text, commands });
  await cdp(id, 'Input.dispatchKeyEvent', { type: 'keyUp', ...base });
}

// MARK: The cursor, in the page and on screen

// One cursor at a time: in the page while the owner is looking at Pennant's window (it's the focused one), and
// otherwise Pennant's own cursor on the Mac, above whatever covers the window.
async function cursorAt(id, x, y, click) {
  const win = state.windowId != null ? await chrome.windows.get(state.windowId).catch(() => null) : null;
  const watching = !!(win && win.focused);
  const at = await inPage(id, drawCursor, [x, y, click, watching]).catch(() => null);
  if (at && !watching) send({ event: 'cursor', x: at.sx, y: at.sy, click });
}

// Runs in the page: where (x, y) is on the screen, and, when `show`, a violet pointer that glides there.
function drawCursor(x, y, click, show) {
  // outerWidth is in screen points and innerWidth in the page's own pixels, so their ratio is the page's zoom.
  const zoom = window.innerWidth > 0 ? window.outerWidth / window.innerWidth : 1;
  const at = {
    sx: window.screenX + x * zoom,
    sy: window.screenY + (window.outerHeight - window.innerHeight * zoom) + y * zoom,
  };
  let c = document.getElementById('__pennant_cursor');
  if (!show) {
    if (c) c.style.opacity = '0';
    return at;
  }
  if (!c) {
    c = document.createElement('div');
    c.id = '__pennant_cursor';
    c.style.cssText = 'position:fixed;left:0;top:0;width:22px;height:30px;z-index:2147483647;pointer-events:none;transition:transform .28s ease,opacity .3s;filter:drop-shadow(0 0 6px rgba(107,64,217,.55))';
    c.innerHTML = '<svg width="16" height="22" viewBox="0 0 16 22"><path d="M0 0 L0 19 L4.8 14 L8.3 22 L11.2 20.5 L7.7 12.8 L16 12.8 Z" fill="#6B40D9" stroke="white" stroke-width="1.5"/></svg>';
    document.documentElement.appendChild(c);
  }
  c.style.opacity = '1';
  c.style.transform = `translate(${x}px, ${y}px)`;
  if (click) {
    const r = document.createElement('div');
    r.style.cssText = `position:fixed;left:${x - 3}px;top:${y - 3}px;width:6px;height:6px;border-radius:50%;border:2px solid rgba(107,64,217,.6);z-index:2147483647;pointer-events:none;transition:all .45s ease-out`;
    document.documentElement.appendChild(r);
    requestAnimationFrame(() => { r.style.transform = 'scale(6)'; r.style.opacity = '0'; });
    setTimeout(() => r.remove(), 500);
  }
  clearTimeout(window.__pennantCursorTimer);
  window.__pennantCursorTimer = setTimeout(() => { c.style.opacity = '0'; }, 5000);
  return at;
}

// Runs in the page: the text, and the things to click or fill, numbered (passwords never read out).
function readPage() {
  const selector = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=combobox], [contenteditable=""], [contenteditable=true]';
  document.querySelectorAll('[data-pennant-ref]').forEach((e) => e.removeAttribute('data-pennant-ref'));
  const elements = [];
  let n = 0;
  for (const el of document.querySelectorAll(selector)) {
    if (elements.length >= 250) break;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    const style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none' || el.disabled) continue;
    n += 1;
    el.setAttribute('data-pennant-ref', String(n));
    const tag = el.tagName.toLowerCase();
    const kind = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? (el.type || 'text') : tag);
    const labelled = el.labels && el.labels[0] ? el.labels[0].innerText : '';
    const label = (el.getAttribute('aria-label') || labelled || el.innerText || el.placeholder || el.getAttribute('title') || el.getAttribute('alt') || el.name || '')
      .trim().replace(/\s+/g, ' ').slice(0, 90);
    const item = { ref: n, kind, label, inView: r.bottom > 0 && r.top < innerHeight };
    if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.type !== 'password') item.value = String(el.value ?? '').slice(0, 90);
    if (el.type === 'checkbox' || el.type === 'radio') item.value = el.checked ? 'checked' : 'not checked';
    if (tag === 'a' && el.href && !el.href.startsWith('javascript:')) item.href = el.href.slice(0, 300);
    elements.push(item);
  }
  const text = document.body ? document.body.innerText.replace(/\n{3,}/g, '\n\n').trim().slice(0, 12000) : '';
  return { title: document.title, url: location.href, text, elements };
}

// Runs in the page: an element by its number, scrolled into view, and its middle.
function locate(ref) {
  const el = document.querySelector(`[data-pennant-ref="${ref}"]`);
  if (!el) return null;
  el.scrollIntoView({ block: 'center', inline: 'center' });
  const r = el.getBoundingClientRect();
  const tag = el.tagName.toLowerCase();
  const kind = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? (el.type || 'field') : tag);
  const label = (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.name || '').trim().replace(/\s+/g, ' ').slice(0, 60);
  return { x: r.left + r.width / 2, y: r.top + r.height / 2, what: label ? `the ${kind} “${label}”` : `the ${kind}` };
}

function pageScale() { return window.devicePixelRatio || 1; }

function hideCursor(hidden) {
  const c = document.getElementById('__pennant_cursor');
  if (c) c.style.visibility = hidden ? 'hidden' : 'visible';
}

// MARK: Actions

const actions = {
  async open({ url, tab }) {
    if (tab != null) {
      const id = await focusTab(await ownTab(tab));
      await chrome.tabs.update(id, { url });
      await settled(id);
      return describe(id);
    }
    const windowId = await pennantWindow();
    const blank = (await chrome.tabs.query({ windowId })).find((t) => (t.url === 'about:blank' || t.pendingUrl === 'about:blank') && !state.tabs.includes(t.id));
    const t = blank ? await chrome.tabs.update(blank.id, { url, active: true }) : await chrome.tabs.create({ windowId, url, active: true });
    state.tabs.push(t.id);
    saveState();
    await addToGroup(t.id, windowId);
    await settled(t.id);
    return describe(t.id);
  },

  async read({ tab }) {
    const id = await ownTab(tab);
    const page = await inPage(id, readPage);
    return { tab: id, ...page };
  },

  async screenshot({ tab }) {
    const id = await focusTab(await ownTab(tab));
    await inPage(id, hideCursor, [true]).catch(() => {});
    const shot = await cdp(id, 'Page.captureScreenshot', { format: 'jpeg', quality: 70 });
    await inPage(id, hideCursor, [false]).catch(() => {});
    const scale = await inPage(id, pageScale);
    const metrics = await cdp(id, 'Page.getLayoutMetrics');
    const v = metrics.cssVisualViewport || metrics.visualViewport;
    return { ...(await describe(id)), data: shot.data, width: Math.round(v.clientWidth * scale), height: Math.round(v.clientHeight * scale) };
  },

  async click({ tab, ref, x, y, button = 'left', count = 1 }) {
    const id = await focusTab(await ownTab(tab));
    let point, what;
    if (ref != null) {
      const found = await inPage(id, locate, [ref]);
      if (!found) throw new Error(`There's no element ${ref} on the page now; read it again with web_read.`);
      point = found;
      what = found.what;
      await sleep(150);
    } else {
      const scale = await inPage(id, pageScale);
      point = { x: x / scale, y: y / scale };
      what = `the page at (${Math.round(x)}, ${Math.round(y)})`;
    }
    await cursorAt(id, point.x, point.y, true);
    await mouse(id, point.x, point.y, button, Math.max(1, Math.min(3, count)));
    await sleep(400);
    const t = await chrome.tabs.get(id);
    if (t.status === 'loading') await settled(id);
    return { ...(await describe(id)), did: `Clicked ${what}.` };
  },

  async type({ tab, ref, text, clear, submit }) {
    const id = await focusTab(await ownTab(tab));
    let what = 'where the caret was';
    if (ref != null) {
      const found = await inPage(id, locate, [ref]);
      if (!found) throw new Error(`There's no element ${ref} on the page now; read it again with web_read.`);
      await cursorAt(id, found.x, found.y, true);
      await mouse(id, found.x, found.y);
      what = `into ${found.what}`;
    }
    if (clear) await pressKeys(id, 'cmd+a');
    await cdp(id, 'Input.insertText', { text });
    if (submit) {
      await pressKeys(id, 'enter');
      await sleep(500);
      const t = await chrome.tabs.get(id);
      if (t.status === 'loading') await settled(id);
    }
    return { ...(await describe(id)), did: `Typed ${what}${submit ? ' and pressed Enter' : ''}.` };
  },

  async key({ tab, keys }) {
    const id = await focusTab(await ownTab(tab));
    await pressKeys(id, keys);
    await sleep(300);
    return { ...(await describe(id)), did: `Pressed ${keys}.` };
  },

  async scroll({ tab, deltaY }) {
    const id = await focusTab(await ownTab(tab));
    const size = await inPage(id, () => ({ w: innerWidth, h: innerHeight }));
    await cdp(id, 'Input.dispatchMouseEvent', { type: 'mouseWheel', x: size.w / 2, y: size.h / 2, deltaX: 0, deltaY });
    await sleep(300);
    return { ...(await describe(id)), did: `Scrolled ${deltaY > 0 ? 'down' : 'up'}.` };
  },

  async back({ tab }) {
    const id = await focusTab(await ownTab(tab));
    await chrome.tabs.goBack(id);
    await settled(id);
    return describe(id);
  },

  async tabs() {
    const list = [];
    for (const id of state.tabs) {
      try { list.push(await describe(id)); } catch {}
    }
    return { tabs: list };
  },

  async close({ tab }) {
    const id = await ownTab(tab);
    await chrome.tabs.remove(id);
    return { tab: id };
  },

  async status() {
    return { connected: true, tabs: state.tabs.length };
  },

  // Pennant updated the files: start again from them.
  async reload() {
    setTimeout(() => chrome.runtime.reload(), 100);
    return { reloading: true };
  },
};

// The popup asks whether Pennant is reachable.
chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message === 'status') reply({ connected: !!socket && socket.readyState === 1, tabs: state.tabs.length });
  if (message === 'connect') { connect(); reply({}); }
  if (message === 'show') {
    if (state.windowId !== null) chrome.windows.update(state.windowId, { focused: true }).catch(() => {});
    reply({});
  }
});
