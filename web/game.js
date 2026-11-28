'use strict';

/* ============================================================
 *  떡상 증권 — 게임 레이어
 *  아이템 · 이벤트 · 레벨/업적 · 실시간 피드 · 효과음/폭죽 · 시상식
 *  app.js 의 전역(S, rpc, $, fmt, esc, toast, selStock, poll …)을 사용한다.
 * ============================================================ */

const ITEMS = {
  insider: { icon: '🔮', name: '내부자 정보', desc: '선택한 종목의 진짜 가치를 몰래 엿봅니다', needs: 'stock' },
  pump:    { icon: '📣', name: '찌라시', desc: '선택한 종목에 호재 찌라시! 적정가 +10%', needs: 'stock' },
  bomb:    { icon: '🧨', name: '악성 루머', desc: '선택한 종목에 루머 폭탄! 적정가 -10%', needs: 'stock' },
  shield:  { icon: '🛡️', name: '손실 보험', desc: '60초 동안 매도 손실의 50%를 돌려받습니다' },
  freeze:  { icon: '❄️', name: '얼음', desc: '라이벌을 20초간 거래 불가로 만듭니다 (방 전용)', needs: 'target' },
  lucky:   { icon: '🎰', name: '복권', desc: '70% 확률로 +1~5%, 30% 확률로 -2%' },
};

const ACHS = {
  first_trade: ['🐣', '첫 거래', '첫 주문을 체결하세요'],
  first_profit: ['💵', '첫 수익', '처음으로 이익을 내고 파세요'],
  jackpot: ['💰', '대박', '+10% 이상 수익을 내고 매도'],
  doom: ['💀', '쪽박', '-10% 이상 손실을 보고 매도'],
  streak3: ['🔥', '3연승', '3번 연속 수익 매도'],
  streak5: ['☄️', '5연승', '5번 연속 수익 매도'],
  whale: ['🐋', '고래', '시작자금 30% 이상을 한 번에 거래'],
  limit_up: ['🚀', '상한가 추격', '상한가에 매수 체결'],
  item_user: ['🎒', '아이템 사용', '아이템을 처음 사용'],
  rumor: ['🕵️', '작전 개시', '찌라시나 루머를 퍼뜨리기'],
  insured: ['🛡️', '보험금 수령', '보험으로 손실 일부 회수'],
  millionaire: ['👑', '자산 2배', '총자산을 시작자금의 2배로'],
  champion: ['🏆', '방 1등', '방 대결에서 1등으로 마감'],
};

const AVATARS = ['🐜', '🐂', '🐻', '🦊', '🐯', '🐼', '🐸', '🐵', '🦁', '🐷', '🐰', '🐱', '🐶', '🐲', '🦄', '🐳'];
const EMOJIS = ['🚀', '🤑', '😱', '😭', '🔥', '👏', '🙏', '💀'];

/* ---------- 효과음 (WebAudio, 외부 파일 없음) ---------- */
const Sound = {
  ctx: null,
  on: (() => { try { return localStorage.getItem('st_sound') !== 'off'; } catch { return true; } })(),
  ensure() {
    if (!this.ctx) { try { this.ctx = new (window.AudioContext || window.webkitAudioContext)(); } catch { return null; } }
    if (this.ctx.state === 'suspended') this.ctx.resume();
    return this.ctx;
  },
  tone(freq, start, dur, type = 'sine', vol = 0.12) {
    const c = this.ctx; if (!c) return;
    const o = c.createOscillator(); const g = c.createGain();
    o.type = type; o.frequency.value = freq;
    g.gain.setValueAtTime(vol, c.currentTime + start);
    g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + start + dur);
    o.connect(g); g.connect(c.destination);
    o.start(c.currentTime + start); o.stop(c.currentTime + start + dur + 0.02);
  },
  play(name) {
    if (!this.on || !this.ensure()) return;
    const seq = {
      coin:   [[988, 0, 0.08, 'square'], [1319, 0.08, 0.25, 'square']],
      buy:    [[660, 0, 0.07, 'triangle'], [880, 0.06, 0.1, 'triangle']],
      sell:   [[880, 0, 0.07, 'triangle'], [660, 0.06, 0.1, 'triangle']],
      sad:    [[392, 0, 0.2, 'sawtooth', 0.06], [330, 0.2, 0.2, 'sawtooth', 0.06], [262, 0.4, 0.4, 'sawtooth', 0.06]],
      fanfare:[[523, 0, 0.12], [659, 0.12, 0.12], [784, 0.24, 0.12], [1047, 0.36, 0.4]],
      rise:   [[440, 0, 0.1, 'square', 0.07], [554, 0.1, 0.1, 'square', 0.07], [659, 0.2, 0.1, 'square', 0.07], [880, 0.3, 0.3, 'square', 0.07]],
      fall:   [[880, 0, 0.1, 'square', 0.07], [659, 0.1, 0.1, 'square', 0.07], [554, 0.2, 0.1, 'square', 0.07], [330, 0.3, 0.4, 'square', 0.07]],
      blip:   [[1200, 0, 0.06, 'sine', 0.08]],
      freeze: [[1568, 0, 0.1, 'sine', 0.08], [1319, 0.08, 0.1, 'sine', 0.08], [1047, 0.16, 0.3, 'sine', 0.08]],
      bell:   [[1047, 0, 0.5, 'sine', 0.1], [1568, 0, 0.5, 'sine', 0.05]],
    }[name] || [];
    seq.forEach(([f, s, d, t, v]) => this.tone(f, s, d, t, v));
  },
};

/* ---------- 폭죽 ---------- */
const Confetti = {
  parts: [], running: false,
  burst(n = 120, x = innerWidth / 2, y = innerHeight / 3) {
    const colors = ['#f04452', '#3182f6', '#f5b301', '#2ecc71', '#ffffff', '#a259ff'];
    for (let i = 0; i < n; i++) {
      const a = Math.random() * Math.PI * 2; const sp = 4 + Math.random() * 8;
      this.parts.push({ x, y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 6, life: 90 + Math.random() * 50,
        c: colors[i % colors.length], s: 4 + Math.random() * 5, r: Math.random() * 6 });
    }
    if (!this.running) { this.running = true; requestAnimationFrame(() => this.step()); }
  },
  step() {
    const cv = document.getElementById('fx'); const g = cv.getContext('2d');
    const dpr = devicePixelRatio || 1;
    if (cv.width !== innerWidth * dpr) { cv.width = innerWidth * dpr; cv.height = innerHeight * dpr; }
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, innerWidth, innerHeight);
    this.parts = this.parts.filter((p) => p.life > 0);
    for (const p of this.parts) {
      p.vy += 0.25; p.vx *= 0.99; p.x += p.vx; p.y += p.vy; p.life--; p.r += 0.2;
      g.save(); g.translate(p.x, p.y); g.rotate(p.r); g.fillStyle = p.c;
      g.globalAlpha = Math.min(1, p.life / 30); g.fillRect(-p.s / 2, -p.s / 2, p.s, p.s * 0.6); g.restore();
    }
    if (this.parts.length) requestAnimationFrame(() => this.step()); else { this.running = false; g.clearRect(0, 0, innerWidth, innerHeight); }
  },
};

function shake(strong) {
  const el = document.getElementById('view-game');
  el.classList.remove('shake', 'shake-strong');
  void el.offsetWidth;
  el.classList.add(strong ? 'shake-strong' : 'shake');
}

function floatText(text, cls, anchorId = 'order-box') {
  const a = document.getElementById(anchorId);
  const r = a ? a.getBoundingClientRect() : { left: innerWidth / 2, top: innerHeight / 2, width: 0 };
  const el = document.createElement('div');
  el.className = 'float-text ' + (cls || '');
  el.textContent = text;
  el.style.left = (r.left + r.width / 2) + 'px';
  el.style.top = (r.top + 40) + 'px';
  document.getElementById('float-layer').appendChild(el);
  setTimeout(() => el.remove(), 1800);
}

function floatEmoji(emo) {
  const el = document.createElement('div');
  el.className = 'float-emoji';
  el.textContent = emo;
  el.style.left = (10 + Math.random() * 80) + 'vw';
  document.getElementById('float-layer').appendChild(el);
  setTimeout(() => el.remove(), 3000);
}

let popupTimer;
function popup(html, cls) {
  const p = document.getElementById('popup');
  p.className = 'popup ' + (cls || '');
  p.innerHTML = html;
  clearTimeout(popupTimer);
  popupTimer = setTimeout(() => p.classList.add('hidden'), 3200);
}

/* ============================================================ */
const GameFX = {
  roomId: null,
  channel: null,
  lastFillId: null,
  lastPrices: {},
  lastEvent: null,
  ceremonyShown: {},
  tickerQueue: [],
  tickerBusy: false,
  evTimer: null,

  /* ----- 로비 프로필 ----- */
  renderProfile() {
    const a = S.account;
    const el = document.getElementById('profile-card');
    if (!a || !el) return;
    const lv = a.level || 1;
    const base = a.level_xp || 0; const next = a.next_xp || 25;
    const pctXp = Math.max(0, Math.min(100, ((a.xp - base) / Math.max(1, next - base)) * 100));
    const mine = new Set(a.achievements || []);
    el.innerHTML = `
      <div class="pc-top">
        <button class="pc-avatar" id="pc-avatar" title="아바타 바꾸기">${esc(a.avatar || '🐜')}</button>
        <div class="pc-info">
          <div class="pc-name">${esc(a.nickname)} <span class="lv">Lv.${lv}</span></div>
          <div class="pc-title">[${esc(a.title || '개미')}]</div>
          <div class="xpbar"><div style="width:${pctXp}%"></div></div>
          <div class="muted small">경험치 ${fmt(a.xp)} / 다음 레벨 ${fmt(next)}</div>
        </div>
      </div>
      <div class="ach-grid">${Object.entries(ACHS).map(([k, [ic, nm, ds]]) =>
        `<div class="ach ${mine.has(k) ? 'on' : ''}" title="${esc(nm)} — ${esc(ds)}"><span>${ic}</span><small>${esc(nm)}</small></div>`).join('')}
      </div>`;
    document.getElementById('lobby-user').textContent = `${a.avatar || ''} ${a.nickname}${a.is_guest ? ' (게스트)' : ''}`;
    this.renderMeChip();
  },

  renderMeChip() {
    const a = S.account; const el = document.getElementById('g-me');
    if (!a || !el) return;
    const base = a.level_xp || 0; const next = a.next_xp || 25;
    const pctXp = Math.max(0, Math.min(100, ((a.xp - base) / Math.max(1, next - base)) * 100));
    el.innerHTML = `<span class="av">${esc(a.avatar || '🐜')}</span><span><b>Lv.${a.level || 1}</b> ${esc(a.title || '')}<div class="xpbar mini"><div style="width:${pctXp}%"></div></div></span>`;
  },

  openAvatarPicker() {
    const m = document.getElementById('avatar-picker');
    m.innerHTML = `<div class="modal-card"><h2>아바타 선택</h2><div class="avatar-grid">
      ${AVATARS.map((a) => `<button data-av="${a}">${a}</button>`).join('')}</div>
      <button class="btn ghost wide" data-close>닫기</button></div>`;
    m.classList.remove('hidden');
  },

  /* ----- 게임 입장/퇴장 ----- */
  enter(roomId) {
    this.roomId = roomId;
    this.lastFillId = null;
    this.lastPrices = {};
    this.lastEvent = null;
    document.getElementById('feed-list').innerHTML = '';
    document.getElementById('emoji-bar').innerHTML = EMOJIS.map((e) => `<button data-emo="${e}">${e}</button>`).join('');
    this.loadFeed();
    this.channel = sb.channel('fx-' + roomId)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'st_feed', filter: `room_id=eq.${roomId}` },
        (p) => this.onFeed(p.new, true))
      .subscribe();
    clearInterval(this.evTimer);
    this.evTimer = setInterval(() => this.renderEvent(), 250);
  },

  leave() {
    if (this.channel) { sb.removeChannel(this.channel); this.channel = null; }
    clearInterval(this.evTimer);
    this.roomId = null;
    const ev = document.getElementById('g-event'); if (ev) ev.classList.add('hidden');
  },

  async loadFeed() {
    const roomId = this.roomId;
    const { data } = await sb.from('st_feed').select('*').eq('room_id', roomId).order('id', { ascending: false }).limit(60);
    if (roomId !== this.roomId) return;
    (data || []).reverse().forEach((f) => this.onFeed(f, false));
  },

  feedItem(f) {
    const li = document.createElement('li');
    li.className = 'feed-' + f.kind;
    li.innerHTML = `<time>${timeStr(f.created_at)}</time>${esc(f.body)}`;
    return li;
  },

  onFeed(f, live) {
    const list = document.getElementById('feed-list');
    list.prepend(this.feedItem(f));
    while (list.children.length > 80) list.lastChild.remove();
    if (!live) return;
    const mine = S.account && f.body.includes(S.account.nickname + '님');
    const big = ['event', 'item', 'level', 'ach', 'profit', 'loss', 'trade', 'end', 'streak'].includes(f.kind);
    if (big) this.ticker(f.body, f.kind);
    if (f.kind === 'event') {
      if (/폭등|황소/.test(f.body)) { Sound.play('rise'); Confetti.burst(60, innerWidth / 2, 80); }
      else if (/폭락|곰장/.test(f.body)) { Sound.play('fall'); shake(true); }
    } else if (f.kind === 'item') {
      if (f.body.includes('❄️')) { Sound.play('freeze'); if (f.body.indexOf(S.account.nickname + '님을') >= 0) { shake(true); popup('❄️<br><b>얼음 공격을 받았다!</b><br>20초간 거래 불가 🥶', 'cold'); } }
      else if (f.body.includes('🧨')) { Sound.play('fall'); shake(false); }
      else Sound.play('blip');
    } else if (f.kind === 'ach' && mine) {
      Sound.play('fanfare'); Confetti.burst(100);
      popup(`🏅<br><b>업적 달성!</b><br>${esc(f.body.split('업적 달성: ')[1] || '')}`, 'gold');
    } else if (f.kind === 'level' && mine) {
      Sound.play('fanfare'); Confetti.burst(160);
      popup(`🎉<br><b>레벨 업!</b><br>${esc(f.body.split('님 ')[1] || '')}`, 'gold');
    } else if (f.kind === 'profit' || f.kind === 'streak') {
      Sound.play('coin');
    } else if (f.kind === 'end') {
      Sound.play('fanfare');
    } else if (f.kind === 'day') {
      Sound.play('bell');
    }
  },

  ticker(text, kind) {
    this.tickerQueue.push([text, kind]);
    if (this.tickerQueue.length > 5) this.tickerQueue.shift();
    if (!this.tickerBusy) this.nextTicker();
  },
  nextTicker() {
    const t = document.getElementById('ticker');
    const it = this.tickerQueue.shift();
    if (!it) { this.tickerBusy = false; t.classList.remove('show'); return; }
    this.tickerBusy = true;
    t.className = 'ticker show t-' + it[1];
    t.textContent = it[0];
    setTimeout(() => this.nextTicker(), 2600);
  },

  onChat(c) {
    if (EMOJIS.includes(c.body)) { for (let i = 0; i < 4; i++) setTimeout(() => floatEmoji(c.body), i * 120); }
  },

  /* ----- 매 poll 마다 ----- */
  onPoll(d) {
    this.renderMeChip();
    this.renderItems(d);
    this.renderStatus(d);
    this.flashPrices(d);
    this.checkFills(d);
    this.checkEvent(d.room);
    this.checkCeremony(d.room);
  },

  flashPrices(d) {
    for (const s of d.stocks) {
      const prev = this.lastPrices[s.id];
      if (prev != null && prev !== s.last) {
        const row = document.querySelector(`#stock-list [data-stock="${s.id}"]`);
        if (row) row.classList.add(s.last > prev ? 'flash-up' : 'flash-down');
        if (s.id === S.selId) {
          const q = document.getElementById('q-last');
          q.classList.remove('pop-up', 'pop-down'); void q.offsetWidth;
          q.classList.add(s.last > prev ? 'pop-up' : 'pop-down');
        }
      }
      this.lastPrices[s.id] = s.last;
      const row = document.querySelector(`#stock-list [data-stock="${s.id}"] .nm`);
      if (row && d.room.event_stock === s.id && d.room.event_kind) {
        row.insertAdjacentHTML('beforeend', d.room.event_kind === 'pump' ? ' <span class="ev-tag up">🚀폭등</span>' : ' <span class="ev-tag down">💥폭락</span>');
      }
    }
  },

  checkFills(d) {
    const fills = d.fills || [];
    const top = fills.length ? fills[0].id : 0;
    if (this.lastFillId == null) { this.lastFillId = top; return; }
    const fresh = fills.filter((f) => f.id > this.lastFillId);
    this.lastFillId = Math.max(this.lastFillId, top);
    if (!fresh.length) return;
    let realized = 0; let buys = 0; let sells = 0;
    for (const f of fresh) { if (f.side === 'buy') buys += f.qty; else { sells += f.qty; realized += f.realized; } }
    if (buys) { Sound.play('buy'); floatText(`+${fmt(buys)}주 매수 체결`, 'up'); }
    if (sells) {
      if (realized > 0) {
        Sound.play('coin'); Confetti.burst(Math.min(200, 40 + realized / 20000));
        floatText(`💰 +${fmt(realized)}원`, 'up big');
      } else if (realized < 0) {
        Sound.play('sad'); shake(false);
        floatText(`💸 ${fmt(realized)}원`, 'down big');
      } else { Sound.play('sell'); floatText(`${fmt(sells)}주 매도 체결`, 'down'); }
    }
  },

  checkEvent(room) {
    const key = room.event_kind ? room.event_kind + room.event_until : null;
    if (key && key !== this.lastEvent && this.lastEvent !== null) {
      // 이벤트 시작 효과는 피드에서 처리 (중복 방지)
    }
    this.lastEvent = key || '';
    this.renderEvent();
  },

  renderEvent() {
    const el = document.getElementById('g-event');
    const r = S.room;
    if (!el || !r || !r.event_kind || r.phase !== 'open') { if (el) el.classList.add('hidden'); return; }
    const left = Math.max(0, Math.ceil((new Date(r.event_until).getTime() - serverNow()) / 1000));
    if (!left) { el.classList.add('hidden'); return; }
    const st = S.stocks.find((s) => s.id === r.event_stock);
    const txt = {
      pump: `🚀 ${st ? st.name : ''} 폭등 이벤트! 지금 올라탈까?`,
      dump: `💥 ${st ? st.name : ''} 폭락 이벤트! 탈출하라!`,
      bull: '🐂 황소장! 전 종목 상승세',
      bear: '🐻 곰장! 전 종목 하락세',
    }[r.event_kind];
    el.className = 'event-banner ev-' + r.event_kind;
    el.innerHTML = `${esc(txt)} <b class="ev-count">${left}초</b>${st ? ` <button class="btn tiny" data-goto="${st.id}">종목 보기</button>` : ''}`;
  },

  renderItems(d) {
    const box = document.getElementById('items');
    const me = d.me;
    const items = d.items || {};
    const cdLeft = me && me.item_cd_until ? Math.ceil((new Date(me.item_cd_until).getTime() - serverNow()) / 1000) : 0;
    document.getElementById('item-cd').textContent = cdLeft > 0 ? `재사용 ${cdLeft}초` : '';
    const canUse = me && d.room.status === 'running' && d.room.phase === 'open' && !d.room.paused && cdLeft <= 0;
    const keys = Object.keys(ITEMS).filter((k) => !(k === 'freeze' && d.room.kind === 'main'));
    const html = keys.map((k) => {
      const n = items[k] || 0; const it = ITEMS[k];
      return `<button class="item ${n ? '' : 'empty'}" data-item="${k}" ${n && canUse ? '' : 'disabled'} title="${esc(it.name)} — ${esc(it.desc)}">
        <span class="ic">${it.icon}</span><span class="nm">${esc(it.name)}</span>${n ? `<span class="cnt">${n}</span>` : ''}</button>`;
    }).join('');
    if (box.dataset.html !== html) { box.innerHTML = html; box.dataset.html = html; }
    // 얼음 대상 목록
    const sel = document.getElementById('item-target');
    const show = d.room.kind !== 'main' && (items.freeze || 0) > 0;
    sel.classList.toggle('hidden', !show);
    if (show) {
      const others = (S.ranking || []).filter((r) => r.nickname !== S.account.nickname);
      const opts = '<option value="">❄️ 얼릴 상대 선택</option>' + others.map((r) => `<option value="${esc(r.nickname)}">${esc(r.avatar)} ${esc(r.nickname)}</option>`).join('');
      if (sel.dataset.html !== opts) { const v = sel.value; sel.innerHTML = opts; sel.dataset.html = opts; sel.value = v; }
    }
  },

  renderStatus(d) {
    const me = d.me; const el = document.getElementById('status-chips');
    const ov = document.getElementById('frozen-overlay');
    if (!me) { el.innerHTML = ''; ov.classList.add('hidden'); return; }
    const now = serverNow();
    const fz = me.frozen_until ? Math.ceil((new Date(me.frozen_until).getTime() - now) / 1000) : 0;
    const ins = me.insured_until ? Math.ceil((new Date(me.insured_until).getTime() - now) / 1000) : 0;
    const chips = [];
    if (ins > 0) chips.push(`<span class="chip ins">🛡️ 보험 ${ins}초</span>`);
    if (me.win_streak >= 2) chips.push(`<span class="chip fire">🔥 ${me.win_streak}연승</span>`);
    if (fz > 0) chips.push(`<span class="chip cold">❄️ 얼음 ${fz}초</span>`);
    el.innerHTML = chips.join('');
    ov.classList.toggle('hidden', !(fz > 0));
    if (fz > 0) ov.innerHTML = `❄️<br>얼음 상태!<br><b>${fz}초</b> 후 해제`;
  },

  async useItem(k) {
    const it = ITEMS[k];
    let target = null;
    if (it.needs === 'target') {
      target = document.getElementById('item-target').value;
      if (!target) { toast('얼릴 상대를 먼저 선택하세요'); document.getElementById('item-target').focus(); return; }
    }
    if (it.needs === 'stock' && !selStock()) { toast('종목을 먼저 선택하세요'); return; }
    try {
      const r = await rpc('st_use_item', { p_token: S.token, p_room: S.roomId, p_item: k, p_stock: S.selId, p_target: target });
      Sound.play(k === 'lucky' && r.message.includes('꽝') ? 'sad' : k === 'lucky' ? 'coin' : 'blip');
      if (k === 'lucky' && !r.message.includes('꽝')) Confetti.burst(80);
      popup(esc(r.message), k === 'insider' ? 'secret' : '');
      poll();
    } catch (err) { toast(err.message); }
  },

  /* ----- 시상식 ----- */
  checkCeremony(room) {
    if (room.status !== 'ended' || this.ceremonyShown[room.id]) return;
    if (!S.ranking || !S.ranking.length) { loadRanking(); return; }
    this.ceremonyShown[room.id] = true;
    const rk = S.ranking; const start = room.start_cash;
    const ret = (r) => ((r.total - start) / start) * 100;
    const pod = [rk[1], rk[0], rk[2]];
    const best = rk.reduce((a, b) => (b.best_trade > (a ? a.best_trade : -Infinity) ? b : a), null);
    const worst = rk.reduce((a, b) => (b.worst_trade < (a ? a.worst_trade : Infinity) ? b : a), null);
    const busy = rk.reduce((a, b) => (b.trades > (a ? a.trades : -1) ? b : a), null);
    const myRank = rk.findIndex((r) => r.nickname === S.account.nickname);
    const m = document.getElementById('ceremony');
    m.innerHTML = `<div class="modal-card ceremony">
      <h2>🏁 최종 결과</h2>
      <div class="podium">${pod.map((r, i) => r ? `
        <div class="pod p${[2, 1, 3][i]}"><div class="pod-av">${esc(r.avatar)}</div><div class="pod-nm">${esc(r.nickname)}</div>
          <div class="${cls(ret(r))}">${pct(ret(r))}</div><div class="pod-block">${['🥈', '🥇', '🥉'][i]}</div></div>` : '<div class="pod"></div>').join('')}
      </div>
      <div class="awards">
        ${best && best.best_trade > 0 ? `<div>🎯 <b>최고의 한 방</b> ${esc(best.avatar)} ${esc(best.nickname)} <span class="up">+${fmt(best.best_trade)}원</span></div>` : ''}
        ${worst && worst.worst_trade < 0 ? `<div>💀 <b>눈물의 손절상</b> ${esc(worst.avatar)} ${esc(worst.nickname)} <span class="down">${fmt(worst.worst_trade)}원</span></div>` : ''}
        ${busy && busy.trades > 0 ? `<div>⚡ <b>단타왕</b> ${esc(busy.avatar)} ${esc(busy.nickname)} ${fmt(busy.trades)}회 거래</div>` : ''}
      </div>
      ${myRank >= 0 ? `<p class="my-rank">내 순위: <b>${myRank + 1}위</b> / ${rk.length}명</p>` : ''}
      <button class="btn primary wide" data-close>확인</button></div>`;
    m.classList.remove('hidden');
    Sound.play('fanfare');
    Confetti.burst(250);
    setTimeout(() => Confetti.burst(150, innerWidth * 0.25, innerHeight * 0.4), 500);
    setTimeout(() => Confetti.burst(150, innerWidth * 0.75, innerHeight * 0.4), 900);
  },
};
window.GameFX = GameFX;

/* ---------- 이벤트 바인딩 ---------- */
document.addEventListener('click', async (e) => {
  Sound.ensure();
  const t = e.target;
  const item = t.closest('[data-item]');
  if (item && !item.disabled) { GameFX.useItem(item.dataset.item); return; }
  const emo = t.closest('[data-emo]');
  if (emo) {
    try { await rpc('st_send_chat', { p_token: S.token, p_room: S.roomId, p_body: emo.dataset.emo }); } catch (err) { toast(err.message); }
    return;
  }
  const go = t.closest('[data-goto]');
  if (go) { selectStock(Number(go.dataset.goto)); return; }
  if (t.closest('#pc-avatar')) { GameFX.openAvatarPicker(); return; }
  const av = t.closest('[data-av]');
  if (av) {
    try {
      S.account = await rpc('st_set_avatar', { p_token: S.token, p_avatar: av.dataset.av });
      GameFX.renderProfile();
      document.getElementById('avatar-picker').classList.add('hidden');
    } catch (err) { toast(err.message); }
    return;
  }
  if (t.closest('[data-close]') || t.classList.contains('modal')) {
    t.closest('.modal').classList.add('hidden');
  }
});

document.getElementById('btn-sound').addEventListener('click', () => {
  Sound.on = !Sound.on;
  try { localStorage.setItem('st_sound', Sound.on ? 'on' : 'off'); } catch { /* 무시 */ }
  document.getElementById('btn-sound').textContent = Sound.on ? '🔊' : '🔇';
  if (Sound.on) Sound.play('blip');
});
document.getElementById('btn-sound').textContent = Sound.on ? '🔊' : '🔇';
if (S.account) GameFX.renderProfile();
