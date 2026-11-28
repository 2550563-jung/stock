-- ============================================================
--  게임화: 이벤트, 아이템, 레벨/칭호/업적, 실시간 피드
-- ============================================================

alter table public.st_accounts add column if not exists xp int not null default 0;
alter table public.st_accounts add column if not exists avatar text not null default '🐜';

alter table public.st_members add column if not exists frozen_until timestamptz;
alter table public.st_members add column if not exists insured_until timestamptz;
alter table public.st_members add column if not exists item_cd_until timestamptz;
alter table public.st_members add column if not exists win_streak int not null default 0;
alter table public.st_members add column if not exists trades int not null default 0;
alter table public.st_members add column if not exists best_trade bigint not null default 0;
alter table public.st_members add column if not exists worst_trade bigint not null default 0;

alter table public.st_rooms add column if not exists event_kind text;
alter table public.st_rooms add column if not exists event_stock bigint;
alter table public.st_rooms add column if not exists event_until timestamptz;

create table if not exists public.st_items (
  room_id uuid not null,
  account_id uuid not null,
  item text not null,
  qty int not null default 0,
  primary key (room_id, account_id, item),
  foreign key (room_id, account_id) references public.st_members(room_id, account_id) on delete cascade
);
alter table public.st_items enable row level security;
revoke all on public.st_items from anon, authenticated;

create table if not exists public.st_achievements (
  account_id uuid not null references public.st_accounts(id) on delete cascade,
  code text not null,
  at timestamptz not null default now(),
  primary key (account_id, code)
);
alter table public.st_achievements enable row level security;
revoke all on public.st_achievements from anon, authenticated;

create table if not exists public.st_feed (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  kind text not null,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists st_feed_room on public.st_feed(room_id, id desc);
alter table public.st_feed enable row level security;
revoke all on public.st_feed from anon, authenticated;
grant select on public.st_feed to anon, authenticated;
create policy st_feed_read on public.st_feed for select to anon, authenticated using (true);
alter publication supabase_realtime add table public.st_feed;

-- 메인 시장 템포 업
update public.st_rooms set day_seconds = 90, break_seconds = 10 where kind = 'main';

-- ===== 헬퍼 =====
create or replace function public.st_level(p_xp int) returns int
language sql immutable set search_path = public as $$ select floor(sqrt(greatest(p_xp, 0) / 25.0))::int + 1 $$;

create or replace function public.st_title(p_level int) returns text
language sql immutable set search_path = public as $$
  select case when p_level >= 30 then '주식의 신' when p_level >= 20 then '슈퍼리치'
              when p_level >= 16 then '여의도 큰손' when p_level >= 12 then '작전세력'
              when p_level >= 8 then '슈퍼개미' when p_level >= 5 then '단타왕'
              when p_level >= 3 then '동학개미' else '개미' end
$$;

create or replace function public.st_ach_name(c text) returns text
language sql immutable set search_path = public as $$
  select case c
    when 'first_trade' then '🐣 첫 거래' when 'first_profit' then '💵 첫 수익'
    when 'jackpot' then '💰 대박 (+10% 수익 매도)' when 'doom' then '💀 쪽박 (-10% 손실 매도)'
    when 'streak3' then '🔥 3연속 수익' when 'streak5' then '☄️ 5연속 수익'
    when 'whale' then '🐋 고래 (시작자금 30% 한방 거래)' when 'limit_up' then '🚀 상한가 추격 매수'
    when 'item_user' then '🎒 첫 아이템 사용' when 'rumor' then '🕵️ 작전 개시 (찌라시/루머)'
    when 'champion' then '🏆 방 1등' when 'millionaire' then '👑 자산 2배' when 'insured' then '🛡️ 보험금 수령'
    else c end
$$;

create or replace function public.st_feed_add(p_room uuid, p_kind text, p_body text) returns void
language sql set search_path = public as $$
  insert into public.st_feed(room_id, kind, body) values (p_room, p_kind, p_body)
$$;

create or replace function public.st_nick(p_acc uuid) returns text
language sql stable set search_path = public as $$
  select avatar || ' ' || nickname from public.st_accounts where id = p_acc
$$;

create or replace function public.st_won(v bigint) returns text
language sql immutable set search_path = public as $$ select to_char(v, 'FMS999,999,999,999') || '원' $$;

create or replace function public.st_random_item(p_room uuid) returns text
language plpgsql volatile set search_path = public as $$
declare it text := (array['insider','pump','bomb','shield','freeze','lucky'])[1 + floor(random() * 6)::int];
begin
  if it = 'freeze' and (select kind from public.st_rooms where id = p_room) = 'main' then it := 'lucky'; end if;
  return it;
end $$;

create or replace function public.st_add_item(p_room uuid, p_acc uuid, p_item text) returns void
language sql set search_path = public as $$
  insert into public.st_items(room_id, account_id, item, qty) values (p_room, p_acc, p_item, 1)
  on conflict (room_id, account_id, item) do update set qty = least(9, public.st_items.qty + 1)
$$;

create or replace function public.st_add_xp(p_acc uuid, p_room uuid, p_amt int) returns void
language plpgsql set search_path = public as $$
declare old_xp int; nl int;
begin
  if p_amt <= 0 then return; end if;
  update public.st_accounts set xp = xp + p_amt where id = p_acc returning xp - p_amt into old_xp;
  nl := public.st_level(old_xp + p_amt);
  if nl > public.st_level(old_xp) then
    perform public.st_feed_add(p_room, 'level',
      format('🎉 %s님 레벨 %s 달성! 칭호 [%s] · 보상 아이템 획득', public.st_nick(p_acc), nl, public.st_title(nl)));
    if exists(select 1 from public.st_members where room_id = p_room and account_id = p_acc) then
      perform public.st_add_item(p_room, p_acc, public.st_random_item(p_room));
    end if;
  end if;
end $$;

create or replace function public.st_unlock(p_acc uuid, p_room uuid, p_code text) returns void
language plpgsql set search_path = public as $$
declare n int;
begin
  insert into public.st_achievements(account_id, code) values (p_acc, p_code) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    perform public.st_feed_add(p_room, 'ach', format('🏅 %s님 업적 달성: %s', public.st_nick(p_acc), public.st_ach_name(p_code)));
    perform public.st_add_xp(p_acc, p_room, 50);
  end if;
end $$;

create or replace function public.st_account_json(a public.st_accounts) returns json
language sql stable set search_path = public as $$
  select json_build_object('id', a.id, 'nickname', a.nickname, 'is_guest', a.pass_hash is null,
    'avatar', a.avatar, 'xp', a.xp, 'level', public.st_level(a.xp), 'title', public.st_title(public.st_level(a.xp)),
    'level_xp', 25 * (public.st_level(a.xp) - 1) * (public.st_level(a.xp) - 1),
    'next_xp', 25 * public.st_level(a.xp) * public.st_level(a.xp),
    'achievements', coalesce((select json_agg(code order by at) from public.st_achievements where account_id = a.id), '[]'::json))
$$;

create or replace function public.st_set_avatar(p_token text, p_avatar text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); acc public.st_accounts;
begin
  if p_avatar is null or not (p_avatar = any(array['🐜','🐂','🐻','🦊','🐯','🐼','🐸','🐵','🦁','🐷','🐰','🐱','🐶','🐲','🦄','🐳'])) then
    raise exception '선택할 수 없는 아바타입니다'; end if;
  update public.st_accounts set avatar = p_avatar where id = a returning * into acc;
  return public.st_account_json(acc);
end $$;

-- ===== 체결 정산 (게임 요소 포함) =====
create or replace function public.st_fill(o public.st_orders, q bigint, px int, p_day int) returns void
language plpgsql set search_path = public as $$
declare
  v bigint := q * px;
  fee bigint; tax bigint := 0; new_lock bigint;
  h public.st_holdings; realized bigint := 0; cost bigint := 0;
  rm public.st_rooms; m public.st_members; sname text; prevc int;
  xp int := 3; refund bigint; total bigint;
begin
  if o.account_id is null then return; end if;
  fee := floor(v * public.st_fee_rate());
  select * into rm from public.st_rooms where id = o.room_id;
  select name, prev_close into sname, prevc from public.st_stocks where id = o.stock_id;

  if o.side = 'buy' then
    new_lock := public.st_reserve(o.price, o.qty - o.filled - q);
    update public.st_orders set locked = new_lock where id = o.id;
    update public.st_members
       set cash = cash - v - fee, locked_cash = locked_cash - (o.locked - new_lock), trades = trades + 1
     where room_id = o.room_id and account_id = o.account_id;
    insert into public.st_holdings(room_id, account_id, stock_id, qty, avg_price)
    values (o.room_id, o.account_id, o.stock_id, q, px)
    on conflict (room_id, account_id, stock_id) do update
       set avg_price = (public.st_holdings.avg_price * public.st_holdings.qty + v) / (public.st_holdings.qty + q),
           qty = public.st_holdings.qty + q;
    if px >= public.st_upper(prevc) then perform public.st_unlock(o.account_id, o.room_id, 'limit_up'); end if;
  else
    tax := floor(v * public.st_tax_rate());
    select * into h from public.st_holdings
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id for update;
    cost := round(h.avg_price * q)::bigint;
    realized := v - fee - tax - cost;
    update public.st_holdings set qty = qty - q, locked_qty = locked_qty - q
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id;
    delete from public.st_holdings
     where room_id = o.room_id and account_id = o.account_id and stock_id = o.stock_id and qty = 0 and locked_qty = 0;
    update public.st_members
       set cash = cash + v - fee - tax, trades = trades + 1,
           win_streak = case when realized > 0 then win_streak + 1 else 0 end,
           best_trade = greatest(best_trade, realized), worst_trade = least(worst_trade, realized)
     where room_id = o.room_id and account_id = o.account_id
     returning * into m;

    if realized > 0 then
      perform public.st_unlock(o.account_id, o.room_id, 'first_profit');
      xp := xp + least(100, (realized * 1000 / greatest(rm.start_cash, 1))::int);
      if cost > 0 and realized * 10 >= cost then
        perform public.st_unlock(o.account_id, o.room_id, 'jackpot');
        perform public.st_feed_add(o.room_id, 'profit', format('💰 %s님 %s 대박 매도! %s (+%s%%)',
          public.st_nick(o.account_id), sname, public.st_won(realized), round(realized * 100.0 / cost, 1)));
      end if;
      if m.win_streak >= 3 then perform public.st_unlock(o.account_id, o.room_id, 'streak3'); end if;
      if m.win_streak >= 5 then perform public.st_unlock(o.account_id, o.room_id, 'streak5'); end if;
      if m.win_streak in (3, 5, 7, 10) then
        perform public.st_feed_add(o.room_id, 'streak', format('🔥 %s님 %s연속 수익 중!', public.st_nick(o.account_id), m.win_streak));
      end if;
    elsif realized < 0 then
      if cost > 0 and realized * 10 <= -cost then
        perform public.st_unlock(o.account_id, o.room_id, 'doom');
        perform public.st_feed_add(o.room_id, 'loss', format('💀 %s님 %s 눈물의 손절… %s',
          public.st_nick(o.account_id), sname, public.st_won(realized)));
      end if;
      if m.insured_until is not null and m.insured_until > now() then
        refund := (-realized) / 2;
        update public.st_members set cash = cash + refund where room_id = o.room_id and account_id = o.account_id;
        perform public.st_unlock(o.account_id, o.room_id, 'insured');
        perform public.st_feed_add(o.room_id, 'item', format('🛡️ %s님 보험금 %s 수령!', public.st_nick(o.account_id), public.st_won(refund)));
      end if;
    end if;

    select m2.cash + coalesce((select sum(h2.qty * s2.last) from public.st_holdings h2 join public.st_stocks s2 on s2.id = h2.stock_id
                                where h2.room_id = o.room_id and h2.account_id = o.account_id), 0)
      into total from public.st_members m2 where m2.room_id = o.room_id and m2.account_id = o.account_id;
    if total >= rm.start_cash * 2 then perform public.st_unlock(o.account_id, o.room_id, 'millionaire'); end if;
  end if;

  insert into public.st_fills(room_id, account_id, stock_id, order_id, side, price, qty, fee, tax, realized, day)
  values (o.room_id, o.account_id, o.stock_id, o.id, o.side, px, q, fee, tax, realized, p_day);

  perform public.st_unlock(o.account_id, o.room_id, 'first_trade');
  if v * 10 >= rm.start_cash * 3 then perform public.st_unlock(o.account_id, o.room_id, 'whale'); end if;
  if v * 5 >= rm.start_cash then
    perform public.st_feed_add(o.room_id, 'trade', format('%s %s님이 %s %s주 %s! (%s)',
      case when o.side = 'buy' then '🐋' else '💸' end, public.st_nick(o.account_id), sname, to_char(q, 'FM999,999,999'),
      case when o.side = 'buy' then '풀매수' else '대량 매도' end, public.st_won(v)));
  end if;
  perform public.st_add_xp(o.account_id, o.room_id, xp);
end $$;

-- ===== 장 마감 / 개장 =====
create or replace function public.st_close_day(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare oid bigint; rm public.st_rooms; r record; i int := 0; podium text := '';
begin
  for oid in select id from public.st_orders where room_id = p_room and status = 'open' loop
    perform public.st_cancel_internal(oid);
  end loop;
  select * into rm from public.st_rooms where id = p_room;
  insert into public.st_daily(room_id, stock_id, day, o, h, l, c, v)
  select room_id, id, rm.current_day, coalesce(open, last), coalesce(high, last), coalesce(low, last), last, volume
    from public.st_stocks where room_id = p_room
  on conflict do nothing;
  update public.st_rooms set event_kind = null, event_stock = null, event_until = null where id = p_room;
  if rm.total_days is not null and rm.current_day >= rm.total_days then
    update public.st_rooms set status = 'ended', phase = 'closed', ended_at = now(), phase_started_at = now() where id = p_room;
    for r in select (x->>'account_id')::uuid acc, x->>'nickname' nick, x->>'avatar' av, (x->>'total')::bigint total
               from json_array_elements(public.st_ranking(p_room)) x limit 3 loop
      i := i + 1;
      podium := podium || format(' %s %s %s(%s)', (array['🥇','🥈','🥉'])[i], r.av, r.nick, public.st_won(r.total - rm.start_cash));
      if i = 1 then perform public.st_unlock(r.acc, p_room, 'champion'); end if;
    end loop;
    insert into public.st_news(room_id, headline, day) values (p_room, '🏁 모든 거래일이 끝났습니다. 최종 순위를 확인하세요!', rm.current_day);
    perform public.st_feed_add(p_room, 'end', '🏁 게임 종료!' || podium);
  else
    update public.st_rooms set phase = 'closed', phase_started_at = now() where id = p_room;
    insert into public.st_news(room_id, headline, day)
    values (p_room, format('🔔 %s일차 장 마감. 미체결 주문은 모두 취소되었습니다.', rm.current_day), rm.current_day);
  end if;
end $$;

create or replace function public.st_open_day(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare d int; mem record; rk text;
begin
  update public.st_stocks
     set prev_close = last, open = null, high = null, low = null, volume = 0, turnover = 0, updated_at = now()
   where room_id = p_room;
  update public.st_stock_sim sm
     set fair = least(public.st_upper(st.last), greatest(public.st_lower(st.last),
                 (st.last * exp(sm.vol * 0.7 * public.st_randn()))::numeric))
    from public.st_stocks st
   where st.id = sm.stock_id and st.room_id = p_room;
  update public.st_rooms set phase = 'open', current_day = current_day + 1, phase_started_at = now()
   where id = p_room returning current_day, kind into d, rk;
  -- 매일 아이템 1개 지급 (메인 시장은 최근 10분 접속자만)
  for mem in select account_id from public.st_members
              where room_id = p_room and (rk <> 'main' or last_seen > now() - interval '10 minutes') loop
    perform public.st_add_item(p_room, mem.account_id, public.st_random_item(p_room));
  end loop;
  insert into public.st_news(room_id, headline, day) values (p_room, format('🔔 %s일차 장이 시작되었습니다.', d), d);
  perform public.st_feed_add(p_room, 'day', format('🔔 %s일차 개장! 🎁 모두에게 아이템 1개 지급', d));
end $$;

-- ===== 시장 틱 (이벤트 + 높은 변동성) =====
create or replace function public.st_tick_room(p_room uuid) returns void
language plpgsql set search_path = public as $$
declare
  rm public.st_rooms;
  s record;
  ups int; lows int; tpd numeric; f numeric; tone int; mag numeric;
  bid int; ask int; p int; i int; oid bigint; qty bigint; pbuy numeric;
  ek text; es bigint; esname text; active boolean;
  pos text[] := array[
    '%s, 대규모 해외 수주 계약 체결', '%s, 분기 실적 어닝 서프라이즈', '%s, 신제품 대박 조짐',
    '외국인·기관, %s 쓸어 담는 중', '%s, 자사주 매입 결정', '%s, 정부 지원 사업 선정', '%s, 글로벌 빅테크와 제휴설',
    '%s 대표 "올해 실적 역대 최고 자신"', '유명 유튜버 "%s 지금 안 사면 후회"'];
  neg text[] := array[
    '%s, 분기 실적 쇼크', '%s, 주력 제품 리콜 사태', '%s, 대규모 유상증자 결정',
    '외국인, %s 대량 매도 폭탄', '%s, 경영진 횡령 의혹', '%s, 핵심 계약 해지 통보', '%s, 신용등급 하향',
    '%s 공장 화재 발생', '%s 대주주 지분 대량 처분'];
  mpos text[] := array['📈 중앙은행 기준금리 깜짝 인하', '📈 해외 증시 일제히 급등', '📈 외국인 투자 자금 대거 유입'];
  mneg text[] := array['📉 중앙은행 기준금리 인상 우려', '📉 해외 증시 급락 여파', '📉 환율 급등, 외국인 이탈 공포'];
begin
  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room for update;
  if not found or rm.status <> 'running' then return; end if;

  if rm.kind = 'main' then
    active := exists(select 1 from public.st_members where room_id = rm.id and last_seen > now() - interval '10 minutes');
    if not active then
      if not rm.paused then update public.st_rooms set paused = true, paused_at = now() where id = rm.id; end if;
      return;
    elsif rm.paused then
      update public.st_rooms
         set paused = false, phase_started_at = phase_started_at + (now() - paused_at),
             event_until = event_until + (now() - paused_at), paused_at = null
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

  tpd := greatest(10, rm.day_seconds / 2.0);

  -- 이벤트 종료 / 시작
  if rm.event_kind is not null and now() >= rm.event_until then
    update public.st_rooms set event_kind = null, event_stock = null, event_until = null where id = rm.id returning * into rm;
    perform public.st_feed_add(rm.id, 'event', '⏱️ 이벤트 종료! 시장이 진정됩니다');
  end if;
  if rm.event_kind is null and random() < 1.0 / (tpd * 0.8) then
    ek := (array['pump','dump','bull','bear'])[1 + floor(random() * 4)::int];
    es := null; esname := null;
    if ek in ('pump', 'dump') then
      select id, name into es, esname from public.st_stocks where room_id = rm.id order by random() limit 1;
    end if;
    update public.st_rooms set event_kind = ek, event_stock = es, event_until = now() + interval '20 seconds'
     where id = rm.id returning * into rm;
    perform public.st_feed_add(rm.id, 'event', case ek
      when 'pump' then format('🚀 [이벤트] %s 폭등 시작! 20초간 미친 듯이 오른다!', esname)
      when 'dump' then format('💥 [이벤트] %s 폭락 시작! 20초간 탈출 러시!', esname)
      when 'bull' then '🐂 [이벤트] 황소장 출현! 20초간 전 종목 상승세'
      else '🐻 [이벤트] 곰장 출현! 20초간 전 종목 하락세' end);
  end if;

  if random() < 1.0 / (tpd * 2) then
    tone := case when random() < 0.5 then 1 else -1 end;
    mag := 0.02 + random() * 0.04;
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
    -- 게임용 변동성 1.8배 + 약한 평균회귀
    f := s.fair * exp(s.vol * 1.8 / sqrt(tpd) * public.st_randn()
                      - 0.02 / tpd * ln(s.fair / s.prev_close))::numeric;

    if rm.event_kind = 'pump' and s.id = rm.event_stock then f := f * 1.025;
    elsif rm.event_kind = 'dump' and s.id = rm.event_stock then f := f * 0.975;
    elsif rm.event_kind = 'bull' then f := f * 1.008;
    elsif rm.event_kind = 'bear' then f := f * 0.992;
    end if;

    if random() < 1.0 / (tpd * 0.8) then
      tone := case when random() < 0.5 then 1 else -1 end;
      mag := 0.03 + random() * 0.09;
      f := f * (1 + tone * mag);
      insert into public.st_news(room_id, stock_id, headline, tone, day)
      values (rm.id, s.id,
              format(case when tone > 0 then pos[1 + floor(random() * array_length(pos, 1))::int]
                          else neg[1 + floor(random() * array_length(neg, 1))::int] end, s.name),
              tone, rm.current_day);
    end if;

    f := least(ups, greatest(lows, f));
    update public.st_stock_sim set fair = f where stock_id = s.id;

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

    if random() < 0.8 then
      pbuy := 0.5 + greatest(-0.35, least(0.35, (f - s.last) / s.last * 25));
      qty := greatest(1, round((2e6 + random() * 25e6) / s.last));
      insert into public.st_orders(room_id, stock_id, account_id, side, otype, price, qty)
      values (rm.id, s.id, null, case when random() < pbuy then 'buy' else 'sell' end, 'market', s.last, qty)
      returning id into oid;
      perform public.st_match(oid);
    end if;
  end loop;
end $$;

-- ===== 아이템 사용 =====
create or replace function public.st_use_item(p_token text, p_room uuid, p_item text, p_stock bigint, p_target text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  a uuid := public.st_auth(p_token);
  rm public.st_rooms; m public.st_members; s public.st_stocks; sim public.st_stock_sim;
  have int; msg text; diff numeric; tgt uuid; amt bigint;
begin
  perform pg_advisory_xact_lock(hashtext('st_room:' || p_room::text));
  select * into rm from public.st_rooms where id = p_room;
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  if rm.status <> 'running' or rm.phase <> 'open' or rm.paused then raise exception '아이템은 장중에만 쓸 수 있습니다'; end if;
  select * into m from public.st_members where room_id = p_room and account_id = a for update;
  if not found then raise exception '이 방의 참가자가 아닙니다'; end if;
  if m.item_cd_until is not null and m.item_cd_until > now() then
    raise exception '아이템 재사용 대기 중 (%초)', ceil(extract(epoch from m.item_cd_until - now()))::int; end if;
  select qty into have from public.st_items where room_id = p_room and account_id = a and item = p_item;
  if coalesce(have, 0) < 1 then raise exception '아이템이 없습니다'; end if;

  if p_item in ('insider', 'pump', 'bomb') then
    select * into s from public.st_stocks where id = p_stock and room_id = p_room;
    if not found then raise exception '종목을 선택하세요'; end if;
    select * into sim from public.st_stock_sim where stock_id = s.id for update;
  end if;

  if p_item = 'insider' then
    diff := (sim.fair - s.last) / s.last * 100;
    msg := format('🔮 [내부자 정보] %s 적정가는 현재가 대비 %s%% → %s', s.name, to_char(diff, 'FMS990.0'),
      case when diff > 2 then '곧 오를 가능성이 높다! 📈' when diff < -2 then '곧 떨어질 가능성이 높다! 📉' else '당분간 큰 움직임은 없을 듯 😐' end);
  elsif p_item = 'pump' then
    update public.st_stock_sim set fair = least(public.st_upper(s.prev_close), fair * 1.10) where stock_id = s.id;
    perform public.st_feed_add(p_room, 'item', format('📣 누군가 %s 호재 찌라시를 뿌렸다! 매수세 몰린다 🚀', s.name));
    insert into public.st_news(room_id, stock_id, headline, tone, day) values (p_room, s.id, format('[찌라시] %s 초대형 호재 임박?!', s.name), 1, rm.current_day);
    perform public.st_unlock(a, p_room, 'rumor');
    msg := format('📣 %s 찌라시 유포 성공! 적정가 +10%%', s.name);
  elsif p_item = 'bomb' then
    update public.st_stock_sim set fair = greatest(public.st_lower(s.prev_close), fair * 0.90) where stock_id = s.id;
    perform public.st_feed_add(p_room, 'item', format('🧨 누군가 %s 악성 루머를 퍼뜨렸다! 투매 주의 📉', s.name));
    insert into public.st_news(room_id, stock_id, headline, tone, day) values (p_room, s.id, format('[루머] %s 부도설 확산?!', s.name), -1, rm.current_day);
    perform public.st_unlock(a, p_room, 'rumor');
    msg := format('🧨 %s 루머 유포 성공! 적정가 -10%%', s.name);
  elsif p_item = 'shield' then
    update public.st_members set insured_until = now() + interval '60 seconds' where room_id = p_room and account_id = a;
    perform public.st_feed_add(p_room, 'item', format('🛡️ %s님이 손실 보험에 가입했다! (60초)', public.st_nick(a)));
    msg := '🛡️ 60초 동안 매도 손실의 50%를 돌려받습니다';
  elsif p_item = 'freeze' then
    if rm.kind = 'main' then raise exception '메인 시장에서는 얼음을 쓸 수 없습니다'; end if;
    select m2.account_id into tgt from public.st_members m2 join public.st_accounts ac on ac.id = m2.account_id
     where m2.room_id = p_room and ac.nickname_key = lower(btrim(coalesce(p_target, '')));
    if tgt is null then raise exception '대상 플레이어를 선택하세요'; end if;
    if tgt = a then raise exception '자기 자신은 얼릴 수 없습니다'; end if;
    update public.st_members set frozen_until = now() + interval '20 seconds' where room_id = p_room and account_id = tgt;
    perform public.st_feed_add(p_room, 'item', format('❄️ %s님이 %s님을 얼렸다! 20초간 거래 불가 🥶', public.st_nick(a), public.st_nick(tgt)));
    msg := '❄️ 상대를 20초간 얼렸습니다!';
  elsif p_item = 'lucky' then
    if random() < 0.7 then
      amt := round(rm.start_cash * (0.01 + random() * 0.04));
    else
      amt := -least(round(rm.start_cash * 0.02)::bigint, m.cash - m.locked_cash);
    end if;
    update public.st_members set cash = cash + amt where room_id = p_room and account_id = a;
    perform public.st_feed_add(p_room, 'item', case when amt >= 0
      then format('🎰 %s님 복권 당첨! %s 🎉', public.st_nick(a), public.st_won(amt))
      else format('🎰 %s님 복권 꽝… %s 😭', public.st_nick(a), public.st_won(amt)) end);
    msg := case when amt >= 0 then format('🎰 당첨! %s', public.st_won(amt)) else format('🎰 꽝… %s', public.st_won(amt)) end;
  else
    raise exception '알 수 없는 아이템입니다';
  end if;

  update public.st_items set qty = qty - 1 where room_id = p_room and account_id = a and item = p_item;
  update public.st_members set item_cd_until = now() + interval '15 seconds', last_seen = now() where room_id = p_room and account_id = a;
  perform public.st_unlock(a, p_room, 'item_user');
  perform public.st_add_xp(a, p_room, 5);
  return json_build_object('message', msg);
end $$;

-- ===== 기존 API 갱신 =====
create or replace function public.st_room_json(r public.st_rooms) returns json
language sql stable set search_path = public as $$
  select json_build_object(
    'id', r.id, 'code', r.code, 'name', r.name, 'kind', r.kind, 'owner_id', r.owner_id,
    'owner_nickname', (select nickname from public.st_accounts where id = r.owner_id),
    'is_private', r.is_private, 'status', r.status, 'phase', r.phase, 'start_cash', r.start_cash,
    'day_seconds', r.day_seconds, 'break_seconds', r.break_seconds, 'total_days', r.total_days,
    'max_players', r.max_players, 'current_day', r.current_day, 'phase_started_at', r.phase_started_at,
    'paused', r.paused, 'started_at', r.started_at, 'ended_at', r.ended_at,
    'event_kind', r.event_kind, 'event_stock', r.event_stock, 'event_until', r.event_until,
    'players', (select count(*) from public.st_members m where m.room_id = r.id))
$$;

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
  if p_day_seconds is null or p_day_seconds < 30 or p_day_seconds > 1800 then
    raise exception '하루 장 시간은 30~1800초 사이여야 합니다'; end if;
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
  insert into public.st_rooms(code, name, kind, owner_id, is_private, start_cash, day_seconds, break_seconds, total_days, max_players)
  values (c, p_name, 'room', a, coalesce(p_private, false), p_start_cash, p_day_seconds, 10, p_total_days, p_max_players)
  returning * into rm;
  insert into public.st_members(room_id, account_id, cash) values (rm.id, a, rm.start_cash);
  perform public.st_add_item(rm.id, a, public.st_random_item(rm.id));
  perform public.st_add_item(rm.id, a, public.st_random_item(rm.id));
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
    update public.st_members set last_seen = now() where room_id = rm.id and account_id = a;
    return public.st_room_json(rm);
  end if;
  if rm.status = 'ended' then raise exception '이미 종료된 방입니다'; end if;
  if (select count(*) from public.st_members where room_id = rm.id) >= rm.max_players then
    raise exception '정원이 가득 찼습니다'; end if;
  insert into public.st_members(room_id, account_id, cash) values (rm.id, a, rm.start_cash);
  perform public.st_add_item(rm.id, a, public.st_random_item(rm.id));
  perform public.st_add_item(rm.id, a, public.st_random_item(rm.id));
  perform public.st_feed_add(rm.id, 'join', format('👋 %s님이 입장했습니다', public.st_nick(a)));
  return public.st_room_json(rm);
end $$;

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
  if m.frozen_until is not null and m.frozen_until > now() then
    raise exception '❄️ 얼음 상태! %초 후 거래할 수 있습니다', ceil(extract(epoch from m.frozen_until - now()))::int; end if;
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
    px := case when p_side = 'buy' then ups else lows end;
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
  update public.st_members set cash = rm.start_cash, locked_cash = 0, resets = resets + 1,
         win_streak = 0, trades = 0, best_trade = 0, worst_trade = 0
   where room_id = p_room and account_id = a;
  perform public.st_feed_add(p_room, 'reset', format('🔄 %s님이 파산 후 재기를 노립니다…', public.st_nick(a)));
end $$;

create or replace function public.st_poll(p_token text, p_room uuid, p_stock bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a uuid := public.st_auth(p_token); rm public.st_rooms; m public.st_members; is_member boolean; acc public.st_accounts;
begin
  select * into rm from public.st_rooms where id = p_room;
  if not found then raise exception '방을 찾을 수 없습니다'; end if;
  update public.st_members set last_seen = now()
   where room_id = p_room and account_id = a and last_seen < now() - interval '15 seconds';
  select * into m from public.st_members where room_id = p_room and account_id = a;
  is_member := found;
  select * into acc from public.st_accounts where id = a;
  return json_build_object(
    'now', now(),
    'room', public.st_room_json(rm),
    'profile', public.st_account_json(acc),
    'stocks', (select json_agg(json_build_object(
        'id', id, 'symbol', symbol, 'name', name, 'sector', sector, 'prev_close', prev_close,
        'open', open, 'high', high, 'low', low, 'last', last, 'volume', volume, 'turnover', turnover,
        'upper', public.st_upper(prev_close), 'lower', public.st_lower(prev_close)) order by id)
        from public.st_stocks where room_id = p_room),
    'me', case when is_member then json_build_object('cash', m.cash, 'locked_cash', m.locked_cash, 'resets', m.resets,
        'frozen_until', m.frozen_until, 'insured_until', m.insured_until, 'item_cd_until', m.item_cd_until,
        'win_streak', m.win_streak, 'trades', m.trades) end,
    'items', coalesce((select json_object_agg(item, qty) from public.st_items where room_id = p_room and account_id = a and qty > 0), '{}'::json),
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
    select a.id as account_id, a.nickname, a.avatar, public.st_level(a.xp) as level, public.st_title(public.st_level(a.xp)) as title,
           a.pass_hash is null as is_guest, m.resets, m.trades, m.best_trade, m.worst_trade, m.win_streak,
           (m.frozen_until is not null and m.frozen_until > now()) as frozen,
           (m.insured_until is not null and m.insured_until > now()) as insured,
           m.cash + coalesce((select sum(h.qty * s.last) from public.st_holdings h join public.st_stocks s on s.id = h.stock_id
                               where h.room_id = m.room_id and h.account_id = m.account_id), 0) as total
      from public.st_members m join public.st_accounts a on a.id = m.account_id
     where m.room_id = p_room
     order by total desc limit 100) x
$$;

create or replace function public.st_maintenance() returns void
language plpgsql set search_path = public as $$
begin
  delete from public.st_trades where created_at < now() - interval '30 minutes';
  delete from public.st_feed where created_at < now() - interval '1 day';
  delete from public.st_sessions where expires_at < now();
  delete from public.st_login_attempts where at < now() - interval '1 day';
  delete from public.st_rooms where kind = 'room' and status = 'waiting' and created_at < now() - interval '1 day';
  delete from public.st_rooms where kind = 'room' and status = 'ended' and ended_at < now() - interval '7 days';
  delete from public.st_orders where status <> 'open' and updated_at < now() - interval '3 days';
  delete from public.st_chat where created_at < now() - interval '3 days';
  delete from public.st_news where created_at < now() - interval '3 days';
  delete from public.st_candles c using public.st_rooms r
   where r.id = c.room_id and r.kind = 'main' and c.day < r.current_day - 30;
end $$;

-- ===== 권한 재설정 =====
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'st\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (
              'st_guest_login','st_register','st_login','st_set_password','st_me','st_logout','st_set_avatar',
              'st_list_rooms','st_create_room','st_join_room','st_start_room','st_reset_me','st_use_item',
              'st_place_order','st_cancel_order','st_poll','st_ranking','st_send_chat') loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;
