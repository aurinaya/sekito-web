-- ============================================================================
-- SÉKITO — "hay un sekreto dando vueltas": el mail de la víspera de SEKI 7
-- ============================================================================
-- Es "la sekta se está construyendo", dado vuelta para la víspera del
-- lanzamiento. De arriba abajo: el sekreto (mañana te lo contamos, adentro),
-- "mientras tanto, el portal se está construyendo", el empujón a invitar, y
-- todo lo que ya se puede hacer adentro. Lo importante arriba: Gmail pliega
-- los mails parecidos.
--
-- No nombra SEKI 7 ni la tanda: dice que lo que esperan se anuncia mañana y
-- se abre solo para quienes estén adentro del portal.
--
-- Va por la fila de mails con prioridad 3: detrás de las bienvenidas y de
-- cualquier mail con código. La fila lo manda a su ritmo (10 por minuto,
-- nunca más de 90 por día).
--
--   select public.avisar_que_manana_pasa_adentro(<id de MAU·000>);  -- prueba, a uno
--   select public.avisar_que_manana_pasa_adentro();                 -- a todos
-- ============================================================================

create or replace function public.mail_manana_adentro(p_baja uuid)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select public.mail_sobre(
    -- lo que se ve en la bandeja de entrada, al lado del asunto
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'tenemos un sekreto. mañana te lo contamos, adentro.</td></tr>'
    -- el sekreto
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:22px;line-height:1.45;letter-spacing:.12em;color:#F2F2F2;padding:0 0 16px">'
    || 'TENEMOS<br>UN SEKRETO</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:13px;line-height:1.75;color:#93A8AC;padding:0 0 36px">'
    || 'Mañana te lo contamos.<br>Adentro.</td></tr>'
    -- mientras tanto
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 28px">'
    || 'mientras tanto, el portal se está construyendo</td></tr>'
    -- el empujón
    || '<tr><td align="center" style="padding:0 0 46px">'
    ||   '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #800020;background:#141414"><tr><td align="center" style="padding:26px 30px">'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;'
    ||     'letter-spacing:.18em;color:#F2F2F2">INVITAR AL SÉKITO</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;'
    ||     'line-height:1.7;color:#93A8AC;padding-top:10px">'
    ||     'Traé a tu gente, entran de tu mano.<br>Usalo con cuidado.</div>'
    ||   '</td></tr></table>'
    || '</td></tr>'
    -- lo de siempre
    || public.mail_item('tus ritos',  'decís a qué fiestas viniste. dos testigos dan fe.')
    || public.mail_item('tu rama',    'de quién venís, y quiénes vinieron por vos.')
    || public.mail_item('devotxs',    'donde el sékito se busca y se encuentra.')
    || public.mail_item('susurros',   'noventa caracteres a una persona. no se responde.')
    || public.mail_item('la sekta',   'no es nadie, y somos todos. usala.')
    || '<tr><td style="padding:0 0 12px"></td></tr>',
    p_baja);
$$;

-- a todos los activos con mail, o (con p_prueba_a) a una sola persona, con
-- "(prueba)" en el asunto
create or replace function public.avisar_que_manana_pasa_adentro(p_prueba_a uuid default null)
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
      case when p_prueba_a is null then '' else '(prueba) ' end || 'hay un sekreto dando vueltas',
      public.mail_manana_adentro(v_fila.baja),
      3::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.mail_manana_adentro(uuid) from public, anon, authenticated;
revoke execute on function public.avisar_que_manana_pasa_adentro(uuid) from public, anon, authenticated;
