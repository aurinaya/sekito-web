-- ---------------------------------------------------------------------------
-- LA CAMPAÑA DE MAIL DE SEKI 7 (02/11)
--
-- Un mail a quien ya estuvo y no tiene entrada: la base de las fiestas
-- anteriores y los del portal sin entrada. Cada uno con su link
-- (sekito.ar/r/TOKEN), que abre la misma pantalla que los links de anfitrión
-- con su nombre y su mail ya puestos.
--
-- Por dentro es un link de anfitrión más, de LA SEKTA, sin cumple: 35 (la
-- hermética, hasta el cierre), 40 y 50. Al cierre el cupo pasa a 0 y el 35
-- desaparece solo. Las compras se ven en el panel, en "los links de anfitrión".
--
-- Los mails NO pasan por mails_en_fila: salen de SEKI PARTY
-- <sekiparty@mail.sekito.ar>, responden a sekiparty@gmail.com, y van con su
-- propio reloj. Necesita Resend Pro: el plan gratis corta a los 100 por día.
--
-- Nada sale hasta que alguien prenda la campaña:
--   select campania_s7_preparar(1);                       -- arma la ronda
--   update campania_s7_estado set ronda = 1, activa = true;
-- Se apaga sola cuando termina, o si Resend empieza a rechazar.
--
-- Los destinatarios se cargan aparte, desde material/ (nunca en el repo).
-- ---------------------------------------------------------------------------

create table if not exists public.campania_s7 (
  token     text primary key default encode(extensions.gen_random_bytes(8), 'hex'),
  mail      text not null unique check (mail = lower(btrim(mail))),
  saludo    text check (char_length(saludo) between 2 and 30),   -- null: el mail va sin nombre
  origen    text not null check (origen in ('portal', 'base')),
  baja_en   timestamptz,
  creado_en timestamptz not null default now()
);

create table if not exists public.campania_s7_envios (
  id         bigserial primary key,
  token      text not null references public.campania_s7(token),
  ronda      smallint not null check (ronda in (1, 2)),
  estado     text not null default 'esperando'
             check (estado in ('esperando', 'mandando', 'enviado', 'fallo', 'salteado')),
  pedido_id  bigint,
  respuesta  integer,
  intentos   smallint not null default 0,
  enviado_en timestamptz,
  unique (token, ronda)
);

create table if not exists public.campania_s7_estado (
  uno       boolean primary key default true check (uno),
  activa    boolean not null default false,
  ronda     smallint not null default 1,
  cierre_35 timestamptz not null default '2026-11-05 23:59:00-03',
  por_vuelta integer not null default 10,      -- por minuto
  pausa_en  integer                            -- si tiene número, frena al llegar a esos enviados
);
insert into public.campania_s7_estado default values on conflict do nothing;

alter table public.campania_s7        enable row level security;
alter table public.campania_s7_envios enable row level security;
alter table public.campania_s7_estado enable row level security;

-- el link de la campaña: una fila de anfitrión de LA SEKTA, con palabra difícil
insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil)
select 'ritoss7q', m.id, 'El sékito te llama...',
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       500, '2026-11-14 20:00:00-03'::timestamptz,
       false, 'el sékito', null, null, 50000
  from public.miembros m
 where m.nombre_sektario = 'LA SEKTA'
   and not exists (select 1 from public.anfitriones a where a.palabra = 'ritoss7q');


-- ¿ya tiene entrada, o una compra en camino?
create or replace function public.campania_s7_ya_tiene(p_mail text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.miembros m
     where lower(btrim(m.email)) = p_mail
       and (exists (select 1 from public.entradas e
                     where e.evento = 'seki7' and e.anulada_en is null and (e.duenio = m.id or e.tenedor = m.id))
            or exists (select 1 from public.compras c
                        where c.comprador = m.id and c.estado in ('a_revisar', 'confirmada'))));
$$;


-- 1. lo que ve quien abre su link
create or replace function public.campania_s7_publico(p_token text)
returns table(palabra text, saludo text, mail text, nombre text)
language sql stable security definer set search_path = public as $$
  select 'ritoss7q', c.saludo, c.mail,
         coalesce((select public.como_le_dicen(m.apodo, m.nombre_real) from public.miembros m
                    where lower(btrim(m.email)) = c.mail and m.nombre_real is not null limit 1), c.saludo)
    from public.campania_s7 c
   where c.token = lower(btrim(coalesce(p_token, '')));
$$;


-- 2. la baja: siempre contesta lo mismo
create or replace function public.campania_s7_baja(p_token text)
returns table(ok boolean) language plpgsql security definer set search_path = public as $$
begin
  update public.campania_s7 c set baja_en = coalesce(c.baja_en, now())
   where c.token = lower(btrim(coalesce(p_token, '')));
  return query select true;
end;
$$;


-- 3. el mail
create or replace function public.campania_s7_html(p_ronda smallint, p_token text, p_saludo text, p_origen text)
returns table(asunto text, html text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_cierre timestamptz := (select e.cierre_35 from public.campania_s7_estado e);
  v_local  timestamp   := v_cierre at time zone 'America/Argentina/Buenos_Aires';
  v_dia    text := (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])[extract(dow from v_local)::int + 1]
                   || ' ' || extract(day from v_local)::int;
  v_link   text := 'https://sekito.ar/r/' || p_token;
  v_baja   text := 'https://sekito.ar/?baja=' || p_token;
  v_s      text := nullif(btrim(coalesce(p_saludo, '')), '');
  v_p      text := '<tr><td style="padding:0 0 22px">';
  v_b      text := '<b style="font-weight:600">';
  v_cuerpo text;
  v_vista  text;
begin
  if p_ronda = 1 then
    asunto  := coalesce(v_s || ', volvemos el 14', 'Volvemos el 14');
    v_vista := 'La séptima, en un lugar nuevo.';
    v_cuerpo :=
      v_p || 'Ya fuiste parte de nuestros ritos.<br>El sékito no olvida a los suyos.</td></tr>' ||
      v_p || 'El sábado 14 volvemos con ' || v_b || 'SEKI 7</b>: lugar nuevo, el mismo cuidado en cada detalle.<br>' ||
             'Dorrego 1735, Palermo, desde las 23:50.</td></tr>' ||
      v_p || 'La entrada hoy está a $40.000. A quienes ya estuvieron les guardamos el precio de la hermética: ' ||
             v_b || '$35.000, hasta el ' || v_dia || ' a las 23:59</b>.</td></tr>' ||
      v_p || 'La sekta no tiene sponsors: se sostiene con los suyos. Elegís cuánto ponés:</td></tr>' ||
      '<tr><td style="padding:0 0 28px">' ||
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;line-height:1.9;color:#F2F2F2">' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$35.000</b></td><td style="color:#93A8AC">venís</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$40.000</b></td><td style="color:#93A8AC">bancás la fiesta</td></tr>' ||
        '<tr><td style="padding:0 18px 0 0">' || v_b || '$50.000</b></td><td style="color:#93A8AC">remil banco, hagan más jodas</td></tr>' ||
        '</table></td></tr>';
  else
    asunto  := coalesce(v_s || ', falta una semana', 'Falta una semana');
    v_vista := 'Y todavía no tenés tu lugar.';
    v_cuerpo :=
      v_p || 'El sábado 14 es ' || v_b || 'SEKI 7</b> y todavía no tenés tu lugar.<br>' ||
             'Dorrego 1735, Palermo, desde las 23:50.</td></tr>' ||
      '<tr><td style="padding:0 0 28px">El precio de la hermética ya cerró. La entrada está a ' || v_b || '$40.000</b>, ' ||
             'o ' || v_b || '$50.000</b> si querés remil bancar.</td></tr>';
  end if;

  html :=
    '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">' ||
    '<meta name="color-scheme" content="dark"></head><body style="margin:0;padding:0;background:#0D0D0D">' ||
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0">' || v_vista || '</div>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0D0D0D;margin:0;padding:0">' ||
    '<tr><td align="center" style="padding:40px 24px 36px">' ||
    '<table role="presentation" width="440" cellpadding="0" cellspacing="0" border="0" style="width:440px;max-width:100%;' ||
      'font-family:ui-monospace,Menlo,Consolas,monospace;color:#F2F2F2;font-size:14px;line-height:1.75;text-align:left">' ||
    coalesce(v_p || replace(replace(v_s, '<', ''), '>', '') || ',</td></tr>', '') ||
    v_cuerpo ||
    '<tr><td align="center" style="padding:0 0 28px">' ||
      '<a href="' || v_link || '" style="display:inline-block;background:#800020;border:1px solid #800020;color:#FFFFFF;' ||
      'text-decoration:none;font-size:12px;letter-spacing:.16em;text-transform:uppercase;padding:15px 34px">quiero mi lugar</a></td></tr>' ||
    v_p || 'Este link es solo tuyo.<br>Elegís, transferís, subís el comprobante y listo.</td></tr>' ||
    '<tr><td style="padding:0 0 30px">Nos vemos el 14.</td></tr>' ||
    '<tr><td style="padding:0 0 34px"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' ||
      '<td style="padding:0 14px 0 0;vertical-align:middle"><img src="https://www.sekito.ar/images/abanico-disco.png" width="44" height="44" alt="" ' ||
      'style="display:block;border:0;width:44px;height:44px;border-radius:50%"></td>' ||
      '<td style="vertical-align:middle;font-size:13px;line-height:1.5">el SÉKITO<br><span style="color:#93A8AC">de SEKI PARTY</span></td>' ||
    '</tr></table></td></tr>' ||
    '<tr><td style="border-top:1px solid #2a2a2a;padding:18px 0 0;font-size:10.5px;line-height:1.8;color:#5C6B6E">' ||
      case when p_origen = 'portal' then 'Te escribimos porque sos parte del portal.'
           else 'Te escribimos porque viniste a una de nuestras fiestas.' end || '<br>' ||
      '<a href="' || v_baja || '" style="color:#5C6B6E;text-decoration:underline">No quiero más estos mails</a></td></tr>' ||
    '</table></td></tr></table></body></html>';
  return next;
end;
$$;


-- 4. armar una ronda: a quien no se dio de baja y todavía no tiene entrada
create or replace function public.campania_s7_preparar(p_ronda smallint)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  insert into public.campania_s7_envios (token, ronda)
  select c.token, p_ronda from public.campania_s7 c
   where c.baja_en is null
     and not public.campania_s7_ya_tiene(c.mail)
     and not exists (select 1 from public.miembros m        -- quien se dio de baja del portal, tampoco
                      where lower(btrim(m.email)) = c.mail and not m.acepta_mails)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;


-- 5. el reloj: cada minuto mira cómo les fue a los anteriores y manda unos pocos más
create or replace function public.campania_s7_despachar()
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_e     record;
  v_r     record;
  v_m     record;
  v_clave text;
  v_n     integer := 0;
begin
  select * into v_e from public.campania_s7_estado;

  -- al cierre, el 35 desaparece del link
  if now() >= v_e.cierre_35 then
    update public.anfitriones set cupo = 0 where palabra = 'ritoss7q' and cupo <> 0;
  end if;

  -- las respuestas de Resend: 200 salió; 429 (muy rápido) vuelve a la fila; otra cosa es un fallo
  for v_r in
    select v.id, r.status_code from public.campania_s7_envios v
      join net._http_response r on r.id = v.pedido_id
     where v.estado = 'mandando'
  loop
    update public.campania_s7_envios set respuesta = v_r.status_code,
           estado = case when v_r.status_code between 200 and 299 then 'enviado'
                         when v_r.status_code = 429 and intentos < 3 then 'esperando'
                         else 'fallo' end
     where id = v_r.id;
  end loop;

  if not v_e.activa then return 0; end if;

  -- el freno: cinco fallos y se apaga, para que alguien mire antes de seguir
  if (select count(*) from public.campania_s7_envios where ronda = v_e.ronda and estado = 'fallo') >= 5
     or (v_e.pausa_en is not null and
         (select count(*) from public.campania_s7_envios where ronda = v_e.ronda and estado in ('mandando', 'enviado')) >= v_e.pausa_en) then
    update public.campania_s7_estado set activa = false;
    return 0;
  end if;

  select decrypted_secret into v_clave from vault.decrypted_secrets where name = 'resend_api_key';
  if v_clave is null then raise exception 'falta_la_clave'; end if;

  for v_m in
    select v.id, c.token, c.mail, c.origen,
           coalesce((select public.como_le_dicen(m.apodo, m.nombre_real) from public.miembros m
                      where lower(btrim(m.email)) = c.mail and m.nombre_real is not null limit 1), c.saludo) as saludo
      from public.campania_s7_envios v join public.campania_s7 c on c.token = v.token
     where v.ronda = v_e.ronda and v.estado = 'esperando'
     -- primero los del portal, después la base, y los de Microsoft al final
     order by c.origen = 'base', c.mail ~ '@(hotmail|outlook|live|msn)\.', v.id
     limit v_e.por_vuelta
     for update of v skip locked
  loop
    -- pudo haber comprado o pedido la baja mientras esperaba
    if public.campania_s7_ya_tiene(v_m.mail)
       or (select c.baja_en is not null from public.campania_s7 c where c.token = v_m.token) then
      update public.campania_s7_envios set estado = 'salteado' where id = v_m.id;
      continue;
    end if;

    update public.campania_s7_envios v
       set estado = 'mandando', intentos = v.intentos + 1, enviado_en = now(),
           pedido_id = (
             select net.http_post(
               url     := 'https://api.resend.com/emails',
               headers := jsonb_build_object('Authorization', 'Bearer ' || v_clave, 'Content-Type', 'application/json'),
               body    := jsonb_build_object(
                 'from',     'SEKI PARTY <sekiparty@mail.sekito.ar>',
                 'reply_to', 'sekiparty@gmail.com',
                 'to',       jsonb_build_array(v_m.mail),
                 'subject',  h.asunto,
                 'html',     h.html,
                 'headers',  jsonb_build_object('List-Unsubscribe',
                               '<https://sekito.ar/?baja=' || v_m.token || '>, <mailto:sekiparty@gmail.com?subject=baja>')))
               from public.campania_s7_html(v_e.ronda, v_m.token, v_m.saludo, v_m.origen) h)
     where v.id = v_m.id;
    v_n := v_n + 1;
    perform pg_sleep(1.2);          -- Resend: hasta 2 por segundo, y la fila del portal también manda
  end loop;

  -- no queda nadie esperando: la ronda terminó
  if v_n = 0 and not exists (select 1 from public.campania_s7_envios
                              where ronda = v_e.ronda and estado in ('esperando', 'mandando')) then
    update public.campania_s7_estado set activa = false;
  end if;

  return v_n;
end;
$$;

revoke all on function public.campania_s7_ya_tiene(text)                       from public, anon, authenticated;
revoke all on function public.campania_s7_html(smallint, text, text, text)     from public, anon, authenticated;
revoke all on function public.campania_s7_preparar(smallint)                   from public, anon, authenticated;
revoke all on function public.campania_s7_despachar()                          from public, anon, authenticated;
revoke all on function public.campania_s7_publico(text)                        from public;
revoke all on function public.campania_s7_baja(text)                           from public;
grant execute on function public.campania_s7_publico(text) to anon, authenticated;
grant execute on function public.campania_s7_baja(text)    to anon, authenticated;

select cron.schedule('campania-s7', '* * * * *', 'select public.campania_s7_despachar()');

-- ---------------------------------------------------------------------------
-- Para mirar:
-- select ronda, estado, count(*) from campania_s7_envios group by 1, 2 order by 1, 2;
-- select respuesta, count(*) from campania_s7_envios where estado = 'fallo' group by 1;
-- ---------------------------------------------------------------------------
