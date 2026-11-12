-- 12/11: el recordatorio de entradas sin asignar, segunda vuelta.
-- Suma el plazo ("Tenés tiempo hasta el sábado a las 15 h", cuando cierran los
-- cambios), dice las cantidades con palabras ("tres entradas") y saca el ¿
-- de apertura. El resto del texto es el del 03/11, cerrado con Mau.
-- Se manda con: select public.recordar_entradas();

create or replace function public.mail_recordar_entradas(p_nombre text, p_sin integer, p_esperando integer, p_baja uuid)
 RETURNS TABLE(asunto text, html text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_dias   integer := date '2026-11-14' - (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_s      text := nullif(btrim(replace(replace(coalesce(p_nombre, ''), '<', ''), '>', '')), '');
  v_p      text := '<tr><td style="padding:0 0 22px">';
  v_b      text := '<b style="font-weight:600">';
  v_paso   text := '<span style="color:#93A8AC">→</span> ';
  v_cuerpo text;
  v_vista  text;
  v_num    text[] := array['una','dos','tres','cuatro','cinco','seis','siete'];
  v_cs     text := coalesce(v_num[p_sin], p_sin::text);
  v_ce     text := coalesce(v_num[p_esperando], p_esperando::text);
begin
  v_vista := case when v_dias = 1 then 'Falta 1 día para S7.' else 'Faltan ' || v_dias || ' días para S7.' end;

  if p_sin > 0 then
    asunto := coalesce(v_s || ', t', 'T') ||
              case when p_sin = 1 then 'e queda una entrada sin asignar' else 'e quedan ' || v_cs || ' entradas sin asignar' end;
  else
    asunto := case when p_esperando = 1 then coalesce(v_s || ', tu', 'Tu') || ' entrada sigue esperando a alguien'
                   else coalesce(v_s || ', tus', 'Tus') || ' entradas siguen esperando a alguien' end;
  end if;

  v_cuerpo :=
    v_p || replace(v_vista, '.', '') || ' y ya estamos manijas.</td></tr>' ||
    v_p || 'Para seguir cuidando lo que armamos entre todxs (la fiesta, la gente, el ambiente), las entradas son personales: ' ||
           'cada QR nace con el nombre de una persona, y es esa persona la que entra.</td></tr>';

  if p_sin > 0 then
    v_cuerpo := v_cuerpo ||
      v_p || 'Por eso te recordamos que tenés ' || v_b ||
             case when p_sin = 1 then 'una entrada sin asignar' else v_cs || ' entradas sin asignar' end ||
             '</b>. Es fácil:</td></tr>' ||
      '<tr><td style="padding:0 0 22px 14px;border-left:1px solid #2a2a2a">' ||
        'entrá al portal<br>' || v_paso || v_b || 'tus entradas</b><br>' || v_paso || v_b || 'asignar</b><br>' ||
        v_paso || 'buscalo por apodo, nombre o código' ||
        '<div style="padding-top:12px;color:#93A8AC">Todavía no está en el portal? Tocá ' ||
        '<span style="color:#F2F2F2">mandale un link con la entrada</span> y pasáselo por WhatsApp.</div>' ||
      '</td></tr>';
  end if;

  if p_esperando > 0 then
    v_cuerpo := v_cuerpo ||
      v_p || case when p_sin > 0 then 'Y tenés ' else 'Por eso te recordamos que tenés ' end || v_b ||
             case when p_esperando = 1 then 'una entrada esperando</b> que la tomen: le mandaste el link a alguien y todavía no lo abrió.'
                  else v_ce || ' entradas esperando</b> que las tomen: mandaste los links y todavía no los abrieron.' end ||
             ' Recordáselo: en ' || v_b || 'tus entradas</b>, tocá ' || v_b || 'ver el link</b> y mandáselo de nuevo.</td></tr>';
  end if;

  html :=
    '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' ||
    '<meta name="color-scheme" content="dark"></head><body style="margin:0;padding:0;background:#0D0D0D">' ||
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0">' || v_vista || '</div>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">' ||
    '<tr><td align="center" style="padding:40px 24px 36px">' ||
    '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%;' ||
      'font-family:ui-monospace,Menlo,Consolas,monospace;color:#F2F2F2;font-size:14px;line-height:1.75;text-align:left">' ||
    coalesce(v_p || v_s || ',</td></tr>', '') ||
    v_cuerpo ||
    v_p || 'Tenés tiempo hasta el ' || v_b || 'sábado a las 15 h</b>.</td></tr>' ||
    '<tr><td align="center" style="padding:6px 0 30px">' ||
      '<a href="https://www.sekito.ar/" style="display:inline-block;background:#800020;border:1px solid #800020;color:#FFFFFF;' ||
      'text-decoration:none;font-size:12px;letter-spacing:.16em;text-transform:uppercase;padding:15px 34px">entrar al sékito</a></td></tr>' ||
    '<tr><td style="padding:0 0 30px;color:#93A8AC">Si pensás en alguien que querés que esté en el sékito, ' ||
      'podés hacerlo entrar de tu mano: invitalo desde el portal, en <span style="color:#F2F2F2">invitar al sékito</span>.<br>' ||
      'El sékito crece de boca en boca y de mano en mano.</td></tr>' ||
    '<tr><td style="padding:0 0 34px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' ||
      '<td style="padding:0 14px 0 0;vertical-align:middle"><img src="https://www.sekito.ar/images/abanico-disco.png" width="44" height="44" alt="" ' ||
      'style="display:block;border:0;width:44px;height:44px;border-radius:50%"></td>' ||
      '<td style="vertical-align:middle;font-size:13px;line-height:1.5">el SÉKITO<br><span style="color:#93A8AC">de SEKI PARTY</span></td>' ||
    '</tr></table></td></tr>' ||
    '<tr><td style="border-top:1px solid #2a2a2a;padding:14px 0 0;font-size:9.5px;line-height:1.6;color:#4A5759">' ||
      '<a href="https://www.sekito.ar/?baja=' || p_baja::text || '" style="color:#4A5759;text-decoration:underline">No quiero más estos mails</a></td></tr>' ||
    '</table></td></tr></table></body></html>';
  return next;
end;
$function$;
