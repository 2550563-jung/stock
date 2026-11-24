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
