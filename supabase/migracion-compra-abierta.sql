-- ---------------------------------------------------------------------------
-- LA SEKRETA CIERRA A LAS 23:59, Y LAS COMPRAS QUE QUEDARON ABIERTAS (15/10)
--
-- El cierre pasó de las 21:28 a las 23:59 del 15/10, sin comunicarlo:
--   select public.programar_cierre(timestamptz '2026-10-15 23:59:00-03');
--
-- Quien tocó "quiero mi lugar" en la sekreta y nunca subió el comprobante
-- tiene la compra guardada a ese precio. Se le avisa por mail que se le
-- mantiene hasta el cierre. Pero al cerrar NO se descartan (Mau, 15/10 a la
-- noche): quedan abiertas y él decide a la mañana a quién se le da un día más,
-- sin comunicarlo. Al volver, el portal le muestra su compra a ese precio.
--
-- A quién: compras de la sekreta esperando comprobante, sin los fundadores y
-- sin quien ya tiene entrada u otra compra en camino (esas son restos de un
-- segundo intento). Una por persona.
--   prueba a una persona:  select public.avisar_compra_abierta(<id>);
--   a todos:               select public.avisar_compra_abierta();
-- ---------------------------------------------------------------------------

create or replace function public.mail_compra_abierta(p_baja uuid, p_cantidad integer, p_total integer)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select public.mail_sobre(
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'tu lugar en SEKI 7 está guardado, pero te faltó subir el comprobante. lo guardamos hasta hoy a las 23:59.</td></tr>'
    || '<tr><td align="center" style="padding:0 0 14px">'
    || '<img src="https://www.sekito.ar/images/mail-s7.png" width="160" height="90" alt="S7" '
    || 'style="display:block;border:0;width:160px;height:90px"></td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;line-height:2;letter-spacing:.26em;color:#F2F2F2;padding:0 0 36px">'
    || 'SÁBADO 14 · NOVIEMBRE<br>'
    || '<span style="color:#93A8AC;letter-spacing:.2em">PALERMO, BUENOS AIRES</span></td></tr>'
    -- la compra, encendida como la sekreta del mail de las 24 hs
    || '<tr><td align="center" style="padding:0 0 18px">'
    ||   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="max-width:400px;border:1px solid #800020;background:#2a0812;box-shadow:0 0 22px rgba(128,0,32,.55)"><tr>'
    ||     '<td align="left" style="padding:18px 20px"><div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:15px;letter-spacing:.16em;color:#F2F2F2">TANDA SEKRETA</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.08em;color:#C9A0AA;padding-top:6px">'
    ||     p_cantidad || case when p_cantidad = 1 then ' entrada' else ' entradas' end || '</div></td>'
    ||     '<td align="right" style="padding:18px 20px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:22px;font-weight:500;color:#F2F2F2;white-space:nowrap">$'
    ||     replace(to_char(p_total, 'FM999,999,999'), ',', '.') || '</td>'
    ||   '</tr></table>'
    || '</td></tr>'
    -- lo que falta, afuera de la tarjeta y destacado, con el punto rojo
    || '<tr><td align="center" style="padding:0 0 30px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;font-weight:500;letter-spacing:.26em;'
    || 'color:#F2F2F2;text-shadow:0 0 12px rgba(255,255,255,.5)">'
    || '<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#E50040;'
    || 'box-shadow:0 0 10px #E50040;vertical-align:2px;margin-right:12px"></span>FALTA EL COMPROBANTE</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;line-height:1.9;letter-spacing:.04em;color:#93A8AC">'
    || 'tu lugar está guardado,<br>pero te faltó subir el comprobante.<br>'
    || 'si ya transferiste, subilo desde el portal.<br>'
    || '<span style="color:#F2F2F2">lo guardamos hasta hoy a las 23:59.</span></td></tr>',
    p_baja,
    'https://www.sekito.ar/?ir=preventa',
    'subir el comprobante');
$$;

create or replace function public.avisar_compra_abierta(p_prueba_a uuid default null)
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
    select distinct on (m.id) q.email, q.baja, c.cantidad, c.total
      from public.compras c
      join public.tandas t on t.id = c.tanda_id and t.nombre = 'sekreta'
      join public.miembros m on m.id = c.comprador
      cross join lateral public.a_quien_escribirle(m.id) q
     where c.estado = 'esperando_comprobante'
       and q.email is not null
       and (p_prueba_a is null or m.id = p_prueba_a)
       and (p_prueba_a is not null or not m.es_fundador)
       and (p_prueba_a is not null or not exists (
             select 1 from public.entradas e
              where e.evento = 'seki7' and e.anulada_en is null and (e.duenio = m.id or e.tenedor = m.id)))
       and (p_prueba_a is not null or not exists (
             select 1 from public.compras c2
              where c2.comprador = m.id and c2.estado in ('a_revisar', 'confirmada')))
     order by m.id, c.creada_en desc
  loop
    perform public.encolar_mail(
      v_fila.email,
      case when p_prueba_a is null then '' else '(prueba) ' end || 'falta tu comprobante · SEKI 7',
      public.mail_compra_abierta(v_fila.baja, v_fila.cantidad, v_fila.total),
      2::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- cuando la tanda pasa, se prende la siguiente; las compras abiertas de la
-- que cerró quedan como están (se descartan a mano, si hace falta)
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

revoke execute on function public.mail_compra_abierta(uuid, integer, integer) from public, anon, authenticated;
revoke execute on function public.avisar_compra_abierta(uuid) from public, anon, authenticated;
revoke execute on function public.pasar_tanda_si_cierra() from public, anon, authenticated;
