-- 한국장 규칙 헬퍼  [적용 완료]
-- 호가가격단위 (2023.1 개편, 유가/코스닥 공통)
create or replace function public.st_tick_size(p numeric) returns int
language sql immutable set search_path = public as $$
  select case when p < 2000 then 1 when p < 5000 then 5 when p < 20000 then 10
              when p < 50000 then 50 when p < 200000 then 100 when p < 500000 then 500
              else 1000 end
$$;
create or replace function public.st_floor_tick(p numeric) returns int
language sql immutable set search_path = public as $$
  select greatest(1, (floor(p / public.st_tick_size(floor(p))) * public.st_tick_size(floor(p)))::int)
$$;
create or replace function public.st_ceil_tick(p numeric) returns int
language sql immutable set search_path = public as $$
  select greatest(1, (ceil(p / public.st_tick_size(ceil(p))) * public.st_tick_size(ceil(p)))::int)
$$;
-- 상한가/하한가 (기준가 ±30%)
create or replace function public.st_upper(prev int) returns int
language sql immutable set search_path = public as $$ select public.st_floor_tick(prev * 1.3) $$;
create or replace function public.st_lower(prev int) returns int
language sql immutable set search_path = public as $$ select public.st_ceil_tick(prev * 0.7) $$;
-- 수수료/세금 (게임용 설정값)
create or replace function public.st_fee_rate() returns numeric
language sql immutable as $$ select 0.00015::numeric $$;   -- 매매수수료 0.015% (매수·매도 각각)
create or replace function public.st_tax_rate() returns numeric
language sql immutable as $$ select 0.0020::numeric $$;    -- 매도 시 거래세 0.20%
create or replace function public.st_reserve(price int, qty bigint) returns bigint
language sql immutable set search_path = public as $$
  select qty * price + ceil(qty * price * public.st_fee_rate())::bigint
$$;
create or replace function public.st_randn() returns float8
language sql volatile as $$ select sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) $$;
