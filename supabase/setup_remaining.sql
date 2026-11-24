-- 매칭 엔진 + 시세 시뮬레이션

-- ===== 주문 취소 (내부) =====
create or replace function public.st_cancel_internal(p_id bigint) returns void
language plpgsql set search_path = public as $$
declare o public.st_orders;
begin
  select * into o from public.st_orders where id = p_id and status = 'open' for update;
  if not found then return; end if;
  if o.account_id is null then
    delete from public.st_orders where id = o.id;
    return;
  end if;
  if o.side = 'buy' then
    update public.st_members set locked_cash = locked_cash - o.locked
     where room_id = o.room_id and account_id = o.account_id;
  else
    update public.st_holdings set locked_qty = locked_qty - (o.qty - o.filled)
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id;
  end if;
  update public.st_orders set status = 'cancelled', locked = 0, updated_at = clock_timestamp() where id = o.id;
end $$;

-- ===== 한쪽 체결 정산 (내부) =====
create or replace function public.st_fill(o public.st_orders, q bigint, px int, p_day int) returns void
language plpgsql set search_path = public as $$
declare
  v bigint := q * px;
  fee bigint;
  tax bigint := 0;
  new_lock bigint;
  h public.st_holdings;
  realized bigint := 0;
begin
  if o.account_id is null then return; end if;
  fee := floor(v * public.st_fee_rate());
  if o.side = 'buy' then
    new_lock := public.st_reserve(o.price, o.qty - o.filled - q);
    update public.st_orders set locked = new_lock where id = o.id;
    update public.st_members
       set cash = cash - v - fee, locked_cash = locked_cash - (o.locked - new_lock)
     where room_id = o.room_id and account_id = o.account_id;
    insert into public.st_holdings(room_id, account_id, stock_id, qty, avg_price)
    values (o.room_id, o.account_id, o.stock_id, q, px)
    on conflict (room_id, account_id, stock_id) do update
       set avg_price = (public.st_holdings.avg_price * public.st_holdings.qty + v) / (public.st_holdings.qty + q),
           qty = public.st_holdings.qty + q;
  else
    tax := floor(v * public.st_tax_rate());
    select * into h from public.st_holdings
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id for update;
    realized := v - fee - tax - round(h.avg_price * q)::bigint;
    update public.st_holdings set qty = qty - q, locked_qty = locked_qty - q
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id;
    delete from public.st_holdings
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id and qty = 0 and locked_qty = 0;
    update public.st_members set cash = cash + v - fee - tax
     where room_id = o.room_id and account_id = o.account_id;
  end if;
  insert into public.st_fills(room_id, account_id, stock_id, order_id, side, price, qty, fee, tax, realized, day)
  values (o.room_id, o.account_id, o.stock_id, o.id, o.side, px, q, fee, tax, realized, p_day);
end $$;

-- ===== 매칭 엔진: 가격우선 → 시간우선, 체결가는 대기 주문의 가격 =====
-- 호출자는 반드시 방 단위 advisory lock 을 잡은 상태여야 함
create or replace function public.st_match(p_order_id bigint) returns void
language plpgsql set search_path = public as $$
declare
  o public.st_orders;
  r public.st_orders;
  rm public.st_rooms;
  q bigint;
  px int;
  idx int;
  impact numeric;
  player_side text;
begin
  select * into o from public.st_orders where id = p_order_id;
  if not found or o.status <> 'open' then return; end if;
  select * into rm from public.st_rooms where id = o.room_id;

  loop
    if o.side = 'buy' then
      select * into r from public.st_orders
       where stock_id = o.stock_id and status = 'open' and side = 'sell' and id <> o.id
         and (o.otype = 'market' or price <= o.price)
       order by price asc, id asc limit 1;
    else
      select * into r from public.st_orders
       where stock_id = o.stock_id and status = 'open' and side = 'buy' and id <> o.id
         and (o.otype = 'market' or price >= o.price)
       order by price desc, id asc limit 1;
    end if;
    exit when not found;

    -- 자기매매 방지: 본인의 반대 주문은 취소
    if r.account_id is not null and r.account_id = o.account_id then
      perform public.st_cancel_internal(r.id);
      continue;
    end if;

    q := least(o.qty - o.filled, r.qty - r.filled);
    px := r.price;
    perform public.st_fill(o, q, px, rm.current_day);
    perform public.st_fill(r, q, px, rm.current_day);

    update public.st_orders
       set filled = filled + q,
           status = case when filled + q >= qty then 'filled' else 'open' end,
           updated_at = clock_timestamp()
     where id in (o.id, r.id);
    delete from public.st_orders where id in (o.id, r.id) and account_id is null and status = 'filled';

    insert into public.st_trades(room_id, stock_id, price, qty, taker_side, day)
    values (o.room_id, o.stock_id, px, q, o.side, rm.current_day);

    update public.st_stocks
       set last = px, open = coalesce(open, px),
           high = greatest(coalesce(high, px), px), low = least(coalesce(low, px), px),
           volume = volume + q, turnover = turnover + q * px, updated_at = now()
     where id = o.stock_id;

    idx := least(38, greatest(0, floor(extract(epoch from (clock_timestamp() - rm.phase_started_at))
                                       / rm.day_seconds * 39)))::int;
    insert into public.st_candles(room_id, stock_id, day, idx, o, h, l, c, v)
    values (o.room_id, o.stock_id, rm.current_day, idx, px, px, px, px, q)
    on conflict (stock_id, day, idx) do update
       set h = greatest(public.st_candles.h, px), l = least(public.st_candles.l, px),
           c = px, v = public.st_candles.v + q;

    -- 플레이어 ↔ 봇 체결이면 적정가에 수급 충격 반영
    if (o.account_id is null) <> (r.account_id is null) then
      player_side := case when o.account_id is not null then o.side else r.side end;
      impact := least(0.02, (q * px)::numeric / 3e9);
      update public.st_stock_sim
         set fair = fair * (1 + case when player_side = 'buy' then impact else -impact end)
       where stock_id = o.stock_id;
    end if;

    select * into o from public.st_orders where id = p_order_id;
    exit when not found or o.status <> 'open';
  end loop;

  -- 시장가 미체결 잔량은 취소
  select * into o from public.st_orders where id = p_order_id;
  if found and o.status = 'open' and o.otype = 'market' then
    perform public.st_cancel_internal(o.id);
  end if;
end $$;

-- ===== 장 마감 / 개장 =====
create or replace function public.st_close_day(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare oid bigint; rm public.st_rooms;
begin
  for oid in select id from public.st_orders where room_id = p_room and status = 'open' loop
    perform public.st_cancel_internal(oid);
  end loop;
  select * into rm from public.st_rooms where id = p_room;
  insert into public.st_daily(room_id, stock_id, day, o, h, l, c, v)
  select room_id, id, rm.current_day, coalesce(open, last), coalesce(high, last), coalesce(low, last), last, volume
    from public.st_stocks where room_id = p_room
  on conflict do nothing;
  if rm.total_days is not null and rm.current_day >= rm.total_days then
    update public.st_rooms set status = 'ended', phase = 'closed', ended_at = now(), phase_started_at = now() where id = p_room;
    insert into public.st_news(room_id, headline, day) values (p_room, '🏁 모든 거래일이 끝났습니다. 최종 순위를 확인하세요!', rm.current_day);
  else
    update public.st_rooms set phase = 'closed', phase_started_at = now() where id = p_room;
    insert into public.st_news(room_id, headline, day)
    values (p_room, format('🔔 %s일차 장 마감. 미체결 주문은 모두 취소되었습니다.', rm.current_day), rm.current_day);
  end if;
end $$;

create or replace function public.st_open_day(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare d int;
begin
  update public.st_stocks
     set prev_close = last, open = null, high = null, low = null, volume = 0, turnover = 0, updated_at = now()
   where room_id = p_room;
  -- 밤사이 갭 (해외 증시 등)
  update public.st_stock_sim sm
     set fair = least(public.st_upper(st.last), greatest(public.st_lower(st.last),
                 (st.last * exp(sm.vol * 0.5 * public.st_randn()))::numeric))
    from public.st_stocks st
   where st.id = sm.stock_id and st.room_id = p_room;
  update public.st_rooms set phase = 'open', current_day = current_day + 1, phase_started_at = now()
   where id = p_room returning current_day into d;
  insert into public.st_news(room_id, headline, day) values (p_room, format('🔔 %s일차 장이 시작되었습니다.', d), d);
end $$;

-- ===== 방 하나의 시장 틱 (2초마다) =====
create or replace function public.st_tick_room(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare
  rm public.st_rooms;
  s record;
  ups int; lows int;
  tpd numeric;
  f numeric;
  tone int; mag numeric;
  bid int; ask int; p int; i int;
  oid bigint; qty bigint; pbuy numeric;
  pos text[] := array[
    '%s, 대규모 해외 수주 계약 체결', '%s, 분기 실적 시장 예상치 크게 상회', '%s, 신제품 흥행 기대감 확산',
    '외국인·기관, %s 대량 순매수', '%s, 자사주 매입 결정', '%s, 정부 지원 사업 수혜 기대', '%s, 글로벌 기업과 기술 제휴'];
  neg text[] := array[
    '%s, 분기 실적 쇼크', '%s, 주력 제품 리콜 사태', '%s, 대규모 유상증자 결정',
    '외국인, %s 대량 순매도', '%s, 경영진 횡령 의혹 제기', '%s, 핵심 계약 해지 통보', '%s, 신용등급 하향 조정'];
  mpos text[] := array['📈 중앙은행 기준금리 인하 시사', '📈 해외 증시 일제히 급등', '📈 외국인 투자 자금 대거 유입'];
  mneg text[] := array['📉 중앙은행 기준금리 인상 우려', '📉 해외 증시 급락 여파', '📉 환율 급등, 외국인 매도 우려'];
  active boolean;
begin
  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room for update;
  if not found or rm.status <> 'running' then return; end if;

  -- 메인 시장은 10분간 접속자가 없으면 일시정지 (리소스 절약)
  if rm.kind = 'main' then
    active := exists(select 1 from public.st_members where room_id = rm.id and last_seen > now() - interval '10 minutes');
    if not active then
      if not rm.paused then update public.st_rooms set paused = true, paused_at = now() where id = rm.id; end if;
      return;
    elsif rm.paused then
      update public.st_rooms
         set paused = false, phase_started_at = phase_started_at + (now() - paused_at), paused_at = null
       where id = rm.id returning * into rm;
    end if;
  end if;

  if rm.phase = 'open' and now() >= rm.phase_started_at + make_interval(secs => rm.day_seconds) then
    perform public.st_close_day(rm.id);
    return;
  end if;
  if rm.phase = 'closed' then
    if now() >= rm.phase_started_at + make_interval(secs => rm.break_seconds) then
      perform public.st_open_day(rm.id);
    end if;
    return;
  end if;

  tpd := greatest(10, rm.day_seconds / 2.0);   -- 하루 틱 수 (2초 간격)

  -- 시장 전체 뉴스
  if random() < 1.0 / (tpd * 3) then
    tone := case when random() < 0.5 then 1 else -1 end;
    mag := 0.01 + random() * 0.03;
    update public.st_stock_sim sm set fair = fair * (1 + tone * mag * (0.5 + random()))
      from public.st_stocks st where st.id = sm.stock_id and st.room_id = rm.id;
    insert into public.st_news(room_id, headline, tone, day)
    values (rm.id, case when tone > 0 then mpos[1 + floor(random() * array_length(mpos, 1))::int]
                        else mneg[1 + floor(random() * array_length(mneg, 1))::int] end, tone, rm.current_day);
  end if;

  for s in
    select st.id, st.name, st.prev_close, st.last, sm.fair, sm.vol
      from public.st_stocks st join public.st_stock_sim sm on sm.stock_id = st.id
     where st.room_id = rm.id order by st.id
  loop
    ups := public.st_upper(s.prev_close);
    lows := public.st_lower(s.prev_close);
    -- 랜덤워크 + 약한 평균회귀(기준가 쪽)
    f := s.fair * exp(s.vol / sqrt(tpd) * public.st_randn()
                      - 0.02 / tpd * ln(s.fair / s.prev_close))::numeric;

    -- 종목 뉴스
    if random() < 1.0 / (tpd * 1.5) then
      tone := case when random() < 0.5 then 1 else -1 end;
      mag := 0.02 + random() * 0.08;
      f := f * (1 + tone * mag);
      insert into public.st_news(room_id, stock_id, headline, tone, day)
      values (rm.id, s.id,
              format(case when tone > 0 then pos[1 + floor(random() * array_length(pos, 1))::int]
                          else neg[1 + floor(random() * array_length(neg, 1))::int] end, s.name),
              tone, rm.current_day);
    end if;

    f := least(ups, greatest(lows, f));
    update public.st_stock_sim set fair = f where stock_id = s.id;

    -- 시장조성 봇: 기존 호가 철회 후 적정가 주변에 5단계 재호가
    delete from public.st_orders where stock_id = s.id and account_id is null and status = 'open';
    bid := public.st_floor_tick(f * 0.9992);
    ask := public.st_ceil_tick(f * 1.0008);
    if ask <= bid then ask := bid + public.st_tick_size(bid); end if;

    p := ask;
    for i in 1..5 loop
      exit when p > ups;
      qty := greatest(1, round((15e6 + random() * 45e6) / p));
      insert into public.st_orders(room_id, stock_id, account_id, side, otype, price, qty)
      values (rm.id, s.id, null, 'sell', 'limit', p, qty) returning id into oid;
      perform public.st_match(oid);
      p := p + public.st_tick_size(p);
    end loop;

    p := bid;
    for i in 1..5 loop
      exit when p < lows or p < 1;
      qty := greatest(1, round((15e6 + random() * 45e6) / p));
      insert into public.st_orders(room_id, stock_id, account_id, side, otype, price, qty)
      values (rm.id, s.id, null, 'buy', 'limit', p, qty) returning id into oid;
      perform public.st_match(oid);
      p := p - public.st_tick_size(p - 1);
    end loop;

    -- 노이즈 트레이더 봇: 시장가 주문 (적정가 방향으로 약간 치우침)
    if random() < 0.7 then
      pbuy := 0.5 + greatest(-0.3, least(0.3, (f - s.last) / s.last * 20));
      qty := greatest(1, round((2e6 + random() * 20e6) / s.last));
      insert into public.st_orders(room_id, stock_id, account_id, side, otype, price, qty)
      values (rm.id, s.id, null, case when random() < pbuy then 'buy' else 'sell' end, 'market', s.last, qty)
      returning id into oid;
      perform public.st_match(oid);
    end if;
  end loop;
end $$;

create or replace function public.st_tick_all() returns void
language plpgsql set search_path = public as $$
declare r uuid;
begin
  for r in select id from public.st_rooms where status = 'running' loop
    begin
      perform public.st_tick_room(r);
    exception when others then
      raise warning 'st_tick_room % failed: %', r, sqlerrm;
    end;
  end loop;
end $$;

-- ===== 종목 생성 (가상 기업 — 실존 기업과 무관하도록 지은 이름) =====
create or replace function public.st_seed_stocks(p_room uuid, p_randomize boolean) returns void
language plpgsql set search_path = public as $$
declare
  rec record;
  price int;
  sid bigint;
begin
  for rec in select * from (values
      ('HBE', '한빛전자',   '반도체',  72000::numeric, 0.035::numeric),
      ('SSB', '새솔바이오', '바이오',  18500, 0.060),
      ('NRM', '누리모터스', '자동차', 215000, 0.030),
      ('BYE', '별빛엔터',   '엔터',    46500, 0.050),
      ('PRE', '푸른에너지', '2차전지',128000, 0.055),
      ('DDF', '도담금융',   '금융',     9800, 0.020),
      ('GOG', '가온게임즈', '게임',     3450, 0.070),
      ('MRC', '미르건설',   '건설',     1580, 0.045)
    ) as t(symbol, name, sector, base, vol)
  loop
    price := public.st_floor_tick(rec.base * case when p_randomize then 0.7 + random() * 0.6 else 1 end);
    insert into public.st_stocks(room_id, symbol, name, sector, prev_close, last)
    values (p_room, rec.symbol, rec.name, rec.sector, price, price) returning id into sid;
    insert into public.st_stock_sim(stock_id, fair, vol) values (sid, price, rec.vol);
  end loop;
end $$;
-- 클라이언트용 API (모두 security definer RPC, 토큰 기반 인증)

-- ===== 인증 =====
create or replace function public.st_hash(t text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(t, 'sha256'), 'hex')
$$;

create or replace function public.st_auth(p_token text) returns uuid
language plpgsql stable set search_path = public, extensions as $$
declare a uuid;
begin
  select account_id into a from public.st_sessions
   where token_hash = public.st_hash(coalesce(p_token, '')) and expires_at > now();
  if a is null then raise exception '로그인이 필요합니다'; end if;
  return a;
end $$;

create or replace function public.st_new_session(p_acc uuid, p_days int) returns text
language plpgsql set search_path = public, extensions as $$
declare tok text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  insert into public.st_sessions(token_hash, account_id, expires_at)
  values (public.st_hash(tok), p_acc, now() + make_interval(days => p_days));
  return tok;
end $$;

create or replace function public.st_account_json(a public.st_accounts) returns json
language sql stable as $$
  select json_build_object('id', a.id, 'nickname', a.nickname, 'is_guest', a.pass_hash is null)
$$;

create or replace function public.st_check_nick(n text) returns void
language plpgsql immutable as $$
begin
  if n is null or n !~ '^[가-힣A-Za-z0-9_]{2,12}$' then
    raise exception '닉네임은 2~12자의 한글/영문/숫자/_ 만 사용할 수 있습니다';
  end if;
end $$;

-- 닉네임만으로 게스트 시작
create or replace function public.st_guest_login(p_nickname text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare acc public.st_accounts;
begin
  p_nickname := btrim(p_nickname);
  perform public.st_check_nick(p_nickname);
  begin
    insert into public.st_accounts(nickname) values (p_nickname) returning * into acc;
  exception when unique_violation then
    raise exception '이미 사용 중인 닉네임입니다';
  end;
  return json_build_object('token', public.st_new_session(acc.id, 365), 'account', public.st_account_json(acc));
end $$;

-- 회원가입 (닉네임 + 비밀번호)
create or replace function public.st_register(p_nickname text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare acc public.st_accounts;
begin
  p_nickname := btrim(p_nickname);
  perform public.st_check_nick(p_nickname);
  if p_password is null or length(p_password) < 4 or length(p_password) > 72 then
    raise exception '비밀번호는 4~72자여야 합니다';
  end if;
  begin
    insert into public.st_accounts(nickname, pass_hash)
    values (p_nickname, extensions.crypt(p_password, extensions.gen_salt('bf', 8))) returning * into acc;
  exception when unique_violation then
    raise exception '이미 사용 중인 닉네임입니다';
  end;
  return json_build_object('token', public.st_new_session(acc.id, 30), 'account', public.st_account_json(acc));
end $$;

-- 로그인 (실패 시 예외 대신 error 필드 반환 → 시도 기록이 롤백되지 않도록)
create or replace function public.st_login(p_nickname text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare acc public.st_accounts; k text := lower(btrim(coalesce(p_nickname, '')));
begin
  if (select count(*) from public.st_login_attempts where nickname_key = k and at > now() - interval '10 minutes') >= 10 then
    return json_build_object('error', '로그인 시도가 너무 많습니다. 10분 후 다시 시도하세요');
  end if;
  select * into acc from public.st_accounts where nickname_key = k;
  if not found or acc.pass_hash is null or acc.pass_hash <> extensions.crypt(coalesce(p_password, ''), acc.pass_hash) then
    insert into public.st_login_attempts(nickname_key) values (k);
    return json_build_object('error', '닉네임 또는 비밀번호가 올바르지 않습니다');
  end if;
  return json_build_object('token', public.st_new_session(acc.id, 30), 'account', public.st_account_json(acc));
end $$;

-- 게스트 → 정식 계정 전환 (비밀번호 설정)
create or replace function public.st_set_password(p_token text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); acc public.st_accounts;
begin
  if p_password is null or length(p_password) < 4 or length(p_password) > 72 then
    raise exception '비밀번호는 4~72자여야 합니다';
  end if;
  update public.st_accounts set pass_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 8))
   where id = a and pass_hash is null returning * into acc;
  if not found then raise exception '이미 비밀번호가 설정된 계정입니다'; end if;
  return public.st_account_json(acc);
end $$;

create or replace function public.st_me(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare acc public.st_accounts;
begin
  select * into acc from public.st_accounts where id = public.st_auth(p_token);
  return public.st_account_json(acc);
end $$;

create or replace function public.st_logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from public.st_sessions where token_hash = public.st_hash(coalesce(p_token, ''));
$$;

-- ===== 방 =====
create or replace function public.st_room_json(r public.st_rooms) returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'id', r.id, 'code', r.code, 'name', r.name, 'kind', r.kind, 'owner_id', r.owner_id,
    'owner_nickname', (select nickname from public.st_accounts where id = r.owner_id),
    'is_private', r.is_private, 'status', r.status, 'phase', r.phase, 'start_cash', r.start_cash,
    'day_seconds', r.day_seconds, 'break_seconds', r.break_seconds, 'total_days', r.total_days,
    'max_players', r.max_players, 'current_day', r.current_day, 'phase_started_at', r.phase_started_at,
    'paused', r.paused, 'started_at', r.started_at, 'ended_at', r.ended_at,
    'players', (select count(*) from public.st_members m where m.room_id = r.id))
$$;

create or replace function public.st_list_rooms(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
             'room', public.st_room_json(r),
             'joined', exists(select 1 from public.st_members m where m.room_id = r.id and m.account_id = a))
           order by (r.kind = 'main') desc, r.created_at desc)
      from public.st_rooms r
     where r.kind = 'main'
        or exists(select 1 from public.st_members m where m.room_id = r.id and m.account_id = a)
        or (r.status <> 'ended' and not r.is_private)
  ), '[]'::json);
end $$;

create or replace function public.st_create_room(
  p_token text, p_name text, p_start_cash bigint, p_day_seconds int, p_total_days int,
  p_max_players int, p_private boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); c text; rm public.st_rooms;
begin
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 30 then raise exception '방 이름은 1~30자여야 합니다'; end if;
  if p_start_cash is null or p_start_cash < 1000000 or p_start_cash > 10000000000 then
    raise exception '시작 자금은 100만 ~ 100억 원 사이여야 합니다'; end if;
  if p_day_seconds is null or p_day_seconds < 60 or p_day_seconds > 1800 then
    raise exception '하루 장 시간은 60~1800초 사이여야 합니다'; end if;
  if p_total_days is null or p_total_days < 1 or p_total_days > 30 then
    raise exception '거래일 수는 1~30일 사이여야 합니다'; end if;
  if p_max_players is null or p_max_players < 2 or p_max_players > 100 then
    raise exception '최대 인원은 2~100명 사이여야 합니다'; end if;
  if (select count(*) from public.st_rooms where owner_id = a and status <> 'ended') >= 3 then
    raise exception '진행 중인 내 방은 최대 3개까지 만들 수 있습니다'; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists(select 1 from public.st_rooms where code = c);
  end loop;
  insert into public.st_rooms(code, name, kind, owner_id, is_private, start_cash, day_seconds, total_days, max_players)
  values (c, p_name, 'room', a, coalesce(p_private, false), p_start_cash, p_day_seconds, p_total_days, p_max_players)
  returning * into rm;
  insert into public.st_members(room_id, account_id, cash) values (rm.id, a, rm.start_cash);
  perform public.st_seed_stocks(rm.id, true);
  return public.st_room_json(rm);
end $$;

create or replace function public.st_join_room(p_token text, p_code text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rm public.st_rooms;
begin
  select * into rm from public.st_rooms where code = upper(btrim(coalesce(p_code, '')));
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  perform pg_advisory_xact_lock(hashtext('st_room:' || rm.id::text));
  if exists(select 1 from public.st_members where room_id = rm.id and account_id = a) then
    return public.st_room_json(rm);
  end if;
  if rm.status = 'ended' then raise exception '이미 종료된 방입니다'; end if;
  if (select count(*) from public.st_members where room_id = rm.id) >= rm.max_players then
    raise exception '정원이 가득 찼습니다'; end if;
  insert into public.st_members(room_id, account_id, cash) values (rm.id, a, rm.start_cash);
  return public.st_room_json(rm);
end $$;

create or replace function public.st_start_room(p_token text, p_room uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rm public.st_rooms;
begin
  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room for update;
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  if rm.owner_id is distinct from a then raise exception '방장만 시작할 수 있습니다'; end if;
  if rm.status <> 'waiting' then raise exception '이미 시작된 방입니다'; end if;
  update public.st_rooms set status = 'running', started_at = now() where id = p_room;
  perform public.st_open_day(p_room);
  select * into rm from public.st_rooms where id = p_room;
  return public.st_room_json(rm);
end $$;

-- 메인 시장 전용: 내 계좌 초기화 (파산 시 재도전)
create or replace function public.st_reset_me(p_token text, p_room uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rm public.st_rooms; oid bigint;
begin
  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room;
  if not found or rm.kind <> 'main' then raise exception '메인 시장에서만 초기화할 수 있습니다'; end if;
  if not exists(select 1 from public.st_members where room_id = p_room and account_id = a) then
    raise exception '참가자가 아닙니다'; end if;
  for oid in select id from public.st_orders where room_id = p_room and account_id = a and status = 'open' loop
    perform public.st_cancel_internal(oid);
  end loop;
  delete from public.st_holdings where room_id = p_room and account_id = a;
  update public.st_members set cash = rm.start_cash, locked_cash = 0, resets = resets + 1
   where room_id = p_room and account_id = a;
end $$;

-- ===== 주문 =====
create or replace function public.st_place_order(
  p_token text, p_room uuid, p_stock bigint, p_side text, p_type text, p_price int, p_qty bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  a uuid := public.st_auth(p_token);
  rm public.st_rooms; s public.st_stocks; m public.st_members; h public.st_holdings; o public.st_orders;
  ups int; lows int; px int; need bigint := 0; oid bigint;
begin
  if p_side not in ('buy', 'sell') or p_type not in ('limit', 'market') then raise exception '잘못된 주문 유형입니다'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 100000000 then raise exception '주문 수량이 올바르지 않습니다'; end if;

  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room;
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  if rm.status <> 'running' then raise exception '거래가 진행 중인 방이 아닙니다'; end if;
  if rm.phase <> 'open' or rm.paused or now() >= rm.phase_started_at + make_interval(secs => rm.day_seconds) then
    raise exception '지금은 장 운영 시간이 아닙니다'; end if;

  select * into m from public.st_members where room_id = p_room and account_id = a for update;
  if not found then raise exception '이 방의 참가자가 아닙니다'; end if;
  select * into s from public.st_stocks where id = p_stock and room_id = p_room;
  if not found then raise exception '종목을 찾을 수 없습니다'; end if;
  if (select count(*) from public.st_orders where room_id = p_room and account_id = a and status = 'open') >= 30 then
    raise exception '미체결 주문은 최대 30개까지 가능합니다'; end if;

  ups := public.st_upper(s.prev_close);
  lows := public.st_lower(s.prev_close);
  if p_type = 'limit' then
    px := p_price;
    if px is null or px < lows or px > ups then
      raise exception '주문 가격은 하한가 % ~ 상한가 % 사이여야 합니다', lows, ups; end if;
    if px % public.st_tick_size(px) <> 0 then
      raise exception '호가 단위(%원)에 맞지 않는 가격입니다', public.st_tick_size(px); end if;
  else
    px := case when p_side = 'buy' then ups else lows end;   -- 시장가 매수 증거금은 상한가 기준
  end if;

  if p_side = 'buy' then
    need := public.st_reserve(px, p_qty);
    if m.cash - m.locked_cash < need then
      raise exception '주문 가능 금액이 부족합니다 (필요: %원, 가능: %원)', need, m.cash - m.locked_cash; end if;
    update public.st_members set locked_cash = locked_cash + need where room_id = p_room and account_id = a;
  else
    select * into h from public.st_holdings where room_id = p_room and account_id = a and stock_id = p_stock for update;
    if not found or h.qty - h.locked_qty < p_qty then raise exception '매도 가능 수량이 부족합니다'; end if;
    update public.st_holdings set locked_qty = locked_qty + p_qty
     where room_id = p_room and account_id = a and stock_id = p_stock;
  end if;

  insert into public.st_orders(room_id, stock_id, account_id, side, otype, price, qty, locked)
  values (p_room, p_stock, a, p_side, p_type, px, p_qty, need) returning id into oid;
  perform public.st_match(oid);
  update public.st_members set last_seen = now() where room_id = p_room and account_id = a;
  select * into o from public.st_orders where id = oid;
  return json_build_object('id', o.id, 'status', o.status, 'filled', o.filled, 'qty', o.qty);
end $$;

create or replace function public.st_cancel_order(p_token text, p_order bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rid uuid; st text;
begin
  select room_id into rid from public.st_orders where id = p_order and account_id = a;
  if rid is null then raise exception '주문을 찾을 수 없습니다'; end if;
  perform pg_advisory_xact_lock(hashtext('st_room:' || rid::text));
  select status into st from public.st_orders where id = p_order;
  if st <> 'open' then raise exception '이미 체결되었거나 취소된 주문입니다'; end if;
  perform public.st_cancel_internal(p_order);
end $$;

-- ===== 조회 =====
create or replace function public.st_book_json(p_stock bigint) returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'asks', coalesce((select json_agg(x order by x.price desc) from (
        select price, sum(qty - filled) qty, count(*) n from public.st_orders
         where stock_id = p_stock and status = 'open' and side = 'sell'
         group by price order by price asc limit 10) x), '[]'::json),
    'bids', coalesce((select json_agg(x order by x.price desc) from (
        select price, sum(qty - filled) qty, count(*) n from public.st_orders
         where stock_id = p_stock and status = 'open' and side = 'buy'
         group by price order by price desc limit 10) x), '[]'::json))
$$;

-- 게임 화면이 1초마다 호출: 방/종목/내 계좌/호가/체결 한 번에
create or replace function public.st_poll(p_token text, p_room uuid, p_stock bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rm public.st_rooms; m public.st_members; is_member boolean;
begin
  select * into rm from public.st_rooms where id = p_room;
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  update public.st_members set last_seen = now()
   where room_id = p_room and account_id = a and last_seen < now() - interval '15 seconds';
  select * into m from public.st_members where room_id = p_room and account_id = a;
  is_member := found;
  return json_build_object(
    'now', now(),
    'room', public.st_room_json(rm),
    'stocks', (select json_agg(json_build_object(
        'id', id, 'symbol', symbol, 'name', name, 'sector', sector, 'prev_close', prev_close,
        'open', open, 'high', high, 'low', low, 'last', last, 'volume', volume, 'turnover', turnover,
        'upper', public.st_upper(prev_close), 'lower', public.st_lower(prev_close)) order by id)
        from public.st_stocks where room_id = p_room),
    'me', case when is_member then json_build_object('cash', m.cash, 'locked_cash', m.locked_cash, 'resets', m.resets) end,
    'holdings', coalesce((select json_agg(json_build_object('stock_id', stock_id, 'qty', qty, 'locked_qty', locked_qty, 'avg_price', avg_price))
        from public.st_holdings where room_id = p_room and account_id = a), '[]'::json),
    'orders', coalesce((select json_agg(json_build_object('id', id, 'stock_id', stock_id, 'side', side, 'otype', otype,
        'price', price, 'qty', qty, 'filled', filled, 'created_at', created_at) order by id desc)
        from public.st_orders where room_id = p_room and account_id = a and status = 'open'), '[]'::json),
    'fills', coalesce((select json_agg(x) from (
        select id, stock_id, side, price, qty, fee, tax, realized, day, created_at from public.st_fills
         where room_id = p_room and account_id = a order by id desc limit 30) x), '[]'::json),
    'book', case when p_stock is not null then public.st_book_json(p_stock) end,
    'trades', coalesce((select json_agg(x) from (
        select id, price, qty, taker_side, created_at from public.st_trades
         where stock_id = p_stock and room_id = p_room order by id desc limit 30) x), '[]'::json));
end $$;

create or replace function public.st_ranking(p_room uuid) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select a.nickname, a.pass_hash is null as is_guest, m.resets,
           m.cash + coalesce((select sum(h.qty * s.last) from public.st_holdings h join public.st_stocks s on s.id = h.stock_id
                               where h.room_id = m.room_id and h.account_id = m.account_id), 0) as total
      from public.st_members m join public.st_accounts a on a.id = m.account_id
     where m.room_id = p_room
     order by total desc limit 100) x
$$;

create or replace function public.st_send_chat(p_token text, p_room uuid, p_body text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token);
begin
  p_body := btrim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 200 then raise exception '메시지는 1~200자여야 합니다'; end if;
  if not exists(select 1 from public.st_members where room_id = p_room and account_id = a) then
    raise exception '방 참가자만 채팅할 수 있습니다'; end if;
  if exists(select 1 from public.st_chat where account_id = a and created_at > now() - interval '1 second') then
    raise exception '너무 빠르게 보내고 있습니다'; end if;
  insert into public.st_chat(room_id, account_id, nickname, body)
  values (p_room, a, (select nickname from public.st_accounts where id = a), p_body);
end $$;

-- ===== 권한: st_ 함수는 기본적으로 실행 불가, API 만 공개 =====
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'st\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (
              'st_guest_login','st_register','st_login','st_set_password','st_me','st_logout',
              'st_list_rooms','st_create_room','st_join_room','st_start_room','st_reset_me',
              'st_place_order','st_cancel_order','st_poll','st_ranking','st_send_chat') loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;
-- 정리 작업 + 스케줄러 + 메인 시장 생성

create or replace function public.st_maintenance() returns void
language plpgsql set search_path = public as $$
begin
  -- 체결 테이프는 30분만 보관 (차트는 st_candles/st_daily 에 남음)
  delete from public.st_trades where created_at < now() - interval '30 minutes';
  delete from public.st_sessions where expires_at < now();
  delete from public.st_login_attempts where at < now() - interval '1 day';
  -- 시작하지 않은 방 1일, 종료된 방 7일 후 삭제
  delete from public.st_rooms where kind = 'room' and status = 'waiting' and created_at < now() - interval '1 day';
  delete from public.st_rooms where kind = 'room' and status = 'ended' and ended_at < now() - interval '7 days';
  -- 오래된 플레이어 주문 기록 / 채팅 / 뉴스
  delete from public.st_orders where status <> 'open' and updated_at < now() - interval '3 days';
  delete from public.st_chat where created_at < now() - interval '3 days';
  delete from public.st_news where created_at < now() - interval '3 days';
  -- 메인 시장 분봉은 최근 30거래일만
  delete from public.st_candles c using public.st_rooms r
   where r.id = c.room_id and r.kind = 'main' and c.day < r.current_day - 30;
end $$;

revoke execute on function public.st_maintenance() from public, anon, authenticated;

select cron.schedule('st-market-tick', '2 seconds', $$select public.st_tick_all()$$);
select cron.schedule('st-maintenance', '*/5 * * * *', $$select public.st_maintenance()$$);

-- 메인(공유) 시장: 시작 자금 1천만원, 하루 5분 + 휴장 20초, 무기한
do $$
declare rid uuid;
begin
  if not exists(select 1 from public.st_rooms where kind = 'main') then
    insert into public.st_rooms(code, name, kind, status, start_cash, day_seconds, break_seconds, total_days, max_players, started_at)
    values ('MAIN', '메인 시장', 'main', 'running', 10000000, 300, 20, null, 100000, now())
    returning id into rid;
    perform public.st_seed_stocks(rid, false);
    perform public.st_open_day(rid);
  end if;
end $$;
