-- ============================================================================
-- SÉKITO — segunda vuelta de la preventa
-- ============================================================================
-- Lo que cambia, y por qué:
--
--   · La primera entrada se asigna sola al que compra. Comprar cuatro y que
--     las cuatro queden sin dueño obliga a asignarte a vos mismo, que es el
--     único caso que el sistema ya sabe.
--
--   · Las entradas tienen TIPO, congelado al nacer igual que el precio:
--     preventa, early, final, staff, free. Sin esto, un free y una preventa
--     son la misma fila y en la puerta no se distinguen.
--
--   · Un QR no se "carga", se ENVÍA. Y una vez enviado la fila se queda en la
--     lista con su estado: una lista de la que las cosas desaparecen no sirve
--     para revisar nada.
--
--   · Hay entradas que no nacen de una compra en el portal: las de staff, las
--     free, y las que se pagaron por afuera. Por eso `compra_id` deja de ser
--     obligatoria.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. las columnas nuevas
-- ----------------------------------------------------------------------------
alter table public.entradas
  add column if not exists tipo text;

-- una entrada de staff o una free no salen de ninguna transferencia
alter table public.entradas
  alter column compra_id drop not null;

-- "cargada" era el verbo del que la sube a Passline. "Enviada" es lo que le
-- pasa a la persona, que es lo que hay que poder mirar.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='entradas'
                and column_name='cargada_en') then
    alter table public.entradas rename column cargada_en  to enviada_en;
    alter table public.entradas rename column cargada_por to enviada_por;
  end if;
end $$;

-- las que ya existen toman el nombre de la tanda con la que se compraron
update public.entradas e
   set tipo = t.nombre
  from public.compras c
  join public.tandas  t on t.id = c.tanda_id
 where e.compra_id = c.id and e.tipo is null;

update public.entradas set tipo = 'preventa' where tipo is null;

alter table public.entradas
  alter column tipo set not null;

alter table public.entradas drop constraint if exists entradas_tipo_conocido;
alter table public.entradas add  constraint entradas_tipo_conocido
  check (tipo in ('preventa','early','final','staff','free'));

comment on column public.entradas.tipo is
  'Congelado al nacer. De una compra sale el nombre de la tanda; staff y free las da un admin.';


-- ----------------------------------------------------------------------------
-- 2. la primera es para el que compra
-- ----------------------------------------------------------------------------
-- Salvo que ya tenga la suya: el candado de una persona, un QR manda por
-- encima de esta comodidad.
create or replace function public.apropiarse_una(p_compra uuid, p_quien uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entrada uuid;
begin
  if exists (select 1 from public.entradas e
              where e.evento = 'seki7' and e.duenio = p_quien) then
    return;
  end if;

  select e.id into v_entrada
    from public.entradas e
   where e.compra_id = p_compra and e.duenio is null
   order by e.creada_en
   limit 1;

  if v_entrada is null then return; end if;

  update public.entradas e
     set duenio = p_quien, asignada_en = now()
   where e.id = v_entrada;
end;
$$;


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

  select t.id, t.precio, t.nombre into v_tanda
    from public.tandas t where t.activa limit 1;

  if v_tanda.id is null then
    raise exception 'sin_tanda';
  end if;

  delete from public.compras c
   where c.comprador = v_yo and c.estado = 'esperando_comprobante';

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total)
  values (v_yo, v_tanda.id, p_cantidad, v_tanda.precio, v_tanda.precio * p_cantidad)
  returning compras.id into v_compra;

  for v_i in 1 .. p_cantidad loop
    insert into public.entradas (compra_id, tenedor, tipo)
    values (v_compra, v_yo, v_tanda.nombre);
  end loop;

  perform public.apropiarse_una(v_compra, v_yo);

  return query select v_compra, v_tanda.precio, v_tanda.precio * p_cantidad;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. mis entradas, con el estado ya resuelto
-- ----------------------------------------------------------------------------
-- El estado lo arma la base y no la pantalla. Son cuatro situaciones y
-- dependen de tres tablas: si lo decide el navegador, tarde o temprano dos
-- pantallas dicen cosas distintas de la misma entrada.
drop function if exists public.mis_entradas(text);

create or replace function public.mis_entradas(p_codigo text)
returns table (
  entrada_id      uuid,
  tipo            text,
  soy_tenedor     boolean,
  soy_duenio      boolean,
  duenio_nombre   text,
  quien_me_la_dio text,
  estado          text
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
           e.tipo,
           e.tenedor = v_yo,
           e.duenio is not distinct from v_yo,
           public.nombre_lindo(d.nombre_real),
           case when e.tenedor = v_yo and p.id is not null
                then public.nombre_lindo(p.nombre_real) end,
           case
             when e.duenio is null                        then 'sin_asignar'
             when e.enviada_en is not null                then 'enviada'
             when c.id is null                            then 'por_enviar'
             when c.estado = 'confirmada'                 then 'por_enviar'
             else 'esperando'
           end
      from public.entradas e
      left join public.compras  c on c.id = e.compra_id
      left join public.miembros d on d.id = e.duenio
      left join public.miembros p on p.id = e.pasada_por
     where (e.tenedor = v_yo or e.duenio = v_yo)
       and (c.id is null or c.estado <> 'rechazada')
     order by (e.duenio is null) desc, e.creada_en;
end;
$$;

grant execute on function public.mis_entradas(text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. el resumen de la SEKI 7
-- ----------------------------------------------------------------------------
-- Los cuatro números que hay que poder mirar sin contar filas a mano.
create or replace function public.admin_resumen_s7(p_codigo text)
returns table (
  vendidas          integer,
  esperando_ingreso integer,
  por_enviar        integer,
  enviadas          integer,
  sin_asignar       integer,
  recaudado         integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select
      -- vendidas: las que ya son plata adentro. Staff y free no se venden.
      (select count(*)::integer from public.entradas e
         join public.compras c on c.id = e.compra_id
        where c.estado = 'confirmada'),
      (select count(*)::integer from public.entradas e
         join public.compras c on c.id = e.compra_id
        where c.estado = 'a_revisar'),
      (select count(*)::integer from public.entradas e
         left join public.compras c on c.id = e.compra_id
        where e.duenio is not null and e.enviada_en is null
          and (c.id is null or c.estado = 'confirmada')),
      (select count(*)::integer from public.entradas e where e.enviada_en is not null),
      (select count(*)::integer from public.entradas e
         left join public.compras c on c.id = e.compra_id
        where e.duenio is null and (c.id is null or c.estado <> 'rechazada')),
      (select coalesce(sum(c.total), 0)::integer from public.compras c
        where c.estado = 'confirmada');
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. todas las entradas, en una sola lista
-- ----------------------------------------------------------------------------
-- No filtra nada: una lista de la que las filas se van cuando las resolvés no
-- sirve para revisar, sólo para vaciar.
create or replace function public.admin_entradas_s7(p_codigo text)
returns table (
  entrada_id uuid,
  tipo       text,
  nombre     text,
  email      text,
  sektario   text,
  tenedor    text,
  compro     text,
  estado     text,
  enviada_en timestamptz,
  creada_en  timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select e.id, e.tipo,
           nullif(trim(coalesce(public.nombre_lindo(d.nombre_real), '') || ' ' ||
                       coalesce(public.nombre_lindo(d.apellido), '')), ''),
           d.email, d.nombre_sektario,
           public.nombre_lindo(te.nombre_real),
           public.nombre_lindo(cm.nombre_real),
           case
             when c.estado = 'rechazada'   then 'rechazada'
             when e.duenio is null         then 'sin_asignar'
             when e.enviada_en is not null then 'enviada'
             when c.id is null             then 'por_enviar'
             when c.estado = 'confirmada'  then 'por_enviar'
             else 'esperando'
           end,
           e.enviada_en, e.creada_en
      from public.entradas e
      left join public.compras  c  on c.id  = e.compra_id
      left join public.miembros d  on d.id  = e.duenio
      left join public.miembros te on te.id = e.tenedor
      left join public.miembros cm on cm.id = c.comprador
     order by
       -- primero lo que hay que hacer algo con ello
       case
         when e.duenio is not null and e.enviada_en is null
              and (c.id is null or c.estado = 'confirmada') then 0
         when e.duenio is null then 1
         else 2
       end,
       e.creada_en;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. enviar el QR, y poder deshacerlo
-- ----------------------------------------------------------------------------
-- Los QR se cargan a mano, de a uno, entre tres personas. Con eso, marcar la
-- fila equivocada no es una posibilidad remota: es cuestión de tiempo. Por eso
-- se puede deshacer — y queda anotado quién lo hizo.
create or replace function public.admin_marcar_enviada(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_duenio uuid;
begin
  update public.entradas e
     set enviada_en = now(), enviada_por = v_admin
   where e.id = p_entrada and e.duenio is not null and e.enviada_en is null
  returning e.duenio into v_duenio;

  if not found then raise exception 'entrada_no_enviable'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'enviar_qr', v_duenio, jsonb_build_object('entrada', p_entrada));

  return query select true;
end;
$$;


create or replace function public.admin_desmarcar_enviada(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_duenio uuid;
begin
  update public.entradas e
     set enviada_en = null, enviada_por = null
   where e.id = p_entrada and e.enviada_en is not null
  returning e.duenio into v_duenio;

  if not found then raise exception 'entrada_no_estaba_enviada'; end if;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'deshacer_envio_qr', v_duenio, jsonb_build_object('entrada', p_entrada));

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. staff y free
-- ----------------------------------------------------------------------------
-- No hay transferencia, no hay comprobante y no hay nada que confirmar: nacen
-- con dueño y listas para enviar. Lo único que sigue valiendo es el candado de
-- una persona, un QR.
create or replace function public.admin_dar_entrada(
  p_codigo text, p_a_quien uuid, p_tipo text
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  if p_tipo not in ('staff', 'free') then
    raise exception 'tipo_invalido';
  end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  if exists (select 1 from public.entradas e
              where e.evento = 'seki7' and e.duenio = p_a_quien) then
    raise exception 'ya_tiene_entrada';
  end if;

  insert into public.entradas (compra_id, tenedor, duenio, asignada_en, tipo)
  values (null, p_a_quien, p_a_quien, now(), p_tipo);

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'dar_entrada', p_a_quien, jsonb_build_object('tipo', p_tipo));

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 8. la compra que se arregló por afuera
-- ----------------------------------------------------------------------------
-- Pasa siempre: alguien escribe por WhatsApp, transfiere, y la compra nunca
-- tocó el portal. Esto la mete ya confirmada, con su tanda y su precio, y a
-- partir de ahí es idéntica a cualquier otra: el que compró reparte las
-- entradas desde su perfil, y nosotros mandamos los QR desde acá.
--
-- El motivo es obligatorio. Una compra confirmada sin comprobante tiene que
-- decir de dónde salió, o dentro de un mes nadie se acuerda.
create or replace function public.admin_cargar_compra(
  p_codigo text, p_comprador uuid, p_cantidad integer, p_motivo text
)
returns table (compra_id uuid) 
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_tanda  record;
  v_compra uuid;
  v_i      integer;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 7 then
    raise exception 'cantidad_invalida';
  end if;
  if v_motivo is null then raise exception 'falta_motivo'; end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_comprador and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  select t.id, t.precio, t.nombre into v_tanda
    from public.tandas t where t.activa limit 1;
  if v_tanda.id is null then raise exception 'sin_tanda'; end if;

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total,
                              estado, revisada_por, revisada_en, motivo)
  values (p_comprador, v_tanda.id, p_cantidad, v_tanda.precio,
          v_tanda.precio * p_cantidad, 'confirmada', v_admin, now(), v_motivo)
  returning compras.id into v_compra;

  for v_i in 1 .. p_cantidad loop
    insert into public.entradas (compra_id, tenedor, tipo)
    values (v_compra, p_comprador, v_tanda.nombre);
  end loop;

  perform public.apropiarse_una(v_compra, p_comprador);

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'cargar_compra', p_comprador,
          jsonb_build_object('cantidad', p_cantidad, 'motivo', v_motivo));

  return query select v_compra;
end;
$$;


-- ----------------------------------------------------------------------------
-- 9. buscar a quién darle una entrada, también desde el panel
-- ----------------------------------------------------------------------------
create or replace function public.admin_buscar_persona(p_codigo text, p_query text)
returns table (id uuid, sektario text, nombre text, ya_tiene boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_q text := btrim(coalesce(p_query, ''));
begin
  perform public.admin_id_de(p_codigo);
  if length(v_q) < 1 then return; end if;

  return query
    select m.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           exists (select 1 from public.entradas e
                    where e.duenio = m.id and e.evento = 'seki7')
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_real is not null
       and (m.nombre_sektario ilike '%' || v_q || '%'
         or m.nombre_real     ilike '%' || v_q || '%'
         or m.apellido        ilike '%' || v_q || '%')
     order by (m.nombre_real ilike v_q || '%' or m.nombre_sektario ilike v_q || '%') desc,
              m.nombre_real nulls last
     limit 8;
end;
$$;


-- ----------------------------------------------------------------------------
-- 10. los permisos
-- ----------------------------------------------------------------------------
drop function if exists public.admin_para_cargar(text);
drop function if exists public.admin_marcar_cargada(text, uuid);

revoke all on function public.apropiarse_una(uuid, uuid) from public, anon, authenticated;

grant execute on function public.admin_resumen_s7(text)                      to anon, authenticated;
grant execute on function public.admin_entradas_s7(text)                     to anon, authenticated;
grant execute on function public.admin_marcar_enviada(text, uuid)            to anon, authenticated;
grant execute on function public.admin_desmarcar_enviada(text, uuid)         to anon, authenticated;
grant execute on function public.admin_dar_entrada(text, uuid, text)         to anon, authenticated;
grant execute on function public.admin_cargar_compra(text, uuid, integer, text) to anon, authenticated;
grant execute on function public.admin_buscar_persona(text, text)            to anon, authenticated;
