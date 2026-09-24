-- ============================================================================
-- SÉKITO — buscar desde la primera letra, y los pedidos de LA SEKTA por mail
-- ============================================================================
-- 1. El buscador de testigos pedía tres letras. No hacía falta: la lista ya
--    corta en ocho y pone adelante a los que empiezan con lo que escribiste.
--    Con una alcanza, y escribir tres antes de ver nada se siente roto.
--
-- 2. Cuando alguien nombra a LA SEKTA como testigo, el pedido no le llega a
--    nadie: LA SEKTA no tiene casilla. Quedaba esperando en el panel a que
--    algún admin se acordara de mirar. Ahora sale en el resumen de la tarde,
--    al mail de MAU·000.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.buscar_testigos(
  p_codigo text,
  p_fiesta uuid,
  p_query  text
)
returns table (
  id            uuid,
  nombre        text,
  nombre_real   text,
  puede_ya      boolean,
  es_sekta      boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then
    return;
  end if;

  return query
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           (m.estado_codigo = 'simbolico' or public.esta_atestiguado(m.id, p_fiesta)),
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.id <> v_yo
       and m.estado_codigo in ('activo', 'simbolico')
       -- los paréntesis importan: sin ellos el "or" se lleva puesta la
       -- condición de búsqueda y devuelve a todo el mundo
       and (m.nombre_real is not null or m.estado_codigo = 'simbolico')
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
           )
     order by
       -- con una sola letra esto es lo que hace la diferencia: primero los
       -- que empiezan así, después el resto
       (m.nombre_real ilike v_q || '%' or m.nombre_sektario ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;
end;
$$;

create or replace function public.buscar_en_el_sekito(p_codigo text, p_query text)
returns table (
  sektario  text,
  nombre    text,
  pantalla  text,
  es_sekta  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then
    return;
  end if;

  return query
    select m.nombre_sektario,
           public.nombre_lindo(m.nombre_real),
           m.pantalla,
           (m.estado_codigo = 'simbolico')
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
           )
     order by
       (m.nombre_sektario ilike v_q || '%' or m.nombre_real ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$$;


-- ----------------------------------------------------------------------------
-- el sobre, con otro destino
-- ----------------------------------------------------------------------------
-- Mismo mail de siempre pero con el botón apuntando a otro lado: los pedidos
-- de LA SEKTA se confirman en el panel, no en el portal.
create or replace function public.mail_sobre(
  p_contenido text, p_baja uuid, p_url text, p_boton text)
returns text
language sql
immutable
set search_path = public
as $$
  select
  '<meta name="color-scheme" content="dark">'
  || '<meta name="supported-color-schemes" content="dark">'
  || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">'
  || '<tr><td align="center" style="padding:36px 16px">'
  ||   '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%">'
  ||     '<tr><td align="center" style="padding:0 0 26px">'
  ||       '<img src="https://www.sekito.ar/images/abanico-disco.png" width="72" height="72" alt="" '
  ||       'style="display:block;border:0;width:72px;height:72px;border-radius:50%">'
  ||     '</td></tr>'
  ||     p_contenido
  ||     '<tr><td align="center" style="padding:0 0 34px">'
  ||       '<a href="' || p_url || '" '
  ||       'style="display:inline-block;border:1px solid #F2F2F2;color:#F2F2F2;text-decoration:none;'
  ||       'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.16em;'
  ||       'text-transform:uppercase;padding:13px 28px">' || p_boton || '</a>'
  ||     '</td></tr>'
  ||     '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
  ||     'font-size:10px;line-height:2;color:#5C6B6E">'
  ||       'sekito.ar &nbsp;·&nbsp; '
  ||       '<a href="https://www.sekito.ar/?baja=' || p_baja::text || '" '
  ||       'style="color:#5C6B6E;text-decoration:underline">no quiero más estos mails</a>'
  ||     '</td></tr>'
  ||   '</table>'
  || '</td></tr></table>';
$$;

revoke all on function public.mail_sobre(text, uuid, text, text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- el resumen de la tarde, ahora también por LA SEKTA
-- ----------------------------------------------------------------------------
create or replace function public.avisar_pedidos_del_dia()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fila     record;
  v_mandados int := 0;
  v_sekta    uuid := public.id_la_sekta();
  v_cuantos  int;
  v_ids      uuid[];
  v_quien    record;
begin
  -- 1. los pedidos a personas
  for v_fila in
    select v.validado_por as a_quien,
           count(*)       as cuantos,
           array_agg(v.id) as ids
      from public.validaciones v
     where v.validado_en    is null
       and v.avisado_en     is null
       and v.no_recuerda_en is null
       and v.validado_por <> v_sekta
     group by v.validado_por
  loop
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

    update public.validaciones set avisado_en = now() where id = any(v_fila.ids);
  end loop;

  -- 2. los pedidos a LA SEKTA, que no tiene casilla: van al mail de MAU·000.
  --    Para sumar a Flor y Naya, agregarlas acá.
  select count(*), array_agg(v.id) into v_cuantos, v_ids
    from public.validaciones v
   where v.validado_en is null
     and v.avisado_en  is null
     and v.validado_por = v_sekta;

  if coalesce(v_cuantos, 0) > 0 then
    select * into v_quien
      from public.a_quien_escribirle((select id from public.miembros where nombre_sektario = 'MAU·000'));

    if v_quien.email is not null then
      perform public.mandar_mail(
        v_quien.email,
        case when v_cuantos = 1 then 'un rito espera a la sekta'
             else v_cuantos || ' ritos esperan a la sekta' end,
        public.mail_sobre(
          '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 14px">la sekta</td></tr>'
          || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
          || case when v_cuantos = 1 then 'TE NOMBRARON A LA SEKTA'
                  else v_cuantos || ' RITOS LA NOMBRARON' end || '</td></tr>'
          || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
          || 'font-size:13px;line-height:1.7;color:#93A8AC;padding:0 0 30px">'
          || 'La sekta no contesta sola.<br>Se confirma desde el panel.</td></tr>',
          v_quien.baja,
          'https://www.sekito.ar/admin/',
          'ir al panel'));
      v_mandados := v_mandados + 1;
    end if;

    update public.validaciones set avisado_en = now() where id = any(v_ids);
  end if;

  return v_mandados;
end;
$$;

revoke all on function public.buscar_testigos(text, uuid, text)  from public;
revoke all on function public.buscar_en_el_sekito(text, text)    from public;
revoke all on function public.avisar_pedidos_del_dia()           from public, anon, authenticated;

grant execute on function public.buscar_testigos(text, uuid, text) to anon, authenticated;
grant execute on function public.buscar_en_el_sekito(text, text)   to anon, authenticated;
