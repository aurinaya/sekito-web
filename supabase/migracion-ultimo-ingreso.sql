-- ---------------------------------------------------------------------------
-- EL ÚLTIMO INGRESO DE CADA MIEMBRO, EN EL PANEL (21/10)
--
-- Para saber si los que no sacaron entrada entran al portal y no compran, o
-- si directamente no entran. Cada vez que alguien abre el portal con su llave
-- (validar_codigo: el portón y la llave recordada) queda la hora, a lo sumo
-- una vez cada 10 minutos para no escribir de más. Solo lo ve el panel.
-- ---------------------------------------------------------------------------

alter table public.miembros add column if not exists ultima_visita timestamptz;

create or replace function public.validar_codigo(p_codigo text)
returns table(nombre_sektario text, nombre_real text, pantalla text, fecha_ingreso timestamp with time zone,
              es_fundador boolean, invitado_por_nombre text, registro_completo boolean, apodo text)
language plpgsql security definer set search_path = public as $$
begin
  update public.miembros m
     set ultima_visita = now()
   where m.codigo_acceso = upper(btrim(p_codigo))
     and m.estado_codigo = 'activo'
     and (m.ultima_visita is null or m.ultima_visita < now() - interval '10 minutes');

  return query
    select
      m.nombre_sektario,
      m.nombre_real,
      m.pantalla,
      m.fecha_ingreso,
      m.es_fundador,
      quien.nombre_sektario           as invitado_por_nombre,
      (m.nombre_real is not null)     as registro_completo,
      m.apodo
    from public.miembros m
    left join public.miembros quien on quien.id = m.invitado_por
    where m.codigo_acceso = upper(btrim(p_codigo))
      and m.estado_codigo = 'activo'
    limit 1;
end;
$$;

drop function if exists public.admin_listar_miembros(text);
create function public.admin_listar_miembros(p_codigo text)
returns table(id uuid, codigo_acceso text, nombre_sektario text, nombre_real text, apellido text, email text,
              telefono text, como_llegaste text, nota_admin text, estado_codigo text, es_fundador boolean,
              pantalla text, invitado_por uuid, invitado_por_nombre text, registro_completo boolean,
              fecha_ingreso timestamp with time zone, creado_en timestamp with time zone, apodo text,
              registrado_en timestamp with time zone, ultima_visita timestamp with time zone)
language plpgsql security definer set search_path = public as $$
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
      m.fecha_ingreso, m.creado_en, m.apodo, m.registrado_en, m.ultima_visita
    from public.miembros m
    left join public.miembros quien on quien.id = m.invitado_por
    order by m.creado_en;
end;
$$;
