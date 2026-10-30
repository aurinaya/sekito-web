-- ---------------------------------------------------------------------------
-- EL LINK DE VENTA (29/10)
--
-- Para vender por instagram sin hacer pasar a nadie por la llave y el registro
-- antes de comprar. El panel genera un link personal (sekito.ar/c/LLAVE): por
-- dentro es una llave del panel, de LA SEKTA, como "+ llave nueva", con la nota
-- "link de venta · <para quién>". Con ese link la persona:
--   1. compra sin registrarse: elige cuántas, ve el alias, deja su mail y sube
--      el comprobante (comprar_entradas y adjuntar_comprobante, de siempre);
--   2. cuando ustedes confirman, le llega "ya tenés tu entrada" con su link;
--   3. con el link completa sus datos (completar_registro) y entra al portal
--      con su entrada.
-- La entrada nace suya al confirmar (como cualquier compra), pero el código y
-- el QR solo se ven adentro, después de completar los datos.
-- ---------------------------------------------------------------------------

-- 1. el link: una llave del panel con su nota
create or replace function public.admin_link_de_venta(p_codigo text, p_para text)
returns table(codigo_acceso text)
language plpgsql security definer set search_path = public as $$
declare
  v_para text := nullif(btrim(coalesce(p_para, '')), '');
  v_m    record;
begin
  if v_para is null then raise exception 'falta_el_nombre'; end if;
  select * into v_m from public.admin_crear_miembro(p_codigo, 'link de venta · ' || left(v_para, 80), null);
  return query select v_m.codigo_acceso;
end;
$$;

-- 2. dónde está la persona del link: registrada o no, su mail, y si ya tiene
--    entradas (confirmadas) que la esperan
create or replace function public.venta_estado(p_codigo text)
returns table(registrado boolean, email text, entradas integer, para text)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select m.nombre_real is not null, m.email,
           (select count(*)::integer from public.entradas e
             where e.evento = 'seki7' and e.anulada_en is null and (e.duenio = v_yo or e.tenedor = v_yo)),
           case when m.nota_admin like 'link de venta · %' then substr(m.nota_admin, 17) end
      from public.miembros m where m.id = v_yo;
end;
$$;

-- 3. el mail, antes del comprobante (solo mientras no completó sus datos)
create or replace function public.guardar_mail_venta(p_codigo text, p_email text)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo   uuid := public.miembro_de(p_codigo);
  v_mail text := lower(btrim(coalesce(p_email, '')));
begin
  if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'mail_invalido'; end if;
  if exists (select 1 from public.miembros m where m.id = v_yo and m.nombre_real is not null) then
    raise exception 'registro_ya_completo';
  end if;
  update public.miembros m set email = v_mail where m.id = v_yo;   -- el disparador frena un mail repetido
  return query select true;
end;
$$;

-- 4. completar los datos: si ya tiene quién lo trajo (el link es de LA SEKTA),
--    no hace falta elegirlo
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
  v_cand       text;
  v_apodo      text := nullif(btrim(coalesce(p_apodo, '')), '');
  i            int;
begin
  select m.id, m.nombre_sektario, m.es_fundador, (m.nombre_real is not null), m.invitado_por
    into v_id, v_sektario, v_fundador, v_ya, v_trajo
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
        como_llegaste   = nullif(btrim(coalesce(p_como_llegaste, '')), ''),
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

-- 5. el mail de la confirmación para quien compró por link y todavía no
--    completó sus datos: sin código, con su link
create or replace function public.mail_venta_confirmada(p_baja uuid, p_llave text, p_cantidad integer)
returns text language sql immutable set search_path = public as $$
  select public.mail_sobre(
    '<tr><td style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden">'
    || 'la sekta vio tu comprobante. completá tus datos y vas a ver tu entrada.</td></tr>'
    || '<tr><td align="center" style="padding:0 0 14px">'
    || '<img src="https://www.sekito.ar/images/mail-s7.png" width="160" height="90" alt="S7" '
    || 'style="display:block;border:0;width:160px;height:90px"></td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:11px;line-height:2;letter-spacing:.26em;color:#F2F2F2;padding:0 0 30px">'
    || 'SÁBADO 14 · NOVIEMBRE<br>'
    || '<span style="color:#93A8AC;letter-spacing:.2em">PALERMO, BUENOS AIRES</span></td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:19px;letter-spacing:.12em;color:#F2F2F2;padding:0 0 12px">'
    || case when p_cantidad = 1 then 'YA TENÉS TU ENTRADA' else 'YA TENÉS TUS ENTRADAS' end || '</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:12px;line-height:1.9;color:#93A8AC;padding:0 0 30px">'
    || 'La sekta vio tu comprobante.<br>'
    || '<span style="color:#F2F2F2">Entrá con tu link, completá tus datos<br>y vas a ver '
    || case when p_cantidad = 1 then 'tu entrada' else 'tus ' || p_cantidad || ' entradas' end
    || ' en el portal.</span></td></tr>',
    p_baja, 'https://www.sekito.ar/c/' || p_llave,
    case when p_cantidad = 1 then 'ver mi entrada' else 'ver mis entradas' end);
$$;
revoke execute on function public.mail_venta_confirmada(uuid, text, integer) from public, anon, authenticated;

-- 6. confirmar una compra: igual que siempre; si quien compró todavía no
--    completó sus datos (compró por link), le llega el mail con su link
create or replace function public.admin_confirmar_compra(p_codigo text, p_compra uuid)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_c      record;
  v_i      integer;
  v_suyo   text;
  v_faltan integer;
  v_m      record;
  v_q      record;
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

  select m.nombre_real, m.codigo_acceso into v_m from public.miembros m where m.id = v_c.comprador;

  -- compró por link y todavía no completó sus datos: el mail con su link
  if v_m.nombre_real is null then
    select q.email, q.baja into v_q from public.a_quien_escribirle(v_c.comprador) q;
    if v_q.email is not null then
      perform public.encolar_mail(v_q.email,
        case when v_c.cantidad = 1 then 'ya tenés tu entrada para SEKI 7' else 'ya tenés tus entradas para SEKI 7' end,
        public.mail_venta_confirmada(v_q.baja, v_m.codigo_acceso, v_c.cantidad), 1::smallint);
    end if;
    return query select true;
    return;
  end if;

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
$$;

-- 7. en el panel, una compra por link sin datos todavía se ve con su nota y su llave
drop function if exists public.admin_compras(text, text);
create function public.admin_compras(p_codigo text, p_estado text default null)
returns table(compra_id uuid, comprador text, sektario text, email text, cantidad integer, total integer,
              tanda text, estado text, creada_en timestamp with time zone, tiene_comprobante boolean,
              sin_asignar integer, por_link text)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select c.id,
           coalesce(nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                                coalesce(public.nombre_lindo(m.apellido), '')), ''),
                    case when m.nota_admin like 'link de venta · %' then substr(m.nota_admin, 17) end, ''),
           m.nombre_sektario, m.email,
           c.cantidad, c.total, t.nombre, c.estado, c.creada_en,
           c.comprobante is not null,
           (select count(*)::integer from public.entradas e
             where e.compra_id = c.id and e.duenio is null),
           case when m.nombre_real is null and m.nota_admin like 'link de venta · %' then m.codigo_acceso end
      from public.compras c
      join public.miembros m on m.id = c.comprador
      join public.tandas   t on t.id = c.tanda_id
     where c.estado <> 'esperando_comprobante'
       and (p_estado is null or c.estado = p_estado)
     order by (c.estado = 'a_revisar') desc, c.creada_en;
end;
$$;
