-- ============================================================================
-- SÉKITO — canal B: que un miembro invite a otro
-- ============================================================================
-- Hasta ahora los códigos salían de los fundadores. Con esto, cualquier
-- miembro activo genera desde su perfil un link de invitación:
--
--   sekito.ar/i/CODIGO
--
-- El que lo recibe toca, cae en el formulario de bienvenida con su referente
-- ya cargado, y al terminar recibe un código de acceso propio y permanente.
-- La invitación se gasta en ese momento.
--
-- Reglas: un solo uso, vence a los 7 días, hasta 5 abiertas por miembro.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. azar de verdad
-- ----------------------------------------------------------------------------
-- random() de Postgres es un generador predecible: alcanza con ver unos
-- cuantos resultados para adivinar los que siguen. Sirve para barajar, no para
-- fabricar credenciales. gen_random_bytes (pgcrypto) es azar criptográfico.
--
-- Lo del "tope": un byte da 0..255. Si el alfabeto tiene 24 símbolos, 256 no
-- se reparte parejo (256 = 24×10 + 16), y los primeros 16 símbolos saldrían
-- más seguido que el resto. Descartando los bytes sobrantes, todos los
-- símbolos quedan con la misma probabilidad.
create or replace function public.azar_de(p_alfabeto text, p_largo int)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n    int  := length(p_alfabeto);
  v_tope int  := (256 / v_n) * v_n;
  v_out  text := '';
  v_byte int;
begin
  while length(v_out) < p_largo loop
    v_byte := get_byte(extensions.gen_random_bytes(1), 0);
    continue when v_byte >= v_tope;
    v_out := v_out || substr(p_alfabeto, (v_byte % v_n) + 1, 1);
  end loop;
  return v_out;
end;
$$;

revoke all on function public.azar_de(text, int) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. el generador de códigos de acceso pasa a usar ese azar
-- ----------------------------------------------------------------------------
-- Mismo formato de siempre (tres letras y tres números, sin I ni O), pero ya
-- no sale de random(). Lo usan el panel de administración y el canal B.
create or replace function public.generar_codigo_acceso()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text;
  v_i      int;
begin
  for v_i in 1 .. 200 loop
    v_codigo := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ', 3)
             || public.azar_de('0123456789', 3);
    if not exists (select 1 from public.miembros m where m.codigo_acceso = v_codigo) then
      return v_codigo;
    end if;
  end loop;

  raise exception 'No se pudo generar un código libre después de 200 intentos.';
end;
$$;

revoke all on function public.generar_codigo_acceso() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. crear una invitación
-- ----------------------------------------------------------------------------
-- El miembro manda su propio código de acceso. Tiene que estar activo: un
-- suspendido no sigue sumando gente.
--
-- El código de invitación es de 12 caracteres sobre un alfabeto de 32 —unos
-- 60 bits—. Nadie lo escribe a mano (viaja en el link), así que puede ser
-- largo, y conviene que lo sea: el que lo tenga entra al sékito.
create or replace function public.crear_invitacion(p_codigo text)
returns table (codigo text, vence_en timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miembro  uuid;
  v_abiertas int;
  v_cod      text;
  v_vence    timestamptz;
  v_i        int;
begin
  select m.id into v_miembro
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  select count(*) into v_abiertas
    from public.invitaciones i
   where i.generada_por = v_miembro
     and i.usada = false
     and i.vence_en > now();

  if v_abiertas >= 5 then
    raise exception 'demasiadas_abiertas';
  end if;

  -- el índice único de la columna es lo que garantiza que no se repita; este
  -- bucle es sólo la red por si justo cae una repetida
  for v_i in 1 .. 200 loop
    begin
      v_cod := public.azar_de('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 12);

      insert into public.invitaciones (generada_por, codigo, vence_en)
      values (v_miembro, v_cod, now() + interval '7 days')
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
-- 4. mirar una invitación sin gastarla
-- ----------------------------------------------------------------------------
-- Se llama cuando alguien abre el link, para saber si sirve y mostrarle quién
-- lo invitó antes de que complete nada.
--
-- El motivo se devuelve como dato y no como error a propósito: "vencida" y
-- "ya usada" son respuestas normales que la pantalla tiene que poder explicar.
create or replace function public.validar_invitacion(p_codigo text)
returns table (motivo text, referente_nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv record;
begin
  select i.usada, i.vence_en, m.nombre_sektario
    into v_inv
    from public.invitaciones i
    join public.miembros m on m.id = i.generada_por
   where i.codigo = upper(btrim(coalesce(p_codigo, '')));

  if not found then
    return query select 'no_existe'::text, null::text;
  elsif v_inv.usada then
    return query select 'ya_usada'::text, v_inv.nombre_sektario;
  elsif v_inv.vence_en <= now() then
    return query select 'vencida'::text, v_inv.nombre_sektario;
  else
    return query select 'ok'::text, v_inv.nombre_sektario;
  end if;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. registrarse con una invitación
-- ----------------------------------------------------------------------------
-- Lo importante acá es cómo se gasta la invitación. NO se consulta primero y
-- se escribe después: entre esas dos cosas entra otra persona con el mismo
-- link y entran las dos. El update de abajo busca y marca en un solo paso
-- indivisible; el segundo que llegue no encuentra ninguna fila y rebota.
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
   where i.codigo = upper(btrim(coalesce(p_invitacion, '')))
     and i.usada = false
     and i.vence_en > now()
  returning i.id, i.generada_por into v_inv, v_referente;

  if v_inv is null then
    -- no se pudo gastar: averiguar por qué, para poder explicarlo
    select i.usada, (i.vence_en <= now()) as vencida
      into v_estado
      from public.invitaciones i
     where i.codigo = upper(btrim(coalesce(p_invitacion, '')));

    if not found            then raise exception 'invitacion_no_existe';
    elsif v_estado.usada    then raise exception 'invitacion_ya_usada';
    elsif v_estado.vencida  then raise exception 'invitacion_vencida';
    else                         raise exception 'invitacion_no_existe';
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
-- 6. las invitaciones abiertas de un miembro
-- ----------------------------------------------------------------------------
-- Para que en su perfil vea cuántas le quedan antes de llegar al tope.
create or replace function public.mis_invitaciones(p_codigo text)
returns table (codigo text, vence_en timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miembro uuid;
begin
  select m.id into v_miembro
    from public.miembros m
   where m.codigo_acceso = upper(btrim(coalesce(p_codigo, '')))
     and m.estado_codigo = 'activo';

  if v_miembro is null then
    raise exception 'codigo_invalido';
  end if;

  return query
    select i.codigo, i.vence_en
      from public.invitaciones i
     where i.generada_por = v_miembro
       and i.usada = false
       and i.vence_en > now()
     order by i.creado_en;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.crear_invitacion(text)                                  from public;
revoke all on function public.validar_invitacion(text)                                from public;
revoke all on function public.registrar_con_invitacion(text,text,text,text,text,text) from public;
revoke all on function public.mis_invitaciones(text)                                  from public;

grant execute on function public.crear_invitacion(text)                                  to anon, authenticated;
grant execute on function public.validar_invitacion(text)                                to anon, authenticated;
grant execute on function public.registrar_con_invitacion(text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.mis_invitaciones(text)                                  to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select * from public.crear_invitacion('UNCODIGO');   -> código de 12 y fecha
-- select * from public.validar_invitacion('ESECODIGO'); -> motivo = ok
-- Y después de registrarse con él, el mismo validar_invitacion da 'ya_usada'.
