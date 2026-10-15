-- ---------------------------------------------------------------------------
-- MAIL "ÚLTIMAS 24 HS DE LA TANDA SEKRETA" (14/10) — preparado, sin mandar
--
-- A los miembros activos y registrados que todavía no tienen entrada (ni la
-- tienen en la mano), sin los fundadores y sin quien ya subió un comprobante
-- (esa compra está por confirmarse). Por la fila, con prioridad 3: detrás de
-- las bienvenidas, las llaves y las entradas.
--   prueba a una persona:  select public.avisar_ultimas_24(<id>);
--   a todos:               select public.avisar_ultimas_24();
-- ---------------------------------------------------------------------------

create or replace function public.mail_ultimas_24(p_baja uuid)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select public.mail_sobre(
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'la tanda sekreta cierra mañana a las 21:28. después, no vuelve.</td></tr>'
    -- el S7 en Cleopatra (la letra de la Seki): en los mails va como imagen,
    -- porque Gmail no carga tipografías propias
    || '<tr><td align="center" style="padding:0 0 14px">'
    || '<img src="https://www.sekito.ar/images/mail-s7.png" width="160" height="90" alt="S7" '
    || 'style="display:block;border:0;width:160px;height:90px"></td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;line-height:2;letter-spacing:.26em;color:#F2F2F2;padding:0 0 36px">'
    || 'SÁBADO 14 · NOVIEMBRE<br>'
    || '<span style="color:#93A8AC;letter-spacing:.2em">PALERMO, BUENOS AIRES</span></td></tr>'
    -- la sekreta, encendida como en la placa del feed
    || '<tr><td align="center" style="padding:0 0 18px">'
    ||   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="max-width:400px;border:1px solid #800020;background:#2a0812;box-shadow:0 0 22px rgba(128,0,32,.55)"><tr>'
    ||     '<td align="left" style="padding:20px 20px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:15px;letter-spacing:.16em;color:#F2F2F2">TANDA SEKRETA</td>'
    ||     '<td align="right" style="padding:20px 20px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:22px;font-weight:500;color:#F2F2F2;white-space:nowrap">$30.000</td>'
    ||   '</tr></table>'
    || '</td></tr>'
    -- ÚLTIMAS 24 HORAS, afuera de la tarjeta y destacado: el punto rojo y el brillo
    || '<tr><td align="center" style="padding:0 0 34px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;font-weight:500;letter-spacing:.26em;'
    || 'color:#F2F2F2;text-shadow:0 0 12px rgba(255,255,255,.5)">'
    || '<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#E50040;'
    || 'box-shadow:0 0 10px #E50040;vertical-align:2px;margin-right:12px"></span>ÚLTIMAS 24 HORAS</td></tr>'
    -- las que siguen: debajo de DESPUÉS, en tarjetas más chicas y apagadas;
    -- que estén, sin competir con la sekreta
    || '<tr><td align="center" style="padding:0 0 12px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:10px;letter-spacing:.24em;color:#5f6c6f">DESPUÉS</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px">'
    ||   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:320px">'
    ||   '<tr><td style="padding:0 0 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #262626;background:#101010"><tr>'
    ||     '<td align="left" style="padding:11px 14px"><div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.14em;color:#7d8a8d">TANDA HERMÉTICA</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:9.5px;letter-spacing:.06em;color:#5a6669;padding-top:5px">'
    ||     '<span style="display:inline-block;width:5px;height:5px;border-radius:50%;background:#3d4648;vertical-align:1px;margin-right:7px"></span>pendiente · no dura nada</div></td>'
    ||     '<td align="right" style="padding:11px 14px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;color:#7d8a8d;white-space:nowrap">$35.000</td>'
    ||   '</tr></table></td></tr>'
    ||   '<tr><td style="padding:0 0 8px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #262626;background:#101010"><tr>'
    ||     '<td align="left" style="padding:11px 14px"><div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.14em;color:#7d8a8d">TANDA ABIERTA</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:9.5px;letter-spacing:.06em;color:#5a6669;padding-top:5px">'
    ||     '<span style="display:inline-block;width:5px;height:5px;border-radius:50%;background:#3d4648;vertical-align:1px;margin-right:7px"></span>pendiente · la única tanda real</div></td>'
    ||     '<td align="right" style="padding:11px 14px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;color:#7d8a8d;white-space:nowrap">$40.000</td>'
    ||   '</tr></table></td></tr>'
    ||   '</table>'
    || '</td></tr>',
    p_baja,
    'https://www.sekito.ar/?ir=preventa',
    'tanda sekreta desde el portal');
$$;

create or replace function public.avisar_ultimas_24(p_prueba_a uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_fila record;
  v_n    int := 0;
begin
  for v_fila in
    select q.email, q.baja
      from public.miembros m
      cross join lateral public.a_quien_escribirle(m.id) q
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and (p_prueba_a is not null or not m.es_fundador)
       and (p_prueba_a is null or m.id = p_prueba_a)
       and q.email is not null
       and (p_prueba_a is not null or not exists (
             select 1 from public.entradas e
              where e.evento = 'seki7' and e.anulada_en is null and (e.duenio = m.id or e.tenedor = m.id)))
       and (p_prueba_a is not null or not exists (
             select 1 from public.compras c where c.comprador = m.id and c.estado = 'a_revisar'))
     order by m.fecha_ingreso
  loop
    perform public.encolar_mail(
      v_fila.email,
      case when p_prueba_a is null then '' else '(prueba) ' end || 'últimas 24 hs de la tanda sekreta',
      public.mail_ultimas_24(v_fila.baja),
      3::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.mail_ultimas_24(uuid) from public, anon, authenticated;
revoke execute on function public.avisar_ultimas_24(uuid) from public, anon, authenticated;
