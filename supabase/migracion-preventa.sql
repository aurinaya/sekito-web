-- ============================================================================
-- SÉKITO — la preventa de la SEKI 7
-- ============================================================================
-- Comprar es adentro del portal, así que el que compra ya tiene nombre,
-- apellido y mail cargados: el formulario de entrada los exige desde siempre,
-- en el navegador y otra vez acá. Por eso comprar no pide datos.
--
-- Dos planos que conviene no mezclar:
--
--   LA COMPRA es la plata. Una transferencia, un comprobante, una decisión.
--   LA ENTRADA es la persona. Un dueño, un mail, un QR.
--
-- Una compra de tres entradas es una sola transferencia y tres destinos
-- distintos, que pueden resolverse semanas después.
--
-- Y dos palabras que parecen la misma y no lo son:
--
--   TENER una entrada es controlarla: decidir a quién va.
--   SER DUEÑO es tenerla a tu nombre, y es lo único que hace salir un QR.
--
-- Nadie puede ser dueño de dos entradas del mismo evento. Pero cualquiera
-- puede tener varias en la mano. Así, cuando le querés dar una entrada a
-- alguien que ya tiene, no hay que frenar la venta ni perder la plata: se la
-- dejás igual, sin dueño, y la reparte esa persona.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. las tandas
-- ----------------------------------------------------------------------------
-- El precio va a subir y no sabemos cuándo. Si viviera en el código, cada
-- cambio de precio sería una publicación del sitio. Acá es una fila.
create table if not exists public.tandas (
  id        serial primary key,
  nombre    text    not null,
  precio    integer not null check (precio > 0),
  activa    boolean not null default false,
  creada_en timestamptz not null default now()
);

comment on table public.tandas is
  'Los precios de la preventa. El precio se copia a la compra: cambiar una tanda no reescribe el pasado.';

-- una sola activa a la vez, garantizado por la base y no por la pantalla
create unique index if not exists tandas_una_sola_activa
  on public.tandas (activa) where activa;

alter table public.tandas enable row level security;

insert into public.tandas (nombre, precio, activa)
select v.nombre, v.precio, v.activa
  from (values ('preventa', 30000, true),
               ('early',    35000, false),
               ('final',    40000, false)) as v(nombre, precio, activa)
 where not exists (select 1 from public.tandas);


-- ----------------------------------------------------------------------------
-- 2. las compras
-- ----------------------------------------------------------------------------
-- El comprobante se guarda acá adentro, en la misma pieza cerrada que todo lo
-- demás, y no en un archivo con dirección propia. Una transferencia lleva el
-- CBU, el nombre completo y el banco de una persona: no puede quedar colgando
-- de una dirección que alguien pueda adivinar o reenviar sin querer.
create table if not exists public.compras (
  id               uuid primary key default gen_random_uuid(),
  evento           text    not null default 'seki7',
  comprador        uuid    not null references public.miembros(id) on delete restrict,
  tanda_id         integer not null references public.tandas(id),
  cantidad         integer not null check (cantidad between 1 and 7),
  precio_unitario  integer not null,
  total            integer not null,
  comprobante      bytea,
  comprobante_tipo text,
  estado           text    not null default 'esperando_comprobante'
                     check (estado in ('esperando_comprobante','a_revisar','confirmada','rechazada')),
  revisada_por     uuid references public.admins(id) on delete set null,
  revisada_en      timestamptz,
  motivo           text,
  creada_en        timestamptz not null default now(),
  constraint comprobante_no_gigante
    check (comprobante is null or octet_length(comprobante) <= 3000000)
);

comment on column public.compras.precio_unitario is
  'Congelado al comprar. Si la tanda sube después, esta compra sigue valiendo lo que valía.';

alter table public.compras enable row level security;

create index if not exists compras_por_comprador on public.compras (comprador, creada_en desc);
create index if not exists compras_por_estado    on public.compras (estado, creada_en);


-- ----------------------------------------------------------------------------
-- 3. las entradas
-- ----------------------------------------------------------------------------
-- En el schema del día uno ya había una tabla `entradas`: un boceto de esta
-- misma idea, con la entrada pegada al que la compraba y el comprobante como
-- una URL suelta. Nunca se usó — cero filas, ninguna función la nombra, nada
-- apunta a ella. Se descarta, porque el nombre lo necesita la de verdad.
drop table if exists public.entradas;

create table if not exists public.entradas (
  id           uuid primary key default gen_random_uuid(),
  evento       text not null default 'seki7',
  compra_id    uuid not null references public.compras(id) on delete cascade,
  tenedor      uuid not null references public.miembros(id) on delete restrict,
  duenio       uuid references public.miembros(id) on delete restrict,
  asignada_en  timestamptz,
  pasada_por   uuid references public.miembros(id) on delete set null,
  cargada_en   timestamptz,
  cargada_por  uuid references public.admins(id) on delete set null,
  creada_en    timestamptz not null default now()
);

comment on column public.entradas.tenedor is
  'Quién la controla ahora. Arranca en el que compró y puede pasar de mano.';
comment on column public.entradas.duenio is
  'A nombre de quién queda. Sin esto no sale ningún QR.';

-- una persona, un QR. Es el único candado que importa de verdad.
create unique index if not exists entradas_un_qr_por_persona
  on public.entradas (evento, duenio) where duenio is not null;

alter table public.entradas enable row level security;

create index if not exists entradas_por_tenedor on public.entradas (tenedor);
create index if not exists entradas_por_compra  on public.entradas (compra_id);


-- ----------------------------------------------------------------------------
-- 4. qué tanda está abierta
-- ----------------------------------------------------------------------------
create or replace function public.la_tanda(p_codigo text)
returns table (tanda_id integer, nombre text, precio integer, tope integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.miembro_de(p_codigo);   -- esto es adentro del portal, no afuera

  return query
    select t.id, t.nombre, t.precio, 7
      from public.tandas t
     where t.activa
     limit 1;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. comprar
-- ----------------------------------------------------------------------------
-- No cobra nada ni confirma nada: anota la intención y prepara los lugares.
-- La plata la mira Flor después, con el comprobante en la mano.
--
-- Si quedó una compra a medio hacer (entró, eligió tres, se fue sin subir
-- nada), esa se descarta. No tiene ningún valor y ensucia la lista de Flor.
create or replace function public.comprar_entradas(p_codigo text, p_cantidad integer)
returns table (compra_id uuid, precio_unitario integer, total integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo      uuid := public.miembro_de(p_codigo);
  v_tanda   record;
  v_compra  uuid;
  v_i       integer;
begin
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 7 then
    raise exception 'cantidad_invalida';
  end if;

  select t.id, t.precio into v_tanda
    from public.tandas t
   where t.activa
   limit 1;

  if v_tanda.id is null then
    raise exception 'sin_tanda';
  end if;

  delete from public.compras c
   where c.comprador = v_yo
     and c.estado = 'esperando_comprobante';

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total)
  values (v_yo, v_tanda.id, p_cantidad, v_tanda.precio, v_tanda.precio * p_cantidad)
  returning compras.id into v_compra;

  for v_i in 1 .. p_cantidad loop
    insert into public.entradas (compra_id, tenedor) values (v_compra, v_yo);
  end loop;

  return query select v_compra, v_tanda.precio, v_tanda.precio * p_cantidad;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. subir el comprobante
-- ----------------------------------------------------------------------------
-- Llega en base64 porque es lo que un navegador sabe mandar sin pelearse con
-- nadie. Acá se guarda como bytes.
create or replace function public.adjuntar_comprobante(
  p_codigo  text,
  p_compra  uuid,
  p_base64  text,
  p_tipo    text
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo    uuid := public.miembro_de(p_codigo);
  v_bytes bytea;
begin
  if coalesce(btrim(p_base64), '') = '' then
    raise exception 'sin_comprobante';
  end if;

  v_bytes := decode(p_base64, 'base64');

  if octet_length(v_bytes) > 3000000 then
    raise exception 'comprobante_pesado';
  end if;

  update public.compras c
     set comprobante      = v_bytes,
         comprobante_tipo = coalesce(nullif(btrim(p_tipo), ''), 'image/jpeg'),
         estado           = 'a_revisar'
   where c.id = p_compra
     and c.comprador = v_yo
     and c.estado in ('esperando_comprobante', 'a_revisar');

  if not found then
    raise exception 'compra_no_encontrada';
  end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. mis compras
-- ----------------------------------------------------------------------------
create or replace function public.mis_compras(p_codigo text)
returns table (
  compra_id uuid, cantidad integer, precio_unitario integer, total integer,
  tanda text, estado text, motivo text, creada_en timestamptz, sin_asignar integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select c.id, c.cantidad, c.precio_unitario, c.total,
           t.nombre, c.estado, c.motivo, c.creada_en,
           (select count(*)::integer from public.entradas e
             where e.compra_id = c.id and e.duenio is null)
      from public.compras c
      join public.tandas t on t.id = c.tanda_id
     where c.comprador = v_yo
       and c.estado <> 'esperando_comprobante'
     order by c.creada_en desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- 8. mis entradas
-- ----------------------------------------------------------------------------
-- Devuelve las que controlo y también las que son mías aunque las haya
-- comprado otro: las dos cosas viven en la misma pantalla porque para el que
-- mira son lo mismo, "mi lugar en la fiesta".
create or replace function public.mis_entradas(p_codigo text)
returns table (
  entrada_id   uuid,
  soy_tenedor  boolean,
  soy_duenio   boolean,
  duenio_nombre text,
  duenio_sektario text,
  quien_me_la_dio text,
  compra_estado text,
  cargada      boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select e.id,
           e.tenedor = v_yo,
           e.duenio  is not distinct from v_yo,
           public.nombre_lindo(d.nombre_real),
           d.nombre_sektario,
           case when e.tenedor = v_yo and p.id is not null
                then public.nombre_lindo(p.nombre_real) end,
           c.estado,
           e.cargada_en is not null
      from public.entradas e
      join public.compras  c on c.id = e.compra_id
      left join public.miembros d on d.id = e.duenio
      left join public.miembros p on p.id = e.pasada_por
     where (e.tenedor = v_yo or e.duenio = v_yo)
       and c.estado <> 'rechazada'
     order by (e.duenio is null) desc, e.creada_en;
end;
$$;


-- ----------------------------------------------------------------------------
-- 9. asignar una entrada
-- ----------------------------------------------------------------------------
-- El candado está sobre SER DUEÑO, no sobre tener. Si la persona ya tiene una
-- entrada a su nombre, esto corta con 'ya_tiene_entrada' y la pantalla ofrece
-- la otra salida: dejársela igual, sin dueño, para que la reparta ella.
create or replace function public.asignar_entrada(
  p_codigo  text,
  p_entrada uuid,
  p_a_quien uuid
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_e  record;
begin
  select e.* into v_e
    from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo;

  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;
  if v_e.cargada_en is not null then raise exception 'entrada_ya_cargada'; end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  if exists (select 1 from public.entradas e
              where e.evento = v_e.evento
                and e.duenio = p_a_quien
                and e.id <> p_entrada) then
    raise exception 'ya_tiene_entrada';
  end if;

  update public.entradas e
     set duenio = p_a_quien, asignada_en = now()
   where e.id = p_entrada;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 10. dejársela igual
-- ----------------------------------------------------------------------------
-- La entrada cambia de mano sin cambiar de nombre: sigue sin dueño, pero
-- ahora la reparte otro. Es lo que evita que una entrada pagada quede sin uso
-- porque la persona a la que se la querías dar ya tenía la suya.
create or replace function public.pasar_entrada(
  p_codigo  text,
  p_entrada uuid,
  p_a_quien uuid
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_e  record;
begin
  select e.* into v_e
    from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo;

  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;
  if v_e.duenio is not null then raise exception 'ya_tiene_duenio'; end if;
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
$$;


-- ----------------------------------------------------------------------------
-- 11. sacar una asignación
-- ----------------------------------------------------------------------------
-- Poner un nombre equivocado tiene que poder deshacerse. Una vez cargada en
-- Passline ya no: ahí afuera hay un mail con un QR que no vuelve.
create or replace function public.sacar_asignacion(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  update public.entradas e
     set duenio = null, asignada_en = null
   where e.id = p_entrada
     and e.tenedor = v_yo
     and e.cargada_en is null;

  if not found then raise exception 'no_se_puede_sacar'; end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 12. los mails de la preventa
-- ----------------------------------------------------------------------------
-- Un solo lugar donde se arma cada uno, para que los llame tanto el panel
-- como la asignación sin repetir el texto.
create or replace function public.mail_de_preventa(
  p_a_quien uuid,
  p_rotulo  text,
  p_titulo  text,
  p_bajada  text,
  p_asunto  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_d record;
begin
  select * into v_d from public.a_quien_escribirle(p_a_quien);
  if v_d.email is null then return; end if;

  perform public.mandar_mail(
    v_d.email, p_asunto,
    public.mail_armado(p_rotulo, p_titulo, p_bajada, v_d.baja));
end;
$$;


-- ----------------------------------------------------------------------------
-- 13. el panel: las compras
-- ----------------------------------------------------------------------------
-- El comprobante NO viaja en esta lista. Son 300 fotos: mandarlas todas
-- juntas para mostrar una tabla sería absurdo, y además cada una lleva datos
-- bancarios de alguien. Se pide de a una, cuando se abre.
create or replace function public.admin_compras(p_codigo text, p_estado text default null)
returns table (
  compra_id uuid, comprador text, sektario text, email text,
  cantidad integer, total integer, tanda text, estado text,
  creada_en timestamptz, tiene_comprobante boolean, sin_asignar integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select c.id,
           trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                coalesce(public.nombre_lindo(m.apellido), '')),
           m.nombre_sektario, m.email,
           c.cantidad, c.total, t.nombre, c.estado, c.creada_en,
           c.comprobante is not null,
           (select count(*)::integer from public.entradas e
             where e.compra_id = c.id and e.duenio is null)
      from public.compras c
      join public.miembros m on m.id = c.comprador
      join public.tandas   t on t.id = c.tanda_id
     where c.estado <> 'esperando_comprobante'
       and (p_estado is null or c.estado = p_estado)
     order by (c.estado = 'a_revisar') desc, c.creada_en;
end;
$$;


-- ----------------------------------------------------------------------------
-- 14. el panel: ver un comprobante
-- ----------------------------------------------------------------------------
create or replace function public.admin_comprobante(p_codigo text, p_compra uuid)
returns table (tipo text, datos text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select c.comprobante_tipo, encode(c.comprobante, 'base64')
      from public.compras c
     where c.id = p_compra and c.comprobante is not null;
end;
$$;


-- ----------------------------------------------------------------------------
-- 15. el panel: confirmar o rechazar el ingreso
-- ----------------------------------------------------------------------------
create or replace function public.admin_confirmar_compra(p_codigo text, p_compra uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_c     record;
  v_faltan integer;
begin
  update public.compras c
     set estado = 'confirmada', revisada_por = v_admin, revisada_en = now(), motivo = null
   where c.id = p_compra and c.estado = 'a_revisar'
  returning c.comprador, c.cantidad into v_c;

  if not found then raise exception 'compra_no_revisable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'confirmar_compra', v_c.comprador, jsonb_build_object('compra', p_compra));

  select count(*) into v_faltan
    from public.entradas e where e.compra_id = p_compra and e.duenio is null;

  -- a los que ya tenían nombre puesto antes de que la plata estuviera
  -- confirmada, el trigger no les avisó: se avisa acá
  perform public.avisar_asignacion_suelta(e.id)
     from public.entradas e
    where e.compra_id = p_compra and e.duenio is not null and e.duenio <> e.tenedor;

  perform public.mail_de_preventa(
    v_c.comprador,
    'seki 7',
    'tu lugar está',
    case when v_faltan = 0
         then 'La sekta vio tu transferencia. Ya está.'
         else 'La sekta vio tu transferencia. Te quedan <strong>' || v_faltan ||
              '</strong> sin asignar: entrá al portal y decidí de quién son.' end,
    'tu lugar en la seki 7 está confirmado');

  return query select true;
end;
$$;


create or replace function public.admin_rechazar_compra(
  p_codigo text, p_compra uuid, p_motivo text
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
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
    v_c.comprador, 'seki 7', 'algo no cierra',
    v_motivo || '<br><br>Entrá al portal y volvé a subirlo.',
    'tu compra de la seki 7 necesita una vuelta más');

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 16. el panel: las entradas que hay que cargar en Passline
-- ----------------------------------------------------------------------------
-- Se cargan a mano, de a una, entre tres personas. Así que esto devuelve
-- exactamente lo que hay que copiar y nada más: nombre completo y mail.
create or replace function public.admin_para_cargar(p_codigo text)
returns table (
  entrada_id uuid, nombre text, email text, sektario text,
  compro text, confirmada_en timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select e.id,
           trim(coalesce(public.nombre_lindo(d.nombre_real), '') || ' ' ||
                coalesce(public.nombre_lindo(d.apellido), '')),
           d.email, d.nombre_sektario,
           public.nombre_lindo(cm.nombre_real),
           c.revisada_en
      from public.entradas e
      join public.compras  c  on c.id = e.compra_id
      join public.miembros d  on d.id = e.duenio
      join public.miembros cm on cm.id = c.comprador
     where c.estado = 'confirmada'
       and e.duenio is not null
       and e.cargada_en is null
     order by c.revisada_en;
end;
$$;


create or replace function public.admin_marcar_cargada(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_duenio uuid;
begin
  update public.entradas e
     set cargada_en = now(), cargada_por = v_admin
   where e.id = p_entrada and e.duenio is not null and e.cargada_en is null
  returning e.duenio into v_duenio;

  if not found then raise exception 'entrada_no_cargable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'cargar_entrada', v_duenio, jsonb_build_object('entrada', p_entrada));

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 17. el panel: las tandas
-- ----------------------------------------------------------------------------
create or replace function public.admin_tandas(p_codigo text)
returns table (tanda_id integer, nombre text, precio integer, activa boolean, vendidas integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select t.id, t.nombre, t.precio, t.activa,
           (select coalesce(sum(c.cantidad), 0)::integer from public.compras c
             where c.tanda_id = t.id and c.estado = 'confirmada')
      from public.tandas t
     order by t.id;
end;
$$;


create or replace function public.admin_activar_tanda(p_codigo text, p_tanda integer)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  -- primero se apagan todas: el índice único no deja que haya dos prendidas
  -- ni por un instante dentro de la misma sentencia
  update public.tandas set activa = false where activa;
  update public.tandas set activa = true  where id = p_tanda;

  if not found then raise exception 'tanda_invalida'; end if;

  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'activar_tanda', jsonb_build_object('tanda', p_tanda));

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 18. avisarle al que le asignaron una entrada
-- ----------------------------------------------------------------------------
-- Va por trigger y no adentro de asignar_entrada porque hay dos caminos que
-- terminan en lo mismo: que te asignen, y que confirmen la compra de una
-- entrada que ya tenía tu nombre. Un solo aviso para los dos.
--
-- No avisa cuando alguien se la asigna a sí mismo: ya lo sabe, lo acaba de
-- hacer. Y no avisa antes de que la plata esté confirmada, porque un "tenés
-- tu lugar" que después se cae es peor que no decir nada.
create or replace function public.avisar_asignacion_suelta(p_entrada uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e record;
  v_de text;
begin
  select e.duenio, e.tenedor into v_e
    from public.entradas e where e.id = p_entrada;

  if v_e.duenio is null or v_e.duenio = v_e.tenedor then return; end if;

  select public.nombre_lindo(m.nombre_real) into v_de
    from public.miembros m where m.id = v_e.tenedor;

  perform public.mail_de_preventa(
    v_e.duenio, 'seki 7', 'tenés tu lugar',
    coalesce(v_de, 'Alguien') || ' te dio una entrada para la SEKI 7.' ||
    '<br><br>Te va a llegar el QR por separado.',
    'tenés tu lugar en la seki 7');
end;
$$;


create or replace function public.avisar_asignacion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estado text;
begin
  if new.duenio is null or new.duenio = new.tenedor then
    return new;
  end if;

  select c.estado into v_estado from public.compras c where c.id = new.compra_id;
  if v_estado <> 'confirmada' then return new; end if;

  perform public.avisar_asignacion_suelta(new.id);

  return new;
end;
$$;

drop trigger if exists entradas_avisar_asignacion on public.entradas;
create trigger entradas_avisar_asignacion
  after update of duenio on public.entradas
  for each row
  when (new.duenio is not null and new.duenio is distinct from old.duenio)
  execute function public.avisar_asignacion();


-- ----------------------------------------------------------------------------
-- 19. borrar los comprobantes
-- ----------------------------------------------------------------------------
-- Treinta días después de la fiesta no queda una sola foto de una
-- transferencia en la base. No hay ninguna razón para conservar el CBU de
-- trescientas personas, y sí muchas para no hacerlo.
--
-- Borra los bytes, no la compra: el registro de quién pagó cuánto se queda.
create or replace function public.olvidar_comprobantes()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cuantos integer;
begin
  if now() < timestamptz '2026-11-14 00:00-03' + interval '30 days' then
    return 0;
  end if;

  update public.compras c
     set comprobante = null, comprobante_tipo = null
   where c.comprobante is not null;

  get diagnostics v_cuantos = row_count;
  return v_cuantos;
end;
$$;

select cron.unschedule('olvidar-comprobantes')
 where exists (select 1 from cron.job where jobname = 'olvidar-comprobantes');

select cron.schedule('olvidar-comprobantes', '30 4 * * *',
                     $job$ select public.olvidar_comprobantes(); $job$);


-- ----------------------------------------------------------------------------
-- 20. los permisos
-- ----------------------------------------------------------------------------
-- Las tablas quedan con RLS y sin políticas: nadie las toca con la clave
-- pública del sitio. El único camino son estas funciones.
revoke all on function public.mail_de_preventa(uuid, text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.avisar_asignacion()        from public, anon, authenticated;
revoke all on function public.avisar_asignacion_suelta(uuid) from public, anon, authenticated;
revoke all on function public.olvidar_comprobantes() from public, anon, authenticated;

grant execute on function public.la_tanda(text)                            to anon, authenticated;
grant execute on function public.comprar_entradas(text, integer)           to anon, authenticated;
grant execute on function public.adjuntar_comprobante(text, uuid, text, text) to anon, authenticated;
grant execute on function public.mis_compras(text)                         to anon, authenticated;
grant execute on function public.mis_entradas(text)                        to anon, authenticated;
grant execute on function public.asignar_entrada(text, uuid, uuid)         to anon, authenticated;
grant execute on function public.pasar_entrada(text, uuid, uuid)           to anon, authenticated;
grant execute on function public.sacar_asignacion(text, uuid)              to anon, authenticated;

grant execute on function public.admin_compras(text, text)                 to anon, authenticated;
grant execute on function public.admin_comprobante(text, uuid)             to anon, authenticated;
grant execute on function public.admin_confirmar_compra(text, uuid)        to anon, authenticated;
grant execute on function public.admin_rechazar_compra(text, uuid, text)   to anon, authenticated;
grant execute on function public.admin_para_cargar(text)                   to anon, authenticated;
grant execute on function public.admin_marcar_cargada(text, uuid)          to anon, authenticated;
grant execute on function public.admin_tandas(text)                        to anon, authenticated;
grant execute on function public.admin_activar_tanda(text, integer)        to anon, authenticated;
-- ----------------------------------------------------------------------------
-- 21. buscar a quién darle una entrada
-- ----------------------------------------------------------------------------
-- El buscador del padrón no devuelve identificadores a propósito. Este sí,
-- porque acá hay que elegir a una persona y no sólo mirarla.
--
-- Devuelve `ya_tiene` para que la pantalla lo diga ANTES de que toques nada.
-- Enterarte de que alguien ya tiene entrada recién cuando te rebota el botón
-- es enterarte tarde.
--
-- LA SEKTA queda afuera: no va a la fiesta.
create or replace function public.buscar_para_entrada(p_codigo text, p_query text)
returns table (id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7')
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and (
             m.nombre_sektario ilike '%' || v_q || '%'
          or m.nombre_real     ilike '%' || v_q || '%'
          or m.apellido        ilike '%' || v_q || '%'
           )
     order by
       (m.nombre_real ilike v_q || '%' or m.nombre_sektario ilike v_q || '%') desc,
       m.nombre_real nulls last
     limit 8;
end;
$$;

grant execute on function public.buscar_para_entrada(text, text) to anon, authenticated;
