-- ---------------------------------------------------------------------------
-- "FALTA TU COMPROBANTE", PARA CUALQUIER TANDA (26/10)
--
-- El mismo mail del 15/10 (migracion-compra-abierta.sql, que era solo para la
-- sekreta), con la tanda como dato: después de que una tanda cierra, a quien
-- reservó y no subió el comprobante se le mantiene ese precio hasta hoy a las
-- 23:59. Sin los fundadores ni quien ya tiene entrada u otra compra en camino.
--   prueba a una persona:  select public.avisar_compra_abierta_tanda('hermética', <id>);
--   a todos:               select public.avisar_compra_abierta_tanda('hermética');
-- ---------------------------------------------------------------------------

create or replace function public.mail_compra_abierta_tanda(p_baja uuid, p_tanda text, p_cantidad integer, p_total integer)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select public.mail_sobre(
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'tu lugar en SEKI 7 está guardado, pero te faltó subir el comprobante. te mantenemos el precio de la tanda '
    || p_tanda || ' hasta hoy a las 23:59.</td></tr>'
    || '<tr><td align="center" style="padding:0 0 14px">'
    || '<img src="https://www.sekito.ar/images/mail-s7.png" width="160" height="90" alt="S7" '
    || 'style="display:block;border:0;width:160px;height:90px"></td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;line-height:2;letter-spacing:.26em;color:#F2F2F2;padding:0 0 36px">'
    || 'SÁBADO 14 · NOVIEMBRE<br>'
    || '<span style="color:#93A8AC;letter-spacing:.2em">PALERMO, BUENOS AIRES</span></td></tr>'
    || '<tr><td align="center" style="padding:0 0 18px">'
    ||   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="max-width:400px;border:1px solid #800020;background:#2a0812;box-shadow:0 0 22px rgba(128,0,32,.55)"><tr>'
    ||     '<td align="left" style="padding:18px 20px"><div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:15px;letter-spacing:.16em;color:#F2F2F2">TANDA '
    ||     upper(p_tanda) || '</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.08em;color:#C9A0AA;padding-top:6px">'
    ||     p_cantidad || case when p_cantidad = 1 then ' entrada' else ' entradas' end || '</div></td>'
    ||     '<td align="right" style="padding:18px 20px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:22px;font-weight:500;color:#F2F2F2;white-space:nowrap">$'
    ||     replace(to_char(p_total, 'FM999,999,999'), ',', '.') || '</td>'
    ||   '</tr></table>'
    || '</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;font-weight:500;letter-spacing:.26em;'
    || 'color:#F2F2F2;text-shadow:0 0 12px rgba(255,255,255,.5)">'
    || '<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#E50040;'
    || 'box-shadow:0 0 10px #E50040;vertical-align:2px;margin-right:12px"></span>FALTA EL COMPROBANTE</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;line-height:1.9;letter-spacing:.04em;color:#93A8AC">'
    || 'tu lugar está guardado,<br>pero te faltó subir el comprobante.<br>'
    || 'si ya transferiste, subilo desde el portal.<br>'
    || '<span style="color:#F2F2F2">te mantenemos el precio de la tanda ' || p_tanda || '<br>hasta hoy a las 23:59.</span></td></tr>',
    p_baja,
    'https://www.sekito.ar/?ir=preventa',
    'subir el comprobante');
$$;

create or replace function public.avisar_compra_abierta_tanda(p_tanda text, p_prueba_a uuid default null)
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
      join public.tandas t on t.id = c.tanda_id and t.nombre = p_tanda
      join public.miembros m on m.id = c.comprador
      cross join lateral public.a_quien_escribirle(m.id) q
     where (p_prueba_a is not null or c.estado = 'esperando_comprobante')
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
      public.mail_compra_abierta_tanda(v_fila.baja, p_tanda, v_fila.cantidad, v_fila.total),
      2::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.mail_compra_abierta_tanda(uuid, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.avisar_compra_abierta_tanda(text, uuid) from public, anon, authenticated;
