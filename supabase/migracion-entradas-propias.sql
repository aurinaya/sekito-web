-- ============================================================================
-- SÉKITO — SEKI 7 sin Passline: la entrada la hace el portal
-- ============================================================================
-- Hasta acá Passline emitía los QR y los cargábamos a mano entre los tres.
-- Ahora la entrada es nuestra de punta a punta:
--
--   LA COMPRA tiene tres momentos:
--     pedida      → eligió cuántas, falta el comprobante  (esperando_comprobante)
--     a confirmar → subió el comprobante                   (a_revisar)
--     confirmada  → un admin lo abrió y está bien          (o rechazada)
--
--   LA ENTRADA nace recién cuando la compra se confirma, y puede estar:
--     sin asignar → la tiene alguien en la mano, no tiene dueño
--     asignada    → tiene dueño (o es de alguien de afuera) y ya tiene código
--     adentro     → la marcó la puerta
--
-- El código es corto (S7-K4QM7), no se adivina y no usa letras que se
-- confundan. El QR es ese mismo código dibujado. Nace cuando la entrada
-- tiene a quién pertenecer y muere si cambia de dueño: una captura vieja no
-- sirve.
--
-- Los mails de la preventa no salen directo: entran a una fila que respeta el
-- tope diario del plan gratis de Resend, y salen primero los que llevan
-- código. La entrada siempre está en el portal aunque el mail tarde.
--
-- Nada de esto lo usa el sitio publicado todavía: la preventa no salió.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. las tandas: sekreta, hermética, abierta
-- ----------------------------------------------------------------------------
update public.tandas set nombre = 'sekreta'   where id = 1;
update public.tandas set nombre = 'hermética' where id = 2;
update public.tandas set nombre = 'abierta'   where id = 3;


-- ----------------------------------------------------------------------------
-- 2. la entrada, con todo lo que necesita para ser una entrada
-- ----------------------------------------------------------------------------
alter table public.entradas drop constraint if exists entradas_tipo_conocido;
alter table public.entradas add constraint entradas_tipo_conocido
  check (tipo in ('sekreta', 'hermética', 'abierta', 'staff', 'free'));

alter table public.entradas
  add column if not exists precio           integer not null default 0 check (precio >= 0),
  add column if not exists codigo           text unique,
  add column if not exists codigo_en        timestamptz,
  -- alguien de afuera del portal: un DJ, staff, el +1 de alguien. Solo desde
  -- el panel; lo que se compra es siempre para gente del portal
  add column if not exists externo_nombre   text,
  add column if not exists externo_apellido text,
  add column if not exists externo_apodo    text,
  add column if not exists externo_contacto text,
  add column if not exists nota             text,
  add column if not exists generada_por     uuid references public.admins(id) on delete set null,
  add column if not exists anulada_en       timestamptz,
  add column if not exists anulada_motivo   text,
  add column if not exists adentro_en       timestamptz,
  add column if not exists adentro_por      text;

comment on column public.entradas.precio is
  'Lo que se pagó por esta entrada. El recaudado es la suma de esto: si alguien pagó $2, suma $2.';
comment on column public.entradas.codigo is
  'Lo que se muestra en la puerta (y el QR). Nace con el dueño y muere si cambia.';

-- sin Passline ya no hay "QR enviado"
alter table public.entradas drop column if exists enviada_en;
alter table public.entradas drop column if exists enviada_por;

-- un dueño, una entrada; las anuladas no cuentan
drop index if exists public.entradas_un_qr_por_persona;
create unique index entradas_un_qr_por_persona
  on public.entradas (evento, duenio) where duenio is not null and anulada_en is null;

-- una entrada es de un miembro o de alguien de afuera, nunca de los dos
alter table public.entradas drop constraint if exists entradas_de_uno_solo;
alter table public.entradas add constraint entradas_de_uno_solo
  check (duenio is null or externo_nombre is null);


-- el código: cinco signos sin 0/O, 1/I/L, 2/Z, 5/S, 8/B
create or replace function public.nuevo_codigo_entrada()
returns text
language plpgsql
volatile
set search_path to 'public'
as $$
declare
  v_signos constant text := 'ACDEFGHJKMNPQRTUVWXY34679';
  v_c text;
begin
  loop
    select 'S7-' || string_agg(substr(v_signos, 1 + floor(random() * length(v_signos))::int, 1), '')
      into v_c from generate_series(1, 5);
    exit when not exists (select 1 from public.entradas where codigo = v_c);
  end loop;
  return v_c;
end;
$$;

-- el código sigue a quien la tiene a su nombre
create or replace function public.entrada_codigo()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_quien_antes text := case when tg_op = 'UPDATE'
                             then coalesce(old.duenio::text, old.externo_nombre) end;
  v_quien_ahora text := coalesce(new.duenio::text, new.externo_nombre);
begin
  if new.anulada_en is not null or v_quien_ahora is null then
    new.codigo := null; new.codigo_en := null;
  elsif tg_op = 'INSERT' or v_quien_ahora is distinct from v_quien_antes
        or new.codigo is null then
    new.codigo := public.nuevo_codigo_entrada(); new.codigo_en := now();
  end if;
  return new;
end;
$$;

drop trigger if exists entradas_codigo on public.entradas;
create trigger entradas_codigo
  before insert or update of duenio, externo_nombre, anulada_en on public.entradas
  for each row execute function public.entrada_codigo();


-- hasta cuándo se pueden soltar y pasar entradas: 24 h antes de que abra la
-- puerta (el 14/11 abre a las 23 h, confirmado por Mau). Después, sólo el panel.
create or replace function public.cierre_de_cambios()
returns timestamptz
language sql
immutable
as $$ select timestamptz '2026-11-13 23:00-03' $$;


-- ----------------------------------------------------------------------------
-- 3. la fila de mails
-- ----------------------------------------------------------------------------
create table if not exists public.mails_en_fila (
  id         bigserial primary key,
  para       text not null,
  asunto     text not null,
  html       text not null,
  prioridad  smallint not null default 2,   -- 1: lleva un código de entrada
  creado_en  timestamptz not null default now(),
  enviado_en timestamptz,
  pedido_id  bigint                          -- el pedido de pg_net, para rastrear
);
alter table public.mails_en_fila enable row level security;
create index if not exists mails_en_fila_pendientes
  on public.mails_en_fila (prioridad, creado_en) where enviado_en is null;

comment on table public.mails_en_fila is
  'Lo que espera salir. El plan gratis de Resend corta a los 100 por día: la fila manda 90 y deja el resto para mañana.';

create or replace function public.encolar_mail(p_para text, p_asunto text, p_html text,
                                               p_prioridad smallint default 2)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into public.mails_en_fila (para, asunto, html, prioridad)
  values (p_para, p_asunto, p_html, p_prioridad);
$$;

-- corre cada minuto: manda hasta 10, sin pasar los 90 del día (día de Resend:
-- UTC), primero los que llevan código
create or replace function public.despachar_mails()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tope_dia constant int := 90;
  v_hoy      int;
  v_m        record;
  v_n        int := 0;
begin
  select count(*) into v_hoy from public.mails_en_fila
   where enviado_en >= date_trunc('day', now() at time zone 'utc') at time zone 'utc';

  for v_m in
    select * from public.mails_en_fila
     where enviado_en is null
     order by prioridad, creado_en
     limit least(10, greatest(v_tope_dia - v_hoy, 0))
     for update skip locked
  loop
    update public.mails_en_fila
       set enviado_en = now(),
           pedido_id  = public.mandar_mail(v_m.para, v_m.asunto, v_m.html)
     where id = v_m.id;
    v_n := v_n + 1;
    perform pg_sleep(0.6);              -- Resend gratis: hasta 2 por segundo
  end loop;

  return v_n;
end;
$$;

select cron.unschedule('despachar-mails')
 where exists (select 1 from cron.job where jobname = 'despachar-mails');
select cron.schedule('despachar-mails', '* * * * *', 'select public.despachar_mails()');


-- ----------------------------------------------------------------------------
-- 4. los mails de la preventa (TEXTOS A REVISAR CON MAU)
-- ----------------------------------------------------------------------------
-- el código, grande, solo, en el medio del mail. La entrada está en el portal
create or replace function public.mail_codigo(p_codigo text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select '<tr><td align="center" style="padding:0 0 30px">'
      || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
      || 'style="border:1px solid #800020;background:#141414"><tr><td align="center" style="padding:20px 38px">'
      || '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:28px;'
      || 'letter-spacing:.16em;color:#F2F2F2">' || p_codigo || '</div>'
      || '</td></tr></table></td></tr>';
$$;

-- un mail de la preventa a un miembro, a la fila. Con código, va primero.
-- La versión vieja, de cinco parámetros, se va antes: si no, las dos
-- quedarían compitiendo por las mismas llamadas
drop function if exists public.mail_de_preventa(uuid, text, text, text, text);
create or replace function public.mail_de_preventa(p_a_quien uuid, p_rotulo text, p_titulo text,
                                                   p_bajada text, p_asunto text,
                                                   p_codigo text default null,
                                                   p_despues text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_d record;
begin
  select * into v_d from public.a_quien_escribirle(p_a_quien);
  if v_d.email is null then return; end if;

  perform public.encolar_mail(
    v_d.email, p_asunto,
    public.mail_sobre(
      '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:10px;letter-spacing:.22em;color:#93A8AC;text-transform:uppercase;padding:0 0 14px">'
      || p_rotulo || '</td></tr>'
      || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:19px;line-height:1.5;letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
      || p_titulo || '</td></tr>'
      || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
      || 'font-size:13px;line-height:1.7;color:#93A8AC;padding:0 0 26px">'
      || p_bajada || '</td></tr>'
      || case when p_codigo is null then '' else public.mail_codigo(p_codigo) end
      || case when p_despues is null then '' else
           '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
           || 'font-size:12px;line-height:1.8;color:#93A8AC;padding:0 0 30px">'
           || p_despues || '</td></tr>' end,
      v_d.baja,
      'https://www.sekito.ar/?ir=preventa',
      case when p_codigo is null then 'entrar al portal' else 'ver mi entrada' end),
    case when p_codigo is null then 2 else 1 end::smallint);
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. comprar
-- ----------------------------------------------------------------------------
-- subir el comprobante ya no crea entradas: eso pasa al confirmar
create or replace function public.adjuntar_comprobante(p_codigo text, p_compra uuid, p_base64 text, p_tipo text)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo     uuid := public.miembro_de(p_codigo);
  v_bytes  bytea;
  v_antes  text;
begin
  if coalesce(btrim(p_base64), '') = '' then
    raise exception 'sin_comprobante';
  end if;

  v_bytes := decode(p_base64, 'base64');

  if octet_length(v_bytes) > 3000000 then
    raise exception 'comprobante_pesado';
  end if;

  select c.estado into v_antes
    from public.compras c
   where c.id = p_compra and c.comprador = v_yo
     and c.estado in ('esperando_comprobante', 'a_revisar')
     for update;

  if v_antes is null then raise exception 'compra_no_encontrada'; end if;

  update public.compras c
     set comprobante      = v_bytes,
         comprobante_tipo = coalesce(nullif(btrim(p_tipo), ''), 'image/jpeg'),
         estado           = 'a_revisar'
   where c.id = p_compra;

  -- el primer mail que recibe: sólo la primera vez, no si cambia la foto
  if v_antes = 'esperando_comprobante' then
    perform public.mail_de_preventa(
      v_yo, 'seki 7', 'TU COMPROBANTE LLEGÓ',
      'La sekta lo va a mirar.<br>Cuando esté confirmado, te escribimos de nuevo.',
      'la sekta tiene tu comprobante');
  end if;

  return query select true;
end;
$function$;


-- una entrada para quien compró, si todavía no tiene la suya
create or replace function public.apropiarse_una(p_compra uuid, p_quien uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_entrada uuid;
begin
  if exists (select 1 from public.entradas e
              where e.evento = 'seki7' and e.duenio = p_quien and e.anulada_en is null) then
    return;
  end if;

  select e.id into v_entrada
    from public.entradas e
   where e.compra_id = p_compra and e.duenio is null and e.externo_nombre is null
     and e.anulada_en is null
   order by e.creada_en
   limit 1;

  if v_entrada is null then return; end if;

  update public.entradas e
     set duenio = p_quien, asignada_en = now()
   where e.id = v_entrada;
end;
$function$;


-- confirmar: acá nacen las entradas, y la de quien compró ya con código
create or replace function public.admin_confirmar_compra(p_codigo text, p_compra uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_c      record;
  v_i      integer;
  v_suyo   text;
  v_faltan integer;
begin
  update public.compras c
     set estado = 'confirmada', revisada_por = v_admin, revisada_en = now(), motivo = null
   where c.id = p_compra and c.estado = 'a_revisar'
  returning c.comprador, c.cantidad, c.precio_unitario, c.tanda_id into v_c;

  if not found then raise exception 'compra_no_revisable'; end if;

  for v_i in 1 .. v_c.cantidad loop
    insert into public.entradas (compra_id, tenedor, tipo, precio)
    select p_compra, v_c.comprador, t.nombre, v_c.precio_unitario
      from public.tandas t where t.id = v_c.tanda_id;
  end loop;

  perform public.apropiarse_una(p_compra, v_c.comprador);

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'confirmar_compra', v_c.comprador, jsonb_build_object('compra', p_compra));

  select e.codigo into v_suyo
    from public.entradas e where e.compra_id = p_compra and e.duenio = v_c.comprador;
  select count(*) into v_faltan
    from public.entradas e where e.compra_id = p_compra and e.duenio is null;

  perform public.mail_de_preventa(
    v_c.comprador, 'seki 7',
    case when v_c.cantidad = 1 then 'TU ENTRADA ESTÁ CONFIRMADA'
         else 'TUS ENTRADAS ESTÁN CONFIRMADAS' end,
    'La sekta vio tu comprobante. Ya está.',
    case when v_c.cantidad = 1 then 'tu entrada para SEKI 7 está confirmada'
         else 'tus entradas para SEKI 7 están confirmadas' end,
    v_suyo,
    concat_ws('<br><br>',
      case when v_suyo is not null then 'Accedé a tu entrada desde el portal.' end,
      case when v_faltan = 1 then 'Te queda <strong style="color:#F2F2F2">una</strong> sin asignar: entrá al portal y decidí de quién es.'
           when v_faltan > 1 then 'Te quedan <strong style="color:#F2F2F2">' || v_faltan || '</strong> sin asignar: entrá al portal y decidí de quién son.' end));

  return query select true;
end;
$function$;


create or replace function public.admin_rechazar_compra(p_codigo text, p_compra uuid, p_motivo text)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_c      record;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if v_motivo is null then raise exception 'falta_motivo'; end if;

  update public.compras c
     set estado = 'rechazada', revisada_por = v_admin, revisada_en = now(), motivo = v_motivo
   where c.id = p_compra and c.estado = 'a_revisar'
  returning c.comprador into v_c;

  if not found then raise exception 'compra_no_revisable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'rechazar_compra', v_c.comprador,
          jsonb_build_object('compra', p_compra, 'motivo', v_motivo));

  perform public.mail_de_preventa(
    v_c.comprador, 'seki 7', 'ALGO NO CIERRA',
    v_motivo || '<br><br>La sekta te va a escribir.',
    'tu compra de SEKI 7 necesita una vuelta más');

  return query select true;
end;
$function$;


-- ----------------------------------------------------------------------------
-- 6. asignar, pasar, soltar
-- ----------------------------------------------------------------------------
-- el mail a quien recibe una entrada, con su código. Quien la da no recibe nada
create or replace function public.avisar_asignacion_suelta(p_entrada uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_e  record;
  v_de text;
begin
  select e.duenio, e.tenedor, e.codigo, e.compra_id into v_e
    from public.entradas e where e.id = p_entrada and e.anulada_en is null;

  if v_e.duenio is null or v_e.duenio = v_e.tenedor then return; end if;

  select public.como_le_dicen(m.apodo, m.nombre_real) into v_de
    from public.miembros m where m.id = v_e.tenedor and m.estado_codigo = 'activo';

  perform public.mail_de_preventa(
    v_e.duenio, 'seki 7', 'TENÉS TU LUGAR',
    coalesce(v_de, 'La sekta') || ' te dio una entrada para SEKI 7.',
    coalesce(lower(v_de), 'la sekta') || ' te dio una entrada para SEKI 7',
    v_e.codigo,
    'Accedé a tu entrada desde el portal.');
end;
$function$;

-- toda entrada nace confirmada: el aviso sale apenas tiene otro dueño
create or replace function public.avisar_asignacion()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.duenio is null or new.duenio = new.tenedor or new.anulada_en is not null then
    return new;
  end if;
  perform public.avisar_asignacion_suelta(new.id);
  return new;
end;
$function$;


create or replace function public.asignar_entrada(p_codigo text, p_entrada uuid, p_a_quien uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_e  record;
begin
  if now() >= public.cierre_de_cambios() then raise exception 'cambios_cerrados'; end if;

  select e.* into v_e
    from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo and e.anulada_en is null;

  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;
  if v_e.duenio is not null or v_e.externo_nombre is not null then raise exception 'ya_tiene_duenio'; end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  if exists (select 1 from public.entradas e
              where e.evento = v_e.evento and e.duenio = p_a_quien and e.anulada_en is null) then
    raise exception 'ya_tiene_entrada';
  end if;

  update public.entradas e
     set duenio = p_a_quien, asignada_en = now()
   where e.id = p_entrada;

  return query select true;
end;
$function$;


create or replace function public.pasar_entrada(p_codigo text, p_entrada uuid, p_a_quien uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_e  record;
begin
  if now() >= public.cierre_de_cambios() then raise exception 'cambios_cerrados'; end if;

  select e.* into v_e
    from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo and e.anulada_en is null;

  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;
  if v_e.duenio is not null or v_e.externo_nombre is not null then raise exception 'ya_tiene_duenio'; end if;
  if p_a_quien = v_yo then raise exception 'ya_es_tuya'; end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  update public.entradas e
     set tenedor = p_a_quien, pasada_por = v_yo
   where e.id = p_entrada;

  return query select true;
end;
$function$;


-- el dueño la suelta y le queda en la mano para dársela a otro. Su código
-- muere. Hasta 24 h antes; después, sólo el panel
create or replace function public.soltar_entrada(p_codigo text, p_entrada uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  if now() >= public.cierre_de_cambios() then raise exception 'cambios_cerrados'; end if;

  update public.entradas e
     set duenio = null, asignada_en = null, tenedor = v_yo, pasada_por = null
   where e.id = p_entrada
     and e.duenio = v_yo
     and e.anulada_en is null
     and e.adentro_en is null;

  if not found then raise exception 'no_se_puede_soltar'; end if;

  return query select true;
end;
$function$;


-- lo que ve cada uno: sus entradas, y la suya con todo para la tarjeta
drop function if exists public.mis_entradas(text);
create function public.mis_entradas(p_codigo text)
returns table(entrada_id uuid, tipo text, soy_tenedor boolean, soy_duenio boolean,
              duenio_nombre text, quien_me_la_dio text, estado text,
              codigo text, nombre text, apellido text, apodo text, sektario text,
              puede_cambiar boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select e.id,
           e.tipo,
           e.tenedor = v_yo,
           e.duenio is not distinct from v_yo,
           public.como_le_dicen(d.apodo, d.nombre_real),
           case when e.tenedor = v_yo and p.id is not null
                then public.como_le_dicen(p.apodo, p.nombre_real) end,
           case when e.adentro_en is not null then 'adentro'
                when e.duenio is null         then 'sin_asignar'
                else 'asignada' end,
           -- el código, sólo a su dueño
           case when e.duenio = v_yo then e.codigo end,
           case when e.duenio = v_yo then public.nombre_lindo(d.nombre_real) end,
           case when e.duenio = v_yo then public.nombre_lindo(d.apellido) end,
           case when e.duenio = v_yo then d.apodo end,
           case when e.duenio = v_yo then d.nombre_sektario end,
           now() < public.cierre_de_cambios() and e.adentro_en is null
      from public.entradas e
      left join public.miembros d on d.id = e.duenio
      left join public.miembros p on p.id = e.pasada_por
     where (e.tenedor = v_yo or e.duenio = v_yo)
       and e.anulada_en is null
     -- primero la suya, después las que tiene para repartir
     order by (e.duenio is not distinct from v_yo) desc, (e.duenio is null) desc, e.creada_en;
end;
$function$;


create or replace function public.mis_compras(p_codigo text)
returns table(compra_id uuid, cantidad integer, precio_unitario integer, total integer, tanda text,
              estado text, motivo text, creada_en timestamptz, sin_asignar integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select c.id, c.cantidad, c.precio_unitario, c.total,
           t.nombre, c.estado, c.motivo, c.creada_en,
           (select count(*)::integer from public.entradas e
             where e.compra_id = c.id and e.duenio is null and e.anulada_en is null)
      from public.compras c
      join public.tandas t on t.id = c.tanda_id
     where c.comprador = v_yo
     -- también la pedida: si se fue sin subir el comprobante, al volver la
     -- encuentra esperando y la termina
     order by c.creada_en desc;
end;
$function$;


-- quién puede recibir: los que ya tienen entrada salen marcados
create or replace function public.buscar_para_entrada(p_codigo text, p_query text)
returns table(id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7' and e.anulada_en is null)
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;
end;
$function$;


-- ----------------------------------------------------------------------------
-- 7. el panel
-- ----------------------------------------------------------------------------
drop function if exists public.admin_marcar_enviada(text, uuid);
drop function if exists public.admin_desmarcar_enviada(text, uuid);
drop function if exists public.admin_dar_entrada(text, uuid, text);
drop function if exists public.admin_cargar_compra(text, uuid, integer, text);

-- "+ entradas": margen total. Cuántas, de qué tipo, a qué precio, y para
-- quién: un miembro (una es suya y el resto le queda en la mano para
-- repartir), alguien de afuera (una sola, con su nombre), o nadie todavía
-- (quedan en la mano de quien se elija, o de LA SEKTA). Nacen confirmadas.
create or replace function public.admin_generar_entradas(
  p_codigo text, p_cantidad integer, p_tipo text, p_precio integer,
  p_para uuid default null,
  p_externo_nombre text default null, p_externo_apellido text default null,
  p_externo_apodo text default null, p_externo_contacto text default null,
  p_en_mano_de uuid default null, p_nota text default null)
returns table(entrada_id uuid, codigo text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin   uuid := public.admin_id_de(p_codigo);
  v_externo text := nullif(btrim(coalesce(p_externo_nombre, '')), '');
  v_tenedor uuid;
  v_ids     uuid[] := '{}';
  v_id      uuid;
  v_i       integer;
begin
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 50 then raise exception 'cantidad_invalida'; end if;
  if p_tipo not in ('sekreta', 'hermética', 'abierta', 'staff', 'free') then raise exception 'tipo_invalido'; end if;
  if p_precio is null or p_precio < 0 then raise exception 'precio_invalido'; end if;
  if p_para is not null and v_externo is not null then raise exception 'para_uno_solo'; end if;
  if v_externo is not null and p_cantidad <> 1 then raise exception 'externo_una_sola'; end if;

  if p_para is not null then
    if not exists (select 1 from public.miembros m where m.id = p_para and m.estado_codigo = 'activo') then
      raise exception 'persona_invalida';
    end if;
    v_tenedor := p_para;
  else
    v_tenedor := coalesce(p_en_mano_de, public.id_la_sekta());
    if not exists (select 1 from public.miembros m where m.id = v_tenedor
                    and m.estado_codigo in ('activo', 'simbolico')) then
      raise exception 'persona_invalida';
    end if;
  end if;

  for v_i in 1 .. p_cantidad loop
    insert into public.entradas (compra_id, tenedor, tipo, precio, nota, generada_por,
                                 externo_nombre, externo_apellido, externo_apodo, externo_contacto)
    values (null, v_tenedor, p_tipo, p_precio, nullif(btrim(coalesce(p_nota, '')), ''), v_admin,
            v_externo, nullif(btrim(coalesce(p_externo_apellido, '')), ''),
            nullif(btrim(coalesce(p_externo_apodo, '')), ''), nullif(btrim(coalesce(p_externo_contacto, '')), ''))
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  -- para un miembro: una es suya, si todavía no tiene. Se le avisa con su código
  if p_para is not null and not exists (
       select 1 from public.entradas e where e.evento = 'seki7' and e.duenio = p_para and e.anulada_en is null) then
    update public.entradas e set duenio = p_para, asignada_en = now() where e.id = v_ids[1];
    perform public.mail_de_preventa(
      p_para, 'seki 7', 'TENÉS TU LUGAR',
      'La sekta te dio una entrada para SEKI 7.',
      'la sekta te dio una entrada para SEKI 7',
      (select e.codigo from public.entradas e where e.id = v_ids[1]),
      'Accedé a tu entrada desde el portal.'
      || case when p_cantidad > 1 then '<br><br>Te dejamos ' || (p_cantidad - 1)
              || ' más para repartir: entrá al portal y decidí de quién son.' else '' end);
  end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'generar_entradas', p_para,
          jsonb_build_object('cantidad', p_cantidad, 'tipo', p_tipo, 'precio', p_precio,
                             'externo', v_externo, 'nota', p_nota));

  return query select e.id, e.codigo from public.entradas e where e.id = any(v_ids) order by e.creada_en;
end;
$function$;


-- el panel puede darle una entrada sin dueño a cualquiera, del portal o de afuera
create or replace function public.admin_asignar_entrada(
  p_codigo text, p_entrada uuid, p_para uuid default null,
  p_externo_nombre text default null, p_externo_apellido text default null,
  p_externo_apodo text default null, p_externo_contacto text default null)
returns table(codigo text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin   uuid := public.admin_id_de(p_codigo);
  v_externo text := nullif(btrim(coalesce(p_externo_nombre, '')), '');
begin
  if (p_para is null) = (v_externo is null) then raise exception 'para_uno_solo'; end if;

  if not exists (select 1 from public.entradas e where e.id = p_entrada and e.anulada_en is null
                    and e.duenio is null and e.externo_nombre is null) then
    raise exception 'ya_tiene_duenio';
  end if;

  if p_para is not null then
    if not exists (select 1 from public.miembros m where m.id = p_para and m.estado_codigo = 'activo') then
      raise exception 'persona_invalida';
    end if;
    if exists (select 1 from public.entradas e where e.evento = 'seki7' and e.duenio = p_para and e.anulada_en is null) then
      raise exception 'ya_tiene_entrada';
    end if;
    update public.entradas e set duenio = p_para, asignada_en = now() where e.id = p_entrada;
  else
    update public.entradas e
       set externo_nombre = v_externo,
           externo_apellido = nullif(btrim(coalesce(p_externo_apellido, '')), ''),
           externo_apodo    = nullif(btrim(coalesce(p_externo_apodo, '')), ''),
           externo_contacto = nullif(btrim(coalesce(p_externo_contacto, '')), ''),
           asignada_en = now()
     where e.id = p_entrada;
  end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'asignar_entrada', p_para, jsonb_build_object('entrada', p_entrada, 'externo', v_externo));

  return query select e.codigo from public.entradas e where e.id = p_entrada;
end;
$function$;


-- soltarla desde el panel: siempre, aunque haya pasado el cierre. Su código muere
create or replace function public.admin_soltar_entrada(p_codigo text, p_entrada uuid)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_e      record;
  v_vuelve uuid;
begin
  select e.id, e.duenio, e.tenedor, e.compra_id into v_e
    from public.entradas e
   where e.id = p_entrada and e.anulada_en is null
     and (e.duenio is not null or e.externo_nombre is not null);

  if v_e.id is null then raise exception 'no_estaba_asignada'; end if;

  select c.comprador into v_vuelve from public.compras c where c.id = v_e.compra_id;

  update public.entradas e
     set duenio = null, asignada_en = null, pasada_por = null,
         externo_nombre = null, externo_apellido = null, externo_apodo = null, externo_contacto = null,
         tenedor = coalesce(v_vuelve, e.tenedor)
   where e.id = p_entrada;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'soltar_entrada', v_e.duenio, jsonb_build_object('entrada', p_entrada));

  return query select true;
end;
$function$;


-- anular: un error de carga, una devolución. La fila queda, no cuenta más
create or replace function public.admin_anular_entrada(p_codigo text, p_entrada uuid, p_motivo text)
returns table(ok boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_duenio uuid;
begin
  if v_motivo is null then raise exception 'falta_motivo'; end if;

  update public.entradas e
     set anulada_en = now(), anulada_motivo = v_motivo
   where e.id = p_entrada and e.anulada_en is null
  returning e.duenio into v_duenio;

  if not found then raise exception 'entrada_invalida'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'anular_entrada', v_duenio, jsonb_build_object('entrada', p_entrada, 'motivo', v_motivo));

  return query select true;
end;
$function$;


-- la lista: ninguna fila desaparece
drop function if exists public.admin_entradas_s7(text);
create function public.admin_entradas_s7(p_codigo text)
returns table(entrada_id uuid, codigo text, tipo text, precio integer,
              nombre text, apodo text, sektario text, email text, contacto text, de_afuera boolean,
              tenedor text, compro text, estado text, nota text,
              adentro_en timestamptz, creada_en timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select e.id, e.codigo, e.tipo, e.precio,
           coalesce(nullif(trim(coalesce(public.nombre_lindo(d.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(d.apellido), '')), ''),
                    nullif(trim(coalesce(e.externo_nombre, '') || ' ' || coalesce(e.externo_apellido, '')), '')),
           coalesce(d.apodo, e.externo_apodo),
           d.nombre_sektario,
           d.email,
           coalesce(d.telefono, e.externo_contacto),
           e.externo_nombre is not null,
           coalesce(public.como_le_dicen(te.apodo, te.nombre_real), te.nombre_sektario),
           public.como_le_dicen(cm.apodo, cm.nombre_real),
           case when e.anulada_en is not null then 'anulada'
                when e.adentro_en is not null then 'adentro'
                when e.duenio is null and e.externo_nombre is null then 'sin_asignar'
                else 'asignada' end,
           coalesce(e.anulada_motivo, e.nota),
           e.adentro_en, e.creada_en
      from public.entradas e
      left join public.compras  c  on c.id  = e.compra_id
      left join public.miembros d  on d.id  = e.duenio
      left join public.miembros te on te.id = e.tenedor
      left join public.miembros cm on cm.id = c.comprador
     order by (e.anulada_en is not null), e.creada_en;
end;
$function$;


drop function if exists public.admin_resumen_s7(text);
create function public.admin_resumen_s7(p_codigo text)
returns table(vendidas integer, staff integer, free integer, total integer,
              a_confirmar integer, sin_asignar integer, adentro integer, recaudado integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select
      count(*) filter (where e.tipo in ('sekreta', 'hermética', 'abierta'))::integer,
      count(*) filter (where e.tipo = 'staff')::integer,
      count(*) filter (where e.tipo = 'free')::integer,
      -- lo que va a entrar por la puerta
      count(*)::integer,
      (select coalesce(sum(c.cantidad), 0)::integer from public.compras c where c.estado = 'a_revisar'),
      count(*) filter (where e.duenio is null and e.externo_nombre is null)::integer,
      count(*) filter (where e.adentro_en is not null)::integer,
      coalesce(sum(e.precio), 0)::integer
      from public.entradas e
     where e.anulada_en is null;
end;
$function$;


create or replace function public.admin_tandas(p_codigo text)
returns table(tanda_id integer, nombre text, precio integer, activa boolean, vendidas integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select t.id, t.nombre, t.precio, t.activa,
           (select count(*)::integer from public.entradas e
             where e.tipo = t.nombre and e.anulada_en is null)
      from public.tandas t
     order by t.id;
end;
$function$;


create or replace function public.admin_buscar_persona(p_codigo text, p_query text)
returns table(id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_q text := btrim(coalesce(p_query, ''));
begin
  perform public.admin_id_de(p_codigo);
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7' and e.anulada_en is null)
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
              m.nombre_real nulls last
     limit 8;
end;
$function$;


-- ----------------------------------------------------------------------------
-- 8. permisos: lo interno no se llama desde afuera
-- ----------------------------------------------------------------------------
revoke execute on function public.nuevo_codigo_entrada() from public, anon, authenticated;
revoke execute on function public.entrada_codigo() from public, anon, authenticated;
revoke execute on function public.cierre_de_cambios() from public, anon, authenticated;
revoke execute on function public.encolar_mail(text, text, text, smallint) from public, anon, authenticated;
revoke execute on function public.despachar_mails() from public, anon, authenticated;
revoke execute on function public.mail_codigo(text) from public, anon, authenticated;
revoke execute on function public.mail_de_preventa(uuid, text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.apropiarse_una(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.avisar_asignacion_suelta(uuid) from public, anon, authenticated;
revoke execute on function public.avisar_asignacion() from public, anon, authenticated;

notify pgrst, 'reload schema';
