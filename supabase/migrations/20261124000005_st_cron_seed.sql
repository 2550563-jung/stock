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

-- 보안 린트: 고정 search_path
alter function public.st_randn() set search_path = public;
alter function public.st_tax_rate() set search_path = public;
alter function public.st_fee_rate() set search_path = public;
alter function public.st_account_json(public.st_accounts) set search_path = public;
alter function public.st_check_nick(text) set search_path = public;
