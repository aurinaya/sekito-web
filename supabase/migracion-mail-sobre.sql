-- ============================================================================
-- SÉKITO — el sobre: ancho fijo, abanico arriba, y el botón bien arriba
-- ============================================================================
-- Dos cosas que se vieron recién en Gmail de escritorio:
--
--   · el mail se estiraba a todo el ancho de la pantalla. Faltaba una caja
--     centrada con ancho máximo, que en correo se hace con <table> y no con
--     css: Gmail y Outlook ignoran buena parte del css moderno.
--
--   · Gmail lo recortaba con los tres puntitos y escondía el botón. Gmail
--     pliega lo que se repite entre mails parecidos, y el pie es igual en
--     todos. La defensa es que lo importante entre antes del pliegue: por eso
--     el botón sube y el mail entero se hace más corto.
--
-- El abanico va como PNG y desde una URL pública: los clientes de correo no
-- dibujan SVG ni entienden máscaras de css.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

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
  select
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">'
  || '<tr><td align="center" style="padding:36px 16px">'
  ||   '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%">'

  --  el abanico
  ||     '<tr><td align="center" style="padding:0 0 26px">'
  ||       '<img src="https://www.sekito.ar/images/abanico-mail.png" width="64" height="42" alt="" '
  ||       'style="display:block;border:0;width:64px;height:auto">'
  ||     '</td></tr>'

  --  el rótulo, si lo hay
  ||     case when coalesce(btrim(p_rotulo),'') = '' then ''
         else '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
              || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 14px">'
              || p_rotulo || '</td></tr>' end

  --  el título
  ||     '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
  ||     'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
  ||     p_titulo || '</td></tr>'

  --  la bajada
  ||     '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
  ||     'font-size:13px;line-height:1.7;color:#93A8AC;padding:0 0 30px">'
  ||     p_bajada || '</td></tr>'

  --  el botón, lo más arriba posible: es lo único que tiene que sobrevivir
  --  a que Gmail pliegue el resto
  ||     '<tr><td align="center" style="padding:0 0 34px">'
  ||       '<a href="https://www.sekito.ar" '
  ||       'style="display:inline-block;border:1px solid #F2F2F2;color:#F2F2F2;text-decoration:none;'
  ||       'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.16em;'
  ||       'text-transform:uppercase;padding:13px 28px">entrar al portal</a>'
  ||     '</td></tr>'

  --  el pie
  ||     '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
  ||     'font-size:10px;line-height:2;color:#5C6B6E">'
  ||       'sekito.ar &nbsp;·&nbsp; '
  ||       '<a href="https://www.sekito.ar/?baja=' || p_baja::text || '" '
  ||       'style="color:#5C6B6E;text-decoration:underline">no quiero más estos mails</a>'
  ||     '</td></tr>'

  ||   '</table>'
  || '</td></tr></table>';
$$;

revoke all on function public.mail_armado(text, text, text, uuid) from public, anon, authenticated;
