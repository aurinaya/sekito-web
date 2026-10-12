-- ---------------------------------------------------------------------------
-- LOS FUNDADORES, SOLO MAU (12/10)
--
-- Las tres llaves de admin (MAU, TANO, FLOR) podían lo mismo: ver la llave
-- del portal de cualquiera (también la de los fundadores, que es entrar como
-- ellos) y editarlos o suspenderlos. Ahora:
--   * la llave de MAU·000, NYA·000 y FLR·000 solo la ve MAU; cada uno ve la suya
--   * editar, suspender, renovar la llave o borrar susurros de un fundador:
--     solo MAU
--   * renovar la llave de cualquier otro miembro: los tres (admin_renovar_llave)
-- Va en la base y no en la pantalla: con una llave de admin se le puede pedir
-- todo a la base directo, sin pasar por el panel.
-- ---------------------------------------------------------------------------

alter table public.admins add column if not exists es_dueno boolean not null default false;
update public.admins set es_dueno = (nombre = 'MAU');

-- frena si el miembro es fundador y el admin no es MAU
create or replace function public.admin_puede_tocar(p_admin uuid, p_miembro uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from public.miembros m where m.id = p_miembro and m.es_fundador)
     and not exists (select 1 from public.admins a where a.id = p_admin and a.es_dueno) then
    raise exception 'solo_mau';
  end if;
end;
$$;
revoke execute on function public.admin_puede_tocar(uuid, uuid) from public, anon, authenticated;

-- si alguien perdió su llave (o se le filtró): una nueva, y la vieja deja de
-- andar. La llave nueva no queda en admin_acciones: el registro la mostraría.
create or replace function public.admin_renovar_llave(p_codigo text, p_miembro_id uuid)
returns table(codigo_acceso text)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_est   text;
  v_cod   text;
begin
  select m.estado_codigo into v_est from public.miembros m where m.id = p_miembro_id;
  if v_est is null then
    raise exception 'Ese miembro no existe.';
  end if;
  if v_est = 'simbolico' then
    raise exception 'Ese miembro es simbólico y no tiene llave.';
  end if;

  perform public.admin_puede_tocar(v_admin, p_miembro_id);

  v_cod := public.generar_codigo_acceso();
  update public.miembros m set codigo_acceso = v_cod where m.id = p_miembro_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'renovar_llave', p_miembro_id, null);

  return query select v_cod;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_listar_miembros(p_codigo text)
 RETURNS TABLE(id uuid, codigo_acceso text, nombre_sektario text, nombre_real text, apellido text, email text, telefono text, como_llegaste text, nota_admin text, estado_codigo text, es_fundador boolean, pantalla text, invitado_por uuid, invitado_por_nombre text, registro_completo boolean, fecha_ingreso timestamp with time zone, creado_en timestamp with time zone, apodo text, registrado_en timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_dueno boolean;
  v_yo    uuid;
begin
  select coalesce(a.es_dueno, false), a.miembro_id into v_dueno, v_yo from public.admins a where a.id = v_admin;

  return query
    select
      m.id,
      -- la llave de un fundador solo la ve MAU (y cada uno la suya)
      case when m.es_fundador and not v_dueno and m.id is distinct from v_yo
           then null else m.codigo_acceso end,
      m.nombre_sektario, m.nombre_real, m.apellido,
      m.email, m.telefono, m.como_llegaste, m.nota_admin, m.estado_codigo,
      m.es_fundador, m.pantalla, m.invitado_por,
      quien.nombre_sektario as invitado_por_nombre,
      (m.nombre_real is not null) as registro_completo,
      m.fecha_ingreso, m.creado_en, m.apodo, m.registrado_en
    from public.miembros m
    left join public.miembros quien on quien.id = m.invitado_por
    order by m.creado_en;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_editar_miembro(p_codigo text, p_miembro_id uuid, p_nombre text DEFAULT NULL::text, p_apellido text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_telefono text DEFAULT NULL::text, p_nota text DEFAULT NULL::text, p_invitado_por uuid DEFAULT NULL::uuid, p_cambiar_invitador boolean DEFAULT false)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin     uuid := public.admin_id_de(p_codigo);
  v_fundador  boolean;
  v_quien     uuid;
  v_otro      text;
begin
  select m.es_fundador into v_fundador
    from public.miembros m where m.id = p_miembro_id;

  if v_fundador is null then
    raise exception 'Ese miembro no existe.';
  end if;

  perform public.admin_puede_tocar(v_admin, p_miembro_id);

  if p_cambiar_invitador and p_invitado_por is not null
     and not exists (select 1 from public.miembros m where m.id = p_invitado_por) then
    raise exception 'El invitador elegido no existe.';
  end if;

  if nullif(btrim(coalesce(p_email, '')), '') is not null then
    select coalesce(public.como_le_dicen(m.apodo, m.nombre_real), m.nota_admin, 'una llave sin usar')
           || coalesce(' (' || m.nombre_sektario || ')', '')
      into v_otro
      from public.miembros m
     where m.id <> p_miembro_id
       and m.estado_codigo in ('activo', 'simbolico')
       and lower(btrim(m.email)) = lower(btrim(p_email))
     limit 1;
    if v_otro is not null then
      raise exception 'Ese mail ya es de %. Un mail, una persona: buscala antes de hacerle otra cuenta.', v_otro;
    end if;
  end if;

  v_quien := case
               when not p_cambiar_invitador then null
               when p_invitado_por is not null then p_invitado_por
               when v_fundador then null
               else public.id_la_sekta()
             end;

  update public.miembros m set
    nombre_real  = coalesce(nullif(btrim(p_nombre),   ''), m.nombre_real),
    apellido     = coalesce(nullif(btrim(p_apellido), ''), m.apellido),
    email        = coalesce(nullif(btrim(p_email),    ''), m.email),
    telefono     = coalesce(nullif(btrim(p_telefono), ''), m.telefono),
    nota_admin   = coalesce(nullif(btrim(p_nota),     ''), m.nota_admin),
    invitado_por = case when p_cambiar_invitador then v_quien else m.invitado_por end
  where m.id = p_miembro_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'editar_miembro', p_miembro_id,
          jsonb_strip_nulls(jsonb_build_object(
            'nombre',   nullif(btrim(coalesce(p_nombre, '')),   ''),
            'apellido', nullif(btrim(coalesce(p_apellido, '')), ''),
            'email',    case when nullif(btrim(coalesce(p_email, '')), '')    is not null then 'cambiado' end,
            'telefono', case when nullif(btrim(coalesce(p_telefono, '')), '') is not null then 'cambiado' end,
            'nota',     nullif(btrim(coalesce(p_nota, '')), ''),
            'invitador', case when p_cambiar_invitador then coalesce(
                            (select coalesce(q.nombre_sektario, q.codigo_acceso)
                               from public.miembros q where q.id = v_quien),
                            'sin invitador') end
          )));

  return query select p_miembro_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_cambiar_estado(p_codigo text, p_miembro_id uuid, p_estado text)
 RETURNS TABLE(estado_codigo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin   uuid := public.admin_id_de(p_codigo);
  v_previo  text;
begin
  if p_estado not in ('activo', 'suspendido', 'revocado') then
    raise exception 'Estado inválido: %. Sólo activo, suspendido o revocado.', p_estado;
  end if;

  select m.estado_codigo into v_previo
    from public.miembros m where m.id = p_miembro_id;

  if v_previo is null then
    raise exception 'Ese miembro no existe.';
  end if;

  perform public.admin_puede_tocar(v_admin, p_miembro_id);

  -- FISURA no es una persona, es la opción "no me trajo nadie en particular"
  -- del formulario. Si se la desactiva, esa opción desaparece del buscador.
  if v_previo = 'simbolico' then
    raise exception 'Ese miembro es simbólico y no se le cambia el estado.';
  end if;

  update public.miembros m set estado_codigo = p_estado where m.id = p_miembro_id;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'cambiar_estado', p_miembro_id,
          jsonb_build_object('de', v_previo, 'a', p_estado));

  return query select p_estado;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_borrar_susurros_de(p_codigo text, p_de text, p_para text)
 RETURNS TABLE(borrados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_de    uuid;
  v_para  uuid;
  v_n     int;
begin
  if v_admin is null then
    raise exception 'codigo_invalido';
  end if;

  select m.id into v_de   from public.miembros m where m.nombre_sektario = btrim(p_de);
  select m.id into v_para from public.miembros m where m.nombre_sektario = btrim(p_para);

  if v_de is null or v_para is null then
    raise exception 'no_esta_en_el_padron';
  end if;

  perform public.admin_puede_tocar(v_admin, v_de);
  perform public.admin_puede_tocar(v_admin, v_para);

  delete from public.susurros s where s.de = v_de and s.para = v_para;
  get diagnostics v_n = row_count;

  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'borrar_susurros',
          jsonb_build_object('de', btrim(p_de), 'para', btrim(p_para), 'cuantos', v_n));

  return query select v_n;
end;
$function$;
