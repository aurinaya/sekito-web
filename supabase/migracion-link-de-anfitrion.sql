-- ---------------------------------------------------------------------------
-- EL LINK DE ANFITRIÓN (29/10)
--
-- Para que alguien que cumple años traiga a su gente sin invitaciones ni
-- registro previo: sekito.ar/cumplefede. Quien lo abre ve la frase del cumple,
-- elige entre el precio del cumple (cuenta como hermética) y "bancás la fiesta"
-- (cuenta como abierta), deja nombre y mail, y sube el comprobante, todo en un
-- solo paso (anfitrion_comprar).
--   - Si el navegador ya tiene su llave, compra con ella: va a su cuenta.
--   - Si no, y el mail ya es de alguien del portal, la compra se suma a esa
--     cuenta sin decirle nada (el panel lo marca).
--   - Si no, nace un miembro nuevo, colgado del anfitrión. Al confirmar le
--     llega el mail con su link (/c/LLAVE), como en el link de venta.
-- El precio del cumple tiene un cupo (25 entradas); lleno, queda solo el otro.
-- ---------------------------------------------------------------------------

create table if not exists public.anfitriones (
  id            serial primary key,
  palabra       text not null unique check (palabra ~ '^[a-z0-9]{3,30}$'),
  anfitrion     uuid not null references public.miembros(id),
  frase         text not null check (char_length(frase) between 3 and 140),
  tanda_cumple  integer not null references public.tandas(id),
  tanda_bancar  integer not null references public.tandas(id),
  cupo          integer not null default 25 check (cupo between 0 and 500),
  hasta         timestamptz not null,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now()
);
alter table public.anfitriones enable row level security;

alter table public.compras  add column if not exists anfitrion_id   integer references public.anfitriones(id);
alter table public.compras  add column if not exists mail_ya_estaba boolean not null default false;
alter table public.miembros add column if not exists por_anfitrion  integer references public.anfitriones(id);

-- las palabras que ya usa el sitio (carpetas y links)
create or replace function public.palabra_reservada(p text)
returns boolean language sql immutable as $$
  select p = any (array['s7','arbol','puerta','admin','assets','images','fuentes','material','supabase',
                        'index','favicon','entrada','api','www','sekito','seki','colapso']);
$$;

-- cuántas entradas del cupo del cumple ya se fueron (las rechazadas vuelven)
create or replace function public.cupo_usado(p_anfitrion integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(c.cantidad), 0)::integer
    from public.compras c join public.anfitriones a on a.id = c.anfitrion_id
   where c.anfitrion_id = p_anfitrion and c.tanda_id = a.tanda_cumple
     and c.estado in ('a_revisar', 'confirmada');
$$;

-- 1. lo que ve cualquiera que abre el link
create or replace function public.anfitrion_publico(p_palabra text)
returns table(frase text, quien text, precio_cumple integer, precio_bancar integer,
              quedan integer, abierto boolean)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select a.frase, public.como_le_dicen(m.apodo, m.nombre_real),
           tc.precio, tb.precio,
           greatest(a.cupo - public.cupo_usado(a.id), 0),
           a.activo and now() < a.hasta
      from public.anfitriones a
      join public.miembros m  on m.id  = a.anfitrion
      join public.tandas   tc on tc.id = a.tanda_cumple
      join public.tandas   tb on tb.id = a.tanda_bancar
     where a.palabra = lower(btrim(coalesce(p_palabra, '')));
end;
$$;

-- 2. comprar: la compra nace con el comprobante adentro, lista para revisar
create or replace function public.anfitrion_comprar(p_palabra text, p_codigo text, p_nombre text, p_email text,
  p_cantidad integer, p_banca boolean, p_base64 text, p_tipo text)
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
  v_bytes  bytea;
  v_cod    text;
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
  if p_banca then
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_bancar;
  else
    if public.cupo_usado(v_a.id) + p_cantidad > v_a.cupo then raise exception 'sin_cupo'; end if;
    select * into v_tanda from public.tandas t where t.id = v_a.tanda_cumple;
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
      if (select count(*) from public.miembros m where m.por_anfitrion = v_a.id) >= 120 then
        raise exception 'muchos_pedidos';
      end if;
      v_cod := public.generar_codigo_acceso();
      insert into public.miembros (codigo_acceso, nota_admin, invitado_por, estado_codigo, email,
                                   como_llegaste, por_anfitrion)
      values (v_cod, v_a.palabra || ' · ' || v_nombre, v_a.anfitrion, 'activo', v_mail,
              'por el cumple de ' || (select public.como_le_dicen(m.apodo, m.nombre_real)
                                        from public.miembros m where m.id = v_a.anfitrion),
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
  values (v_yo, v_tanda.id, p_cantidad, v_tanda.precio, v_tanda.precio * p_cantidad,
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

-- 3. la llave de un link: si nació en un cumple, se comporta como el link de
--    venta (completa sus datos con el mail puesto), y dice quién lo trajo
drop function if exists public.venta_estado(text);
create function public.venta_estado(p_codigo text)
returns table(registrado boolean, email text, entradas integer, para text, nombre text, cumple text)
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
           (select public.como_le_dicen(q.apodo, q.nombre_real)
              from public.anfitriones a join public.miembros q on q.id = a.anfitrion
             where a.id = m.por_anfitrion)
      from public.miembros m where m.id = v_yo;
end;
$$;

-- 4. completar los datos: si ya tiene "cómo llegó" (el cumple), no se pierde
create or replace function public.completar_registro(p_codigo text, p_nombre text, p_apellido text, p_email text,
  p_telefono text, p_invitado_por uuid, p_como_llegaste text, p_apodo text default null)
returns table(nombre_sektario text, nombre_real text, pantalla text, fecha_ingreso timestamp with time zone,
              es_fundador boolean, invitado_por_nombre text, registro_completo boolean, apodo text)
language plpgsql security definer set search_path = public as $$
declare
  v_id         uuid;
  v_sektario   text;
  v_fundador   boolean;
  v_ya         boolean;
  v_trajo      uuid;
  v_como       text;
  v_cand       text;
  v_apodo      text := nullif(btrim(coalesce(p_apodo, '')), '');
  i            int;
begin
  select m.id, m.nombre_sektario, m.es_fundador, (m.nombre_real is not null), m.invitado_por, m.como_llegaste
    into v_id, v_sektario, v_fundador, v_ya, v_trajo, v_como
    from public.miembros m
   where m.codigo_acceso = upper(btrim(p_codigo))
     and m.estado_codigo = 'activo';

  if v_id is null then
    raise exception 'codigo_invalido';
  end if;

  if v_ya then
    raise exception 'registro_ya_completo';
  end if;

  if btrim(coalesce(p_nombre, ''))   = '' or btrim(coalesce(p_apellido, '')) = ''
  or btrim(coalesce(p_email, ''))    = '' or btrim(coalesce(p_telefono, '')) = '' then
    raise exception 'faltan_datos';
  end if;

  if v_apodo is not null and char_length(v_apodo) > 24 then
    raise exception 'apodo_largo';
  end if;

  -- a los fundadores no los trajo nadie; al resto sí (o ya viene puesto)
  if not v_fundador and p_invitado_por is null and v_trajo is null then
    raise exception 'falta_invitado_por';
  end if;

  for i in 1..50 loop
    begin
      if v_sektario is null then
        v_cand := public.generar_nombre_sektario(p_nombre, p_apellido);
      else
        v_cand := v_sektario;
      end if;

      update public.miembros m set
        nombre_real     = btrim(p_nombre),
        apellido        = btrim(p_apellido),
        email           = btrim(p_email),
        telefono        = btrim(p_telefono),
        invitado_por    = coalesce(p_invitado_por, v_trajo),
        como_llegaste   = coalesce(nullif(btrim(coalesce(p_como_llegaste, '')), ''), v_como),
        apodo           = v_apodo,
        nombre_sektario = v_cand
      where m.id = v_id;

      exit;  -- salió bien
    exception when unique_violation then
      if v_sektario is not null then
        raise;
      end if;
    end;
  end loop;

  return query
    select m.nombre_sektario,
           m.nombre_real,
           m.pantalla,
           m.fecha_ingreso,
           m.es_fundador,
           quien.nombre_sektario,
           true,
           m.apodo
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_id;
end;
$$;

-- 5. el panel: crear, ver y pausar
create or replace function public.admin_crear_anfitrion(p_codigo text, p_palabra text, p_anfitrion uuid,
  p_frase text, p_cupo integer, p_hasta timestamptz)
returns table(id integer, palabra text)
language plpgsql security definer set search_path = public as $$
declare
  v_admin   uuid := public.admin_id_de(p_codigo);
  v_palabra text := lower(btrim(coalesce(p_palabra, '')));
  v_id      integer;
begin
  if v_palabra !~ '^[a-z0-9]{3,30}$' then raise exception 'palabra_invalida'; end if;
  if public.palabra_reservada(v_palabra) then raise exception 'palabra_reservada'; end if;
  if exists (select 1 from public.anfitriones a where a.palabra = v_palabra) then raise exception 'palabra_usada'; end if;
  if not exists (select 1 from public.miembros m where m.id = p_anfitrion and m.nombre_real is not null) then
    raise exception 'anfitrion_invalido';
  end if;
  if char_length(btrim(coalesce(p_frase, ''))) < 3 then raise exception 'falta_frase'; end if;

  insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta)
  values (v_palabra, p_anfitrion, btrim(p_frase),
          (select t.id from public.tandas t where t.nombre = 'hermética'),
          (select t.id from public.tandas t where t.nombre = 'abierta'),
          coalesce(p_cupo, 25), p_hasta)
  returning anfitriones.id into v_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'crear_anfitrion', p_anfitrion, jsonb_build_object('palabra', v_palabra));

  return query select v_id, v_palabra;
end;
$$;

create or replace function public.admin_anfitriones(p_codigo text)
returns table(id integer, palabra text, quien text, sektario text, frase text, cupo integer, usado integer,
              bancaron integer, hasta timestamptz, activo boolean, compras jsonb)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select a.id, a.palabra, public.como_le_dicen(m.apodo, m.nombre_real), m.nombre_sektario, a.frase,
           a.cupo, public.cupo_usado(a.id),
           (select coalesce(sum(c.cantidad), 0)::integer from public.compras c
             where c.anfitrion_id = a.id and c.tanda_id = a.tanda_bancar and c.estado in ('a_revisar', 'confirmada')),
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
                      where c.anfitrion_id = a.id), '[]'::jsonb)
      from public.anfitriones a join public.miembros m on m.id = a.anfitrion
     order by a.creado_en desc;
end;
$$;

create or replace function public.admin_pausar_anfitrion(p_codigo text, p_id integer, p_activo boolean)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  update public.anfitriones a set activo = p_activo where a.id = p_id;
  if not found then raise exception 'no_existe'; end if;
  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, case when p_activo then 'reanudar_anfitrion' else 'pausar_anfitrion' end,
          jsonb_build_object('anfitrion', p_id));
  return query select true;
end;
$$;

-- 6. en las transferencias: de qué cumple vino, y si el mail ya era de alguien
drop function if exists public.admin_compras(text, text);
create function public.admin_compras(p_codigo text, p_estado text default null)
returns table(compra_id uuid, comprador text, sektario text, email text, cantidad integer, total integer,
              tanda text, estado text, creada_en timestamp with time zone, tiene_comprobante boolean,
              sin_asignar integer, por_link text, anfitrion text, mail_ya_estaba boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select c.id,
           coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(m.apellido), '')), ''),
                    case when m.nota_admin like 'link de venta · %' then substr(m.nota_admin, 17)
                         when m.por_anfitrion is not null then substr(m.nota_admin, strpos(m.nota_admin, ' · ') + 3) end, ''),
           m.nombre_sektario, m.email,
           c.cantidad, c.total, t.nombre, c.estado, c.creada_en,
           c.comprobante is not null,
           (select count(*)::integer from public.entradas e
             where e.compra_id = c.id and e.duenio is null),
           case when m.nombre_real is null and (m.nota_admin like 'link de venta · %' or m.por_anfitrion is not null)
                then m.codigo_acceso end,
           a.palabra,
           c.mail_ya_estaba
      from public.compras c
      join public.miembros m on m.id = c.comprador
      join public.tandas   t on t.id = c.tanda_id
      left join public.anfitriones a on a.id = c.anfitrion_id
     where c.estado <> 'esperando_comprobante'
       and (p_estado is null or c.estado = p_estado)
     order by (c.estado = 'a_revisar') desc, c.creada_en;
end;
$$;

revoke execute on function public.cupo_usado(integer) from public, anon, authenticated;
grant execute on function public.anfitrion_publico(text) to anon, authenticated;
grant execute on function public.anfitrion_comprar(text, text, text, text, integer, boolean, text, text) to anon, authenticated;
grant execute on function public.venta_estado(text) to anon, authenticated;
grant execute on function public.admin_crear_anfitrion(text, text, uuid, text, integer, timestamptz) to anon, authenticated;
grant execute on function public.admin_anfitriones(text) to anon, authenticated;
grant execute on function public.admin_pausar_anfitrion(text, integer, boolean) to anon, authenticated;
grant execute on function public.admin_compras(text, text) to anon, authenticated;
