-- ---------------------------------------------------------------------------
-- LA ENTRADA TRAE A LA PERSONA (21/10)
--
-- Quien compró varias y quiere darle una a alguien que todavía no está en el
-- portal, le manda su invitación CON la entrada: la entrada queda guardada
-- para esa invitación y, cuando la persona entra al sékito con ella, pasa a
-- su nombre sola (los disparadores de siempre le ponen el código y le mandan
-- el mail). El filtro sigue siendo el miembro que invita.
--
-- Si la invitación se vence, se revoca o se usa sin que la entrada pase, la
-- entrada vuelve a estar sin asignar: no hay que limpiar nada, "guardada" se
-- calcula mirando la invitación.
--
--   invitar_con_entrada(llave, entrada, para) → el código de la invitación
--     (si ya estaba guardada, devuelve la misma: "mandar de nuevo")
--   soltar_invitacion_de_entrada(llave, entrada) → la revoca y la entrada vuelve
-- ---------------------------------------------------------------------------

alter table public.entradas
  add column if not exists para_invitacion uuid references public.invitaciones(id);

-- ¿la entrada sigue guardada para una invitación que todavía sirve?
create or replace function public.invitacion_viva(p_inv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invitaciones i
                  where i.id = p_inv and not i.usada and not i.revocada and i.vence_en > now());
$$;
revoke execute on function public.invitacion_viva(uuid) from public, anon, authenticated;

create or replace function public.invitar_con_entrada(p_codigo text, p_entrada uuid, p_para text)
returns table(codigo text, vence_en timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_e   record;
  v_inv record;
begin
  if now() >= public.cierre_de_cambios() then raise exception 'cambios_cerrados'; end if;

  select e.* into v_e from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo and e.anulada_en is null
   for update;
  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;
  if v_e.duenio is not null or v_e.externo_nombre is not null then raise exception 'ya_tiene_duenio'; end if;

  -- ya estaba guardada y la invitación sirve: la misma, para volver a mandarla
  if v_e.para_invitacion is not null and public.invitacion_viva(v_e.para_invitacion) then
    return query select i.codigo, i.vence_en from public.invitaciones i where i.id = v_e.para_invitacion;
    return;
  end if;

  -- una invitación como cualquier otra (cuenta en el tope de las abiertas)
  select * into v_inv from public.crear_invitacion(p_codigo, coalesce(nullif(btrim(p_para), ''), 'con entrada'));

  update public.entradas e
     set para_invitacion = (select i.id from public.invitaciones i where i.codigo = v_inv.codigo)
   where e.id = p_entrada;

  return query select v_inv.codigo, v_inv.vence_en;
end;
$$;

create or replace function public.soltar_invitacion_de_entrada(p_codigo text, p_entrada uuid)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_e  record;
begin
  select e.* into v_e from public.entradas e
   where e.id = p_entrada and e.tenedor = v_yo and e.anulada_en is null and e.duenio is null;
  if v_e.id is null then raise exception 'no_sos_tenedor'; end if;

  if v_e.para_invitacion is not null then
    update public.invitaciones i set revocada = true, revocada_en = now()
     where i.id = v_e.para_invitacion and not i.usada;
    update public.entradas e set para_invitacion = null where e.id = p_entrada;
  end if;
  return query select true;
end;
$$;

-- asignar a alguien de adentro: si estaba guardada para una invitación viva,
-- primero hay que soltarla (el portal no lo ofrece mientras está guardada)
create or replace function public.asignar_entrada(p_codigo text, p_entrada uuid, p_a_quien uuid)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
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
  if v_e.para_invitacion is not null and public.invitacion_viva(v_e.para_invitacion) then
    raise exception 'guardada_para_invitacion';
  end if;

  if not exists (select 1 from public.miembros m
                  where m.id = p_a_quien and m.estado_codigo = 'activo') then
    raise exception 'persona_invalida';
  end if;

  if exists (select 1 from public.entradas e
              where e.evento = v_e.evento and e.duenio = p_a_quien and e.anulada_en is null) then
    raise exception 'ya_tiene_entrada';
  end if;

  update public.entradas e
     set duenio = p_a_quien, asignada_en = now(), para_invitacion = null
   where e.id = p_entrada;

  return query select true;
end;
$$;

-- al entrar con la invitación: si traía una entrada, pasa a su nombre
create or replace function public.registrar_con_invitacion(p_invitacion text, p_nombre text, p_apellido text,
  p_email text, p_telefono text, p_como_llegaste text default null, p_apodo text default null)
returns table(codigo_acceso text, nombre_sektario text, nombre_real text, pantalla text,
              fecha_ingreso timestamp with time zone, es_fundador boolean, invitado_por_nombre text,
              registro_completo boolean, apodo text)
language plpgsql security definer set search_path = public as $$
declare
  v_inv       uuid;
  v_referente uuid;
  v_estado    record;
  v_nuevo     uuid;
  v_cod       text;
  v_apodo     text := nullif(btrim(coalesce(p_apodo, '')), '');
  v_i         int;
begin
  if nullif(btrim(coalesce(p_nombre,   '')), '') is null
  or nullif(btrim(coalesce(p_apellido, '')), '') is null
  or nullif(btrim(coalesce(p_email,    '')), '') is null
  or nullif(btrim(coalesce(p_telefono, '')), '') is null then
    raise exception 'faltan_datos';
  end if;

  if v_apodo is not null and char_length(v_apodo) > 24 then
    raise exception 'apodo_largo';
  end if;

  -- buscar y gastar, todo junto
  update public.invitaciones i
     set usada = true, usada_en = now()
   where i.codigo   = upper(btrim(coalesce(p_invitacion, '')))
     and i.usada    = false
     and i.revocada = false
     and i.vence_en > now()
  returning i.id, i.generada_por into v_inv, v_referente;

  if v_inv is null then
    -- no se pudo gastar: averiguar por qué, para poder explicarlo
    select i.usada, i.revocada, (i.vence_en <= now()) as vencida
      into v_estado
      from public.invitaciones i
     where i.codigo = upper(btrim(coalesce(p_invitacion, '')));

    if not found             then raise exception 'invitacion_no_existe';
    elsif v_estado.usada     then raise exception 'invitacion_ya_usada';
    elsif v_estado.revocada  then raise exception 'invitacion_revocada';
    elsif v_estado.vencida   then raise exception 'invitacion_vencida';
    else                          raise exception 'invitacion_no_existe';
    end if;
  end if;

  -- el miembro nuevo, con su código permanente
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.generar_codigo_acceso();

      insert into public.miembros
        (codigo_acceso, nombre_real, apellido, email, telefono,
         como_llegaste, invitado_por, estado_codigo, apodo)
      values
        (v_cod, btrim(p_nombre), btrim(p_apellido), btrim(p_email),
         btrim(p_telefono), nullif(btrim(coalesce(p_como_llegaste, '')), ''),
         v_referente, 'activo', v_apodo)
      returning miembros.id into v_nuevo;

      exit;
    exception when unique_violation then
      -- entre el "está libre" y el insert se lo quedó otro registro
      v_nuevo := null;
    end;
  end loop;

  if v_nuevo is null then
    raise exception 'no_se_pudo_generar';
  end if;

  -- el nombre sektario, con su propio reintento por si el número ya existía
  for v_i in 1 .. 25 loop
    begin
      update public.miembros m
         set nombre_sektario = public.generar_nombre_sektario(p_nombre, p_apellido)
       where m.id = v_nuevo;
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;

  update public.invitaciones i set usada_por = v_nuevo where i.id = v_inv;

  -- la entrada que venía con la invitación: ahora es suya (una sola)
  update public.entradas e
     set duenio = v_nuevo, asignada_en = now()
   where e.id = (select x.id from public.entradas x
                  where x.para_invitacion = v_inv and x.duenio is null
                    and x.externo_nombre is null and x.anulada_en is null
                  limit 1);

  return query
    select m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.pantalla,
           m.fecha_ingreso, m.es_fundador,
           quien.nombre_sektario,
           (m.nombre_real is not null),
           m.apodo
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_nuevo;
end;
$$;

-- en "tus entradas": la guardada se ve como tal, con para quién y hasta cuándo
drop function if exists public.mis_entradas(text);
create function public.mis_entradas(p_codigo text)
returns table(entrada_id uuid, tipo text, soy_tenedor boolean, soy_duenio boolean, duenio_nombre text,
              quien_me_la_dio text, estado text, codigo text, nombre text, apellido text, apodo text,
              sektario text, puede_cambiar boolean,
              guardada_para text, guardada_codigo text, guardada_vence timestamptz)
language plpgsql security definer set search_path = public as $$
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
                when e.duenio is null and inv.id is not null then 'guardada'
                when e.duenio is null         then 'sin_asignar'
                else 'asignada' end,
           -- el código, sólo a su dueño
           case when e.duenio = v_yo then e.codigo end,
           case when e.duenio = v_yo then public.nombre_lindo(d.nombre_real) end,
           case when e.duenio = v_yo then public.nombre_lindo(d.apellido) end,
           case when e.duenio = v_yo then d.apodo end,
           case when e.duenio = v_yo then d.nombre_sektario end,
           now() < public.cierre_de_cambios() and e.adentro_en is null,
           case when e.tenedor = v_yo then inv.para end,
           case when e.tenedor = v_yo then inv.codigo end,
           case when e.tenedor = v_yo then inv.vence_en end
      from public.entradas e
      left join public.miembros d on d.id = e.duenio
      left join public.miembros p on p.id = e.pasada_por
      left join public.invitaciones inv on inv.id = e.para_invitacion
                                       and not inv.usada and not inv.revocada and inv.vence_en > now()
     where (e.tenedor = v_yo or e.duenio = v_yo)
       and e.anulada_en is null
     -- primero la suya, después las que tiene para repartir
     order by (e.duenio is not distinct from v_yo) desc, (e.duenio is null) desc, e.creada_en;
end;
$$;

-- en el panel: la nota dice si está guardada para una invitación
create or replace function public.admin_entradas_s7(p_codigo text)
returns table(entrada_id uuid, codigo text, tipo text, precio integer, nombre text, apodo text, sektario text,
              email text, contacto text, de_afuera boolean, tenedor text, compro text, estado text, nota text,
              adentro_en timestamp with time zone, creada_en timestamp with time zone)
language plpgsql security definer set search_path = public as $$
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
           coalesce(e.anulada_motivo,
                    case when inv.id is not null and e.duenio is null
                         then 'guardada para la invitación de ' || coalesce(inv.para, '?') ||
                              ' · vence ' || to_char(inv.vence_en at time zone 'America/Argentina/Buenos_Aires', 'DD/MM') end,
                    e.nota),
           e.adentro_en, e.creada_en
      from public.entradas e
      left join public.compras  c  on c.id  = e.compra_id
      left join public.miembros d  on d.id  = e.duenio
      left join public.miembros te on te.id = e.tenedor
      left join public.miembros cm on cm.id = c.comprador
      left join public.invitaciones inv on inv.id = e.para_invitacion
                                       and not inv.usada and not inv.revocada and inv.vence_en > now()
     order by (e.anulada_en is not null), e.creada_en;
end;
$$;

-- quien abre el link se entera en la bienvenida de que trae una entrada
drop function if exists public.validar_invitacion(text);
create function public.validar_invitacion(p_codigo text)
returns table(motivo text, referente_nombre text, con_entrada boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_inv record;
begin
  select i.id, i.usada, i.revocada, i.vence_en, m.nombre_sektario
    into v_inv
    from public.invitaciones i
    join public.miembros m on m.id = i.generada_por
   where i.codigo = upper(btrim(coalesce(p_codigo, '')));

  if not found then
    return query select 'no_existe'::text, null::text, false;
  elsif v_inv.usada then
    return query select 'ya_usada'::text, v_inv.nombre_sektario, false;
  elsif v_inv.revocada then
    return query select 'revocada'::text, v_inv.nombre_sektario, false;
  elsif v_inv.vence_en <= now() then
    return query select 'vencida'::text, v_inv.nombre_sektario, false;
  else
    return query select 'ok'::text, v_inv.nombre_sektario,
      exists (select 1 from public.entradas e
               where e.para_invitacion = v_inv.id and e.duenio is null and e.anulada_en is null);
  end if;
end;
$$;
