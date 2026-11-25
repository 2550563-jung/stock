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
  cidx int;
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

    cidx := least(38, greatest(0, floor(extract(epoch from (clock_timestamp() - rm.phase_started_at))
                                       / rm.day_seconds * 39)))::int;
    insert into public.st_candles(room_id, stock_id, day, idx, o, h, l, c, v)
    values (o.room_id, o.stock_id, rm.current_day, cidx, px, px, px, px, q)
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
    price := public.st_floor_tick((rec.base * case when p_randomize then 0.7 + random() * 0.6 else 1 end)::numeric);
    insert into public.st_stocks(room_id, symbol, name, sector, prev_close, last)
    values (p_room, rec.symbol, rec.name, rec.sector, price, price) returning id into sid;
    insert into public.st_stock_sim(stock_id, fair, vol) values (sid, price, rec.vol);
  end loop;
end $$;
