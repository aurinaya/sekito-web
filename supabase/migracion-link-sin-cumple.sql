-- ---------------------------------------------------------------------------
-- EL LINK DE ANFITRIÓN, SIN CUMPLE (31/10)
--
-- sekito.ar/mau y sekito.ar/tano: la misma base que el link del cumple, para
-- que cada uno empuje a su gente. Cambia lo que se ve: su foto, su frase, un
-- tercer precio ("remil banco", que cuenta como abierta pero se registra a 50)
-- y abajo de todo el botón QUIERO UN FREE, que abre su MD de Instagram.
--
-- Los links del cumple siguen igual: es_cumple queda en true y lo demás vacío.
-- Las filas de los dos links están aparte, en links-mau-y-tano.sql: se cargan
-- recién cuando el sitio ya sabe mostrarlos.
-- ---------------------------------------------------------------------------

alter table public.anfitriones add column if not exists es_cumple    boolean not null default true;
alter table public.anfitriones add column if not exists quien_dice   text check (char_length(quien_dice) between 2 and 30);
alter table public.anfitriones add column if not exists foto         text check (foto ~ '^[a-z0-9-]{3,30}$');
alter table public.anfitriones add column if not exists instagram    text check (instagram ~ '^[a-z0-9._]{1,30}$');
alter table public.anfitriones add column if not exists precio_remil integer check (precio_remil > 0);

-- 1. lo que ve cualquiera que abre el link
drop function if exists public.anfitrion_publico(text);
create function public.anfitrion_publico(p_palabra text)
returns table(frase text, quien text, precio_cumple integer, precio_bancar integer,
              quedan integer, abierto boolean,
              es_cumple boolean, foto text, instagram text, precio_remil integer)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select a.frase, coalesce(a.quien_dice, public.como_le_dicen(m.apodo, m.nombre_real)),
           tc.precio, tb.precio,
           greatest(a.cupo - public.cupo_usado(a.id), 0),
           a.activo and now() < a.hasta,
           a.es_cumple, a.foto, a.instagram, a.precio_remil
      from public.anfitriones a
      join public.miembros m  on m.id  = a.anfitrion
      join public.tandas   tc on tc.id = a.tanda_cumple
      join public.tandas   tb on tb.id = a.tanda_bancar
     where a.palabra = lower(btrim(coalesce(p_palabra, '')));
end;
$$;

-- 2. comprar: suma "remil banco". Cuenta como la tanda de bancar, a su precio
drop function if exists public.anfitrion_comprar(text, text, text, text, integer, boolean, text, text);
create function public.anfitrion_comprar(p_palabra text, p_codigo text, p_nombre text, p_email text,
  p_cantidad integer, p_banca boolean, p_base64 text, p_tipo text, p_remil boolean default false)
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
  if coalesce(p_remil, false) then
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

-- 3. la llave de un link: quién lo trajo, y si fue por un cumple
drop function if exists public.venta_estado(text);
create function public.venta_estado(p_codigo text)
returns table(registrado boolean, email text, entradas integer, para text, nombre text, cumple text, es_cumple boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select m.nombre_real is not null, m.email,
           (select count(*)::integer from public.entradas e
             where e.evento = 'seki7' and e.anulada_en is null and (e.duenio = v_yo or e.tenedor = v_yo)),
           case when m.nota_admin like 'link de venta · %' then substr(m.nota_admin, 17)
                when m.por_anfitrion is not null then m.nota_admin end,
           case when m.por_anfitrion is not null then substr(m.nota_admin, strpos(m.nota_admin, ' · ') + 3) end,
           (select coalesce(a.quien_dice, public.como_le_dicen(q.apodo, q.nombre_real))
              from public.anfitriones a join public.miembros q on q.id = a.anfitrion
             where a.id = m.por_anfitrion),
           (select a.es_cumple from public.anfitriones a where a.id = m.por_anfitrion)
      from public.miembros m where m.id = v_yo;
end;
$$;

-- 4. el panel: cuántas a cada precio
drop function if exists public.admin_anfitriones(text);
create function public.admin_anfitriones(p_codigo text)
returns table(id integer, palabra text, quien text, sektario text, frase text, cupo integer, usado integer,
              bancaron integer, hasta timestamptz, activo boolean, compras jsonb,
              es_cumple boolean, remil integer, precio_remil integer)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select a.id, a.palabra, public.como_le_dicen(m.apodo, m.nombre_real), m.nombre_sektario, a.frase,
           a.cupo, public.cupo_usado(a.id),
           (select coalesce(sum(c.cantidad), 0)::integer from public.compras c
             where c.anfitrion_id = a.id and c.tanda_id = a.tanda_bancar and c.estado in ('a_revisar', 'confirmada')
               and c.precio_unitario is distinct from a.precio_remil),
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
           a.precio_remil
      from public.anfitriones a join public.miembros m on m.id = a.anfitrion
     order by a.creado_en desc;
end;
$$;

grant execute on function public.anfitrion_publico(text) to anon, authenticated;
grant execute on function public.anfitrion_comprar(text, text, text, text, integer, boolean, text, text, boolean) to anon, authenticated;
grant execute on function public.venta_estado(text) to anon, authenticated;
grant execute on function public.admin_anfitriones(text) to anon, authenticated;
