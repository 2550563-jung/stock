-- 주식 게임 스키마 (모든 객체는 st_ 접두어)  [적용 완료]
create table public.st_accounts (
  id uuid primary key default gen_random_uuid(),
  nickname text not null,
  nickname_key text generated always as (lower(nickname)) stored unique,
  pass_hash text,                       -- null 이면 게스트
  created_at timestamptz not null default now()
);

create table public.st_sessions (
  token_hash text primary key,
  account_id uuid not null references public.st_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index on public.st_sessions(account_id);

create table public.st_login_attempts (
  id bigserial primary key,
  nickname_key text not null,
  at timestamptz not null default now()
);
create index on public.st_login_attempts(nickname_key, at);

create table public.st_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  kind text not null check (kind in ('main','room')),
  owner_id uuid references public.st_accounts(id) on delete set null,
  is_private boolean not null default false,
  status text not null default 'waiting' check (status in ('waiting','running','ended')),
  phase text not null default 'closed' check (phase in ('open','closed')),
  start_cash bigint not null,
  day_seconds int not null,
  break_seconds int not null default 15,
  total_days int,
  max_players int not null default 50,
  current_day int not null default 0,
  phase_started_at timestamptz,
  paused boolean not null default false,
  paused_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.st_stocks (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  symbol text not null,
  name text not null,
  sector text not null,
  prev_close int not null,
  open int, high int, low int,
  last int not null,
  volume bigint not null default 0,
  turnover bigint not null default 0,
  updated_at timestamptz not null default now(),
  unique (room_id, symbol)
);

-- 비공개: 시뮬레이션 내부값 (적정가 등) — 플레이어가 볼 수 없음
create table public.st_stock_sim (
  stock_id bigint primary key references public.st_stocks(id) on delete cascade,
  fair numeric not null,
  vol numeric not null          -- 일간 변동성 (예: 0.04 = 4%)
);

create table public.st_members (
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  account_id uuid not null references public.st_accounts(id) on delete cascade,
  cash bigint not null,
  locked_cash bigint not null default 0,
  resets int not null default 0,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (room_id, account_id),
  check (locked_cash >= 0 and locked_cash <= cash)
);

create table public.st_holdings (
  room_id uuid not null,
  account_id uuid not null,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  qty bigint not null default 0,
  locked_qty bigint not null default 0,
  avg_price numeric(18,2) not null default 0,
  primary key (room_id, account_id, stock_id),
  foreign key (room_id, account_id) references public.st_members(room_id, account_id) on delete cascade,
  check (qty >= 0 and locked_qty >= 0 and locked_qty <= qty)
);

create table public.st_orders (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  account_id uuid,                      -- null = 시장 조성 봇
  side text not null check (side in ('buy','sell')),
  otype text not null check (otype in ('limit','market')),
  price int not null,                   -- 시장가 매수는 증거금 계산용 상한가
  qty bigint not null check (qty > 0),
  filled bigint not null default 0,
  locked bigint not null default 0,     -- 매수 주문에 묶인 금액
  status text not null default 'open' check (status in ('open','filled','cancelled')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index st_orders_book on public.st_orders(stock_id, side, price, id) where status = 'open';
create index st_orders_acct on public.st_orders(account_id, room_id, status);

create table public.st_trades (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  price int not null,
  qty bigint not null,
  taker_side text not null,
  day int not null,
  created_at timestamptz not null default clock_timestamp()
);
create index on public.st_trades(stock_id, id desc);
create index on public.st_trades(created_at);

create table public.st_fills (
  id bigserial primary key,
  room_id uuid not null,
  account_id uuid not null,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  order_id bigint not null,
  side text not null,
  price int not null,
  qty bigint not null,
  fee bigint not null,
  tax bigint not null,
  realized bigint not null default 0,
  day int not null,
  created_at timestamptz not null default clock_timestamp(),
  foreign key (room_id, account_id) references public.st_members(room_id, account_id) on delete cascade
);
create index on public.st_fills(room_id, account_id, id desc);

create table public.st_candles (
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  day int not null,
  idx int not null,
  o int not null, h int not null, l int not null, c int not null,
  v bigint not null,
  primary key (stock_id, day, idx)
);

create table public.st_daily (
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  stock_id bigint not null references public.st_stocks(id) on delete cascade,
  day int not null,
  o int not null, h int not null, l int not null, c int not null,
  v bigint not null,
  primary key (stock_id, day)
);

create table public.st_news (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  stock_id bigint references public.st_stocks(id) on delete cascade,
  headline text not null,
  tone int not null default 0,          -- 1 호재, -1 악재, 0 중립
  day int not null,
  created_at timestamptz not null default now()
);
create index on public.st_news(room_id, id desc);

create table public.st_chat (
  id bigserial primary key,
  room_id uuid not null references public.st_rooms(id) on delete cascade,
  account_id uuid references public.st_accounts(id) on delete set null,
  nickname text not null,
  body text not null,
  created_at timestamptz not null default now()
);
create index on public.st_chat(room_id, id desc);

-- RLS: 모두 활성화. 공개 조회 테이블만 select 정책 부여. 쓰기는 오직 RPC(security definer)로만.
do $$
declare t text;
begin
  foreach t in array array['st_accounts','st_sessions','st_login_attempts','st_rooms','st_stocks','st_stock_sim',
    'st_members','st_holdings','st_orders','st_trades','st_fills','st_candles','st_daily','st_news','st_chat'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
  foreach t in array array['st_rooms','st_stocks','st_trades','st_candles','st_daily','st_news','st_chat'] loop
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_read', t);
  end loop;
end $$;

alter publication supabase_realtime add table public.st_news, public.st_chat;
