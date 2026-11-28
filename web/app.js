'use strict';

/* ============================================================
 *  모의 증권거래소 — 클라이언트
 *  서버(Supabase/Postgres)가 매칭·잔고·시세를 모두 처리하고
 *  클라이언트는 RPC 호출과 화면 표시만 담당한다.
 * ============================================================ */

const cfg = window.STOCK_CONFIG;
const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const FEE = 0.00015;
const TAX = 0.002;

const S = {
  token: null,
  account: null,
  roomId: null,
  room: null,
  stocks: [],
  selId: null,
  data: null,          // 마지막 st_poll 결과
  clockOffset: 0,      // 서버시간 - 로컬시간 (ms)
  side: 'buy',
  otype: 'limit',
  chartMode: 'intraday',
  candles: [],
  ranking: [],
  timers: [],
  channel: null,
  priceTouched: false,
  btab: 'feed',
};

/* ---------- 유틸 ---------- */
const $ = (id) => document.getElementById(id);
const fmt = (n) => (n == null || isNaN(n) ? '-' : Math.round(n).toLocaleString('ko-KR'));
const pct = (n) => (n > 0 ? '+' : '') + n.toFixed(2) + '%';
const cls = (n) => (n > 0 ? 'up' : n < 0 ? 'down' : '');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* 무시 */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* 무시 */ } },
};
const serverNow = () => Date.now() + S.clockOffset;
const pad2 = (n) => String(n).padStart(2, '0');
const timeStr = (iso) => { const d = new Date(iso); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`; };

function tickSize(p) {
  if (p < 2000) return 1;
  if (p < 5000) return 5;
  if (p < 20000) return 10;
  if (p < 50000) return 50;
  if (p < 200000) return 100;
  if (p < 500000) return 500;
  return 1000;
}
const floorTick = (p) => { const t = tickSize(Math.floor(p)); return Math.max(1, Math.floor(p / t) * t); };
const nextUp = (p) => p + tickSize(p);
const nextDown = (p) => Math.max(1, p - tickSize(p - 1));

let toastTimer;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
}

async function rpc(name, params) {
  const { data, error } = await sb.rpc(name, params);
  if (error) {
    const msg = error.message || '오류가 발생했습니다';
    if (msg.includes('로그인이 필요합니다')) { logout(); }
    throw new Error(msg);
  }
  return data;
}

function show(view) {
  for (const v of ['auth', 'lobby', 'game']) $('view-' + v).classList.toggle('hidden', v !== view);
}

/* ============================================================
 *  로그인
 * ============================================================ */
let authTab = 'guest';
function setAuthTab(tab) {
  authTab = tab;
  document.querySelectorAll('#auth-tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  $('auth-pw-wrap').classList.toggle('hidden', tab === 'guest');
  $('auth-pw').required = tab !== 'guest';
  $('auth-pw').autocomplete = tab === 'register' ? 'new-password' : 'current-password';
  $('auth-hint').classList.toggle('hidden', tab !== 'guest');
  $('auth-submit').textContent = { guest: '시작하기', login: '로그인', register: '가입하고 시작' }[tab];
  $('auth-error').textContent = '';
}

async function submitAuth(e) {
  e.preventDefault();
  const nick = $('auth-nick').value.trim();
  const pw = $('auth-pw').value;
  $('auth-error').textContent = '';
  $('auth-submit').disabled = true;
  try {
    let res;
    if (authTab === 'guest') res = await rpc('st_guest_login', { p_nickname: nick });
    else if (authTab === 'register') res = await rpc('st_register', { p_nickname: nick, p_password: pw });
    else res = await rpc('st_login', { p_nickname: nick, p_password: pw });
    if (res.error) throw new Error(res.error);
    S.token = res.token;
    S.account = res.account;
    store.set('st_token', S.token);
    enterLobby();
  } catch (err) {
    $('auth-error').textContent = err.message;
  } finally {
    $('auth-submit').disabled = false;
  }
}

async function logout() {
  const tok = S.token;
  leaveGame();
  S.token = null;
  S.account = null;
  store.del('st_token');
  show('auth');
  if (tok) { try { await sb.rpc('st_logout', { p_token: tok }); } catch { /* 무시 */ } }
}

async function setPassword() {
  const pw = prompt('사용할 비밀번호를 입력하세요 (4자 이상).\n설정 후에는 닉네임+비밀번호로 다른 기기에서도 로그인할 수 있습니다.');
  if (!pw) return;
  try {
    S.account = await rpc('st_set_password', { p_token: S.token, p_password: pw });
    renderUser();
    toast('비밀번호가 설정되었습니다');
  } catch (err) { toast(err.message); }
}

/* ============================================================
 *  로비
 * ============================================================ */
function renderUser() {
  $('lobby-user').textContent = `${S.account.nickname}${S.account.is_guest ? ' (게스트)' : ''}`;
  $('btn-set-pw').classList.toggle('hidden', !S.account.is_guest);
  if (window.GameFX) GameFX.renderProfile();
}

async function enterLobby() {
  leaveGame();
  show('lobby');
  renderUser();
  location.hash = '';
  await loadRooms();
}

async function loadRooms() {
  $('lobby-error').textContent = '';
  try {
    const list = await rpc('st_list_rooms', { p_token: S.token });
    $('room-list').innerHTML = list.map(({ room: r, joined }) => {
      const status = { running: '진행 중', waiting: '대기 중', ended: '종료' }[r.status];
      const days = r.total_days ? `${r.current_day}/${r.total_days}일차` : `${r.current_day}일차`;
      const meta = r.kind === 'main'
        ? `모두가 함께하는 상시 시장 · 시작자금 ${fmt(r.start_cash)}원 · ${r.players}명 참여`
        : `방장 ${esc(r.owner_nickname || '-')} · ${r.players}/${r.max_players}명 · ${days} · 하루 ${r.day_seconds}초 · 시작자금 ${fmt(r.start_cash)}원`;
      return `<div class="room-card ${r.kind === 'main' ? 'main' : ''}">
        <div class="info">
          <div class="name">${r.kind === 'main' ? '🏛️ ' : ''}${esc(r.name)}
            <span class="badge ${r.status}">${status}</span>${r.is_private ? '<span class="badge">비공개</span>' : ''}</div>
          <div class="meta">${meta}</div>
        </div>
        <button class="btn ${joined ? 'ghost' : 'primary'} small" data-join="${esc(r.code)}">${joined ? '들어가기' : '참가'}</button>
      </div>`;
    }).join('') || '<p class="muted">방이 없습니다.</p>';
  } catch (err) { $('lobby-error').textContent = err.message; }
}

async function joinByCode(code) {
  $('lobby-error').textContent = '';
  try {
    const room = await rpc('st_join_room', { p_token: S.token, p_code: code });
    enterGame(room.id);
  } catch (err) { $('lobby-error').textContent = err.message; }
}

async function createRoom(e) {
  e.preventDefault();
  $('lobby-error').textContent = '';
  try {
    const room = await rpc('st_create_room', {
      p_token: S.token,
      p_name: $('cr-name').value,
      p_start_cash: Number($('cr-cash').value),
      p_day_seconds: Number($('cr-day').value),
      p_total_days: Number($('cr-days').value),
      p_max_players: Number($('cr-max').value),
      p_private: $('cr-private').checked,
    });
    enterGame(room.id);
  } catch (err) { $('lobby-error').textContent = err.message; }
}

/* ============================================================
 *  게임 화면
 * ============================================================ */
function leaveGame() {
  S.timers.forEach(clearInterval);
  S.timers = [];
  if (S.channel) { sb.removeChannel(S.channel); S.channel = null; }
  if (window.GameFX) GameFX.leave();
  S.roomId = null; S.room = null; S.data = null; S.stocks = []; S.selId = null; S.candles = [];
}

async function enterGame(roomId) {
  leaveGame();
  S.ranking = [];
  S.roomId = roomId;
  location.hash = 'room=' + roomId;
  show('game');
  $('news-list').innerHTML = '';
  $('chat-list').innerHTML = '';
  S.priceTouched = false;
  await poll();
  if (!S.roomId) return;
  loadCandles();
  loadRanking();
  loadNewsAndChat();
  subscribeRealtime();
  if (window.GameFX) GameFX.enter(roomId);
  S.timers.push(setInterval(poll, 1000));
  S.timers.push(setInterval(loadCandles, 4000));
  S.timers.push(setInterval(loadRanking, 5000));
  S.timers.push(setInterval(renderClock, 250));
}

let polling = false;
async function poll() {
  if (polling || !S.roomId) return;
  polling = true;
  const roomId = S.roomId;
  try {
    const d = await rpc('st_poll', { p_token: S.token, p_room: roomId, p_stock: S.selId });
    if (roomId !== S.roomId) return;
    S.data = d;
    S.room = d.room;
    S.stocks = d.stocks || [];
    S.clockOffset = new Date(d.now).getTime() - Date.now();
    if (d.profile) S.account = d.profile;
    if (!S.selId && S.stocks.length) { S.selId = S.stocks[0].id; polling = false; return poll(); }
    renderGame();
  } catch (err) {
    toast(err.message);
  } finally {
    polling = false;
  }
}

const selStock = () => S.stocks.find((s) => s.id === S.selId);

function selectStock(id) {
  if (id === S.selId) return;
  S.selId = id;
  S.priceTouched = false;
  S.candles = [];
  $('tape').innerHTML = '';
  $('book').innerHTML = '';
  poll();
  loadCandles();
}

function renderGame() {
  const d = S.data;
  const r = d.room;
  $('g-room-name').textContent = r.name;
  $('g-room-code').textContent = r.kind === 'main' ? '' : r.code;
  $('g-room-code').classList.toggle('hidden', r.kind === 'main');

  // 방장 대기 화면 / 종료 화면
  const banner = $('g-waiting');
  if (r.status === 'waiting') {
    const isOwner = S.account && r.owner_id === S.account.id;
    banner.innerHTML = `대기 중 · 참가자 ${r.players}/${r.max_players}명 · 방 코드 <b>${esc(r.code)}</b>를 친구에게 알려주세요.` +
      (isOwner ? ' <button id="btn-start" class="btn primary small">게임 시작</button>' : ' 방장이 시작하면 거래가 열립니다.');
    banner.classList.remove('hidden');
  } else if (r.status === 'ended') {
    banner.innerHTML = '🏁 게임이 종료되었습니다. 아래 <b>순위</b> 탭에서 결과를 확인하세요.';
    banner.classList.remove('hidden');
  } else if (r.paused) {
    banner.textContent = '접속자가 없어 시장이 일시정지되었습니다. 곧 재개됩니다…';
    banner.classList.remove('hidden');
  } else {
    banner.classList.add('hidden');
  }

  renderStockList();
  renderQuote();
  renderBook();
  renderTape();
  renderAccount();
  renderOrderForm();
  renderBottom();
  if (window.GameFX) GameFX.onPoll(d);
}

function renderClock() {
  const r = S.room;
  if (!r) return;
  const ph = $('g-phase');
  const now = serverNow();
  if (r.status === 'waiting') { ph.textContent = '대기 중'; ph.className = 'phase'; $('g-clock').textContent = ''; return; }
  if (r.status === 'ended') { ph.textContent = '게임 종료'; ph.className = 'phase'; $('g-clock').textContent = ''; return; }
  const start = new Date(r.phase_started_at).getTime();
  const dayLabel = `${r.current_day}일차${r.total_days ? '/' + r.total_days : ''}`;
  if (r.phase === 'open' && !r.paused) {
    const frac = Math.min(1, Math.max(0, (now - start) / (r.day_seconds * 1000)));
    const gm = 9 * 60 + Math.floor(frac * 390);  // 09:00 ~ 15:30 압축
    const left = Math.max(0, Math.ceil(r.day_seconds - (now - start) / 1000));
    ph.textContent = `${dayLabel} · 장중`;
    ph.className = 'phase open';
    $('g-clock').textContent = `${String(Math.floor(gm / 60)).padStart(2, '0')}:${String(gm % 60).padStart(2, '0')} · 마감까지 ${left}초`;
  } else {
    const left = Math.max(0, Math.ceil(r.break_seconds - (now - start) / 1000));
    ph.textContent = `${dayLabel} · 장 마감`;
    ph.className = 'phase closed';
    $('g-clock').textContent = r.paused ? '일시정지' : `다음 개장까지 ${left}초`;
  }
}

function changeOf(s) { return s.prev_close ? ((s.last - s.prev_close) / s.prev_close) * 100 : 0; }

function renderStockList() {
  $('stock-list').innerHTML = S.stocks.map((s) => {
    const c = changeOf(s);
    const tag = s.last >= s.upper ? '<span class="limit-tag up">상</span>' : s.last <= s.lower ? '<span class="limit-tag down">하</span>' : '';
    return `<div class="stock-row ${s.id === S.selId ? 'sel' : ''}" data-stock="${s.id}">
      <div class="nm">${esc(s.name)}${tag}</div><div class="px ${cls(c)}">${fmt(s.last)}</div>
      <div class="sc">${esc(s.sector)}</div><div class="ch ${cls(c)}">${pct(c)}</div>
    </div>`;
  }).join('');
}

function renderQuote() {
  const s = selStock();
  if (!s) return;
  const c = changeOf(s);
  $('q-name').textContent = `${s.name} (${s.symbol}) · ${s.sector}`;
  $('q-last').textContent = fmt(s.last);
  $('q-last').className = cls(c);
  $('q-chg').textContent = `${c >= 0 ? '▲' : '▼'} ${fmt(Math.abs(s.last - s.prev_close))} (${pct(c)})`;
  $('q-chg').className = 'small ' + cls(c);
  $('q-stats').innerHTML = `
    <div><span>시가</span>${fmt(s.open)}</div><div><span>고가</span><b class="up">${fmt(s.high)}</b></div>
    <div><span>저가</span><b class="down">${fmt(s.low)}</b></div><div><span>기준가</span>${fmt(s.prev_close)}</div>
    <div><span>상한가</span><b class="up">${fmt(s.upper)}</b></div><div><span>하한가</span><b class="down">${fmt(s.lower)}</b></div>
    <div><span>거래량</span>${fmt(s.volume)}</div><div><span>거래대금</span>${fmt(s.turnover / 1e6)}백만</div>`;
}

function renderBook() {
  const s = selStock();
  const b = S.data.book;
  if (!s || !b) return;
  const maxQ = Math.max(1, ...b.asks.map((x) => x.qty), ...b.bids.map((x) => x.qty));
  const myPrices = new Set(S.data.orders.filter((o) => o.stock_id === s.id && o.otype === 'limit').map((o) => o.side + o.price));
  const row = (lv, side) => {
    const c = changeOf({ last: lv.price, prev_close: s.prev_close });
    const w = (lv.qty / maxQ) * 100;
    const mine = myPrices.has(side + lv.price) ? ' ●' : '';
    const qtyCell = `<td class="q"><div class="bar" style="width:${w}%"></div><span class="qv">${fmt(lv.qty)}</span></td>`;
    const pCell = `<td class="p ${cls(c)}" data-price="${lv.price}">${fmt(lv.price)}<div class="small">${pct(c)}${mine}</div></td>`;
    return side === 'sell'
      ? `<tr class="ask ${lv.price === s.last ? 'cur' : ''}">${qtyCell}${pCell}<td></td></tr>`
      : `<tr class="bid ${lv.price === s.last ? 'cur' : ''}"><td></td>${pCell}${qtyCell}</tr>`;
  };
  const askSum = b.asks.reduce((a, x) => a + Number(x.qty), 0);
  const bidSum = b.bids.reduce((a, x) => a + Number(x.qty), 0);
  $('book').innerHTML =
    b.asks.map((x) => row(x, 'sell')).join('') +
    `<tr class="mid"><td colspan="3">매도잔량 ${fmt(askSum)} · 매수잔량 ${fmt(bidSum)}</td></tr>` +
    b.bids.map((x) => row(x, 'buy')).join('');
}

function renderTape() {
  const s = selStock();
  if (!s) return;
  $('tape').innerHTML = (S.data.trades || []).map((t) =>
    `<tr><td>${timeStr(t.created_at)}</td><td class="${cls(t.price - s.prev_close)}">${fmt(t.price)}</td>
      <td class="${t.taker_side === 'buy' ? 'up' : 'down'}">${fmt(t.qty)}</td></tr>`).join('');
}

function holdingsValue() {
  let v = 0;
  for (const h of S.data.holdings) {
    const s = S.stocks.find((x) => x.id === h.stock_id);
    if (s) v += h.qty * s.last;
  }
  return v;
}

function renderAccount() {
  const me = S.data.me;
  if (!me) { $('g-total').textContent = '관전 중'; $('g-ret').textContent = ''; return; }
  const total = me.cash + holdingsValue();
  const ret = ((total - S.room.start_cash) / S.room.start_cash) * 100;
  $('g-total').textContent = fmt(total) + '원';
  $('g-ret').textContent = pct(ret);
  $('g-ret').className = 'small ' + cls(ret);
}

/* ---------- 주문 ---------- */
function setSide(side) {
  S.side = side;
  document.querySelectorAll('.side-tabs button').forEach((b) => b.classList.toggle('active', b.dataset.side === side));
  const btn = $('o-submit');
  btn.textContent = side === 'buy' ? '매수' : '매도';
  btn.className = 'btn wide ' + side;
  renderOrderForm();
}
function setOtype(t) {
  S.otype = t;
  document.querySelectorAll('.type-tabs button').forEach((b) => b.classList.toggle('active', b.dataset.otype === t));
  $('o-price').disabled = t === 'market';
  $('px-up').disabled = $('px-dn').disabled = t === 'market';
  renderOrderForm();
}

function orderPrice() {
  const s = selStock();
  if (!s) return 0;
  if (S.otype === 'market') return S.side === 'buy' ? s.upper : s.lower;
  return Number($('o-price').value) || 0;
}

function availableQty() {
  const s = selStock();
  const me = S.data && S.data.me;
  if (!s || !me) return 0;
  if (S.side === 'buy') {
    const px = orderPrice();
    if (px <= 0) return 0;
    return Math.max(0, Math.floor((me.cash - me.locked_cash) / (px * (1 + FEE)) - 1e-9));
  }
  const h = S.data.holdings.find((x) => x.stock_id === s.id);
  return h ? h.qty - h.locked_qty : 0;
}

function renderOrderForm() {
  const s = selStock();
  const me = S.data && S.data.me;
  if (!s) return;
  if (!S.priceTouched && document.activeElement !== $('o-price')) $('o-price').value = s.last;
  const px = orderPrice();
  const qty = Number($('o-qty').value) || 0;
  if (S.side === 'buy') {
    $('o-avail').textContent = me ? `${fmt(me.cash - me.locked_cash)}원 (${fmt(availableQty())}주)` : '-';
    $('o-est').textContent = S.otype === 'market' ? `약 ${fmt(qty * s.last)}원` : `${fmt(px * qty + Math.ceil(px * qty * FEE))}원`;
  } else {
    $('o-avail').textContent = me ? `${fmt(availableQty())}주` : '-';
    const v = (S.otype === 'market' ? s.last : px) * qty;
    $('o-est').textContent = `${S.otype === 'market' ? '약 ' : ''}${fmt(v - Math.floor(v * FEE) - Math.floor(v * TAX))}원 (세후)`;
  }
  const r = S.room;
  const frozen = me && me.frozen_until && new Date(me.frozen_until).getTime() > serverNow();
  const canTrade = me && r.status === 'running' && r.phase === 'open' && !r.paused && !frozen;
  $('o-submit').disabled = !canTrade;
}

function stepPrice(dir) {
  const s = selStock();
  if (!s) return;
  let p = Number($('o-price').value) || s.last;
  p = floorTick(p);
  p = dir > 0 ? nextUp(p) : nextDown(p);
  p = Math.min(s.upper, Math.max(s.lower, p));
  $('o-price').value = p;
  S.priceTouched = true;
  renderOrderForm();
}

async function submitOrder() {
  const s = selStock();
  if (!s) return;
  const qty = Math.floor(Number($('o-qty').value));
  let price = S.otype === 'limit' ? Math.floor(Number($('o-price').value)) : null;
  if (S.otype === 'limit' && price % tickSize(price) !== 0) {
    price = floorTick(price);
    $('o-price').value = price;
    toast(`호가 단위에 맞춰 ${fmt(price)}원으로 조정했습니다. 다시 확인 후 주문하세요.`);
    return;
  }
  $('o-submit').disabled = true;
  $('o-msg').textContent = '';
  try {
    const res = await rpc('st_place_order', {
      p_token: S.token, p_room: S.roomId, p_stock: s.id, p_side: S.side,
      p_type: S.otype, p_price: price, p_qty: qty,
    });
    const label = S.side === 'buy' ? '매수' : '매도';
    let msg;
    if (res.status === 'filled') msg = `${label} ${fmt(res.filled)}주 전량 체결`;
    else if (res.status === 'cancelled') msg = res.filled > 0 ? `${label} ${fmt(res.filled)}주 체결, 잔량 취소` : `${label} 체결 가능한 호가가 없어 취소됨`;
    else msg = res.filled > 0 ? `${label} ${fmt(res.filled)}/${fmt(res.qty)}주 체결, 잔량 대기` : `${label} 주문 접수 (미체결 대기)`;
    $('o-msg').textContent = msg;
    toast(msg);
    poll();
  } catch (err) {
    $('o-msg').textContent = err.message;
    toast(err.message);
  } finally {
    renderOrderForm();
  }
}

async function cancelOrder(id) {
  try {
    await rpc('st_cancel_order', { p_token: S.token, p_order: id });
    toast('주문이 취소되었습니다');
    poll();
  } catch (err) { toast(err.message); }
}

/* ---------- 하단 탭 ---------- */
function setBtab(t) {
  S.btab = t;
  document.querySelectorAll('.bottom-tabs button').forEach((b) => b.classList.toggle('active', b.dataset.btab === t));
  document.querySelectorAll('.btab').forEach((el) => el.classList.toggle('hidden', el.id !== 'btab-' + t));
  renderBottom();
  if (t === 'chat') { const cl = $('chat-list'); cl.scrollTop = cl.scrollHeight; }
}

const stockName = (id) => (S.stocks.find((s) => s.id === id) || {}).name || '-';

function renderBottom() {
  const d = S.data;
  if (!d) return;
  $('cnt-orders').textContent = d.orders.length ? `(${d.orders.length})` : '';

  if (S.btab === 'holdings') {
    const me = d.me;
    if (!me) { $('btab-holdings').innerHTML = '<div class="empty">이 방의 참가자가 아닙니다.</div>'; return; }
    let evalSum = 0; let costSum = 0;
    const rows = d.holdings.map((h) => {
      const s = S.stocks.find((x) => x.id === h.stock_id) || { last: 0 };
      const ev = h.qty * s.last;
      const cost = h.qty * Number(h.avg_price);
      evalSum += ev; costSum += cost;
      const pl = ev - cost;
      const r = cost ? (pl / cost) * 100 : 0;
      return `<tr class="click" data-stock="${h.stock_id}"><td>${esc(stockName(h.stock_id))}</td><td>${fmt(h.qty)}${h.locked_qty ? ` <span class="muted small">(매도대기 ${fmt(h.locked_qty)})</span>` : ''}</td>
        <td>${fmt(Number(h.avg_price))}</td><td>${fmt(s.last)}</td><td>${fmt(ev)}</td>
        <td class="${cls(pl)}">${fmt(pl)}</td><td class="${cls(r)}">${pct(r)}</td></tr>`;
    }).join('');
    const total = me.cash + evalSum;
    const ret = ((total - S.room.start_cash) / S.room.start_cash) * 100;
    $('btab-holdings').innerHTML = `
      <div class="summary">
        <div><span>예수금</span>${fmt(me.cash)}원</div>
        <div><span>주문가능</span>${fmt(me.cash - me.locked_cash)}원</div>
        <div><span>평가금액</span>${fmt(evalSum)}원</div>
        <div><span>평가손익</span><b class="${cls(evalSum - costSum)}">${fmt(evalSum - costSum)}원</b></div>
        <div><span>총자산</span><b>${fmt(total)}원</b> <span class="${cls(ret)}">${pct(ret)}</span></div>
        ${S.room.kind === 'main' ? `<button id="btn-reset" class="btn ghost tiny">계좌 초기화${me.resets ? ` (${me.resets}회)` : ''}</button>` : ''}
      </div>
      ${rows ? `<table><thead><tr><th>종목</th><th>보유수량</th><th>평균단가</th><th>현재가</th><th>평가금액</th><th>평가손익</th><th>수익률</th></tr></thead><tbody>${rows}</tbody></table>`
             : '<div class="empty">보유 종목이 없습니다.</div>'}`;
  } else if (S.btab === 'orders') {
    $('btab-orders').innerHTML = d.orders.length
      ? `<table><thead><tr><th>종목</th><th>구분</th><th>주문가</th><th>주문량</th><th>체결량</th><th>시각</th><th></th></tr></thead><tbody>
        ${d.orders.map((o) => `<tr><td>${esc(stockName(o.stock_id))}</td>
          <td class="${o.side === 'buy' ? 'up' : 'down'}">${o.side === 'buy' ? '매수' : '매도'}</td>
          <td>${fmt(o.price)}</td><td>${fmt(o.qty)}</td><td>${fmt(o.filled)}</td><td>${timeStr(o.created_at)}</td>
          <td><button class="btn tiny" data-cancel="${o.id}">취소</button></td></tr>`).join('')}</tbody></table>`
      : '<div class="empty">미체결 주문이 없습니다.</div>';
  } else if (S.btab === 'fills') {
    $('btab-fills').innerHTML = d.fills.length
      ? `<table><thead><tr><th>시각</th><th>종목</th><th>구분</th><th>체결가</th><th>수량</th><th>수수료+세금</th><th>실현손익</th></tr></thead><tbody>
        ${d.fills.map((f) => `<tr><td>${f.day}일 ${timeStr(f.created_at)}</td><td>${esc(stockName(f.stock_id))}</td>
          <td class="${f.side === 'buy' ? 'up' : 'down'}">${f.side === 'buy' ? '매수' : '매도'}</td>
          <td>${fmt(f.price)}</td><td>${fmt(f.qty)}</td><td>${fmt(f.fee + f.tax)}</td>
          <td class="${cls(f.realized)}">${f.side === 'sell' ? fmt(f.realized) : '-'}</td></tr>`).join('')}</tbody></table>`
      : '<div class="empty">체결 내역이 없습니다.</div>';
  } else if (S.btab === 'ranking') {
    renderRanking();
  }
}

/* ---------- 순위 ---------- */
async function loadRanking() {
  if (!S.roomId) return;
  try {
    const data = await rpc('st_ranking', { p_room: S.roomId });
    const old = S.ranking || [];
    S.rankMove = {};
    data.forEach((r, i) => {
      const pi = old.findIndex((o) => o.nickname === r.nickname);
      if (pi >= 0 && pi !== i) S.rankMove[r.nickname] = pi - i;
    });
    S.ranking = data;
    if (S.btab === 'ranking') renderRanking();
  } catch { /* 다음 주기에 재시도 */ }
}
function renderRanking() {
  const start = S.room ? S.room.start_cash : 1;
  const medal = ['🥇', '🥈', '🥉'];
  $('btab-ranking').innerHTML = S.ranking.length
    ? `<table><thead><tr><th>순위</th><th>플레이어</th><th>총자산</th><th>수익률</th><th>거래</th></tr></thead><tbody>
      ${S.ranking.map((r, i) => {
        const ret = ((r.total - start) / start) * 100;
        const me = S.account && r.nickname === S.account.nickname;
        const mv = (S.rankMove || {})[r.nickname] || 0;
        const move = !mv ? '' : mv > 0 ? `<span class="up small">▲${mv}</span>` : `<span class="down small">▼${-mv}</span>`;
        const tags = `${r.frozen ? ' ❄️' : ''}${r.insured ? ' 🛡️' : ''}${r.win_streak >= 3 ? ` 🔥${r.win_streak}` : ''}`;
        return `<tr class="${me ? 'me-row' : ''}"><td>${medal[i] || i + 1} ${move}</td>
          <td><span class="av">${esc(r.avatar || '🐜')}</span> ${esc(r.nickname)} <span class="lv">Lv.${r.level || 1} ${esc(r.title || '')}</span>${tags}${r.resets ? ` <span class="muted small">파산 ${r.resets}회</span>` : ''}</td>
          <td>${fmt(r.total)}</td><td class="${cls(ret)}">${pct(ret)}</td><td>${fmt(r.trades || 0)}</td></tr>`;
      }).join('')}</tbody></table>`
    : '<div class="empty">참가자가 없습니다.</div>';
}

/* ---------- 뉴스 / 채팅 (Supabase Realtime) ---------- */
function newsItem(n) {
  const li = document.createElement('li');
  li.innerHTML = `<time>${n.day}일 ${timeStr(n.created_at)}</time><span class="${n.tone > 0 ? 'up' : n.tone < 0 ? 'down' : ''}">${esc(n.headline)}</span>`;
  return li;
}
function chatItem(c) {
  const li = document.createElement('li');
  li.innerHTML = `<time>${timeStr(c.created_at)}</time><b>${esc(c.nickname)}</b>${esc(c.body)}`;
  return li;
}
async function loadNewsAndChat() {
  const roomId = S.roomId;
  const [news, chat] = await Promise.all([
    sb.from('st_news').select('*').eq('room_id', roomId).order('id', { ascending: false }).limit(50),
    sb.from('st_chat').select('*').eq('room_id', roomId).order('id', { ascending: false }).limit(50),
  ]);
  if (roomId !== S.roomId) return;
  const nl = $('news-list');
  nl.innerHTML = '';
  (news.data || []).forEach((n) => nl.appendChild(newsItem(n)));
  const cl = $('chat-list');
  cl.innerHTML = '';
  (chat.data || []).slice().reverse().forEach((c) => cl.appendChild(chatItem(c)));
  cl.scrollTop = cl.scrollHeight;
}
function subscribeRealtime() {
  const roomId = S.roomId;
  S.channel = sb.channel('room-' + roomId)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'st_news', filter: `room_id=eq.${roomId}` }, (p) => {
      const nl = $('news-list');
      nl.prepend(newsItem(p.new));
      while (nl.children.length > 50) nl.lastChild.remove();
      if (p.new.stock_id) toast('📰 ' + p.new.headline);
    })
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'st_chat', filter: `room_id=eq.${roomId}` }, (p) => {
      const cl = $('chat-list');
      const atBottom = cl.scrollHeight - cl.scrollTop - cl.clientHeight < 40;
      cl.appendChild(chatItem(p.new));
      if (window.GameFX) GameFX.onChat(p.new);
      while (cl.children.length > 100) cl.firstChild.remove();
      if (atBottom) cl.scrollTop = cl.scrollHeight;
    })
    .subscribe();
}
async function sendChat(e) {
  e.preventDefault();
  const body = $('chat-input').value.trim();
  if (!body) return;
  try {
    await rpc('st_send_chat', { p_token: S.token, p_room: S.roomId, p_body: body });
    $('chat-input').value = '';
  } catch (err) { toast(err.message); }
}

/* ============================================================
 *  차트 (Canvas 캔들 + 거래량)
 * ============================================================ */
async function loadCandles() {
  const s = selStock();
  if (!s || !S.room) return;
  const sid = s.id;
  let rows = [];
  if (S.chartMode === 'intraday') {
    const { data } = await sb.from('st_candles').select('day,idx,o,h,l,c,v')
      .eq('stock_id', sid).gte('day', Math.max(0, S.room.current_day - 2))
      .order('day').order('idx').limit(200);
    rows = (data || []).map((r) => {
      const m = 9 * 60 + r.idx * 10;
      return { ...r, label: `${r.day}일 ${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}` };
    });
  } else {
    const { data } = await sb.from('st_daily').select('day,o,h,l,c,v')
      .eq('stock_id', sid).order('day', { ascending: false }).limit(60);
    rows = (data || []).reverse().map((r) => ({ ...r, label: `${r.day}일` }));
    // 오늘(진행 중) 일봉 추가
    if (S.room.phase === 'open' && s.open != null) {
      rows.push({ day: S.room.current_day, o: s.open, h: s.high, l: s.low, c: s.last, v: s.volume, label: `${S.room.current_day}일` });
    }
  }
  if (sid !== S.selId) return;
  S.candles = rows;
  drawChart();
}

function drawChart() {
  const cv = $('chart');
  const s = selStock();
  const dpr = window.devicePixelRatio || 1;
  const W = cv.clientWidth; const H = cv.clientHeight;
  if (!W || !H) return;
  cv.width = W * dpr; cv.height = H * dpr;
  const g = cv.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, W, H);
  const css = getComputedStyle(document.documentElement);
  const UP = css.getPropertyValue('--up').trim();
  const DOWN = css.getPropertyValue('--down').trim();
  const LINE = css.getPropertyValue('--line').trim();
  const MUTED = css.getPropertyValue('--muted').trim();
  g.font = '11px system-ui, sans-serif';

  const data = S.candles;
  if (!data.length || !s) {
    g.fillStyle = MUTED;
    g.textAlign = 'center';
    g.fillText('아직 체결 데이터가 없습니다', W / 2, H / 2);
    return;
  }
  const padR = 64; const padB = 18; const volH = H * 0.2;
  const plotW = W - padR - 8; const priceH = H - padB - volH - 10;
  let hi = Math.max(...data.map((d) => d.h)); let lo = Math.min(...data.map((d) => d.l));
  if (S.chartMode === 'intraday') { hi = Math.max(hi, s.prev_close); lo = Math.min(lo, s.prev_close); }
  if (hi === lo) { hi += 1; lo -= 1; }
  const pad = (hi - lo) * 0.08; hi += pad; lo -= pad;
  const y = (p) => 8 + (hi - p) / (hi - lo) * priceH;
  const maxV = Math.max(...data.map((d) => d.v), 1);
  const n = Math.max(data.length, 40);
  const cw = plotW / n;
  const bw = Math.max(1, cw * 0.65);

  // 가격 격자
  g.strokeStyle = LINE; g.fillStyle = MUTED; g.lineWidth = 1; g.textAlign = 'left';
  for (let i = 0; i <= 4; i++) {
    const p = lo + (hi - lo) * i / 4;
    const yy = Math.round(y(p)) + 0.5;
    g.beginPath(); g.moveTo(0, yy); g.lineTo(plotW, yy); g.stroke();
    g.fillText(fmt(p), plotW + 6, yy + 4);
  }
  // 기준가 점선
  if (S.chartMode === 'intraday') {
    g.setLineDash([4, 4]); g.strokeStyle = MUTED;
    const yy = Math.round(y(s.prev_close)) + 0.5;
    g.beginPath(); g.moveTo(0, yy); g.lineTo(plotW, yy); g.stroke();
    g.setLineDash([]);
  }
  // 캔들 + 거래량
  data.forEach((d, i) => {
    const x = i * cw + cw / 2;
    const col = d.c >= d.o ? UP : DOWN;
    g.strokeStyle = col; g.fillStyle = col;
    g.beginPath(); g.moveTo(Math.round(x) + 0.5, y(d.h)); g.lineTo(Math.round(x) + 0.5, y(d.l)); g.stroke();
    const top = y(Math.max(d.o, d.c)); const bh = Math.max(1, Math.abs(y(d.o) - y(d.c)));
    g.fillRect(x - bw / 2, top, bw, bh);
    const vh = (d.v / maxV) * volH;
    g.globalAlpha = 0.45;
    g.fillRect(x - bw / 2, H - padB - vh, bw, vh);
    g.globalAlpha = 1;
  });
  // 현재가 라벨
  const ly = y(s.last);
  g.fillStyle = s.last >= s.prev_close ? UP : DOWN;
  g.fillRect(plotW + 2, ly - 8, padR - 4, 16);
  g.fillStyle = '#fff';
  g.fillText(fmt(s.last), plotW + 6, ly + 4);
  // x축 라벨
  g.fillStyle = MUTED;
  const step = Math.max(1, Math.ceil(data.length / Math.max(2, Math.floor(plotW / 120))));
  data.forEach((d, i) => {
    if (i % step !== 0) return;
    g.textAlign = i === 0 ? 'left' : 'center';
    g.fillText(d.label, i === 0 ? 0 : i * cw + cw / 2, H - 4);
  });
}

/* ============================================================
 *  이벤트 바인딩
 * ============================================================ */
function bind() {
  document.querySelectorAll('#auth-tabs button').forEach((b) => b.addEventListener('click', () => setAuthTab(b.dataset.tab)));
  $('auth-form').addEventListener('submit', submitAuth);
  $('btn-logout').addEventListener('click', logout);
  $('btn-set-pw').addEventListener('click', setPassword);
  $('btn-refresh-rooms').addEventListener('click', loadRooms);
  $('room-list').addEventListener('click', (e) => { const b = e.target.closest('[data-join]'); if (b) joinByCode(b.dataset.join); });
  $('join-form').addEventListener('submit', (e) => { e.preventDefault(); joinByCode($('join-code').value); });
  $('create-form').addEventListener('submit', createRoom);
  $('btn-back').addEventListener('click', enterLobby);
  $('g-room-code').addEventListener('click', () => {
    try { navigator.clipboard.writeText(S.room.code); toast('방 코드를 복사했습니다'); } catch { /* 무시 */ }
  });
  $('g-waiting').addEventListener('click', async (e) => {
    if (e.target.id !== 'btn-start') return;
    try { await rpc('st_start_room', { p_token: S.token, p_room: S.roomId }); poll(); } catch (err) { toast(err.message); }
  });
  $('stock-list').addEventListener('click', (e) => { const r = e.target.closest('[data-stock]'); if (r) selectStock(Number(r.dataset.stock)); });
  $('btab-holdings').addEventListener('click', async (e) => {
    if (e.target.id === 'btn-reset') {
      if (!confirm('계좌를 초기화할까요? 보유 주식과 주문이 모두 사라지고 시작 자금으로 돌아갑니다.')) return;
      try { await rpc('st_reset_me', { p_token: S.token, p_room: S.roomId }); toast('계좌를 초기화했습니다'); poll(); } catch (err) { toast(err.message); }
      return;
    }
    const r = e.target.closest('[data-stock]'); if (r) selectStock(Number(r.dataset.stock));
  });
  $('btab-orders').addEventListener('click', (e) => { const b = e.target.closest('[data-cancel]'); if (b) cancelOrder(Number(b.dataset.cancel)); });
  $('book').addEventListener('click', (e) => {
    const c = e.target.closest('[data-price]');
    if (!c) return;
    setOtype('limit');
    $('o-price').value = c.dataset.price;
    S.priceTouched = true;
    renderOrderForm();
  });
  document.querySelectorAll('.side-tabs button').forEach((b) => b.addEventListener('click', () => setSide(b.dataset.side)));
  document.querySelectorAll('.type-tabs button').forEach((b) => b.addEventListener('click', () => setOtype(b.dataset.otype)));
  document.querySelectorAll('.bottom-tabs button').forEach((b) => b.addEventListener('click', () => setBtab(b.dataset.btab)));
  document.querySelectorAll('.chart-tools button').forEach((b) => b.addEventListener('click', () => {
    S.chartMode = b.dataset.chart;
    document.querySelectorAll('.chart-tools button').forEach((x) => x.classList.toggle('active', x === b));
    loadCandles();
  }));
  $('px-up').addEventListener('click', () => stepPrice(1));
  $('px-dn').addEventListener('click', () => stepPrice(-1));
  $('o-price').addEventListener('input', () => { S.priceTouched = true; renderOrderForm(); });
  $('o-qty').addEventListener('input', renderOrderForm);
  document.querySelectorAll('.pct button').forEach((b) => b.addEventListener('click', () => {
    $('o-qty').value = Math.max(1, Math.floor(availableQty() * Number(b.dataset.pct) / 100));
    renderOrderForm();
  }));
  $('o-submit').addEventListener('click', submitOrder);
  $('chat-form').addEventListener('submit', sendChat);
  window.addEventListener('resize', drawChart);
}

async function boot() {
  bind();
  setAuthTab('guest');
  S.token = store.get('st_token');
  if (!S.token) { show('auth'); return; }
  try {
    S.account = await rpc('st_me', { p_token: S.token });
  } catch {
    show('auth');
    return;
  }
  const m = location.hash.match(/room=([0-9a-f-]{36})/);
  if (m) { renderUser(); enterGame(m[1]); } else { enterLobby(); }
}

boot();
