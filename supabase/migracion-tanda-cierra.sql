-- ---------------------------------------------------------------------------
-- LA TANDA CON HORA DE CIERRE (14/10) — preparada, sin aplicar
--
-- La historia de "últimas 24 hs" promete que la tanda sekreta se cierra: esto
-- lo cumple solo. tandas.cierra_en es la hora; cada minuto la base mira si la
-- tanda activa ya pasó su hora y, si pasó, prende la siguiente (por id:
-- sekreta → hermética → abierta). El portal muestra la cuenta regresiva en el
-- cartel S7 del perfil y en la pantalla de compra; el panel, la hora.
--
-- Se programa cuando Mau sube la historia:
--   select public.programar_cierre(now() + interval '24 hours');
-- Se cancela con: select public.programar_cierre(null);
-- Cambiar de tanda a mano desde el panel borra la hora (admin_activar_tanda).
-- ---------------------------------------------------------------------------

alter table public.tandas add column if not exists cierra_en timestamptz;

drop function if exists public.la_tanda(text);
create function public.la_tanda(p_codigo text)
returns table(tanda_id integer, nombre text, precio integer, tope integer, cierra_en timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public.miembro_de(p_codigo);   -- esto es adentro del portal, no afuera
  return query
    select t.id, t.nombre, t.precio, 7, t.cierra_en
      from public.tandas t
     where t.activa
     limit 1;
end;
$$;

drop function if exists public.admin_tandas(text);
create function public.admin_tandas(p_codigo text)
returns table(tanda_id integer, nombre text, precio integer, activa boolean, vendidas integer, cierra_en timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select t.id, t.nombre, t.precio, t.activa,
           (select count(*)::integer from public.entradas e
             where e.tipo = t.nombre and e.anulada_en is null),
           t.cierra_en
      from public.tandas t
     order by t.id;
end;
$$;

-- la hora de cierre de la tanda activa (null la cancela)
create or replace function public.programar_cierre(p_cuando timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare v_nombre text;
begin
  update public.tandas set cierra_en = p_cuando where activa returning nombre into v_nombre;
  return coalesce(v_nombre, 'no hay tanda activa');
end;
$$;
revoke execute on function public.programar_cierre(timestamptz) from public, anon, authenticated;

-- cada minuto: si la activa ya pasó su hora, se prende la siguiente
create or replace function public.pasar_tanda_si_cierra()
returns void language plpgsql security definer set search_path = public as $$
declare v_act record; v_sig integer;
begin
  select id into v_act from public.tandas where activa and cierra_en is not null and cierra_en <= now();
  if v_act.id is null then return; end if;
  select id into v_sig from public.tandas where id > v_act.id order by id limit 1;
  if v_sig is null then return; end if;     -- era la última: queda abierta
  update public.tandas set activa = false, cierra_en = null where id = v_act.id;
  update public.tandas set activa = true where id = v_sig;
end;
$$;
revoke execute on function public.pasar_tanda_si_cierra() from public, anon, authenticated;

select cron.unschedule('pasar-tanda') where exists (select 1 from cron.job where jobname = 'pasar-tanda');
select cron.schedule('pasar-tanda', '* * * * *', 'select public.pasar_tanda_si_cierra();');

-- cambiar de tanda a mano borra la hora de cierre
CREATE OR REPLACE FUNCTION public.admin_activar_tanda(p_codigo text, p_tanda integer)
 RETURNS TABLE(ok boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  -- primero se apagan todas: el índice único no deja que haya dos prendidas
  -- ni por un instante dentro de la misma sentencia
  -- a mano, la hora de cierre de la que estaba se borra
  update public.tandas set activa = false, cierra_en = null where activa;
  update public.tandas set activa = true  where id = p_tanda;

  if not found then raise exception 'tanda_invalida'; end if;

  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'activar_tanda', jsonb_build_object('tanda', p_tanda));

  return query select true;
end;
$function$;

-- /s7 es pública (sin llave): la tanda que está abierta y cuándo cierra. Solo
-- eso, que es lo mismo que dicen el feed y las historias.
create or replace function public.tanda_publica()
returns table(nombre text, cierra_en timestamptz)
language sql stable security definer set search_path = public as $$
  select t.nombre, t.cierra_en from public.tandas t where t.activa limit 1;
$$;
grant execute on function public.tanda_publica() to anon, authenticated;
