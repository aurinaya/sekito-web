-- ============================================================================
-- SÉKITO — nadie queda sin origen
-- ============================================================================
-- Todo miembro que quedaría sin invitador pasa a colgar de LA SEKTA. Así el
-- árbol no tiene huérfanos sueltos: o te trajo alguien, o te trajo la sekta.
--
-- La excepción son los tres fundadores. No cuelgan de nadie a propósito: son
-- la semilla, y poner a LA SEKTA arriba de ellos sería decir que algo los
-- trajo. No los trajo nada.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. el id de LA SEKTA, a mano
-- ----------------------------------------------------------------------------
create or replace function public.id_la_sekta()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.id from public.miembros m where m.estado_codigo = 'simbolico' limit 1;
$$;

revoke all on function public.id_la_sekta() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. crear un miembro sin elegir invitador lo deja colgando de LA SEKTA
-- ----------------------------------------------------------------------------
create or replace function public.admin_crear_miembro(
  p_codigo        text,
  p_nota          text default null,
  p_invitado_por  uuid default null
)
returns table (id uuid, codigo_acceso text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin  uuid := public.admin_id_de(p_codigo);
  v_nuevo  uuid;
  v_cod    text := public.generar_codigo_acceso();
  v_quien  uuid := coalesce(p_invitado_por, public.id_la_sekta());
begin
  if p_invitado_por is not null
     and not exists (select 1 from public.miembros m where m.id = p_invitado_por) then
    raise exception 'El invitador elegido no existe.';
  end if;

  insert into public.miembros (codigo_acceso, nota_admin, invitado_por, estado_codigo)
  values (v_cod, nullif(btrim(coalesce(p_nota, '')), ''), v_quien, 'activo')
  returning miembros.id into v_nuevo;

  insert into public.admin_acciones (admin_id, accion, miembro_id, detalle)
  values (v_admin, 'crear_miembro', v_nuevo,
          jsonb_build_object(
            'codigo_acceso', v_cod,
            'invitado_por', (select coalesce(q.nombre_sektario, q.codigo_acceso)
                               from public.miembros q where q.id = v_quien)));

  return query select v_nuevo, v_cod;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. vaciar el invitador desde el panel tampoco deja a nadie suelto
-- ----------------------------------------------------------------------------
-- Salvo que sea fundador: a ésos sí se los deja sin nadie arriba.
create or replace function public.admin_editar_miembro(
  p_codigo             text,
  p_miembro_id         uuid,
  p_nombre             text default null,
  p_apellido           text default null,
  p_email              text default null,
  p_telefono           text default null,
  p_nota               text default null,
  p_invitado_por       uuid default null,
  p_cambiar_invitador  boolean default false
)
returns table (id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin     uuid := public.admin_id_de(p_codigo);
  v_fundador  boolean;
  v_quien     uuid;
begin
  select m.es_fundador into v_fundador
    from public.miembros m where m.id = p_miembro_id;

  if v_fundador is null then
    raise exception 'Ese miembro no existe.';
  end if;

  if p_cambiar_invitador and p_invitado_por is not null
     and not exists (select 1 from public.miembros m where m.id = p_invitado_por) then
    raise exception 'El invitador elegido no existe.';
  end if;

  -- sin invitador elegido: LA SEKTA, salvo que sea uno de la semilla
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
$$;

revoke all on function public.admin_crear_miembro(text, text, uuid) from public;
revoke all on function public.admin_editar_miembro(text, uuid, text, text, text, text, text, uuid, boolean) from public;
grant execute on function public.admin_crear_miembro(text, text, uuid) to anon, authenticated;
grant execute on function public.admin_editar_miembro(text, uuid, text, text, text, text, text, uuid, boolean) to anon, authenticated;
