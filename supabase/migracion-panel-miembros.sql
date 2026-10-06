-- ============================================================================
-- SÉKITO — el panel de miembros más claro, y devotxs con más datos
-- ============================================================================
-- 1. Cuándo entró de verdad cada persona al portal. Hasta acá "ingreso" era
--    el día en que se creó la llave, no el día en que la usó. Desde ahora se
--    guarda al completar el registro.
--    Para lo que ya pasó, lo mejor que hay: quien entró por un link de
--    invitación tiene la fecha exacta (cuando lo usó); quien entró con una
--    llave del panel queda con el día en que se creó su llave.
-- 2. Las invitaciones que andan dando vueltas, para verlas en el panel con
--    los días que les quedan.
-- 3. Devotxs devuelve también nombre y apellido, para mostrarlos debajo del
--    apodo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. registrado_en
-- ---------------------------------------------------------------------------
alter table public.miembros add column if not exists registrado_en timestamptz;

update public.miembros m
   set registrado_en = coalesce(
         (select max(i.usada_en) from public.invitaciones i where i.usada_por = m.id),
         m.fecha_ingreso)
 where m.nombre_real is not null and m.registrado_en is null;

create or replace function public.miembro_registrado_en()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  -- se registra cuando aparece su nombre: es lo que hace "registro completo"
  if new.nombre_real is not null and new.registrado_en is null
     and (tg_op = 'INSERT' or old.nombre_real is null) then
    new.registrado_en := now();
  end if;
  return new;
end;
$$;

drop trigger if exists miembros_registrado_en on public.miembros;
create trigger miembros_registrado_en
  before insert or update of nombre_real on public.miembros
  for each row execute function public.miembro_registrado_en();

revoke execute on function public.miembro_registrado_en() from public, anon, authenticated;

-- la lista del panel, con el ingreso de verdad al final
drop function public.admin_listar_miembros(text);
create function public.admin_listar_miembros(p_codigo text)
returns table(id uuid, codigo_acceso text, nombre_sektario text, nombre_real text, apellido text,
              email text, telefono text, como_llegaste text, nota_admin text, estado_codigo text,
              es_fundador boolean, pantalla text, invitado_por uuid, invitado_por_nombre text,
              registro_completo boolean, fecha_ingreso timestamp with time zone,
              creado_en timestamp with time zone, apodo text, registrado_en timestamp with time zone)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.admin_id_de(p_codigo);

  return query
    select
      m.id, m.codigo_acceso, m.nombre_sektario, m.nombre_real, m.apellido,
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
revoke execute on function public.admin_listar_miembros(text) from public;
grant execute on function public.admin_listar_miembros(text) to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 2. las invitaciones vigentes
-- ---------------------------------------------------------------------------
create or replace function public.admin_invitaciones_vigentes(p_codigo text)
returns table(invitacion_id uuid, de text, de_sektario text, para text,
              creado_en timestamptz, vence_en timestamptz, dias_restantes integer)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select i.id,
           public.como_le_dicen(m.apodo, m.nombre_real),
           m.nombre_sektario,
           i.para, i.creado_en, i.vence_en,
           greatest(ceil(extract(epoch from (i.vence_en - now())) / 86400), 0)::integer
      from public.invitaciones i
      join public.miembros m on m.id = i.generada_por
     where not i.usada and not i.revocada
       and (i.vence_en is null or i.vence_en > now())
     order by i.vence_en nulls last;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. devotxs: también nombre y apellido
-- ---------------------------------------------------------------------------
drop function public.buscar_en_el_sekito(text, text);
create function public.buscar_en_el_sekito(p_codigo text, p_query text)
returns table(sektario text, nombre text, pantalla text, es_sekta boolean, nombre_completo text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 1 then
    return;
  end if;

  return query
    select m.nombre_sektario,
           public.como_le_dicen(m.apodo, m.nombre_real),
           m.pantalla,
           (m.estado_codigo = 'simbolico'),
           nullif(trim(coalesce(public.nombre_lindo(m.nombre_real), '') || ' ' ||
                       coalesce(public.nombre_lindo(m.apellido), '')), '')
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, m.apellido, m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$function$;

notify pgrst, 'reload schema';
