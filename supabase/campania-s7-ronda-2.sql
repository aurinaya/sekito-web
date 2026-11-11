-- CAMPAÑA S7, RONDA 2 — "el séptimo rito" (texto cerrado con Mau el 11/11/2026)
--
-- Reemplaza el borrador viejo de la ronda 2 (el de "la hermética ya cerró,
-- $40.000"). La ronda 1 queda igual, letra por letra. Lo nuevo de la ronda 2:
--   - 30 / 40 / 50 sin beneficio, "elegís cuánto ponés"
--   - abajo del botón, la frase para quien no está pudiendo (@seki.party y
--     @sekito.gde, al privado)
--   - el link vale hasta el sábado a las 20 (anfitriones.hasta de ritoss7q)
--
-- PARA MANDAR (solo cuando Mau avisa), ver el final del archivo.

create or replace function public.campania_s7_html(p_ronda smallint, p_token text, p_saludo text, p_origen text)
 returns table(asunto text, html text)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_cierre timestamptz := (select e.cierre_35 from public.campania_s7_estado e);
  v_local  timestamp   := v_cierre at time zone 'America/Argentina/Buenos_Aires';
  v_dia    text := (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])[extract(dow from v_local)::int + 1]
                   || ' ' || extract(day from v_local)::int;
  v_link   text := 'https://sekito.ar/r/' || p_token;
  v_baja   text := 'https://sekito.ar/?baja=' || p_token;
  v_s      text := nullif(btrim(coalesce(p_saludo, '')), '');
  v_p      text := '<tr><td style="padding:0 0 22px">';
  v_b      text := '<b style="font-weight:600">';
  v_precios text;
  v_cuerpo text;
  v_vista  text;
  v_tras_boton text := '';
  v_del_link   text := 'Este link es solo tuyo.<br>Elegís, transferís, subís el comprobante y listo.';
begin
  if p_ronda = 1 then
    asunto  := coalesce(v_s || ', volvemos el 14', 'Volvemos el 14');
    v_vista := 'La séptima, en un lugar nuevo.';
    v_cuerpo :=
      v_p || case when p_origen = 'portal'
                  then 'Estás en el portal, y eso ya te hace parte del sékito.'
                  else 'Te llega este mail porque alguna vez estuviste en una de nuestras noches.<br>Y eso te hace parte del sékito.' end ||
             '</td></tr>' ||
      v_p || 'El sábado 14 volvemos con ' || v_b || 'SEKI 7</b>: lugar nuevo, el mismo cuidado en cada detalle.<br>' ||
             'Dorrego 1735, Palermo, desde las 23:50.</td></tr>' ||
      v_p || 'La entrada hoy está a $40.000. A quienes ya estuvieron les guardamos el precio de la hermética: ' ||
             v_b || '$35.000, hasta el ' || v_dia || ' a las 23:59</b>.</td></tr>' ||
      v_p || 'Nuestras fiestas no tienen sponsors: el sékito se sostiene con los suyos. Vos elegís cuánto aportás:</td></tr>' ||
      '<tr><td style="padding:0 0 28px">' ||
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;line-height:1.9;color:#F2F2F2">' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$35.000</b></td><td style="color:#93A8AC">venís</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$40.000</b></td><td style="color:#93A8AC">bancás la fiesta</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$50.000</b></td><td style="color:#93A8AC">remil banco, hagan más jodas</td></tr>' ||
        '</table></td></tr>';
  else
    asunto  := coalesce(v_s || ', el sábado es el séptimo rito', 'El sábado es el séptimo rito');
    v_vista := 'Y te queremos adentro.';
    v_cuerpo :=
      v_p || 'Seis ritos. Los armamos cuidando cada detalle, con la energía de pista que siempre mantuvimos.</td></tr>' ||
      v_p || 'Y cada uno existió porque vinieron. El sékito no tiene sponsors ni marcas atrás: ' ||
             'se sostiene con los suyos. Lo construimos juntxs.</td></tr>' ||
      v_p || 'Este sábado 14 es ' || v_b || 'SEKI 7</b>, el séptimo rito.<br>' ||
             'Lugar nuevo: Dorrego 1735, Palermo, desde las 23:50.</td></tr>' ||
      v_p || v_b || 'Queremos a todxs adentro.</b></td></tr>' ||
      v_p || 'Elegís cuánto ponés:</td></tr>' ||
      '<tr><td style="padding:0 0 28px">' ||
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;line-height:1.9;color:#F2F2F2">' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$30.000</b></td><td style="color:#93A8AC">venís</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$40.000</b></td><td style="color:#93A8AC">bancás la fiesta</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$50.000</b></td><td style="color:#93A8AC">remil banco, hagan más jodas</td></tr>' ||
        '</table></td></tr>';
    v_tras_boton :=
      '<tr><td style="padding:0 0 26px;font-size:12px;line-height:1.7;color:#93A8AC">' ||
        'El sékito no deja afuera a los suyos. Si no estás pudiendo con estos valores, escribinos a ' ||
        '<a href="https://ig.me/m/seki.party" style="color:#F2F2F2;text-decoration:underline">@seki.party</a> o a ' ||
        '<a href="https://ig.me/m/sekito.gde" style="color:#F2F2F2;text-decoration:underline">@sekito.gde</a>.</td></tr>';
    v_del_link := v_del_link || '<br>Vale hasta el sábado a las 20.';
  end if;

  html :=
    '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' ||
    '<meta name="color-scheme" content="dark"></head><body style="margin:0;padding:0;background:#0D0D0D">' ||
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0">' || v_vista || '</div>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">' ||
    '<tr><td align="center" style="padding:40px 24px 36px">' ||
    '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%;' ||
      'font-family:ui-monospace,Menlo,Consolas,monospace;color:#F2F2F2;font-size:14px;line-height:1.75;text-align:left">' ||
    coalesce(v_p || replace(replace(v_s, '<', ''), '>', '') || ',</td></tr>', '') ||
    v_cuerpo ||
    '<tr><td align="center" style="padding:0 0 28px">' ||
      '<a href="' || v_link || '" style="display:inline-block;background:#800020;border:1px solid #800020;color:#FFFFFF;' ||
      'text-decoration:none;font-size:12px;letter-spacing:.16em;text-transform:uppercase;padding:15px 34px">quiero mi lugar</a></td></tr>' ||
    v_tras_boton ||
    v_p || v_del_link || '</td></tr>' ||
    '<tr><td style="padding:0 0 30px">Nos vemos el 14.</td></tr>' ||
    '<tr><td style="padding:0 0 34px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' ||
      '<td style="padding:0 14px 0 0;vertical-align:middle"><img src="https://www.sekito.ar/images/abanico-disco.png" width="44" height="44" alt="" ' ||
      'style="display:block;border:0;width:44px;height:44px;border-radius:50%"></td>' ||
      '<td style="vertical-align:middle;font-size:13px;line-height:1.5">el SÉKITO<br><span style="color:#93A8AC">de SEKI PARTY</span></td>' ||
    '</tr></table></td></tr>' ||
    '<tr><td style="border-top:1px solid #2a2a2a;padding:14px 0 0;font-size:9.5px;line-height:1.6;color:#4A5759">' ||
      '<a href="' || v_baja || '" style="color:#4A5759;text-decoration:underline">No quiero más estos mails</a></td></tr>' ||
    '</table></td></tr></table></body></html>';
  return next;
end;
$function$;

revoke all on function public.campania_s7_html(smallint, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- PARA MANDAR (cuando Mau avisa):
--
-- 1) sumar a quien entró al portal después del 02/11 y sigue sin entrada
-- insert into public.campania_s7 (mail, saludo, origen)
-- select distinct on (lower(btrim(m.email))) lower(btrim(m.email)),
--        left(public.como_le_dicen(m.apodo, m.nombre_real), 30), 'portal'
--   from public.miembros m
--  where m.estado_codigo = 'activo' and m.nombre_real is not null and not m.es_fundador
--    and m.acepta_mails and m.email like '%@%'
--    and not public.campania_s7_ya_tiene(lower(btrim(m.email)))
-- on conflict (mail) do nothing;
--
-- 2) armar la ronda (saca a quien compró o pidió la baja) y prenderla
-- select public.campania_s7_preparar(2::smallint);
-- update public.campania_s7_estado set ronda = 2, activa = true;
--
-- 3) mirar cómo va
-- select ronda, estado, count(*) from public.campania_s7_envios group by 1, 2 order by 1, 2;
-- ---------------------------------------------------------------------------
