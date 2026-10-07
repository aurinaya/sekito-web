-- ============================================================================
-- SÉKITO — un mail, una persona
-- ============================================================================
-- Decidido con Mau el 07/10/2026, después del caso de Manuel La Rosa
-- Pedernera: entró con la invitación de Florencia y, horas después, se
-- registró otra vez con una llave que le dio el panel. Dos cuentas, el mismo
-- mail.
--
-- La regla: un mail no puede estar en dos cuentas activas. Vale para todo lo
-- que escribe un mail (la bienvenida con una llave del panel, el registro
-- con una invitación, editar desde el panel) y también para reactivar una
-- cuenta suspendida. Las suspendidas y revocadas no cuentan: la cuenta
-- duplicada de Manuel quedó suspendida y no le traba nada a nadie.
--
-- Es un trigger y no un índice único a propósito: las funciones de registro
-- reintentan solas ante un unique_violation (así esquivan códigos repetidos),
-- y un índice único las dejaba dando vueltas sin registrar a nadie y sin
-- decir nada. El trigger corta con 'mail_ya_esta', que el portal traduce.
--
-- En el panel, editar un miembro con un mail que ya es de otro dice de
-- quién es, para encontrarlo en vez de crear otra cuenta.
-- ============================================================================

create or replace function public.un_mail_por_persona()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if nullif(btrim(coalesce(new.email, '')), '') is null
     or new.estado_codigo not in ('activo', 'simbolico') then
    return new;
  end if;

  -- si no cambió ni el mail ni el estado, no hay nada que mirar
  if tg_op = 'UPDATE'
     and lower(btrim(new.email)) = lower(btrim(coalesce(old.email, '')))
     and old.estado_codigo in ('activo', 'simbolico') then
    return new;
  end if;

  if exists (select 1 from public.miembros m
              where m.id <> new.id
                and m.estado_codigo in ('activo', 'simbolico')
                and lower(btrim(m.email)) = lower(btrim(new.email))) then
    raise exception 'mail_ya_esta';
  end if;

  return new;
end;
$$;

drop trigger if exists miembros_un_mail on public.miembros;
create trigger miembros_un_mail
  before insert or update of email, estado_codigo on public.miembros
  for each row execute function public.un_mail_por_persona();

revoke execute on function public.un_mail_por_persona() from public, anon, authenticated;


-- el panel: si el mail ya es de otro, dice de quién
create or replace function public.admin_editar_miembro(
  p_codigo text, p_miembro_id uuid, p_nombre text default null, p_apellido text default null,
  p_email text default null, p_telefono text default null, p_nota text default null,
  p_invitado_por uuid default null, p_cambiar_invitador boolean default false)
returns table(id uuid)
language plpgsql
security definer
set search_path to 'public'
as $function$
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
