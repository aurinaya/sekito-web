-- ============================================================================
-- SÉKITO — "no recuerdo"
-- ============================================================================
-- Primer caso real contra la regla de que no existe rechazar: a MAU le
-- pidieron fe de una fiesta a la que el otro no fue. El silencio ya alcanzaba
-- —sin las dos confirmaciones el rito nunca queda atestiguado— pero el pedido
-- le quedaba colgado para siempre en su lista.
--
-- Así que no es un rechazo, es una salida. El testigo se corre:
--
--   · a él se le va el pedido de la lista
--   · al que declaró le queda el testigo en gris, quieto. Sin aviso, sin
--     mail, sin que nadie diga que no
--   · y puede cambiarlo por otra persona, que es lo que ya podía hacer
--
-- Nadie acusa a nadie. Si hay algo que decirse, se dice por WhatsApp.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

alter table public.validaciones
  add column if not exists no_recuerda_en timestamptz;


-- ----------------------------------------------------------------------------
-- correrse
-- ----------------------------------------------------------------------------
create or replace function public.no_recuerdo(p_codigo text, p_validacion uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_id uuid;
begin
  update public.validaciones v
     set no_recuerda_en = now()
   where v.id = p_validacion
     and v.validado_por = v_yo
     and v.validado_en is null
  returning v.id into v_id;

  if v_id is null then
    raise exception 'ese_pedido_ya_no_esta';
  end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- los pedidos que me hicieron: los que me saqué de encima no vuelven
-- ----------------------------------------------------------------------------
drop function if exists public.mis_pedidos(text);

create or replace function public.mis_pedidos(p_codigo text)
returns table (
  validacion_id  uuid,
  quien          text,
  quien_nombre   text,
  fiesta         text,
  fecha          timestamptz,
  puedo_ya       boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select v.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           f.nombre, f.fecha,
           public.esta_atestiguado(v_yo, f.id)
      from public.validaciones v
      join public.asistencias a on a.id = v.asistencia_id
      join public.miembros    m on m.id = a.miembro_id
      join public.fiestas     f on f.id = a.fiesta_id
     where v.validado_por = v_yo
       and v.validado_en    is null
       and v.no_recuerda_en is null
     order by f.fecha desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- mis ritos: el testigo que se corrió se ve en gris
-- ----------------------------------------------------------------------------
create or replace function public.mis_ritos(p_codigo text)
returns table (
  fiesta_id  uuid,
  nombre     text,
  fecha      timestamptz,
  lugar      text,
  estado     text,
  testigos   jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select
      f.id, f.nombre, f.fecha, f.lugar,
      case
        when a.id is null                then 'sin_declarar'
        when a.estado = 'confirmada'     then 'atestiguado'
        else                                  'esperando'
      end,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'validacion_id', v.id,
                 'nombre',        t.nombre_sektario,
                 'nombre_real',   public.nombre_lindo(t.nombre_real),
                 'dio_fe',        (v.validado_en is not null),
                 'no_recuerda',   (v.no_recuerda_en is not null),
                 'es_sekta',      (t.estado_codigo = 'simbolico')
               ) order by t.nombre_sektario)
          from public.validaciones v
          join public.miembros t on t.id = v.validado_por
         where v.asistencia_id = a.id
      ), '[]'::jsonb)
    from public.fiestas f
    left join public.asistencias a
           on a.fiesta_id = f.id and a.miembro_id = v_yo
   where f.fecha <= now()
   order by f.fecha desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- cambiar de testigo limpia la marca
-- ----------------------------------------------------------------------------
-- La fila de validación se reusa: se le cambia el nombre. Si no se borrara la
-- marca, el testigo nuevo heredaría el "no recuerdo" del anterior y no vería
-- nunca el pedido.
create or replace function public.cambiar_testigo(
  p_codigo     text,
  p_validacion uuid,
  p_nuevo      uuid
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo         uuid := public.miembro_de(p_codigo);
  v_asistencia uuid;
begin
  select v.asistencia_id into v_asistencia
    from public.validaciones v
    join public.asistencias a on a.id = v.asistencia_id
   where v.id = p_validacion
     and a.miembro_id = v_yo
     and v.validado_en is null;

  if v_asistencia is null then
    raise exception 'ese_testigo_ya_dio_fe';
  end if;

  if p_nuevo = v_yo then
    raise exception 'no_podes_ser_tu_testigo';
  end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_nuevo and m.estado_codigo in ('activo','simbolico')) then
    raise exception 'testigo_invalido';
  end if;

  if exists (select 1 from public.validaciones v
              where v.asistencia_id = v_asistencia and v.validado_por = p_nuevo) then
    raise exception 'ya_es_testigo';
  end if;

  update public.validaciones v
     set validado_por = p_nuevo,
         no_recuerda_en = null,
         avisado_en = null          -- al nuevo sí hay que avisarle
   where v.id = p_validacion;

  return query select true;
end;
$$;


-- el resumen diario no le escribe a quien ya se corrió
create or replace function public.avisar_pedidos_del_dia()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila    record;
  v_mandados int := 0;
begin
  for v_fila in
    select v.validado_por as a_quien,
           count(*)       as cuantos,
           array_agg(v.id) as ids
      from public.validaciones v
     where v.validado_en    is null
       and v.avisado_en     is null
       and v.no_recuerda_en is null
     group by v.validado_por
  loop
    declare v_quien record;
    begin
      select * into v_quien from public.a_quien_escribirle(v_fila.a_quien);

      if v_quien.email is not null then
        perform public.mandar_mail(
          v_quien.email,
          case when v_fila.cuantos = 1
               then 'te piden que des fe'
               else 'te piden que des fe de ' || v_fila.cuantos || ' ritos' end,
          public.mail_armado(
            'los ritos',
            case when v_fila.cuantos = 1
                 then 'ALGUIEN TE NOMBRÓ TESTIGO'
                 else v_fila.cuantos || ' TE NOMBRARON TESTIGO' end,
            case when v_fila.cuantos = 1
                 then 'Dice que estuviste ahí.<br>Solo vos podés confirmarlo.'
                 else 'Dicen que estuviste ahí.<br>Solo vos podés confirmarlo.' end,
            v_quien.baja));
        v_mandados := v_mandados + 1;
        perform pg_sleep(1.2);
      end if;

      update public.validaciones
         set avisado_en = now()
       where id = any(v_fila.ids);
    end;
  end loop;

  return v_mandados;
end;
$$;

revoke all on function public.no_recuerdo(text, uuid)                from public;
revoke all on function public.mis_pedidos(text)                      from public;
revoke all on function public.mis_ritos(text)                        from public;
revoke all on function public.cambiar_testigo(text, uuid, uuid)      from public;
revoke all on function public.avisar_pedidos_del_dia()               from public, anon, authenticated;

grant execute on function public.no_recuerdo(text, uuid)           to anon, authenticated;
grant execute on function public.mis_pedidos(text)                 to anon, authenticated;
grant execute on function public.mis_ritos(text)                   to anon, authenticated;
grant execute on function public.cambiar_testigo(text, uuid, uuid) to anon, authenticated;
