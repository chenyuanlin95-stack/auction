-- V2.7: persist fixed-lot owner codes and repair consignments missed by older seeding.
create or replace function public.host_seed_lots(p_room_id text,p_host_secret text,p_lots jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); v jsonb; owner_code text; invite_row invites%rowtype; mapped_player uuid; begin
 perform 1 from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 for v in select value from jsonb_array_elements(p_lots) loop
  owner_code:=upper(btrim(coalesce(v->>'owner',''))); invite_row:=null; mapped_player:=null;
  if owner_code<>'' then
   insert into invites(room_id,code,label) values(rid,owner_code,owner_code)
   on conflict(room_id,code) do nothing;
   select * into invite_row from invites where room_id=rid and code=owner_code;
   if invite_row.confirmed then mapped_player:=invite_row.used_by; end if;
  end if;
  insert into lots(room_id,id,title,description,start_price,min_increment,consigner_id,consigner_invite_id,sort_order)
  values(rid,(v->>'id')::integer,v->>'title',coalesce(v->>'desc',''),(v->>'start')::bigint,(v->>'step')::bigint,
   mapped_player,invite_row.id,(v->>'id')::integer)
  on conflict(room_id,id) do update set
   consigner_invite_id=coalesce(lots.consigner_invite_id,excluded.consigner_invite_id),
   consigner_id=coalesce(lots.consigner_id,excluded.consigner_id);
 end loop;
end $$;

create or replace function public.host_repair_unpaid_consignments(p_room_id text,p_host_secret text)
returns integer language plpgsql security definer set search_path=public as $$
declare rid text:=upper(p_room_id); r rooms%rowtype; rec record; fee bigint; income bigint; remaining bigint; pay bigint; debt loans%rowtype; repaired integer:=0; begin
 select * into r from rooms where id=rid and host_secret=p_host_secret for update;
 if not found then raise exception '主持人权限无效'; end if;
 update lots l set consigner_id=i.used_by
 from invites i where l.room_id=rid and l.consigner_invite_id=i.id and i.confirmed and i.used_by is not null;
 for rec in
  select w.lot_id,w.price,l.consigner_id from wins w join lots l on l.room_id=w.room_id and l.id=w.lot_id
  where w.room_id=rid and l.consigner_id is not null
   and not exists(select 1 from transactions t where t.room_id=rid and t.related_lot_id=w.lot_id and t.type='consignment_income')
  order by w.created_at,w.lot_id
 loop
  fee:=auction_commission(rid,rec.price); income:=rec.price-fee; remaining:=income;
  if r.auto_repay then
   for debt in select * from loans where room_id=rid and player_id=rec.consigner_id and status='active' order by created_at,id for update loop
    exit when remaining=0; pay:=least(remaining,debt.outstanding);
    update loans set outstanding=outstanding-pay,status=case when outstanding-pay=0 then 'repaid' else 'active' end where id=debt.id;
    update wins set status=case when debt.outstanding-pay=0 then 'held' else 'mortgaged' end where room_id=rid and lot_id=debt.lot_id;
    insert into transactions(room_id,player_id,type,amount,related_lot_id,related_loan_id,description)
    values(rid,rec.consigner_id,'repayment',-pay,rec.lot_id,debt.id,'补发委托收入自动偿债');
    remaining:=remaining-pay;
   end loop;
  end if;
  update players set balance=balance+remaining where room_id=rid and id=rec.consigner_id;
  insert into transactions(room_id,player_id,type,amount,related_lot_id,description)
  values(rid,rec.consigner_id,'consignment_income',income,rec.lot_id,'补发委托成交收入');
  insert into transactions(room_id,player_id,type,amount,related_lot_id,description)
  values(rid,rec.consigner_id,'commission',-fee,rec.lot_id,'拍卖行累进佣金');
  repaired:=repaired+1;
 end loop;
 return repaired;
end $$;

grant execute on function public.host_seed_lots(text,text,jsonb),public.host_repair_unpaid_consignments(text,text) to anon,authenticated;
