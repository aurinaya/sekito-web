-- ============================================================================
-- SÉKITO — "sekreto revelado": el mail del lanzamiento de SEKI 7
-- ============================================================================
-- La vuelta del mail de la víspera ("hay un sekreto dando vueltas"): el
-- sekreto era S7, y la tanda sekreta ya está abierta. Tres cosas, en el
-- idioma de la casa: salió la tanda sekreta, es solo para quienes estamos en
-- el portal, y pasa rápido. El botón lleva directo a comprar (como /s7).
--
-- Va por la fila de mails con prioridad 3: detrás de cualquier mail con
-- código o de una compra. La fila lo manda a su ritmo (10 por minuto, nunca
-- más de 90 por día).
--
--   select public.avisar_sekreto_revelado(<id de MAU·000>);  -- prueba, a uno
--   select public.avisar_sekreto_revelado();                 -- a todos
-- ============================================================================

create or replace function public.mail_sekreto_revelado(p_baja uuid)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select public.mail_sobre(
    -- lo que se ve en la bandeja de entrada, al lado del asunto
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'el sekreto era S7. la tanda sekreta ya está abierta, adentro.</td></tr>'
    -- el sekreto
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;letter-spacing:.3em;color:#93A8AC;padding:0 0 18px">'
    || 'SEKRETO REVELADO</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:64px;line-height:1;font-weight:500;letter-spacing:.03em;color:#F2F2F2;'
    || 'text-shadow:0 0 18px rgba(255,255,255,.45);padding:0 0 20px">'
    || 'S7</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;line-height:2;letter-spacing:.26em;color:#F2F2F2;padding:0 0 40px">'
    || 'SÁBADO 14 · NOVIEMBRE<br>'
    || '<span style="color:#93A8AC;letter-spacing:.2em">PALERMO, BUENOS AIRES</span></td></tr>'
    -- la tanda
    || '<tr><td align="center" style="padding:0 0 30px">'
    ||   '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #800020;background:#141414"><tr><td align="center" style="padding:26px 30px">'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;'
    ||     'letter-spacing:.18em;color:#F2F2F2">LA TANDA SEKRETA ESTÁ ABIERTA</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;'
    ||     'line-height:1.75;color:#93A8AC;padding-top:12px">'
    ||     'Solo para quienes estamos en el portal.<br>'
    ||     'Pasa rápido: cuando se cierra, no vuelve.</div>'
    ||   '</td></tr></table>'
    || '</td></tr>',
    p_baja,
    'https://www.sekito.ar/?ir=preventa',
    'tanda sekreta desde el portal');
$$;

-- a todos los activos con mail, o (con p_prueba_a) a una sola persona, con
-- "(prueba)" en el asunto
create or replace function public.avisar_sekreto_revelado(p_prueba_a uuid default null)
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
       and (p_prueba_a is null or m.id = p_prueba_a)
       and q.email is not null
     order by m.fecha_ingreso
  loop
    perform public.encolar_mail(
      v_fila.email,
      case when p_prueba_a is null then '' else '(prueba) ' end || 'sekreto revelado',
      public.mail_sekreto_revelado(v_fila.baja),
      3::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.mail_sekreto_revelado(uuid) from public, anon, authenticated;
revoke execute on function public.avisar_sekreto_revelado(uuid) from public, anon, authenticated;
