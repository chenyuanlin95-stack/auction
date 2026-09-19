-- V2.6: optional invitation matching, reassignable ownership, controlled awards.
alter table public.rooms add column if not exists award_index integer not null default -1;
alter table public.rooms add column if not exists settlement_visible boolean not null default false;

create or replace function public.join_room(p_room_id text,p_name text,p_token text,p_invite_code text default null)
returns table(player_id uuid,balance bigint) language plpgsql security definer set search_path=public as $$
declare rid text:=upper(btrim(p_room_id)); nm text:=left(btrim(p_name),20); code_value text:=upper(btrim(coalesce(p_invite_code,''))); pid uuid; r rooms%rowtype; v_invite invites%rowtype; v_no integer; begin
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
 if code_value<>'' then select * into v_invite from invites where room_id=rid and code=code_value and used_by is null for update; end if;
 select coalesce(max(vip_no),0)+1 into v_no from players where room_id=rid;
 insert into players(room_id,name,token,balance,vip_no,invite_code) values(rid,nm,p_token,r.initial_balance,v_no,nullif(code_value,'')) returning id into pid;
 if v_invite.id is not null then update invites set used_by=pid where id=v_invite.id; end if;
 insert into transactions(room_id,player_id,type,amount,description) values(rid,pid,'initial_balance',r.initial_balance,'初始资金');
 return query select p.id,p.balance from players p where p.id=pid;
end $$;

create or replace function public.host_advance_award(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); begin
 update rooms set award_index=least(award_index+1,greatest(jsonb_array_length(awards)-1,-1))
 where id=rid and host_secret=p_host_secret and ended_at is not null;
 if not found then raise exception '主持人权限无效或尚未结算'; end if;
end $$;

create or replace function public.host_show_settlement(p_room_id text,p_host_secret text)
returns void language plpgsql security definer set search_path=public as $$ begin
 update rooms set settlement_visible=true where id=upper(p_room_id) and host_secret=p_host_secret and ended_at is not null;
 if not found then raise exception '主持人权限无效或尚未结算'; end if;
end $$;

grant execute on function public.join_room(text,text,text,text),public.host_advance_award(text,text),public.host_show_settlement(text,text) to anon,authenticated;
