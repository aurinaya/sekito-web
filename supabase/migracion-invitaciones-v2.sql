-- ============================================================================
-- SÉKITO — invitaciones, segunda vuelta
-- ============================================================================
-- Qué estaba mal: el link se generaba al ENTRAR a la pantalla. Alguien que
-- entraba a leer el texto ya había gastado una invitación sin decidirlo.
-- MAU llegó al tope de 5 con una sola usada: cuatro de las seis se crearon
-- el mismo día, tres de ellas en siete horas. No estaba invitando a nadie,
-- estaba mirando.
--
-- Y una vez generado el link no había forma de volver a verlo, de saber a
-- quién se lo mandó, ni de soltarlo. El tope bloqueaba sin explicar.
--
-- Lo que cambia:
--   · cada invitación lleva un TAG obligatorio: a quién se la mandaste
--   · se pueden dar de baja, y la baja libera el lugar
--   · la lista devuelve los cuatro estados, no solo las abiertas
--   · los fundadores no tienen tope
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. las columnas nuevas
-- ----------------------------------------------------------------------------
-- `para` es texto libre que escribió el que invita, y lo ve solo él. No es el
-- nombre del invitado a los ojos del sistema: es un recordatorio. Puede decir
-- "el del gimnasio" y está perfecto.
--
-- `revocada` es aparte de `vence_en` a propósito. Se podría dar de baja
-- poniendo vence_en = now(), pero entonces el que abre el link leería
-- "vencida", que es mentira y además lo deja pensando que llegó tarde.
alter table public.invitaciones
  add column if not exists para        text,
  add column if not exists revocada    boolean not null default false,
  add column if not exists revocada_en timestamptz;


-- ----------------------------------------------------------------------------
-- 2. crear una invitación
-- ----------------------------------------------------------------------------
-- El tope de 5 no es por costo: es control de admisión. Con la baja y la
-- lista a la vista, 5 abiertas deja de ser una pared y pasa a ser un límite
-- que se administra. Los fundadores quedan afuera del tope.
create or replace function public.crear_invitacion(p_codigo text, p_para text)
returns table (codigo text, vence_en timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miembro   uuid;
  v_fundador  boolean;
  v_abiertas  int;
  v_para      text := nullif(btrim(coalesce(p_para, '')), '');
  v_cod       text;
  v_vence     timestamptz;
  v_i         int;
begin
  if v_para is null then
    raise exception 'falta_tag';
  end if;

  select m.id, m.es_fundador into v_miembro, v_fundador
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  if not v_fundador then
    select count(*) into v_abiertas
      from public.invitaciones i
     where i.generada_por = v_miembro
       and i.usada    = false
       and i.revocada = false
       and i.vence_en > now();

    if v_abiertas >= 5 then
      raise exception 'demasiadas_abiertas';
    end if;
  end if;

  -- el índice único de la columna es lo que garantiza que no se repita; este
  -- bucle es sólo la red por si justo cae una repetida
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 12);

      insert into public.invitaciones (generada_por, codigo, vence_en, para)
      values (v_miembro, v_cod, now() + interval '7 days', left(v_para, 60))
      returning invitaciones.vence_en into v_vence;

      return query select v_cod, v_vence;
      return;
    exception when unique_violation then
      null;  -- ya existía: probar con otro
    end;
  end loop;

  raise exception 'no_se_pudo_generar';
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. dar de baja una invitación
-- ----------------------------------------------------------------------------
-- Solo el que la generó, y solo si todavía no se usó: una invitación gastada
-- ya es una persona adentro, y eso no se deshace desde acá.
create or replace function public.revocar_invitacion(p_codigo text, p_invitacion text)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miembro uuid;
  v_id      uuid;
begin
  select m.id into v_miembro
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  update public.invitaciones i
     set revocada = true, revocada_en = now()
   where i.codigo       = upper(btrim(coalesce(p_invitacion, '')))
     and i.generada_por = v_miembro
     and i.usada        = false
     and i.revocada     = false
  returning i.id into v_id;

  if v_id is null then
    raise exception 'no_se_pudo_dar_de_baja';
  end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. mirar una invitación sin gastarla
-- ----------------------------------------------------------------------------
-- Suma el motivo 'revocada'. Importa que sea distinto de 'vencida': el que
-- abre el link no llegó tarde, se lo dieron de baja, y lo que tiene que hacer
-- es pedir otro. Decirle "vencida" lo manda a esperar algo que no va a pasar.
create or replace function public.validar_invitacion(p_codigo text)
returns table (motivo text, referente_nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv record;
begin
  select i.usada, i.revocada, i.vence_en, m.nombre_sektario
    into v_inv
    from public.invitaciones i
    join public.miembros m on m.id = i.generada_por
   where i.codigo = upper(btrim(coalesce(p_codigo, '')));

  if not found then
    return query select 'no_existe'::text, null::text;
  elsif v_inv.usada then
    return query select 'ya_usada'::text, v_inv.nombre_sektario;
  elsif v_inv.revocada then
    return query select 'revocada'::text, v_inv.nombre_sektario;
  elsif v_inv.vence_en <= now() then
    return query select 'vencida'::text, v_inv.nombre_sektario;
  else
    return query select 'ok'::text, v_inv.nombre_sektario;
  end if;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. mis invitaciones
-- ----------------------------------------------------------------------------
-- Antes devolvía solo las abiertas, y las usadas desaparecían. Justo la que
-- uno quiere ver: quién entró por tu mano. Ahora vuelven las cuatro, con el
-- tag y con el nombre sektario del que entró.
--
-- Las dadas de baja no vuelven: el que las dio de baja decidió que no pasaron.
--
-- El orden: primero lo que estás esperando, después los que entraron, al
-- final lo que quedó en la nada. Y dentro de cada grupo, lo más nuevo arriba.
--
-- Probé ordenar las abiertas por vencimiento —lo más urgente primero— y era
-- peor: el link recién generado caía en el medio de la lista, justo cuando lo
-- único que querés hacer es mandarlo. La urgencia ya la dice el color.
-- Cambia la forma de lo que devuelve, así que Postgres exige tirarla antes:
-- una función no puede cambiar sus columnas de salida en el lugar.
drop function if exists public.mis_invitaciones(text);

create or replace function public.mis_invitaciones(p_codigo text)
returns table (
  codigo         text,
  para           text,
  estado         text,
  vence_en       timestamptz,
  dias_restantes int,
  creado_en      timestamptz,
  usada_en       timestamptz,
  quien_entro    text,
  al_tope        boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miembro  uuid;
  v_fundador boolean;
  v_abiertas int;
begin
  select m.id, m.es_fundador into v_miembro, v_fundador
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  select count(*) into v_abiertas
    from public.invitaciones i
   where i.generada_por = v_miembro
     and i.usada = false and i.revocada = false and i.vence_en > now();

  return query
    select i.codigo,
           i.para,
           case when i.usada              then 'entro'
                when i.vence_en <= now()  then 'vencida'
                else                           'esperando' end,
           i.vence_en,
           greatest(0, ceil(extract(epoch from (i.vence_en - now())) / 86400)::int),
           i.creado_en,
           i.usada_en,
           quien.nombre_sektario,
           (not v_fundador and v_abiertas >= 5)
      from public.invitaciones i
      left join public.miembros quien on quien.id = i.usada_por
     where i.generada_por = v_miembro
       and i.revocada = false
     order by
       case when i.usada             then 2
            when i.vence_en <= now() then 3
            else                          1 end,
       i.creado_en desc;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. registrarse con una invitación
-- ----------------------------------------------------------------------------
-- Igual que antes, pero una invitación dada de baja no sirve. El update
-- sigue siendo el que busca y gasta en un solo paso indivisible: si dos
-- personas tocan el mismo link al mismo tiempo, entra una sola.
create or replace function public.registrar_con_invitacion(
  p_invitacion    text,
  p_nombre        text,
  p_apellido      text,
  p_email         text,
  p_telefono      text,
  p_como_llegaste text default null
)
returns table (
  codigo_acceso        text,
  nombre_sektario      text,
  nombre_real          text,
  pantalla             text,
  fecha_ingreso        timestamptz,
  es_fundador          boolean,
  invitado_por_nombre  text,
  registro_completo    boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv       uuid;
  v_referente uuid;
  v_estado    record;
  v_nuevo     uuid;
  v_cod       text;
  v_i         int;
begin
  if nullif(btrim(coalesce(p_nombre,   '')), '') is null
  or nullif(btrim(coalesce(p_apellido, '')), '') is null
  or nullif(btrim(coalesce(p_email,    '')), '') is null
  or nullif(btrim(coalesce(p_telefono, '')), '') is null then
    raise exception 'faltan_datos';
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
         como_llegaste, invitado_por, estado_codigo)
      values
        (v_cod, btrim(p_nombre), btrim(p_apellido), btrim(p_email),
         btrim(p_telefono), nullif(btrim(coalesce(p_como_llegaste, '')), ''),
         v_referente, 'activo')
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

  return query
    select m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.pantalla,
           m.fecha_ingreso, m.es_fundador,
           quien.nombre_sektario,
           (m.nombre_real is not null)
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_nuevo;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.crear_invitacion(text, text)                            from public;
revoke all on function public.revocar_invitacion(text, text)                          from public;
revoke all on function public.validar_invitacion(text)                                from public;
revoke all on function public.mis_invitaciones(text)                                  from public;
revoke all on function public.registrar_con_invitacion(text,text,text,text,text,text) from public;

grant execute on function public.crear_invitacion(text, text)                            to anon, authenticated;
grant execute on function public.revocar_invitacion(text, text)                          to anon, authenticated;
grant execute on function public.validar_invitacion(text)                                to anon, authenticated;
grant execute on function public.mis_invitaciones(text)                                  to anon, authenticated;
grant execute on function public.registrar_con_invitacion(text,text,text,text,text,text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 8. la versión vieja
-- ----------------------------------------------------------------------------
-- crear_invitacion(text) —de un solo argumento— era la que llamaba el sitio
-- anterior. Se mantuvo viva hasta que el sitio nuevo estuvo publicado, para
-- que el botón de invitar no dejara de andar en el medio. Ya no está.
drop function if exists public.crear_invitacion(text);
--
-- ============================================================================
-- Verificación
-- ============================================================================
-- select * from public.crear_invitacion('UNCODIGO', 'el del gimnasio');
-- select * from public.mis_invitaciones('UNCODIGO');
-- select * from public.revocar_invitacion('UNCODIGO', 'ESECODIGODE12');
-- select * from public.validar_invitacion('ESECODIGODE12');  -> revocada
