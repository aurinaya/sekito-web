-- ============================================================================
-- SÉKITO — el tope de invitaciones pasa a 7
-- ============================================================================
-- Arranca la preventa de la SEKI 7 y cada entrada que alguien compra para un
-- amigo de afuera le cuesta una invitación. Con 5, comprar seis entradas te
-- deja sin forma de repartirlas.
--
-- El número estaba escrito tres veces: adentro de crear_invitacion, adentro
-- de mis_invitaciones, y otra vez en la pantalla. Tres lugares para un mismo
-- número es tres lugares donde se pueden desincronizar. Ahora hay uno.
--
-- Para ampliarle el cupo a alguien puntual, la sekta atiende por el privado
-- de sekito.gde: eso queda dicho en la pantalla, no automatizado.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.tope_invitaciones()
returns integer
language sql
immutable
set search_path = public
as $$ select 7 $$;

revoke all on function public.tope_invitaciones() from public, anon, authenticated;


create or replace function public.crear_invitacion(p_codigo text, p_para text)
 RETURNS TABLE(codigo text, vence_en timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_miembro   uuid;
  v_fundador  boolean;
  v_abiertas  int;
  v_para      text := nullif(btrim(coalesce(p_para, '')), '');
  v_cod       text;
  v_vence     timestamptz;
  v_i         int;
begin
  if v_para is null then
    raise exception 'falta_tag';
  end if;

  select m.id, m.es_fundador into v_miembro, v_fundador
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  if not v_fundador then
    select count(*) into v_abiertas
      from public.invitaciones i
     where i.generada_por = v_miembro
       and i.usada    = false
       and i.revocada = false
       and i.vence_en > now();

    if v_abiertas >= public.tope_invitaciones() then
      raise exception 'demasiadas_abiertas';
    end if;
  end if;

  -- el índice único de la columna es lo que garantiza que no se repita; este
  -- bucle es sólo la red por si justo cae una repetida
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 12);

      insert into public.invitaciones (generada_por, codigo, vence_en, para)
      values (v_miembro, v_cod, now() + interval '7 days', left(v_para, 60))
      returning invitaciones.vence_en into v_vence;

      return query select v_cod, v_vence;
      return;
    exception when unique_violation then
      null;  -- ya existía: probar con otro
    end;
  end loop;

  raise exception 'no_se_pudo_generar';
end;
$function$;

create or replace function public.mis_invitaciones(p_codigo text)
 RETURNS TABLE(codigo text, para text, estado text, vence_en timestamp with time zone, dias_restantes integer, creado_en timestamp with time zone, usada_en timestamp with time zone, quien_entro text, al_tope boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_miembro  uuid;
  v_fundador boolean;
  v_abiertas int;
begin
  select m.id, m.es_fundador into v_miembro, v_fundador
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  select count(*) into v_abiertas
    from public.invitaciones i
   where i.generada_por = v_miembro
     and i.usada = false and i.revocada = false and i.vence_en > now();

  return query
    select i.codigo,
           i.para,
           case when i.usada              then 'entro'
                when i.vence_en <= now()  then 'vencida'
                else                           'esperando' end,
           i.vence_en,
           greatest(0, ceil(extract(epoch from (i.vence_en - now())) / 86400)::int),
           i.creado_en,
           i.usada_en,
           quien.nombre_sektario,
           (not v_fundador and v_abiertas >= public.tope_invitaciones())
      from public.invitaciones i
      left join public.miembros quien on quien.id = i.usada_por
     where i.generada_por = v_miembro
       and i.revocada = false
     order by
       case when i.usada             then 2
            when i.vence_en <= now() then 3
            else                          1 end,
       i.creado_en desc;
end;
$function$;
