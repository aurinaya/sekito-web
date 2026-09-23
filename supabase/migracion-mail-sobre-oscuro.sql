-- ============================================================================
-- SÉKITO — el sobre aguanta el modo oscuro
-- ============================================================================
-- Gmail en modo oscuro invierte el mail entero: el fondo #0D0D0D se vuelve
-- blanco. Y NO invierte las imágenes, así que el abanico blanco sobre
-- transparente desaparecía.
--
-- A Gmail no se le puede pedir que no invierta —ignora color-scheme—, así que
-- la defensa es que el abanico traiga su propio disco oscuro adentro del PNG.
-- El meta de color-scheme va igual, porque Apple Mail y Outlook sí lo
-- respetan y ahí el mail se ve como fue diseñado.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

create or replace function public.mail_sobre(p_contenido text, p_baja uuid)
returns text
language sql
immutable
set search_path = public
as $$
  select
  -- Apple Mail y Outlook respetan esto y no invierten nada. Gmail lo ignora.
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
  ||       '<a href="https://www.sekito.ar" '
  ||       'style="display:inline-block;border:1px solid #F2F2F2;color:#F2F2F2;text-decoration:none;'
  ||       'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.16em;'
  ||       'text-transform:uppercase;padding:13px 28px">entrar al portal</a>'
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

-- los avisos automáticos pasan a usar el mismo sobre, así hay un solo lugar
-- donde cambiar la cara de los mails
create or replace function public.mail_armado(
  p_rotulo text,
  p_titulo text,
  p_bajada text,
  p_baja   uuid
)
returns text
language sql
immutable
set search_path = public
as $$
  select public.mail_sobre(
    case when coalesce(btrim(p_rotulo),'') = '' then ''
         else '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
              || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 14px">'
              || p_rotulo || '</td></tr>' end
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
    || p_titulo || '</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:13px;line-height:1.7;color:#93A8AC;padding:0 0 30px">'
    || p_bajada || '</td></tr>',
    p_baja);
$$;

revoke all on function public.mail_sobre(text, uuid)              from public, anon, authenticated;
revoke all on function public.mail_armado(text, text, text, uuid) from public, anon, authenticated;
