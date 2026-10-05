/* pennant.dev: a day with Pennant. */
(() => {
  'use strict';
const P = {
    code: '<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>',
    down: '<path d="M12 5v14M19 12l-7 7-7-7"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    checkc: '<circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.8 2.8L16 9.5"/>',
    x: '<path d="M18 6 6 18M6 6l12 12"/>',
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    target: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.2"/>',
    doc: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h5"/>',
    brain: '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V6a2 2 0 0 0-3-2zM15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15" rx="2.5"/><path d="M8 3v4M16 3v4M3.5 10h17"/>',
    sparkles: '<path d="M10 3.5 11.8 9l5.2 1.8-5.2 1.8L10 18l-1.8-5.4L3 10.8 8.2 9z"/><path d="M18 13.5l.9 2.6 2.6.9-2.6.9-.9 2.6-.9-2.6-2.6-.9 2.6-.9z"/>',
    more: '<circle cx="12" cy="12" r="9"/><path d="M8 12h.01M12 12h.01M16 12h.01"/>',
    seal: '<path d="M12 2.5 14.3 4l2.7-.2 1 2.5 2.4 1.3-.5 2.7 1.3 2.4-1.9 2 .1 2.8-2.7.6-1.4 2.4-2.6-.9-2.5 1.3-1.9-2-2.8-.3-.5-2.7L2.5 13l1.3-2.4L3.3 8l2.4-1.3 1-2.5 2.7.2z"/><path d="m8.5 12 2.4 2.4 4.6-4.8"/>',
    display: '<rect x="3" y="4" width="18" height="12.5" rx="2"/><path d="M9 20h6M12 16.5V20"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    chat: '<path d="M21 12a8 8 0 0 1-11.6 7.1L3 21l1.9-6.4A8 8 0 1 1 21 12z"/>',
    hand: '<path d="M18 11V6a2 2 0 0 0-4 0v4M14 10V4a2 2 0 0 0-4 0v6M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.9-6-2.4l-3.6-3.6a2 2 0 0 1 2.8-2.8L7 15"/>',
    pause: '<path d="M9 6v12M15 6v12"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    play: '<path d="m7 4 13 8-13 8z" fill="currentColor" stroke="none"/>',
    resume: '<path d="m8 5 11 7-11 7z"/>',
    arrow: '<path d="M7 17 17 7M9 7h8v8"/>',
    right: '<path d="M5 12h14M13 6l6 6-6 6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M21.5 20a6.5 6.5 0 0 0-4-6"/>',
    plug: '<path d="M9 2v6M15 2v6M6 8h12v3a6 6 0 0 1-12 0zM12 17v5"/>',
    person: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    building: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M9 7h.01M15 7h.01M9 11h.01M15 11h.01M9 15h.01M15 15h.01M10 21v-3h4v3"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    chip: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
    wrench: '<path d="M14.7 6.3a4 4 0 0 0 5 5L22 14l-8 8-2.3-2.3a4 4 0 0 0-5-5L4 12l8-8z"/>',
    doc2: '<path d="M8 3h8l4 4v12a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M4 7v12a2 2 0 0 0 2 2"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
    file: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>',
    key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M17 6l3 3M15 8l2 2"/>',
    alert: '<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>',
    book: '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20V3H6.5A2.5 2.5 0 0 0 4 5.5z"/><path d="M4 19.5A2.5 2.5 0 0 0 6.5 22H20v-5"/>',
    cloud: '<path d="M17.5 19a4.5 4.5 0 1 0-1.4-8.8A6 6 0 0 0 4.5 12 3.5 3.5 0 0 0 6 19z"/>',
    server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    laptop: '<rect x="4" y="5" width="16" height="11" rx="2"/><path d="M2 19h20"/>',
    eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    video: '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="m10 9 5 3-5 3z"/>',
    megaphone: '<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
    cursor: '<path d="m4 3 7 17 2.5-7.5L21 10z"/>',
    lock: '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    type: '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    clip: '<path d="m21 11-8.5 8.5a5 5 0 0 1-7-7L14 4a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.5a1.7 1.7 0 0 1-2.4-2.4L15.5 7"/>',
    spark: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M18.4 5.6l-2.8 2.8M8.4 15.6l-2.8 2.8"/>',
    download: '<path d="M12 3v12M7 10l5 5 5-5M4 21h16"/>',
    dollar: '<path d="M12 2v20M17 6.5C17 4.6 14.8 3.5 12 3.5S7 4.6 7 6.8c0 5 10 2.7 10 8 0 2.4-2.3 3.7-5 3.7s-5-1.2-5-3.4"/>',
    pulse: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    replay: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>',
    fork: '<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="8" r="2.5"/><path d="M6 8.5v7M18 10.5c0 4-4 5-9.5 6"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  };
  Object.assign(P, {
    volume: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    chart: '<path d="M3 3v18h18"/><path d="M8 17v-6M13 17V7M18 17v-4"/>',
    branch: '<circle cx="6" cy="5" r="2.5"/><circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="7" r="2.5"/><path d="M6 7.5v9M18 9.5c0 4-4 5-9.5 6.5"/>',
  });

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const ic = n => `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${P[n] || ''}</svg>`;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  $$('[data-ic]').forEach(el => { el.outerHTML = ic(el.dataset.ic); });

  /* The hero picture: a tilt toward the pointer, Pennant's notifications coming in, a banner on the phone. */
  const showcase = $('#showcase'), tilt = $('#showcase .tilt'), toasts = $('#toasts'), banner = $('#banner');
  if (showcase && !reduce) {
    if (matchMedia('(pointer: fine)').matches) {
      showcase.addEventListener('pointermove', e => {
        const r = showcase.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
        tilt.style.setProperty('--ry', (-6 + x * 8).toFixed(2) + 'deg');
        tilt.style.setProperty('--rx', (2 - y * 5).toFixed(2) + 'deg');
      });
      showcase.addEventListener('pointerleave', () => { tilt.style.removeProperty('--ry'); tilt.style.removeProperty('--rx'); });
    }
  }
  const NOTES = [
    ['Inbox drafts', 'Done · one reply needs you', 'Needs you', 'you'],
    ['Faster imports', 'Pull request #482 is up', 'Done', ''],
    ['The heartbeat', 'Checked in · nothing new', 'Quiet', 'quiet'],
    ['Competitor prices', 'Three helpers finished', 'Done', ''],
    ['Launch post', 'Waiting for your yes', 'Needs you', 'you'],
  ];
  let noteI = 0, heroVisible = true;
  function note() {
    const [title, line, chip, cls] = NOTES[noteI++ % NOTES.length];
    const el = add(toasts, `<div class="toast"><span class="av"><svg class="ribbon" aria-hidden="true"><use href="#ribbon"/></svg></span><b>${esc(title)}</b><small>${esc(line)}</small><em class="${cls}">${esc(chip)}</em></div>`);
    toasts.prepend(el);
    const all = $$('.toast', toasts);
    all.slice(2).forEach(t => { t.classList.add('out'); setTimeout(() => t.remove(), 450); });
  }
  if (toasts) {
    note();
    if (!reduce) {
      new IntersectionObserver(es => { heroVisible = es.some(e => e.isIntersecting); }).observe(showcase);
      setTimeout(note, 1600);
      setInterval(() => { if (heroVisible && !document.hidden) note(); }, 3800);
      let bannerOn = false;
      setInterval(() => {
        if (!heroVisible || document.hidden) return;
        bannerOn = !bannerOn;
        banner.classList.toggle('on', bannerOn);
      }, 4200);
    }
  }

  /* The day's log: the hour you're reading lights its dot. Nothing here moves the page. */
  const entries = $$('.entry');
  const lightObs = new IntersectionObserver(found => found.forEach(e => {
    if (e.isIntersecting) entries.forEach(x => x.classList.toggle('on', x === e.target));
  }), { rootMargin: '-40% 0px -55% 0px' });
  entries.forEach(x => lightObs.observe(x));

  /* ---------- Penny's voice: an audio element, a waveform that follows it, a caption that keeps up ---------- */
  const audio = $('#voice');
  let ctx, analyser, bins;
  function ensureAudioGraph() {
    if (ctx || !window.AudioContext) return;
    try {
      ctx = new AudioContext();
      const src = ctx.createMediaElementSource(audio);
      analyser = ctx.createAnalyser();
      analyser.fftSize = 128;
      bins = new Uint8Array(analyser.frequencyBinCount);
      src.connect(analyser);
      analyser.connect(ctx.destination);
    } catch (e) { ctx = null; analyser = null; }
  }
  const voice = { target: null, mode: 'idle', text: '', started: 0, seconds: 0, finished: false };
  function setCaption(cap, text, fraction) {
    const words = text.split(' ');
    const n = Math.round(words.length * Math.min(1, Math.max(0, fraction)));
    const from = Math.max(0, n - 14), to = Math.min(words.length, Math.max(n, from + 14) + 6);
    cap.innerHTML = (from > 0 ? '… ' : '') + esc(words.slice(from, n).join(' ')) + (n < to ? ` <span class="ahead">${esc(words.slice(n, to).join(' '))}</span>` : '') + (to < words.length ? ' …' : '');
  }
  function frame(t) {
    const v = voice;
    if (v.target) {
      const playing = !audio.paused && !audio.ended && audio.currentTime > 0;
      if (playing && analyser) analyser.getByteFrequencyData(bins);
      const bars = v.target.wave.children, h = v.target.wave.clientHeight;
      for (let i = 0; i < bars.length; i++) {
        let y = 4;
        if (playing && analyser) y = 4 + (bins[Math.min(bins.length - 1, 2 + Math.floor(i * bins.length * 0.55 / bars.length))] / 255) * (h - 4);
        else if (playing || v.mode === 'speak') y = 5 + Math.abs(Math.sin(t / 140 + i * 0.9) * Math.sin(t / 310 + i * 0.37)) * (h - 6);
        else if (v.mode === 'listen') y = 4 + Math.abs(Math.sin(t / 90 + i * 1.7)) * h * 0.4;
        else if (v.mode === 'think') y = 4 + (Math.sin(t / 220 - i * 0.6) + 1) * 3;
        bars[i].style.height = y.toFixed(1) + 'px';
      }
      if (v.text) {
        const fraction = playing && audio.duration ? audio.currentTime / audio.duration
          : v.finished ? 1 : v.mode === 'speak' ? (performance.now() - v.started) / (v.seconds * 1000) : 0;
        setCaption(v.target.caption, v.text, fraction);
      }
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  function speak(target, text, clip, out, seconds) {
    Object.assign(voice, { target, text, seconds, started: performance.now(), finished: false, mode: 'speak' });
    return new Promise(resolve => {
      const finish = () => { voice.mode = 'idle'; voice.finished = true; audio.onended = null; resolve(); };
      if (out && clip) {
        ensureAudioGraph();
        if (ctx && ctx.state === 'suspended') ctx.resume();
        audio.src = clip;
        audio.onended = finish;
        audio.play().catch(() => setTimeout(finish, seconds * 1000));
      } else setTimeout(finish, reduce ? 0 : seconds * 1000);
    });
  }
  function hush() { audio.pause(); audio.onended = null; }

  /* ---------- Shared pieces ---------- */
  const runs = {};
  const wait = (ms, name, token) => new Promise(r => setTimeout(() => r(runs[name] === token), reduce ? 0 : ms));
  function add(el, html) {
    const box = document.createElement('div');
    box.innerHTML = html.trim();
    const node = box.firstElementChild;
    el.appendChild(node);
    return node;
  }
  const bubble = (who, text, extra = '') => `<div class="msg ${who}">${esc(text)}${extra}</div>`;
  function card(host, icon, title, kind, kindCls, body, go, ok, no) {
    const node = add(host, `<div class="card"><div class="card-h">${ic(icon)}${esc(title)}<span class="tagline ${kindCls}">${kind}</span></div><div class="card-b">${body}</div><div class="card-f"><button class="go" type="button" data-act="ok">${go}</button><button type="button" data-act="ask">Request changes</button><button type="button" data-act="no">Reject</button></div><form class="changes"><input type="text" aria-label="What to change" placeholder="Say what to change"><button type="submit">Send</button></form><div class="outcome" data-ok="${esc(ok)}" data-no="${esc(no)}"></div></div>`);
    const outcome = $('.outcome', node), form = $('.changes', node);
    const decide = (kindDone, text) => {
      node.classList.remove('asking');
      node.classList.add('decided', kindDone);
      outcome.innerHTML = (kindDone === 'ok' ? ic('checkc') : ic('x')) + `<span>${esc(text)}</span>`;
    };
    $$('[data-act]', node).forEach(b => b.addEventListener('click', () => {
      if (b.dataset.act === 'ok') decide('ok', outcome.dataset.ok);
      if (b.dataset.act === 'no') decide('no', outcome.dataset.no);
      if (b.dataset.act === 'ask') { node.classList.add('asking'); $('input', form).focus(); }
    }));
    form.addEventListener('submit', e => {
      e.preventDefault();
      const note = $('input', form).value.trim() || 'Make it a little better';
      decide('no', `Sent back: "${note}". Pennant redoes it and puts up a new card.`);
    });
    return node;
  }
  function countUp(el, to) {
    if (reduce) { el.textContent = to; return; }
    const start = performance.now(), dur = 900;
    const step = now => { const f = Math.min(1, (now - start) / dur); el.textContent = Math.round(to * f); if (f < 1) requestAnimationFrame(step); };
    requestAnimationFrame(step);
  }

  /* ---------- 6:00 · the inbox ---------- */
  async function inbox() {
    const token = runs.inbox = (runs.inbox || 0) + 1;
    const rows = $$('#mail .mrow'), host = $('#inbox-card');
    rows.forEach(r => r.classList.remove('done', 'gone', 'hit'));
    host.innerHTML = '';
    $$('#tally b').forEach(b => { b.textContent = '0'; });
    if (!await wait(400, 'inbox', token)) return;
    $$('#tally b').forEach(b => countUp(b, +b.dataset.n));
    for (const r of rows) {
      r.classList.add('hit');
      if (!await wait(420, 'inbox', token)) return;
      r.classList.remove('hit');
      r.classList.add('done');
      if (r.hasAttribute('data-gone')) r.classList.add('gone');
      if (!await wait(260, 'inbox', token)) return;
    }
    if (!await wait(400, 'inbox', token)) return;
    card(host, 'mail', 'Reply to Jonas Lindqvist', 'Sending', 'send',
      `<blockquote>Hi Jonas, shared views go live for every Northwind workspace on the 21st, with the admin switch a week before. Priya's team can turn them on under Settings › Views; nothing to install.
Maya</blockquote>`, 'Approve &amp; send', 'Sent from Maya\'s mail, exactly as shown.', 'Not sent. The draft is kept.');
  }

  /* ---------- 8:30 · the morning brief ---------- */
  const BRIEF = "Morning, Maya. Three things from overnight. The inbox is sorted and one reply needs you, the import fix is up for review, and the launch post is waiting for your yes. Everything else ran clean, for about forty cents.";
  const briefTarget = { wave: $('#brief-wave'), caption: $('#brief-caption') };
  async function brief(out) {
    const token = runs.brief = (runs.brief || 0) + 1;
    const chatEl = $('#brief-chat'), state = $('#brief-state'), phoneEl = $('#brief-phone');
    hush();
    chatEl.innerHTML = ''; phoneEl.innerHTML = '';
    briefTarget.caption.textContent = '';
    const setState = (cls, label, mode) => { state.className = 'talk-state ' + cls; $('.label-s', state).textContent = label; voice.target = briefTarget; voice.mode = mode; voice.text = ''; };
    setState('', 'Listening…', 'listen');
    if (!await wait(1300, 'brief', token)) return;
    add(chatEl, bubble('you', 'Morning. What happened overnight?', `<span class="said">${ic('mic')}Said on iPhone</span>`));
    add(phoneEl, bubble('you', 'Morning. What happened overnight?'));
    setState('thinking', 'Thinking…', 'think');
    const typing = add(chatEl, '<div class="msg pen"><span class="typing"><i></i><i></i><i></i></span></div>');
    if (!await wait(900, 'brief', token)) return;
    typing.remove();
    add(chatEl, bubble('pen', BRIEF));
    add(phoneEl, bubble('pen', 'Morning, Maya. Three things from overnight…'));
    state.className = 'talk-state speaking';
    $('.label-s', state).textContent = 'Penny is speaking';
    await speak(briefTarget, BRIEF, 'assets/penny-brief.m4a', out, 13.5);
    if (runs.brief !== token) return;
    state.className = 'talk-state';
    $('.label-s', state).textContent = 'Talk mode';
    add(chatEl, `<div class="threads">
      <div class="tl"><span class="st you">${ic('hand')}</span><span>Inbox drafts<small>One reply needs you</small></span><span class="c">$0.05</span></div>
      <div class="tl"><span class="st">${ic('checkc')}</span><span>Faster imports<small>Pull request #482 is up</small></span><span class="c">$0.21</span></div>
      <div class="tl"><span class="st you">${ic('hand')}</span><span>Launch post for the company page<small>Waiting for your yes</small></span><span class="c">$0.04</span></div>
      <div class="tl"><span class="st">${ic('checkc')}</span><span>6 more ran clean overnight<small>Backups, reports, the weekly digest</small></span><span class="c">$0.11</span></div>
    </div>`);
  }

  /* ---------- 9:15 · code ---------- */
  const CODE_STEPS = [
    'Cloned <b>harbor/importer</b> into a folder of its own',
    'Found the slow path: one INSERT for every row',
    'Batched the writes, 5,000 rows a statement',
    'Ran the tests: <b>214 passed</b>',
    'Timed 50,000 rows before and after',
    'Opened <b>#482</b> as harbor-pennant[bot]',
  ];
  async function code() {
    const token = runs.code = (runs.code || 0) + 1;
    const list = $('#code-steps'), lines = $$('#diff span'), bench = $$('#bench div'), pr = $('#pr'), host = $('#code-card');
    list.innerHTML = ''; host.innerHTML = '';
    lines.forEach(l => l.classList.remove('on')); bench.forEach(b => b.classList.remove('on')); pr.classList.remove('on');
    lines[0].classList.add('on');
    for (let i = 0; i < CODE_STEPS.length; i++) {
      $$('li.now', list).forEach(li => { li.classList.remove('now'); $('.st', li).innerHTML = ic('checkc'); });
      add(list, `<li class="now"><span class="st"></span><span>${CODE_STEPS[i]}</span></li>`);
      if (i === 1) { lines[1].classList.add('on'); lines[2].classList.add('on'); }
      if (i === 2) for (let k = 3; k < lines.length; k++) { if (!await wait(260, 'code', token)) return; lines[k].classList.add('on'); }
      if (i === 4) { bench[0].classList.add('on'); if (!await wait(500, 'code', token)) return; bench[1].classList.add('on'); }
      if (i === 5) pr.classList.add('on');
      if (!await wait(1100, 'code', token)) return;
    }
    $$('li.now', list).forEach(li => { li.classList.remove('now'); $('.st', li).innerHTML = ic('checkc'); });
    if (!await wait(400, 'code', token)) return;
    card(host, 'branch', 'Delete the branch import-batching-try1', 'Deleting', 'del',
      '<div class="row"><span>harbor/importer · the first attempt, replaced by #482</span></div>', 'Approve', 'Deleted. #482 is the one to review.', 'Kept.');
  }



  /* ---------- 11:00 · a goal ---------- */
  async function goal() {
    const token = runs.goal = (runs.goal || 0) + 1;
    const next = $('#g-next'), doing = $('#g-doing'), waiting = $('#g-wait'), session = $('#goal-session'), host = $('#goal-card');
    const count = () => { $('#c-next').textContent = next.children.length; $('#c-doing').textContent = doing.children.length; $('#c-wait').textContent = waiting.children.length; };
    // Back to the start: the post is next on the board.
    const post = $('[data-id="post"]') || add(next, '<div class="gi" data-id="post">A post on shared workspaces<small>People are asking about it</small></div>');
    post.className = 'gi'; post.innerHTML = 'A post on shared workspaces<small>People are asking about it</small>';
    next.prepend(post); waiting.innerHTML = ''; session.innerHTML = ''; host.innerHTML = '';
    $('#goal-followers').style.setProperty('--w', '0%'); $('#goal-spend').style.setProperty('--w', '0%'); $('#goal-spent').textContent = '$6.02 of $20';
    count();
    if (!await wait(300, 'goal', token)) return;
    $('#goal-followers').style.setProperty('--w', '80.6%'); $('#goal-spend').style.setProperty('--w', '30.1%');
    const line = (icon, html) => add(session, `<div class="line">${ic(icon)}<span>${html}</span></div>`);
    if (!await wait(700, 'goal', token)) return;
    line('pulse', '<b>11:00</b> The heartbeat started a session: one was due');
    if (!await wait(900, 'goal', token)) return;
    doing.appendChild(post); post.classList.add('now'); count();
    line('chart', 'Read last week\'s numbers: <b>+84 followers</b>, text posts beat links');
    if (!await wait(1000, 'goal', token)) return;
    line('search', 'Shared workspaces came up in <b>11 customer emails</b> this month');
    if (!await wait(1000, 'goal', token)) return;
    line('doc', 'Drafted the post and a six-slide carousel');
    $('#goal-spend').style.setProperty('--w', '32%'); $('#goal-spent').textContent = '$6.40 of $20';
    if (!await wait(900, 'goal', token)) return;
    waiting.appendChild(post); post.classList.remove('now'); post.classList.add('you'); post.innerHTML = 'A post on shared workspaces<small>Waiting for your yes</small>'; count();
    if (!await wait(400, 'goal', token)) return;
    card(host, 'megaphone', "Post to Harbor's company page", 'Publishing', '',
      `<div class="post">Eleven customers asked us the same thing this month: can a whole team share one workspace? As of today, yes. Here's how Northwind set theirs up in an afternoon.<small>With a six-slide carousel · best time to post: 1 pm</small></div>`,
      'Approve &amp; post', 'Posted. It moves to Done, and Monday\'s numbers will say how it did.', 'Not posted. It stays on the board for later.');
  }

  /* ---------- 14:00 · from the phone ---------- */
  const VENUE = "I found three places that can take twenty on Thursday. The Mill House is the best fit: a private room, a set menu at $65 a head, and it's a short walk from the office. The booking card is up for you.";
  const venueTarget = { wave: $('#venue-wave'), caption: $('#venue-caption') };
  const VENUE_PAGES = {
    search: { url: 'maps.example/search?q=private+dining+for+20', html: `<div class="pv-h">${ic('search')}Private dining for 20 · near the office</div><div class="pv-list"><div class="pv-item" id="v-mill"><span>The Mill House<small>Private room · 24 seats · 6 min walk</small></span><span class="p">$$</span></div><div class="pv-item"><span>Lantern &amp; Oak<small>Semi-private · 30 seats · 12 min walk</small></span><span class="p">$$$</span></div><div class="pv-item"><span>Cardamom<small>Back room · 20 seats · 9 min walk</small></span><span class="p">$$</span></div></div>` },
    mill: { url: 'themillhouse.example/private-dining', html: `<div class="pv-h">The Mill House · private dining</div><div class="pv-list"><div class="pv-item"><span>The Loft room<small>Up to 24 guests · own entrance</small></span><span class="p">✓</span></div><div class="pv-item"><span>Set menu<small>Three courses, wine pairing optional</small></span><span class="p">$65</span></div><div class="pv-item hit" id="v-avail"><span>Thursday, 7:00 pm<small><mark>Available for 20</mark></small></span><span class="p">✓</span></div></div>` },
  };
  function venueCursor(id) {
    const cur = $('#venue-cursor'), page = $('#venue-page'), el = id && $('#' + id, page);
    if (!el) { cur.hidden = true; return; }
    const box = page.closest('.browser').getBoundingClientRect(), r = el.getBoundingClientRect();
    cur.hidden = false;
    cur.style.transform = `translate(${Math.round(r.left - box.left + Math.min(r.width * 0.55, 90))}px, ${Math.round(r.top - box.top + r.height / 2)}px)`;
    setTimeout(() => { cur.classList.remove('click'); void cur.offsetWidth; cur.classList.add('click'); }, reduce ? 0 : 650);
  }
  async function venue(out) {
    const token = runs.venue = (runs.venue || 0) + 1;
    const phoneEl = $('#venue-phone'), state = $('#venue-state'), page = $('#venue-page'), url = $('#venue-url'), host = $('#venue-card');
    hush();
    phoneEl.innerHTML = ''; host.innerHTML = ''; page.innerHTML = ''; url.textContent = "its own tab in Maya's Chrome"; $('#venue-cursor').hidden = true;
    venueTarget.caption.textContent = '';
    const setState = (cls, label, mode) => { state.className = 'talk-state ' + cls; $('.label-s', state).textContent = label; voice.target = venueTarget; voice.mode = mode; voice.text = ''; };
    setState('', 'Listening…', 'listen');
    if (!await wait(1400, 'venue', token)) return;
    add(phoneEl, bubble('you', 'Find somewhere for twenty on Thursday, near the office, about sixty a head.'));
    setState('thinking', 'Thinking…', 'think');
    if (!await wait(800, 'venue', token)) return;
    add(phoneEl, bubble('pen', "On it. I'll look and come back with a shortlist."));
    const show = key => { url.textContent = VENUE_PAGES[key].url; page.innerHTML = VENUE_PAGES[key].html; };
    show('search');
    if (!await wait(500, 'venue', token)) return;
    venueCursor('v-mill');
    if (!await wait(1400, 'venue', token)) return;
    show('mill');
    if (!await wait(400, 'venue', token)) return;
    venueCursor('v-avail');
    if (!await wait(1500, 'venue', token)) return;
    $('#venue-cursor').hidden = true;
    url.textContent = 'shortlist · three places';
    page.innerHTML = `<div class="pv-h">${ic('list')}Thursday, 7 pm · twenty people</div><table class="table"><thead><tr><th>Place</th><th>Room</th><th style="text-align:right">A head</th></tr></thead><tbody><tr class="best"><td>The Mill House<small>6 min walk</small></td><td>The Loft, 24 seats</td><td class="num">$65</td></tr><tr><td>Cardamom<small>9 min walk</small></td><td>Back room, 20 seats</td><td class="num">$58</td></tr><tr><td>Lantern &amp; Oak<small>12 min walk</small></td><td>Semi-private</td><td class="num">$72</td></tr></tbody></table>`;
    add(phoneEl, bubble('pen', 'I found three places that can take twenty on Thursday…'));
    state.className = 'talk-state speaking'; $('.label-s', state).textContent = 'Penny is speaking';
    await speak(venueTarget, VENUE, 'assets/penny-venue.m4a', out, 11.5);
    if (runs.venue !== token) return;
    state.className = 'talk-state'; $('.label-s', state).textContent = 'Talk mode';
    card(host, 'dollar', 'Book The Mill House · Thursday, 7 pm', 'Spending', '',
      '<div class="row"><span>The Loft room · 20 people · set menu $65</span></div><div class="row"><span>Deposit now, the rest on the night</span><b>$300.00</b></div>',
      'Approve &amp; book', 'Booked. It\'s on the team calendar, and the confirmation is in Maya\'s mail.', 'Not booked. The shortlist stays in the thread.');
  }

  /* ---------- 16:40 · production ---------- */
  const LOGS = [
    ['16:31:58', 'secrets rotated: PAYMENTS_API_KEY (provider console)'],
    ['16:32:04', 'checkout POST /pay 502 upstream auth failed', 'e'],
    ['16:32:05', 'checkout POST /pay 502 upstream auth failed', 'e'],
    ['16:32:09', 'retry 1/3 payments: 401 invalid api key', 'e'],
    ['16:33:41', 'checkout POST /pay 502 upstream auth failed', 'e'],
    ['16:35:12', 'deploy harbor-web: env PAYMENTS_API_KEY unchanged since Oct 1'],
    ['16:38:30', 'checkout POST /pay 502 upstream auth failed', 'e'],
  ];
  async function prod() {
    const token = runs.prod = (runs.prod || 0) + 1;
    const logs = $('#prod-logs'), list = $('#prod-steps'), host = $('#prod-card'), fix = $('#prod-fix'), line = $('#prod-line');
    logs.innerHTML = ''; list.innerHTML = ''; host.innerHTML = '';
    fix.setAttribute('opacity', '0'); line.style.opacity = '1';
    $('#prod-rate').textContent = 'Checkout errors at 4.2%'; $('#prod-since').textContent = 'since 16:32 · normally under 0.1%';
    $('#prod-rate').closest('.alert').style.opacity = '1';
    for (const [t, text, cls] of LOGS) {
      add(logs, `<div class="${cls || ''}">${t} ${esc(text)}</div>`);
      if (!await wait(280, 'prod', token)) return;
    }
    const step = (html, cost) => add(list, `<li>${ic('checkc')}<span>${html}</span><span class="c">${cost}</span></li>`);
    if (!await wait(400, 'prod', token)) return;
    step('A helper on Gemma 4, on this Mac, read <b>12,400 log lines</b>', '$0.00');
    if (!await wait(1000, 'prod', token)) return;
    step('Errors began at <b>16:32</b>, a minute after the payments key was rotated', '$0.01');
    if (!await wait(1000, 'prod', token)) return;
    step('The deployment still has the <b>old key</b>; the new one is in the vault', '$0.01');
    if (!await wait(800, 'prod', token)) return;
    const node = card(host, 'server', 'Update the key and restart checkout', 'Changing', 'change',
      '<div class="row"><span>harbor-web · secret PAYMENTS_API_KEY from the vault</span></div><div class="row"><span>Restart checkout, 2 pods, one at a time</span></div>',
      'Approve', 'Done. Errors back under 0.1% by 16:44.', 'Left as it is. The cause is in the thread.');
    $('.go', node).addEventListener('click', () => {
      fix.setAttribute('opacity', '1');
      $('#prod-rate').textContent = 'Checkout errors at 0.08%'; $('#prod-since').textContent = 'resolved at 16:44';
      $('#prod-rate').closest('.alert').style.opacity = '.55';
    });
  }

  /* ---------- 23:00 · the night ---------- */
  async function night() {
    const token = runs.night = (runs.night || 0) + 1;
    const jobs = $$('#night-jobs li'), bars = $$('.ledger .bar i'), learned = $$('#night-learned div');
    jobs.forEach(j => j.classList.remove('on', 'run')); bars.forEach(b => { b.style.width = '0'; }); learned.forEach(l => l.classList.remove('on'));
    for (const j of jobs) {
      j.classList.add('on', 'run');
      if (!await wait(650, 'night', token)) return;
      j.classList.remove('run');
    }
    bars.forEach(b => { b.style.width = b.dataset.w + '%'; });
    for (const l of learned) { if (!await wait(500, 'night', token)) return; l.classList.add('on'); }
  }

  /* Each hour plays once when it comes into view; the buttons play it again. */
  const SCENES = { inbox, brief, code, goal, venue, prod, night };
  const seen = new Set();
  const sceneObs = new IntersectionObserver(entries => entries.forEach(e => {
    const name = e.target.dataset.scene;
    if (e.isIntersecting && !seen.has(name)) { seen.add(name); SCENES[name](false); }
  }), { threshold: 0.35 });
  $$('.entry[data-scene]').forEach(h => sceneObs.observe(h));
  $$('[data-replay]').forEach(b => b.addEventListener('click', () => {
    const name = b.dataset.replay;
    seen.add(name);
    if (name === 'brief' || name === 'venue') { ensureAudioGraph(); if (ctx && ctx.state === 'suspended') ctx.resume(); SCENES[name](true); } else SCENES[name]();
  }));
})();
