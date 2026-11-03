-- ---------------------------------------------------------------------------
-- LO QUE CADA UNO PUEDE (02/11)
--
-- sekito.ar/tano, para su cumple: abajo de todo, "puedo con esto" con cuatro
-- botones (10, 15, 20 y 25 mil) que compran de verdad. Una entrada por
-- persona y un cupo de 20; cuando se llena, los botones desaparecen. Cuenta
-- como la tanda abierta, registrada al precio que eligió (como el remil).
-- Los demás links no cambian: aportes queda vacío.
-- ---------------------------------------------------------------------------

alter table public.anfitriones add column if not exists aportes     integer[];
alter table public.anfitriones add column if not exists cupo_aporte integer not null default 0 check (cupo_aporte >= 0);

create or replace function public.aportes_usados(p_anfitrion integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(c.cantidad), 0)::integer
    from public.compras c join public.anfitriones a on a.id = c.anfitrion_id
   where c.anfitrion_id = p_anfitrion and c.precio_unitario = any(coalesce(a.aportes, '{}'))
     and c.tanda_id = a.tanda_bancar and c.estado in ('a_revisar', 'confirmada');
$$;

-- 1. lo que ve cualquiera que abre el link
drop function if exists public.anfitrion_publico(text);
create function public.anfitrion_publico(p_palabra text)
returns table(frase text, quien text, precio_cumple integer, precio_bancar integer,
              quedan integer, abierto boolean,
              es_cumple boolean, foto text, instagram text, precio_remil integer,
              aportes integer[], quedan_aporte integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select a.frase, coalesce(a.quien_dice, public.como_le_dicen(m.apodo, m.nombre_real)),
           tc.precio, tb.precio,
           greatest(a.cupo - public.cupo_usado(a.id), 0),
           a.activo and now() < a.hasta,
           a.es_cumple, a.foto, a.instagram, a.precio_remil,
           a.aportes, greatest(a.cupo_aporte - public.aportes_usados(a.id), 0)
      from public.anfitriones a
      join public.miembros m  on m.id  = a.anfitrion
      join public.tandas   tc on tc.id = a.tanda_cumple
      join public.tandas   tb on tb.id = a.tanda_bancar
     where a.palabra = lower(btrim(coalesce(p_palabra, '')));
end;
$$;

-- 2. comprar: suma el aporte
drop function if exists public.anfitrion_comprar(text, text, text, text, integer, boolean, text, text, boolean);
create function public.anfitrion_comprar(p_palabra text, p_codigo text, p_nombre text, p_email text,
  p_cantidad integer, p_banca boolean, p_base64 text, p_tipo text, p_remil boolean default false,
  p_aporte integer default null)
returns table(ok boolean, email text)
language plpgsql security definer set search_path = public as $$
declare
  v_a      record;
  v_yo     uuid;
  v_ya     boolean := false;
  v_reg    boolean;
  v_mail   text := lower(btrim(coalesce(p_email, '')));
  v_nombre text := btrim(coalesce(p_nombre, ''));
  v_tanda  record;
  v_precio integer;
  v_bytes  bytea;
  v_cod    text;
  v_quien  text;
begin
  select * into v_a from public.anfitriones a
   where a.palabra = lower(btrim(coalesce(p_palabra, ''))) for update;
  if v_a.id is null then raise exception 'no_existe'; end if;
  if not v_a.activo or now() >= v_a.hasta then raise exception 'cerrado'; end if;

  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 7 then raise exception 'cantidad_invalida'; end if;

  if coalesce(btrim(p_base64), '') = '' then raise exception 'sin_comprobante'; end if;
  v_bytes := decode(p_base64, 'base64');
  if octet_length(v_bytes) > 3000000 then raise exception 'comprobante_pesado'; end if;

  -- el precio: el del cumple mientras quede cupo
  if p_aporte is not null then
    -- lo que cada uno puede (sekito.ar/tano): uno por persona, mientras quede cupo
    if v_a.aportes is null or not (p_aporte = any(v_a.aportes)) then raise exception 'precio_invalido'; end if;
    if p_cantidad <> 1 then raise exception 'cantidad_invalida'; end if;
    if public.aportes_usados(v_a.id) >= v_a.cupo_aporte then raise exception 'sin_aportes'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := p_aporte;
  elsif coalesce(p_remil, false) then
    if v_a.precio_remil is null then raise exception 'precio_invalido'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := v_a.precio_remil;
  elsif p_banca then
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
    v_precio := v_tanda.precio;
  else
    if public.cupo_usado(v_a.id) + p_cantidad > v_a.cupo then raise exception 'sin_cupo'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_cumple;
    v_precio := v_tanda.precio;
  end if;

  -- quién compra: su llave, su mail, o alguien nuevo
  if nullif(btrim(coalesce(p_codigo, '')), '') is not null then
    v_yo := public.miembro_de(p_codigo);
  else
    if v_nombre = '' then raise exception 'falta_nombre'; end if;
    if char_length(v_nombre) > 60 then raise exception 'nombre_largo'; end if;
    if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'mail_invalido'; end if;

    select m.id, m.nombre_real is not null into v_yo, v_reg
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico') and lower(btrim(m.email)) = v_mail
     limit 1;

    if v_yo is not null then
      v_ya := v_reg;     -- solo se marca si ya era de la sekta de verdad
    else
      -- un freno para que nadie llene la base desde afuera
      if (select count(*) from public.miembros m where m.por_anfitrion = v_a.id) >= (case when v_a.es_cumple then 120 else 2000 end) then
        raise exception 'muchos_pedidos';
      end if;
      select coalesce(v_a.quien_dice, public.como_le_dicen(m.apodo, m.nombre_real)) into v_quien
        from public.miembros m where m.id = v_a.anfitrion;
      v_cod := public.generar_codigo_acceso();
      insert into public.miembros (codigo_acceso, nota_admin, invitado_por, estado_codigo, email,
                                   como_llegaste, por_anfitrion)
      values (v_cod, v_a.palabra || ' · ' || v_nombre, v_a.anfitrion, 'activo', v_mail,
              case when v_a.es_cumple then 'por el cumple de ' else 'por ' end || v_quien,
              v_a.id)
      returning miembros.id into v_yo;
    end if;
  end if;

  if p_aporte is not null and exists (
       select 1 from public.compras c
        where c.comprador = v_yo and c.anfitrion_id = v_a.id and c.estado in ('a_revisar', 'confirmada')
          and c.precio_unitario = any(v_a.aportes)) then
    raise exception 'ya_aportaste';
  end if;

  -- dos compras en revisión por persona alcanzan
  if (select count(*) from public.compras c where c.comprador = v_yo and c.estado = 'a_revisar') >= 2 then
    raise exception 'ya_hay_compras';
  end if;

  insert into public.compras (comprador, tanda_id, cantidad, precio_unitario, total,
                              comprobante, comprobante_tipo, estado, anfitrion_id, mail_ya_estaba)
  values (v_yo, v_tanda.id, p_cantidad, v_precio, v_precio * p_cantidad,
          v_bytes, coalesce(nullif(btrim(p_tipo), ''), 'image/jpeg'), 'a_revisar', v_a.id, v_ya);

  -- el mail de "llegó" solo a quien ya está en el portal; al nuevo le llega
  -- su link cuando se confirme
  if exists (select 1 from public.miembros m where m.id = v_yo and m.nombre_real is not null) then
    perform public.mail_de_preventa(
      v_yo, 'seki 7', 'TU COMPROBANTE LLEGÓ',
      'La sekta lo va a mirar.<br>Cuando esté confirmado, te escribimos de nuevo.',
      'la sekta tiene tu comprobante');
  end if;

  return query select true,
    case when nullif(btrim(coalesce(p_codigo, '')), '') is null then v_mail end;
end;
$$;

-- 3. el panel: cuántos aportaron
drop function if exists public.admin_anfitriones(text);
create function public.admin_anfitriones(p_codigo text)
returns table(id integer, palabra text, quien text, sektario text, frase text, cupo integer, usado integer,
              bancaron integer, hasta timestamptz, activo boolean, compras jsonb,
              es_cumple boolean, remil integer, precio_remil integer, aportaron integer)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select a.id, a.palabra, public.como_le_dicen(m.apodo, m.nombre_real), m.nombre_sektario, a.frase,
           a.cupo, public.cupo_usado(a.id),
           (select coalesce(sum(c.cantidad), 0)::integer from public.compras c
             where c.anfitrion_id = a.id and c.tanda_id = a.tanda_bancar and c.estado in ('a_revisar', 'confirmada')
               and c.precio_unitario is distinct from a.precio_remil
               and not (c.precio_unitario = any(coalesce(a.aportes, '{}')))),
           a.hasta, a.activo,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'nombre', coalesce(nullif(btrim(coalesce(public.nombre_lindo(b.nombre_real), '') || ' ' ||
                                                       coalesce(public.nombre_lindo(b.apellido), '')), ''),
                                          substr(b.nota_admin, strpos(b.nota_admin, ' · ') + 3)),
                       'sektario', b.nombre_sektario,
                       'cantidad', c.cantidad, 'precio', c.precio_unitario, 'estado', c.estado,
                       'ya_estaba', c.mail_ya_estaba, 'nuevo', b.por_anfitrion = a.id)
                     order by c.creada_en desc)
                       from public.compras c join public.miembros b on b.id = c.comprador
                      where c.anfitrion_id = a.id), '[]'::jsonb),
           a.es_cumple,
           (select coalesce(sum(c.cantidad), 0)::integer from public.compras c
             where c.anfitrion_id = a.id and c.precio_unitario = a.precio_remil and c.estado in ('a_revisar', 'confirmada')),
           a.precio_remil,
           public.aportes_usados(a.id)
      from public.anfitriones a join public.miembros m on m.id = a.anfitrion
     order by a.creado_en desc;
end;
$$;

grant execute on function public.anfitrion_publico(text) to anon, authenticated;
grant execute on function public.anfitrion_comprar(text, text, text, text, integer, boolean, text, text, boolean, integer) to anon, authenticated;
grant execute on function public.admin_anfitriones(text) to anon, authenticated;

-- el link del Tano
update public.anfitriones set aportes = '{10000,15000,20000,25000}', cupo_aporte = 20 where palabra = 'tano';
