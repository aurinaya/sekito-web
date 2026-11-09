-- 09/11/2026, pedido de Mau
--
-- 1) Los tres fundadores figuran con entrada a SEKI 7: una staff a $0 para
--    cada uno, ya asignada (entra con código y QR como cualquiera). Se inserta
--    con el dueño puesto, así no sale el mail de "te dieron una entrada".
-- 2) El contador de susurros del panel no cuenta los que manda LA SEKTA.
--
-- Para volver atrás: anular las tres entradas desde el panel, y reaplicar
-- admin_numeros_miembros de supabase/migracion-numeros-miembros.sql.

insert into public.entradas (tenedor, duenio, asignada_en, tipo, precio, nota, generada_por)
select m.id, m.id, now(), 'staff', 0, 'fundador',
       (select a.id from public.admins a where a.es_dueno limit 1)
  from public.miembros m
 where m.es_fundador
   and not exists (select 1 from public.entradas e
                    where e.evento = 'seki7' and e.anulada_en is null and e.duenio = m.id);

insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
select (select a.id from public.admins a where a.es_dueno limit 1), 'generar_entradas', m.id,
       jsonb_build_object('cantidad', 1, 'tipo', 'staff', 'precio', 0, 'nota', 'fundador')
  from public.miembros m where m.es_fundador;

create or replace function public.admin_numeros_miembros(p_codigo text)
 returns table(por_invitacion integer, por_panel integer, fundadores integer, susurros integer)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    with adentro as (
      select m.id, m.es_fundador,
             exists (select 1 from public.invitaciones i where i.usada_por = m.id) as invitado
        from public.miembros m
       where m.estado_codigo = 'activo' and m.nombre_real is not null
    )
    select count(*) filter (where invitado)::integer,
           count(*) filter (where not invitado and not es_fundador)::integer,
           count(*) filter (where es_fundador and not invitado)::integer,
           -- los de LA SEKTA no cuentan: el número es de lo que se susurran entre ellxs
           (select count(*)::integer from public.susurros s
             join public.miembros d on d.id = s.de
            where d.estado_codigo <> 'simbolico')
      from adentro;
end;
$function$;
