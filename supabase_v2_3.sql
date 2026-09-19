-- V2.3: synchronized award ceremony data.
alter table public.rooms add column if not exists awards jsonb not null default '[]'::jsonb;

create or replace function public.finish_auction(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare
 rid text:=upper(p_room_id);
 richest text;
 spender text;
 collector text;
 borrower text;
 hammer_name text;
 hammer_lot text;
begin
 update rooms set ended_at=now(),status='closed' where id=rid and host_secret=p_host_secret and ended_at is null;
 if not found then raise exception '主持人权限无效或已结算'; end if;

 select name into richest from players where room_id=rid order by balance desc,joined_at limit 1;
 select p.name into spender from players p left join transactions t on t.player_id=p.id and t.room_id=rid and t.type='auction_purchase'
 where p.room_id=rid group by p.id,p.name,p.joined_at order by coalesce(-sum(t.amount),0) desc,p.joined_at limit 1;
 select p.name into collector from players p left join wins w on w.player_id=p.id and w.room_id=rid
 where p.room_id=rid group by p.id,p.name,p.joined_at order by count(w.id) desc,p.joined_at limit 1;
 select p.name into borrower from players p left join loans d on d.player_id=p.id and d.room_id=rid
 where p.room_id=rid group by p.id,p.name,p.joined_at order by coalesce(sum(d.principal),0) desc,p.joined_at limit 1;
 select p.name,l.title into hammer_name,hammer_lot from wins w join players p on p.id=w.player_id join lots l on l.room_id=w.room_id and l.id=w.lot_id
 where w.room_id=rid order by w.price desc,w.created_at limit 1;

 update rooms set awards=jsonb_build_array(
  jsonb_build_object('title','守财奴','winner',coalesce(richest,'—'),'detail','最终现金最多'),
  jsonb_build_object('title','一掷千金','winner',coalesce(spender,'—'),'detail','拍卖总支出最高'),
  jsonb_build_object('title','收藏狂魔','winner',coalesce(collector,'—'),'detail','获得拍品数量最多'),
  jsonb_build_object('title','负债累累','winner',coalesce(borrower,'—'),'detail','累计融资最高'),
  jsonb_build_object('title','最疯狂一锤','winner',coalesce(hammer_name,'—'),'detail',coalesce(hammer_lot,'本场最高成交价'))
 ) where id=rid;

 update wins set status='seized' where room_id=rid and status='mortgaged';
 update loans set status='seized' where room_id=rid and status='active';
end $$;

grant execute on function public.finish_auction(text,text) to anon,authenticated;
