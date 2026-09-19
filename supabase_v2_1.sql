-- Auction V2.1: invitation-owned consignments and reversible player management.
alter table public.invites add column if not exists confirmed boolean not null default false;
alter table public.invites add column if not exists confirmed_at timestamptz;
alter table public.lots add column if not exists consigner_invite_id bigint references public.invites(id) on delete set null;

update public.lots l set consigner_invite_id=i.id
from public.invites i
where l.room_id=i.room_id and l.consigner_id=i.used_by and l.consigner_invite_id is null;

update public.invites set confirmed=true,confirmed_at=coalesce(confirmed_at,now())
where used_by is not null and exists(
  select 1 from public.lots l where l.room_id=invites.room_id and l.consigner_id=invites.used_by
);

alter table public.rooms alter column invitation_text set default '尊敬的亿万富翁：
您好。
诚挚欢迎您莅临有求必应拍卖行，参加本次私人拍卖会。

今晚，我们为您甄选了一系列独一无二的拍品。
它们或珍贵，或稀有，或无法以寻常方式获得；
其中既有人们孜孜以求之物，也有那些只存在于想象之中的可能。

在这里，财富、机遇、天赋、时间乃至人生的另一种选择，
都将拥有被重新衡量的机会。

每一件拍品仅此一件，每一次落槌皆意味着最终归属。
您可以审慎权衡，也可以为真正心仪之物倾力一掷。

毕竟，理性固然可贵，错过却往往更加令人难忘。

期待与您共赴这场
属于顶级玩家的私人拍卖会。';

update public.rooms set invitation_text='尊敬的亿万富翁：
您好。
诚挚欢迎您莅临有求必应拍卖行，参加本次私人拍卖会。

今晚，我们为您甄选了一系列独一无二的拍品。
它们或珍贵，或稀有，或无法以寻常方式获得；
其中既有人们孜孜以求之物，也有那些只存在于想象之中的可能。

在这里，财富、机遇、天赋、时间乃至人生的另一种选择，
都将拥有被重新衡量的机会。

每一件拍品仅此一件，每一次落槌皆意味着最终归属。
您可以审慎权衡，也可以为真正心仪之物倾力一掷。

毕竟，理性固然可贵，错过却往往更加令人难忘。

期待与您共赴这场
属于顶级玩家的私人拍卖会。'
where invitation_text like '尊敬的亿万富翁：欢迎来到 XXX AUCTION HOUSE%';

create or replace function public.host_manage_player(p_room_id text,p_host_secret text,p_player_id uuid,p_action text,p_amount bigint default 0)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); old_balance bigint; delta bigint; begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 if p_action='kick' then
  update players set active=false where room_id=rid and id=p_player_id;
  if not found then raise exception '玩家不存在'; end if;
  update rooms set current_bid=null,current_bidder=null,current_bidder_name=null where id=rid and current_bidder=p_player_id;
 elsif p_action='restore' then
  if exists(select 1 from players p join players q on q.room_id=p.room_id and q.active and lower(btrim(q.name))=lower(btrim(p.name)) and q.id<>p.id where p.room_id=rid and p.id=p_player_id) then
   raise exception '同名玩家当前已存在，不能恢复';
  end if;
  update players set active=true where room_id=rid and id=p_player_id;
  if not found then raise exception '玩家不存在'; end if;
 elsif p_action='set_balance' then
  if p_amount<0 then raise exception '余额不能小于0'; end if;
  select balance into old_balance from players where room_id=rid and id=p_player_id for update;
  if not found then raise exception '玩家不存在'; end if;
  delta:=p_amount-old_balance;
  update players set balance=p_amount where id=p_player_id;
  insert into transactions(room_id,player_id,type,amount,description)
  values(rid,p_player_id,'manual_adjustment',delta,'主持人直接设置余额为 '||p_amount::text);
 else raise exception '操作无效'; end if;
end $$;

create or replace function public.host_confirm_invite(p_room_id text,p_host_secret text,p_invite_id bigint)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); pid uuid; begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 select used_by into pid from invites where room_id=rid and id=p_invite_id for update;
 if not found then raise exception '受邀人不存在'; end if;
 if pid is null then raise exception '该受邀人尚未匹配进入的玩家'; end if;
 update invites set confirmed=true,confirmed_at=now() where id=p_invite_id;
 update lots set consigner_id=pid where room_id=rid and consigner_invite_id=p_invite_id;
end $$;

create or replace function public.host_upsert_lot_by_invite(p_room_id text,p_host_secret text,p_lot_id integer,p_title text,p_description text,p_start_price bigint,p_min_increment bigint,p_consigner_invite_id bigint,p_preview boolean,p_image_url text default null)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); pid uuid; begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 if p_lot_id<1 or p_start_price<=0 or p_min_increment<=0 or btrim(p_title)='' then raise exception '拍品信息无效'; end if;
 if p_consigner_invite_id is not null then
  select case when confirmed then used_by else null end into pid from invites where room_id=rid and id=p_consigner_invite_id;
  if not found then raise exception '受邀人不属于本房间'; end if;
 end if;
 insert into lots(room_id,id,title,description,start_price,min_increment,consigner_id,consigner_invite_id,is_preview_visible,image_url,sort_order)
 values(rid,p_lot_id,left(btrim(p_title),120),left(p_description,3000),p_start_price,p_min_increment,pid,p_consigner_invite_id,p_preview,p_image_url,p_lot_id)
 on conflict(room_id,id) do update set title=excluded.title,description=excluded.description,start_price=excluded.start_price,
 min_increment=excluded.min_increment,consigner_id=excluded.consigner_id,consigner_invite_id=excluded.consigner_invite_id,
 is_preview_visible=excluded.is_preview_visible,image_url=excluded.image_url;
end $$;

create or replace function public.host_clear_lots(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 delete from lots l where l.room_id=rid and not exists(select 1 from wins w where w.room_id=rid and w.lot_id=l.id);
 update rooms r set current_lot=null,current_bid=null,current_bidder=null,current_bidder_name=null,status='waiting'
 where r.id=rid and not exists(select 1 from lots l where l.room_id=rid and l.id=r.current_lot);
end $$;

grant execute on function public.host_confirm_invite(text,text,bigint),public.host_upsert_lot_by_invite(text,text,integer,text,text,bigint,bigint,bigint,boolean,text),public.host_clear_lots(text,text) to anon,authenticated;
