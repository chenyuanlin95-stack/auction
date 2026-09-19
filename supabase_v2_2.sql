-- V2.2: repair invitation ownership for players who joined before the invite was created.
create or replace function public.host_invite(p_room_id text,p_host_secret text,p_code text,p_label text)
returns void language plpgsql security definer set search_path=public as $$
declare
 rid text:=upper(btrim(p_room_id));
 normalized_code text:=upper(btrim(p_code));
 matched_player uuid;
 match_count integer;
begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 if normalized_code='' then raise exception '首字母不能为空'; end if;

 select count(*),min(id::text)::uuid into match_count,matched_player
 from players
 where room_id=rid and active and upper(btrim(invite_code))=normalized_code;
 if match_count>1 then raise exception '有多个玩家使用这个首字母，请先处理重复账户'; end if;

 insert into invites(room_id,code,label,used_by)
 values(rid,normalized_code,left(btrim(p_label),80),matched_player);
end $$;

create or replace function public.host_confirm_invite(p_room_id text,p_host_secret text,p_invite_id bigint)
returns void language plpgsql security definer set search_path=public as $$
declare
 rid text:=upper(btrim(p_room_id));
 pid uuid;
 invite_code_value text;
 match_count integer;
begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;

 select used_by,code into pid,invite_code_value
 from invites where room_id=rid and id=p_invite_id for update;
 if not found then raise exception '受邀人不存在'; end if;

 if pid is null then
  select count(*),min(id::text)::uuid into match_count,pid
  from players
  where room_id=rid and active and upper(btrim(invite_code))=upper(btrim(invite_code_value));
  if match_count=0 then raise exception '还没有使用该首字母进入的玩家'; end if;
  if match_count>1 then raise exception '有多个玩家使用这个首字母，无法自动确认'; end if;
  update invites set used_by=pid where id=p_invite_id;
 end if;

 update invites set confirmed=true,confirmed_at=now() where id=p_invite_id;
 update lots set consigner_id=pid where room_id=rid and consigner_invite_id=p_invite_id;
end $$;

grant execute on function public.host_invite(text,text,text,text),public.host_confirm_invite(text,text,bigint) to anon,authenticated;

create or replace function public.host_bind_invite(p_room_id text,p_host_secret text,p_invite_id bigint,p_player_id uuid,p_confirmed boolean)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(btrim(p_room_id)); begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret;
 if not found then raise exception '主持人权限无效'; end if;
 perform 1 from invites where room_id=rid and id=p_invite_id for update;
 if not found then raise exception '受邀人不存在'; end if;
 if p_player_id is not null and not exists(select 1 from players where room_id=rid and id=p_player_id and active) then
  raise exception '选择的玩家不在当前房间';
 end if;
 update invites set used_by=p_player_id,confirmed=(p_confirmed and p_player_id is not null),
  confirmed_at=case when p_confirmed and p_player_id is not null then now() else null end
 where room_id=rid and id=p_invite_id;
 update lots set consigner_id=case when p_confirmed then p_player_id else null end
 where room_id=rid and consigner_invite_id=p_invite_id;
end $$;

grant execute on function public.host_bind_invite(text,text,bigint,uuid,boolean) to anon,authenticated;
