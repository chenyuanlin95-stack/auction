-- 人生拍卖会 V2：在 V1 上执行。先备份数据库，再在 SQL Editor 运行。
create extension if not exists pgcrypto;
alter table public.rooms add column if not exists initial_balance bigint not null default 150000000;
alter table public.rooms add column if not exists invitation_text text not null default '尊敬的亿万富翁：欢迎来到 XXX AUCTION HOUSE。我们为少数贵宾准备了绝无仅有的拍品。欲望有价，余下的一切皆可商议。';
alter table public.rooms add column if not exists auto_repay boolean not null default true;
alter table public.rooms add column if not exists mortgage_rate numeric not null default 0.5;
alter table public.rooms add column if not exists ended_at timestamptz;
alter table public.players add column if not exists active boolean not null default true;
alter table public.players add column if not exists invite_code text;
alter table public.players add column if not exists vip_no integer;
-- V1 allowed duplicate display names. Keep the earliest active identity in each
-- room and retire later duplicates before enforcing the V2 room-name rule.
with ranked_players as (
  select id,
         row_number() over (
           partition by room_id, lower(btrim(name))
           order by joined_at nulls last, id
         ) as duplicate_rank
  from public.players
  where active
)
update public.players p
set active = false
from ranked_players r
where p.id = r.id and r.duplicate_rank > 1;
create unique index if not exists players_room_token_uq on public.players(room_id,token);
create unique index if not exists players_room_name_uq on public.players(room_id,lower(btrim(name))) where active;
create unique index if not exists players_room_vip_uq on public.players(room_id,vip_no);
create table if not exists public.invites(
  id bigint generated always as identity primary key, room_id text not null references public.rooms(id) on delete cascade,
  code text not null, label text, used_by uuid references public.players(id),
  unique(room_id,code), unique(room_id,used_by)
);
create table if not exists public.lots(
  room_id text not null references public.rooms(id) on delete cascade, id integer not null,
  title text not null, description text not null default '', image_url text,
  start_price bigint not null check(start_price>0), min_increment bigint not null check(min_increment>0),
  consigner_id uuid references public.players(id), is_preview_visible boolean not null default false,
  sort_order integer not null default 0, primary key(room_id,id)
);
create table if not exists public.commission_tiers(
  room_id text not null references public.rooms(id) on delete cascade,
  lower_bound bigint not null check(lower_bound>=0), rate numeric not null check(rate>=0 and rate<=1),
  primary key(room_id,lower_bound)
);
create table if not exists public.bids(
  id bigint generated always as identity primary key, room_id text not null references public.rooms(id) on delete cascade,
  lot_id integer not null, player_id uuid not null references public.players(id), amount bigint not null,
  created_at timestamptz not null default now()
);
create table if not exists public.transactions(
  id bigint generated always as identity primary key, room_id text not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id), type text not null, amount bigint not null,
  related_lot_id integer, related_loan_id bigint, description text not null default '',
  created_at timestamptz not null default now()
);
create table if not exists public.loans(
  id bigint generated always as identity primary key, room_id text not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id), lot_id integer not null,
  principal bigint not null check(principal>0), outstanding bigint not null check(outstanding>=0),
  status text not null default 'active' check(status in ('active','repaid','seized')),
  created_at timestamptz not null default now(), unique(room_id,lot_id)
);
alter table public.wins add column if not exists status text not null default 'held';
create or replace function public.auction_commission(p_room_id text,p_price bigint)
returns bigint language plpgsql stable security definer set search_path=public as $$
declare t record; v_next bigint; v_fee numeric:=0; begin
 for t in select lower_bound,rate,lead(lower_bound) over(order by lower_bound) as upper_bound from commission_tiers where room_id=upper(p_room_id) order by lower_bound loop
  if p_price>t.lower_bound then v_fee:=v_fee+(least(p_price,coalesce(t.upper_bound,p_price))-t.lower_bound)*t.rate; end if;
 end loop;
 return floor(v_fee)::bigint;
end $$;
create or replace function public.create_room(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(btrim(p_room_id)); begin
 if length(rid)<4 or length(rid)>8 or length(p_host_secret)<16 then raise exception '房间信息无效'; end if;
 insert into rooms(id,host_secret) values(rid,p_host_secret);
 insert into commission_tiers(room_id,lower_bound,rate) values
 (rid,0,.4),(rid,10000000,.5),(rid,20000000,.6),(rid,30000000,.7),(rid,50000000,.8);
end $$;
create or replace function public.join_room(p_room_id text,p_name text,p_token text,p_invite_code text default null)
returns table(player_id uuid,balance bigint) language plpgsql security definer set search_path=public as $$
declare rid text:=upper(btrim(p_room_id)); nm text:=left(btrim(p_name),20); pid uuid; r rooms%rowtype; v_invite invites%rowtype; v_no integer; begin
 select * into r from rooms where id=rid for update; if not found then raise exception '房间不存在'; end if;
 if r.ended_at is not null then raise exception '拍卖已结束'; end if;
 if nm='' or p_token is null or length(p_token)<16 then raise exception '请输入有效姓名'; end if;
 select id into pid from players where room_id=rid and token=p_token;
 if pid is not null then
  if not exists(select 1 from players where id=pid and active) then raise exception '此账户已被主持人移出'; end if;
  return query select p.id,p.balance from players p where p.id=pid; return;
 end if;
 if (select count(*) from players where room_id=rid and active)>=25 then raise exception '房间已满（25人）'; end if;
 if exists(select 1 from players where room_id=rid and active and lower(btrim(name))=lower(nm)) then raise exception '本场姓名已被使用'; end if;
 if exists(select 1 from invites where room_id=rid) then
  select * into v_invite from invites where room_id=rid and code=upper(btrim(p_invite_code)) for update;
  if not found or v_invite.used_by is not null then raise exception '请填写有效且未使用的邀请编号'; end if;
 end if;
 select coalesce(max(vip_no),0)+1 into v_no from players where room_id=rid;
 insert into players(room_id,name,token,balance,vip_no,invite_code)
 values(rid,nm,p_token,r.initial_balance,v_no,coalesce(v_invite.code,upper(btrim(p_invite_code)))) returning id into pid;
 if v_invite.id is not null then update invites set used_by=pid where id=v_invite.id; end if;
 insert into transactions(room_id,player_id,type,amount,description) values(rid,pid,'initial_balance',r.initial_balance,'初始资金');
 return query select p.id,p.balance from players p where p.id=pid;
end $$;
create or replace function public.leave_room(p_room_id text,p_player_token text)
returns void language plpgsql security definer set search_path=public as $$ begin
 -- 退出设备不删除身份，避免重进时获得第二份资金。
 if not exists(select 1 from players where room_id=upper(p_room_id) and token=p_player_token) then raise exception '玩家身份无效'; end if;
end $$;
create or replace function public.host_manage_player(p_room_id text,p_host_secret text,p_player_id uuid,p_action text,p_amount bigint default 0)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 if p_action='kick' then
  update players set active=false where room_id=rid and id=p_player_id;
  if not found then raise exception '玩家不存在'; end if;
  update rooms set current_bid=null,current_bidder=null,current_bidder_name=null where id=rid and current_bidder=p_player_id;
 elsif p_action='adjust' then
  update players set balance=balance+p_amount where room_id=rid and id=p_player_id and balance+p_amount>=0;
  if not found then raise exception '玩家不存在或余额不足'; end if;
  insert into transactions(room_id,player_id,type,amount,description) values(rid,p_player_id,'manual_adjustment',p_amount,'主持人调整');
 else raise exception '操作无效'; end if;
end $$;
create or replace function public.host_settings(p_room_id text,p_host_secret text,p_initial_balance bigint,p_invitation_text text,p_auto_repay boolean,p_mortgage_rate numeric)
returns void language plpgsql security definer set search_path=public as $$ begin
 if p_initial_balance<0 or p_mortgage_rate<0 or p_mortgage_rate>1 then raise exception '设置无效'; end if;
 update rooms set initial_balance=p_initial_balance,invitation_text=left(p_invitation_text,2000),auto_repay=p_auto_repay,mortgage_rate=p_mortgage_rate
 where id=upper(p_room_id) and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
end $$;
create or replace function public.host_invite(p_room_id text,p_host_secret text,p_code text,p_label text)
returns void language plpgsql security definer set search_path=public as $$ begin
 perform 1 from rooms where id=upper(p_room_id) and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 insert into invites(room_id,code,label) values(upper(p_room_id),upper(btrim(p_code)),left(btrim(p_label),80));
end $$;
create or replace function public.host_upsert_lot(p_room_id text,p_host_secret text,p_lot_id integer,p_title text,p_description text,p_start_price bigint,p_min_increment bigint,p_consigner_id uuid,p_preview boolean,p_image_url text default null)
returns void language plpgsql security definer set search_path=public as $$ begin
 perform 1 from rooms where id=upper(p_room_id) and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 if p_lot_id<1 or p_start_price<=0 or p_min_increment<=0 then raise exception '拍品信息无效'; end if;
 if p_consigner_id is not null and not exists(select 1 from players where room_id=upper(p_room_id) and id=p_consigner_id and active) then raise exception '委托人不在本房间'; end if;
 insert into lots(room_id,id,title,description,start_price,min_increment,consigner_id,is_preview_visible,image_url,sort_order)
 values(upper(p_room_id),p_lot_id,left(btrim(p_title),120),left(p_description,3000),p_start_price,p_min_increment,p_consigner_id,p_preview,p_image_url,p_lot_id)
 on conflict(room_id,id) do update set title=excluded.title,description=excluded.description,start_price=excluded.start_price,
 min_increment=excluded.min_increment,consigner_id=excluded.consigner_id,is_preview_visible=excluded.is_preview_visible,image_url=excluded.image_url;
end $$;
create or replace function public.host_seed_lots(p_room_id text,p_host_secret text,p_lots jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 insert into lots(room_id,id,title,description,start_price,min_increment,sort_order)
 select rid,(v->>'id')::integer,v->>'title',coalesce(v->>'desc',''),(v->>'start')::bigint,(v->>'step')::bigint,(v->>'id')::integer
 from jsonb_array_elements(p_lots) v
 on conflict(room_id,id) do nothing;
end $$;
create or replace function public.host_delete_lot(p_room_id text,p_host_secret text,p_lot_id integer)
returns void language plpgsql security definer set search_path=public as $$ begin
 perform 1 from rooms where id=upper(p_room_id) and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 if exists(select 1 from wins where room_id=upper(p_room_id) and lot_id=p_lot_id) then raise exception '已成交拍品不可删除'; end if;
 delete from lots where room_id=upper(p_room_id) and id=p_lot_id;
end $$;
create or replace function public.host_set_commission(p_room_id text,p_host_secret text,p_tiers jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 if jsonb_typeof(p_tiers)<>'array' or jsonb_array_length(p_tiers)=0 then raise exception '佣金档位无效'; end if;
 if not exists(select 1 from jsonb_array_elements(p_tiers) t where (t->>'lower_bound')::bigint=0) then raise exception '佣金必须从0元开始'; end if;
 delete from commission_tiers where room_id=rid;
 insert into commission_tiers(room_id,lower_bound,rate)
 select rid,(t->>'lower_bound')::bigint,(t->>'rate')::numeric from jsonb_array_elements(p_tiers) t;
end $$;
create or replace function public.start_lot(p_room_id text,p_host_secret text,p_lot_id integer)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret and ended_at is null for update;
 if not found then raise exception '主持人权限无效或拍卖已结束'; end if;
 if not exists(select 1 from lots where room_id=rid and id=p_lot_id) then raise exception '拍品不存在'; end if;
 if exists(select 1 from wins where room_id=rid and lot_id=p_lot_id) then raise exception '该拍品已经成交'; end if;
 update rooms set current_lot=p_lot_id,status='open',current_bid=null,current_bidder=null,current_bidder_name=null where id=rid;
end $$;
create or replace function public.place_bid(p_room_id text,p_player_token text,p_amount bigint)
returns void language plpgsql security definer set search_path=public as $$
declare r rooms%rowtype; p players%rowtype; l lots%rowtype; v_min bigint; begin
 select * into r from rooms where id=upper(p_room_id) for update;
 if not found or r.status<>'open' or r.ended_at is not null then raise exception '当前没有开放竞拍'; end if;
 select * into p from players where room_id=r.id and token=p_player_token and active;
 if not found then raise exception '玩家身份无效或已被移出'; end if;
 select * into l from lots where room_id=r.id and id=r.current_lot;
 v_min:=case when r.current_bid is null then l.start_price else r.current_bid+l.min_increment end;
 if p_amount<v_min then raise exception '出价低于最低有效价格'; end if;
 if p_amount>p.balance then raise exception '余额不足'; end if;
 update rooms set current_bid=p_amount,current_bidder=p.id,current_bidder_name=p.name where id=r.id;
 insert into bids(room_id,lot_id,player_id,amount) values(r.id,l.id,p.id,p_amount);
end $$;
create or replace function public.close_lot(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare r rooms%rowtype; buyer players%rowtype; seller players%rowtype; l lots%rowtype; fee bigint; income bigint; remaining bigint; pay bigint; debt loans%rowtype; begin
 select * into r from rooms where id=upper(p_room_id) for update;
 if not found or r.host_secret<>p_host_secret then raise exception '主持人权限无效'; end if;
 if r.status<>'open' or r.current_bidder is null then raise exception '当前没有可成交的竞价'; end if;
 select * into buyer from players where room_id=r.id and id=r.current_bidder and active for update;
 if not found or buyer.balance<r.current_bid then raise exception '赢家余额不足或已离场'; end if;
 select * into l from lots where room_id=r.id and id=r.current_lot;
 update players set balance=balance-r.current_bid where id=buyer.id;
 insert into wins(room_id,lot_id,player_id,player_name,price) values(r.id,l.id,buyer.id,buyer.name,r.current_bid);
 insert into transactions(room_id,player_id,type,amount,related_lot_id,description) values(r.id,buyer.id,'auction_purchase',-r.current_bid,l.id,'拍品成交');
 if l.consigner_id is not null then
  fee:=auction_commission(r.id,r.current_bid); income:=r.current_bid-fee; remaining:=income;
  select * into seller from players where room_id=r.id and id=l.consigner_id for update;
  if r.auto_repay then
   for debt in select * from loans where room_id=r.id and player_id=seller.id and status='active' order by created_at,id for update loop
    exit when remaining=0;
    pay:=least(remaining,debt.outstanding);
    update loans set outstanding=outstanding-pay,status=case when outstanding-pay=0 then 'repaid' else 'active' end where id=debt.id;
    update wins set status=case when debt.outstanding-pay=0 then 'held' else 'mortgaged' end where room_id=r.id and lot_id=debt.lot_id;
    insert into transactions(room_id,player_id,type,amount,related_lot_id,related_loan_id,description)
    values(r.id,seller.id,'repayment',-pay,l.id,debt.id,'委托收入自动偿债');
    remaining:=remaining-pay;
   end loop;
  end if;
  update players set balance=balance+remaining where id=seller.id;
  insert into transactions(room_id,player_id,type,amount,related_lot_id,description)
  values(r.id,seller.id,'consignment_income',income,l.id,'委托成交收入');
  insert into transactions(room_id,player_id,type,amount,related_lot_id,description)
  values(r.id,seller.id,'commission',-fee,l.id,'拍卖行累进佣金');
 end if;
 update rooms set status='closed' where id=r.id;
end $$;
create or replace function public.pass_lot(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$ begin
 update rooms set status='closed' where id=upper(p_room_id) and host_secret=p_host_secret and status='open';
 if not found then raise exception '主持人权限无效或当前未开拍'; end if;
end $$;
create or replace function public.take_loan(p_room_id text,p_player_token text,p_lot_id integer,p_amount bigint)
returns void language plpgsql security definer set search_path=public as $$
declare r rooms%rowtype; p players%rowtype; w wins%rowtype; v_cap bigint; v_id bigint; begin
 select * into r from rooms where id=upper(p_room_id) for update;
 if not found or r.ended_at is not null then raise exception '房间无效或已结算'; end if;
 select * into p from players where room_id=r.id and token=p_player_token and active for update;
 if not found then raise exception '玩家身份无效'; end if;
 select * into w from wins where room_id=r.id and lot_id=p_lot_id and player_id=p.id and status='held' for update;
 if not found then raise exception '此拍品不可抵押'; end if;
 v_cap:=floor(w.price*r.mortgage_rate);
 if p_amount<=0 or p_amount>v_cap then raise exception '超过该拍品抵押上限'; end if;
 insert into loans(room_id,player_id,lot_id,principal,outstanding) values(r.id,p.id,p_lot_id,p_amount,p_amount) returning id into v_id;
 update wins set status='mortgaged' where id=w.id;
 update players set balance=balance+p_amount where id=p.id;
 insert into transactions(room_id,player_id,type,amount,related_lot_id,related_loan_id,description) values(r.id,p.id,'loan',p_amount,p_lot_id,v_id,'藏品抵押融资');
end $$;
create or replace function public.repay_loan(p_room_id text,p_player_token text,p_loan_id bigint,p_amount bigint)
returns void language plpgsql security definer set search_path=public as $$
declare r rooms%rowtype; p players%rowtype; d loans%rowtype; begin
 select * into r from rooms where id=upper(p_room_id) for update;
 select * into p from players where room_id=r.id and token=p_player_token and active for update;
 select * into d from loans where id=p_loan_id and room_id=r.id and player_id=p.id and status='active' for update;
 if not found then raise exception '贷款不存在'; end if;
 if p_amount<=0 or p_amount>d.outstanding or p_amount>p.balance then raise exception '还款金额无效'; end if;
 update players set balance=balance-p_amount where id=p.id;
 update loans set outstanding=outstanding-p_amount,status=case when outstanding-p_amount=0 then 'repaid' else 'active' end where id=d.id;
 if d.outstanding=p_amount then update wins set status='held' where room_id=r.id and lot_id=d.lot_id; end if;
 insert into transactions(room_id,player_id,type,amount,related_lot_id,related_loan_id,description) values(r.id,p.id,'repayment',-p_amount,d.lot_id,d.id,'主动还款');
end $$;
create or replace function public.finish_auction(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 update rooms set ended_at=now(),status='closed' where id=rid and host_secret=p_host_secret and ended_at is null;
 if not found then raise exception '主持人权限无效或已结算'; end if;
 update wins set status='seized' where room_id=rid and status='mortgaged';
 update loans set status='seized' where room_id=rid and status='active';
end $$;
create or replace function public.get_host_state(p_room_id text,p_host_secret text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r rooms%rowtype; begin
 select * into r from rooms where id=upper(p_room_id) and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效或房间不存在'; end if;
 return jsonb_build_object(
 'room',to_jsonb(r)-'host_secret',
 'players',coalesce((select jsonb_agg(to_jsonb(p)-'token' order by p.joined_at) from players p where p.room_id=r.id),'[]'::jsonb),
 'wins',coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from wins w where w.room_id=r.id),'[]'::jsonb),
 'lots',coalesce((select jsonb_agg(to_jsonb(l) order by l.sort_order,l.id) from lots l where l.room_id=r.id),'[]'::jsonb),
 'invites',coalesce((select jsonb_agg(to_jsonb(i) order by i.id) from invites i where i.room_id=r.id),'[]'::jsonb),
 'tiers',coalesce((select jsonb_agg(to_jsonb(t) order by t.lower_bound) from commission_tiers t where t.room_id=r.id),'[]'::jsonb),
 'bids',coalesce((select jsonb_agg(jsonb_build_object('lot_id',b.lot_id,'amount',b.amount,'name',p.name,'created_at',b.created_at) order by b.id desc) from bids b join players p on p.id=b.player_id where b.room_id=r.id and b.lot_id=r.current_lot),'[]'::jsonb),
 'transactions',coalesce((select jsonb_agg(to_jsonb(t) order by t.id desc) from transactions t where t.room_id=r.id),'[]'::jsonb),
 'loans',coalesce((select jsonb_agg(to_jsonb(d) order by d.id desc) from loans d where d.room_id=r.id),'[]'::jsonb));
end $$;
create or replace function public.get_player_state(p_room_id text,p_player_token text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r rooms%rowtype; p players%rowtype; begin
 select * into r from rooms where id=upper(p_room_id); if not found then raise exception '房间不存在'; end if;
 select * into p from players where room_id=r.id and token=p_player_token and active;
 if not found then raise exception '此账户已被主持人移出或身份无效'; end if;
 return jsonb_build_object(
 'room',to_jsonb(r)-'host_secret',
 'player',to_jsonb(p)-'token',
 'wins',coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from wins w where w.room_id=r.id and w.player_id=p.id),'[]'::jsonb),
 'lots',coalesce((select jsonb_agg(to_jsonb(l)-'consigner_id' order by l.sort_order,l.id) from lots l where l.room_id=r.id and (l.is_preview_visible or l.id=r.current_lot or exists(select 1 from wins w where w.room_id=r.id and w.lot_id=l.id and w.player_id=p.id))),'[]'::jsonb),
 'hidden_count',(select count(*) from lots l where l.room_id=r.id and not l.is_preview_visible and l.id is distinct from r.current_lot),
 'loans',coalesce((select jsonb_agg(to_jsonb(d) order by d.id desc) from loans d where d.room_id=r.id and d.player_id=p.id),'[]'::jsonb),
 'transactions',coalesce((select jsonb_agg(to_jsonb(t) order by t.id desc) from transactions t where t.room_id=r.id and t.player_id=p.id),'[]'::jsonb));
end $$;
create or replace function public.get_invitation(p_room_id text)
returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('text',invitation_text,'room_id',id) from rooms where id=upper(p_room_id)
$$;
revoke all on function public.auction_commission(text,bigint) from public;
grant execute on function public.create_room(text,text),public.join_room(text,text,text,text),public.leave_room(text,text),public.host_manage_player(text,text,uuid,text,bigint),public.host_settings(text,text,bigint,text,boolean,numeric),public.host_invite(text,text,text,text),public.host_upsert_lot(text,text,integer,text,text,bigint,bigint,uuid,boolean,text),public.host_seed_lots(text,text,jsonb),public.host_delete_lot(text,text,integer),public.host_set_commission(text,text,jsonb),public.start_lot(text,text,integer),public.place_bid(text,text,bigint),public.close_lot(text,text),public.pass_lot(text,text),public.take_loan(text,text,integer,bigint),public.repay_loan(text,text,bigint,bigint),public.finish_auction(text,text),public.get_host_state(text,text),public.get_player_state(text,text),public.get_invitation(text) to anon,authenticated;
do $$ begin
 begin alter publication supabase_realtime add table public.lots; exception when duplicate_object then null; end;
 begin alter publication supabase_realtime add table public.bids; exception when duplicate_object then null; end;
 begin alter publication supabase_realtime add table public.transactions; exception when duplicate_object then null; end;
 begin alter publication supabase_realtime add table public.loans; exception when duplicate_object then null; end;
end $$;
