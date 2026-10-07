-- ============================================================================
-- SÉKITO — tercera vuelta: entradas fantasma y quién manda sobre una entrada
-- ============================================================================
-- 1) EL ERROR DE LAS ENTRADAS FANTASMA
--
-- `comprar_entradas` creaba las entradas en el momento de elegir la cantidad,
-- antes de que existiera ningún comprobante. Alguien que entra, pone 2 y se
-- va sin subir nada dejaba dos entradas dando vueltas: aparecían en su perfil
-- como "sin asignar" y en el panel entre las que hay que repartir.
--
-- Por eso la pantalla mostraba 6 entradas y 4 vendidas: las otras 2 eran de
-- una compra que nunca pasó de la intención. El número de vendidas siempre
-- estuvo bien; lo que estaba mal era que esas dos existieran.
--
-- Ahora una entrada nace cuando hay un comprobante que la respalda. Elegir
-- la cantidad no crea nada.
--
-- 2) QUIÉN MANDA SOBRE UNA ENTRADA ASIGNADA
--
-- Hasta acá el que compró podía sacarle la entrada a quien se la había dado.
-- Pero a esa persona ya le llegó un mail diciéndole que tiene su lugar. Un
-- regalo que el que lo dio puede deshacer no es un regalo.
--
-- Desde ahora: asignar es un viaje de ida. Una vez que la entrada tiene
-- dueño, el único que puede soltarla es el dueño — y cuando la suelta, queda
-- en sus manos para dársela a quien quiera.
--
-- Para el caso que esto deja sin salida (asignársela a la persona equivocada)
-- hay una puerta en el panel, que no depende de que nadie devuelva nada.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. elegir la cantidad no crea nada
-- ----------------------------------------------------------------------------
create or replace function public.comprar_entradas(p_codigo text, p_cantidad integer)
returns table (compra_id uuid, precio_unitario integer, total integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo     uuid := public.miembro_de(p_codigo);
  v_tanda  record;
  v_compra uuid;
begin
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 7 then
    raise exception 'cantidad_invalida';
  end if;

  select t.id, t.precio, t.nombre into v_tanda
    from public.tandas t where t.activa limit 1;

  if v_tanda.id is null then raise exception 'sin_tanda'; end if;

  -- la anterior a medio hacer se descarta, y con ella sus entradas
  delete from public.compras c
   where c.comprador = v_yo and c.estado = 'esperando_comprobante';

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total)
  values (v_yo, v_tanda.id, p_cantidad, v_tanda.precio, v_tanda.precio * p_cantidad)
  returning compras.id into v_compra;

  return query select v_compra, v_tanda.precio, v_tanda.precio * p_cantidad;
end;
$$;


-- ----------------------------------------------------------------------------
-- 2. las entradas nacen con el comprobante
-- ----------------------------------------------------------------------------
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
  v_yo     uuid := public.miembro_de(p_codigo);
  v_bytes  bytea;
  v_c      record;
  v_i      integer;
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
     and c.estado in ('esperando_comprobante', 'a_revisar')
  returning c.cantidad, c.tanda_id into v_c;

  if not found then raise exception 'compra_no_encontrada'; end if;

  -- sólo la primera vez: volver a subir el comprobante no duplica entradas
  if not exists (select 1 from public.entradas e where e.compra_id = p_compra) then
    for v_i in 1 .. v_c.cantidad loop
      insert into public.entradas (compra_id, tenedor, tipo)
      select p_compra, v_yo, t.nombre from public.tandas t where t.id = v_c.tanda_id;
    end loop;

    perform public.apropiarse_una(p_compra, v_yo);
  end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. asignar es un viaje de ida
-- ----------------------------------------------------------------------------
-- Antes pedía sólo ser el tenedor. Ahora pide además que no tenga dueño: si
-- ya se la diste a alguien, esa entrada dejó de ser tuya.
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

  if v_e.id is null       then raise exception 'no_sos_tenedor'; end if;
  if v_e.duenio is not null then raise exception 'ya_tiene_duenio'; end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  if exists (select 1 from public.entradas e
              where e.evento = v_e.evento and e.duenio = p_a_quien) then
    raise exception 'ya_tiene_entrada';
  end if;

  update public.entradas e
     set duenio = p_a_quien, asignada_en = now()
   where e.id = p_entrada;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. soltar la entrada propia
-- ----------------------------------------------------------------------------
-- Sólo el dueño, y sólo antes de que el QR haya salido. Al soltarla queda en
-- sus manos, no vuelve al que la compró: si se la dio, se la dio.
create or replace function public.soltar_entrada(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  update public.entradas e
     set duenio = null, asignada_en = null, tenedor = v_yo, pasada_por = null
   where e.id = p_entrada
     and e.duenio = v_yo
     and e.enviada_en is null;

  if not found then raise exception 'no_se_puede_soltar'; end if;

  return query select true;
end;
$$;

drop function if exists public.sacar_asignacion(text, uuid);


-- ----------------------------------------------------------------------------
-- 5. la puerta del panel
-- ----------------------------------------------------------------------------
-- La única salida cuando alguien se la asignó a la persona equivocada. La
-- entrada vuelve a manos del que la compró, no de quien la tenía por error.
create or replace function public.admin_soltar_entrada(p_codigo text, p_entrada uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_e     record;
  v_vuelve uuid;
begin
  select e.id, e.duenio, e.tenedor, e.compra_id into v_e
    from public.entradas e where e.id = p_entrada and e.duenio is not null;

  if v_e.id is null then raise exception 'no_estaba_asignada'; end if;

  select coalesce(c.comprador, v_e.tenedor) into v_vuelve
    from public.compras c where c.id = v_e.compra_id;

  update public.entradas e
     set duenio = null, asignada_en = null, enviada_en = null, enviada_por = null,
         tenedor = coalesce(v_vuelve, e.tenedor), pasada_por = null
   where e.id = p_entrada;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'soltar_entrada', v_e.duenio, jsonb_build_object('entrada', p_entrada));

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. el resumen, con los tres tipos sumando al total
-- ----------------------------------------------------------------------------
-- cambia la forma de lo que devuelve, así que hay que soltarla primero
drop function if exists public.admin_resumen_s7(text);

create or replace function public.admin_resumen_s7(p_codigo text)
returns table (
  vendidas          integer,
  staff             integer,
  free              integer,
  total             integer,
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
      (select count(*)::integer from public.entradas e
         join public.compras c on c.id = e.compra_id
        where c.estado = 'confirmada'),
      (select count(*)::integer from public.entradas e where e.tipo = 'staff'),
      (select count(*)::integer from public.entradas e where e.tipo = 'free'),
      -- el total es lo que va a entrar por la puerta: vendidas + staff + free
      (select count(*)::integer from public.entradas e
         left join public.compras c on c.id = e.compra_id
        where c.id is null or c.estado = 'confirmada'),
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
-- 7. los permisos
-- ----------------------------------------------------------------------------
grant execute on function public.soltar_entrada(text, uuid)       to anon, authenticated;
grant execute on function public.admin_soltar_entrada(text, uuid) to anon, authenticated;
