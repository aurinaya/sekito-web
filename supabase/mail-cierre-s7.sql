-- 19/11/2026 · el mail de cierre de S7 (texto cerrado con Mau)
--
-- El mismo para todos los del portal que reciben mails, hayan venido o no: les
-- habla como si hubieran estado (a quien no vino lo deja manija). Tres partes:
-- el agradecimiento, lo que dejó S7 (las cartas y la palabra) y lo próximo.
-- Sale por la fila de mails, con prioridad 3, uno por persona y una sola vez.
--
-- PARA MANDAR (solo cuando Mau avisa):  select public.mandar_cierre_s7();

create table if not exists public.cierre_s7_enviado (
  miembro_id uuid primary key references public.miembros(id),
  encolado_en timestamptz not null default now()
);
alter table public.cierre_s7_enviado enable row level security;

create or replace function public.mail_cierre_s7(p_nombre text, p_baja uuid)
returns table(asunto text, html text)
language plpgsql immutable set search_path = public as $$
declare
  v_s    text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_p    text := '<tr><td style="padding:0 0 22px">';
  v_sep  text := '<tr><td align="center" style="padding:14px 0 38px;font-size:12px;color:#C9566E;letter-spacing:.6em">&#10022;</td></tr>';
  v_tit  text := '<tr><td align="center" style="padding:0 0 22px;font-size:11px;letter-spacing:.28em;color:#C9566E">';
  v_cartas text := '';
  k text;
begin
  foreach k in array array['soberbia','avaricia','lujuria','ira','gula','envidia','pereza'] loop
    v_cartas := v_cartas || '<td style="padding:0 3px"><img src="https://www.sekito.ar/images/estampitas/' || k
             || '.jpg" width="54" alt="" style="display:block;border:0;width:54px"></td>';
  end loop;

  asunto := coalesce(v_s || ', gracias por S7', 'Gracias por S7');
  html :=
    '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' ||
    '<meta name="color-scheme" content="dark"></head><body style="margin:0;padding:0;background:#0D0D0D">' ||
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0">Lo que dejó S7 ahora vive en el portal.</div>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">' ||
    '<tr><td align="center" style="padding:40px 24px 36px">' ||
    '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%;' ||
      'font-family:ui-monospace,Menlo,Consolas,monospace;color:#F2F2F2;font-size:14px;line-height:1.75;text-align:left">' ||
    coalesce(v_p || v_s || ',</td></tr>', '') ||
    -- 1. el agradecimiento
    v_p || 'Gracias por dejarlo todo en <b style="font-weight:600">SEKI 7</b>, como en cada rito.</td></tr>' ||
    v_p || 'Cada noche existe porque vienen. El sékito no tiene sponsors ni marcas atrás: lo sostienen los suyos, y lo construimos juntxs.</td></tr>' ||
    v_sep ||
    -- 2. lo que dejó S7
    v_tit || 'LO QUE DEJÓ S7</td></tr>' ||
    '<tr><td align="center" style="padding:0 0 28px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' ||
      v_cartas || '</tr></table></td></tr>' ||
    v_p || 'Las cartas de los siete pecados que repartimos esa noche ahora viven en el portal.</td></tr>' ||
    v_p || '7 pecados, 7 cartas, 7 mensajes, 7 personas. Elegí a quién mandarle cada una, sin que sepa que sos vos.. o quizás sí.</td></tr>' ||
    '<tr><td style="padding:0 0 30px">Y contanos qué fue S7 para vos, en una sola palabra.</td></tr>' ||
    v_sep ||
    -- 3. lo próximo
    v_tit || 'LO PRÓXIMO</td></tr>' ||
    v_p || 'Algo se está gestando.. por y para el sékito.</td></tr>' ||
    '<tr><td style="padding:0 0 34px">Contanos de qué estás manija y enterate.</td></tr>' ||
    '<tr><td align="center" style="padding:0 0 34px">' ||
      '<a href="https://www.sekito.ar/" style="display:inline-block;background:#800020;border:1px solid #800020;color:#FFFFFF;' ||
      'text-decoration:none;font-size:12px;letter-spacing:.16em;text-transform:uppercase;padding:15px 34px">entrar al sékito</a></td></tr>' ||
    '<tr><td style="padding:0 0 30px;font-size:12px;line-height:1.7;color:#93A8AC">Si estuviste y el portal no lo sabe, es porque tu QR no pasó ' ||
      'por la puerta. Entrá a <b style="font-weight:600;color:#F2F2F2">mis ritos</b>, declarala y pedí que te den fe.</td></tr>' ||
    -- la firma y la baja, como en todos
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

-- a todos los del portal que reciben mails, una sola vez cada uno
create or replace function public.mandar_cierre_s7()
returns integer language plpgsql security definer set search_path = public as $$
declare v_m record; v_q record; v_mail record; v_n int := 0;
begin
  for v_m in
    select m.id, public.como_le_dicen(m.apodo, m.nombre_real) as nombre
      from public.miembros m
     where m.estado_codigo = 'activo'
       and not exists (select 1 from public.cierre_s7_enviado c where c.miembro_id = m.id)
     order by m.creado_en
  loop
    select * into v_q from public.a_quien_escribirle(v_m.id);
    continue when v_q.email is null;
    select * into v_mail from public.mail_cierre_s7(v_m.nombre, v_q.baja);
    perform public.encolar_mail(v_q.email, v_mail.asunto, v_mail.html, 3::smallint);
    insert into public.cierre_s7_enviado (miembro_id) values (v_m.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.mandar_cierre_s7(), public.mail_cierre_s7(text, uuid) from public, anon, authenticated;
