-- ============================================================================
-- SÉKITO — recordatorio de entradas sin asignar (03/11/2026)
-- ============================================================================
-- A quien tiene entradas sin dueño (compró para otros y no las asignó) o un
-- link de invitación con entrada que nadie abrió todavía. Una carta, con la
-- misma cara que la campaña de SEKI 7, que sale por la fila de siempre.
--
-- El plazo no se dice en el mail: corre hasta el sábado 14/11 a las 15 h,
-- cuando se imprime la lista de respaldo. Antes era el viernes 13/11 a las 23.
--
-- Y el recordatorio de llave: a quien pidió llave, se la abrieron y todavía no
-- se registró. El mismo sobre de "tu llave del sékito", con una línea arriba.
--
-- Se puede correr más de una vez sin romper nada (no manda nada: mandar es
-- llamar a recordar_entradas() y recordar_llaves() a mano).
-- ============================================================================

create or replace function public.cierre_de_cambios()
returns timestamptz
language sql
immutable
as $$ select timestamptz '2026-11-14 15:00-03' $$;


-- la carta: nombre, cuántas sin asignar, cuántas esperando por link
create or replace function public.mail_recordar_entradas(p_nombre text, p_sin integer, p_esperando integer,
                                                         p_baja uuid)
returns table(asunto text, html text)
language plpgsql stable set search_path = public as $$
declare
  v_dias   integer := date '2026-11-14' - (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_s      text := nullif(btrim(replace(replace(coalesce(p_nombre, ''), '<', ''), '>', '')), '');
  v_p      text := '<tr><td style="padding:0 0 22px">';
  v_b      text := '<b style="font-weight:600">';
  v_paso   text := '<span style="color:#93A8AC">→</span> ';
  v_cuerpo text;
  v_vista  text;
begin
  v_vista := case when v_dias = 1 then 'Falta 1 día para S7.' else 'Faltan ' || v_dias || ' días para S7.' end;

  if p_sin > 0 then
    asunto := coalesce(v_s || ', t', 'T') ||
              case when p_sin = 1 then 'e queda 1 entrada sin asignar' else 'e quedan ' || p_sin || ' entradas sin asignar' end;
  else
    asunto := coalesce(v_s || ', tu', 'Tu') || ' entrada sigue esperando a alguien';
  end if;

  v_cuerpo :=
    v_p || replace(v_vista, '.', '') || ' y ya estamos manijas.</td></tr>' ||
    v_p || 'Para seguir cuidando lo que armamos entre todxs (la fiesta, la gente, el ambiente), las entradas son personales: ' ||
           'cada QR nace con el nombre de una persona, y es esa persona la que entra.</td></tr>';

  if p_sin > 0 then
    v_cuerpo := v_cuerpo ||
      v_p || 'Por eso te recordamos que tenés ' || v_b ||
             case when p_sin = 1 then '1 entrada sin asignar' else p_sin || ' entradas sin asignar' end ||
             '</b>. Es fácil:</td></tr>' ||
      '<tr><td style="padding:0 0 22px 14px;border-left:1px solid #2a2a2a">' ||
        'entrá al portal<br>' || v_paso || v_b || 'tus entradas</b><br>' || v_paso || v_b || 'asignar</b><br>' ||
        v_paso || 'buscalo por apodo, nombre o código' ||
        '<div style="padding-top:12px;color:#93A8AC">¿Todavía no está en el portal? Tocá ' ||
        '<span style="color:#F2F2F2">mandale un link con la entrada</span> y pasáselo por WhatsApp.</div>' ||
      '</td></tr>';
  end if;

  if p_esperando > 0 then
    v_cuerpo := v_cuerpo ||
      v_p || case when p_sin > 0 then 'Y tenés ' else 'Por eso te recordamos que tenés ' end || v_b ||
             case when p_esperando = 1 then '1 entrada esperando</b> que la tomen: le mandaste el link a alguien y todavía no lo abrió.'
                  else p_esperando || ' entradas esperando</b> que las tomen: mandaste los links y todavía no los abrieron.' end ||
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
$$;


-- a quién: el que tiene en la mano entradas sin dueño (válidas, antes del cierre)
create or replace function public.recordar_entradas()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r   record;
  v_m record;
  v_n integer := 0;
begin
  if now() >= public.cierre_de_cambios() then return 0; end if;
  for r in
    select e.tenedor,
           count(*) filter (where e.para_invitacion is null)     sin,
           count(*) filter (where e.para_invitacion is not null) esperando
      from public.entradas e
     where e.anulada_en is null and e.duenio is null and e.tenedor is not null
     group by e.tenedor
  loop
    select q.email, q.baja into v_m from public.a_quien_escribirle(r.tenedor) q;
    continue when v_m.email is null;
    perform public.encolar_mail(v_m.email, x.asunto, x.html, 3::smallint)
       from public.miembros m,
            public.mail_recordar_entradas(public.como_le_dicen(m.apodo, coalesce(m.nombre_real,
              -- sin registrarse: el nombre que se puso al armar su link
              split_part(case when m.nota_admin like 'link de venta · %' then substr(m.nota_admin, 17)
                   when m.por_anfitrion is not null then substr(m.nota_admin, strpos(m.nota_admin, ' · ') + 3) end, ' ', 1))),
                                          r.sin::int, r.esperando::int, v_m.baja) x
      where m.id = r.tenedor;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;


-- la llave otra vez, para quien la pidió, se la abrieron y no se registró
create or replace function public.recordar_llaves()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select m.codigo_acceso, q.email, q.baja
      from public.pedidos_llave p
      join public.miembros m on m.id = p.miembro_id
      cross join lateral public.a_quien_escribirle(m.id) q
     where p.estado = 'abierto' and m.registrado_en is null
  loop
    perform public.encolar_mail(r.email, 'tu llave del sékito te espera',
      replace(replace(public.mail_tu_llave(r.codigo_acceso, r.baja),
              'Escribila en el portal y entrás.</span><br>',
              'Escribila en el portal y entrás.</span><br>Adentro está S7: sábado 14/11.<br>'),
              'LA SEKTA TE ABRIÓ LA PUERTA</td></tr>',
              'LA SEKTA TE ABRIÓ LA PUERTA</td></tr>' ||
              '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;' ||
              'font-size:12px;line-height:1.9;color:#93A8AC;padding:0 0 26px">y todavía no entraste.</td></tr>'),
      1::smallint);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.cierre_de_cambios()                                  from public, anon, authenticated;
revoke all on function public.mail_recordar_entradas(text, integer, integer, uuid) from public, anon, authenticated;
revoke all on function public.recordar_entradas()                                  from public, anon, authenticated;
revoke all on function public.recordar_llaves()                                    from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Para mandar (a mano, con el OK de Mau):
--   select public.recordar_entradas();
--   select public.recordar_llaves();
-- ---------------------------------------------------------------------------
