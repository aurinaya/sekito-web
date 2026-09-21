-- ============================================================================
-- SÉKITO — los susurros
-- ============================================================================
-- Le dejás algo corto a alguien. Lo lee esa persona y nadie más. No se
-- responde: si querés decir algo, vas y le dejás uno vos.
--
-- Las reglas y el por qué de cada una:
--
--   90 caracteres      No es un tope técnico, es la forma. Con 180 alguien
--                      escribe un párrafo y esto se vuelve un chat con pasos
--                      de más. Quedarse corto es el ejercicio.
--
--   uno por persona    Si se pudiera mandar un segundo enseguida, los 90
--   cada 7 días        dejarían de existir: serían 90 + 90 + 90.
--
--   se puede retirar   Para el que se arrepiente. No es mandar dos: es que
--                      nunca haya dos. Se saca uno y se pone otro. Lo que no
--                      se puede retirar es que ya lo haya leído.
--
--   sin visto          Si el que manda supiera que lo leyeron, le crearía a
--                      la otra persona la obligación de contestar. La única
--                      señal de que llegó es que un día te llegue uno.
--
-- Sobre la privacidad: estos mensajes están en esta base y quien tenga la
-- llave los puede leer. Por eso el sitio no promete que nadie más los ve, y
-- por eso acá NO hay ninguna función que los liste para un admin. Moderar
-- necesita borrar, no leer: admin_borrar_susurros_de borra los de una
-- persona a otra sin devolver el texto.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. la tabla
-- ----------------------------------------------------------------------------
create table if not exists public.susurros (
  id          uuid primary key default gen_random_uuid(),
  de          uuid not null references public.miembros(id) on delete cascade,
  para        uuid not null references public.miembros(id) on delete cascade,
  texto       text not null,
  creado_en   timestamptz not null default now(),
  leido_en    timestamptz,
  retirado_en timestamptz,

  constraint susurros_no_a_uno_mismo check (de <> para),
  constraint susurros_largo check (char_length(btrim(texto)) between 1 and 90)
);

-- char_length y no length(): un emoji tiene que contar uno, igual que en la
-- pantalla. Si contaran distinto, habría textos que el contador acepta y la
-- base rechaza.

create index if not exists susurros_para_idx on public.susurros (para, creado_en desc);
create index if not exists susurros_de_idx   on public.susurros (de, para, creado_en desc);

alter table public.susurros enable row level security;
-- sin políticas: a la clave pública esta tabla le devuelve vacío siempre.
-- Todo pasa por las funciones de abajo.


-- ----------------------------------------------------------------------------
-- 2. dejar un susurro
-- ----------------------------------------------------------------------------
create or replace function public.dejar_susurro(
  p_codigo    text,
  p_sektario  text,
  p_texto     text
)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo    uuid := public.miembro_de(p_codigo);
  v_otro  uuid;
  v_sekta boolean;
  v_txt   text := btrim(coalesce(p_texto, ''));
begin
  if char_length(v_txt) = 0 then
    raise exception 'susurro_vacio';
  end if;
  if char_length(v_txt) > 90 then
    raise exception 'susurro_largo';
  end if;

  select m.id, (m.estado_codigo = 'simbolico') into v_otro, v_sekta
    from public.miembros m
   where m.nombre_sektario = btrim(coalesce(p_sektario, ''))
     and m.estado_codigo in ('activo', 'simbolico');

  if v_otro is null then
    raise exception 'no_esta_en_el_padron';
  end if;
  -- LA SEKTA no es alguien: no tiene oídos
  if v_sekta then
    raise exception 'a_la_sekta_no_se_le_susurra';
  end if;
  if v_otro = v_yo then
    raise exception 'no_te_susurres';
  end if;

  if exists (select 1 from public.susurros s
              where s.de = v_yo and s.para = v_otro
                and s.retirado_en is null
                and s.creado_en > now() - interval '7 days') then
    raise exception 'todavia_no';
  end if;

  insert into public.susurros (de, para, texto) values (v_yo, v_otro, v_txt);
  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. retirar el que dejé
-- ----------------------------------------------------------------------------
-- Solo el que lo dejó, y solo si sigue en pie. Retirarlo lo saca de la vista
-- del otro y libera la espera.
create or replace function public.retirar_susurro(p_codigo text, p_id uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_id uuid;
begin
  update public.susurros s
     set retirado_en = now()
   where s.id = p_id
     and s.de = v_yo
     and s.retirado_en is null
  returning s.id into v_id;

  if v_id is null then
    raise exception 'no_se_pudo_retirar';
  end if;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. los que me dejaron
-- ----------------------------------------------------------------------------
-- Devuelve el estado de lectura ANTES de marcarlos, para que la primera vez
-- se vean como nuevos. Entrar a la pantalla es leerlos.
--
-- El que los mandó nunca se entera de esto.
create or replace function public.mis_susurros(p_codigo text)
returns table (
  id          uuid,
  de_sektario text,
  de_nombre   text,
  texto       text,
  creado_en   timestamptz,
  es_nuevo    boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select s.id, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           s.texto, s.creado_en, (s.leido_en is null)
      from public.susurros s
      join public.miembros m on m.id = s.de
     where s.para = v_yo
       and s.retirado_en is null
     order by s.creado_en desc;

  update public.susurros s
     set leido_en = now()
   where s.para = v_yo and s.leido_en is null and s.retirado_en is null;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. cuántos me esperan
-- ----------------------------------------------------------------------------
-- Para el perfil, sin abrirlos ni marcarlos como leídos.
create or replace function public.susurros_nuevos(p_codigo text)
returns table (nuevos int, total int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select count(*) filter (where s.leido_en is null)::int,
           count(*)::int
      from public.susurros s
     where s.para = v_yo and s.retirado_en is null;
end;
$$;


-- ----------------------------------------------------------------------------
-- 6. la ficha aprende a hablar de susurros
-- ----------------------------------------------------------------------------
-- Suma 'susurro': si le dejé uno que sigue en pie, cuál es; y si no, si puedo
-- dejarle uno ahora o cuántos días faltan. Va acá y no en una llamada aparte
-- para que la ficha se pinte de una sola vez.
create or replace function public.ficha_del_sekito(p_codigo text, p_sektario text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_id  uuid;
  v_res jsonb;
begin
  select m.id into v_id
    from public.miembros m
   where m.nombre_sektario = btrim(coalesce(p_sektario, ''))
     and m.estado_codigo in ('activo', 'simbolico');

  if v_id is null then
    raise exception 'no_esta_en_el_padron';
  end if;

  with recursive rama as (
    select m.id, 1 as profundidad
      from public.miembros m
     where m.invitado_por = v_id
       and m.estado_codigo in ('activo', 'simbolico')

    union all

    select h.id, r.profundidad + 1
      from public.miembros h
      join rama r on h.invitado_por = r.id
     where r.profundidad < 20   -- red de seguridad; los ciclos los frena un trigger
       and h.estado_codigo in ('activo', 'simbolico')
  )
  select jsonb_build_object(
    'sektario',  m.nombre_sektario,
    'nombre',    public.nombre_lindo(m.nombre_real),
    'pantalla',  m.pantalla,
    'fundador',  m.es_fundador,
    'es_sekta',  (m.estado_codigo = 'simbolico'),
    'es_vos',    (m.id = v_yo),
    'desde',     least(
                   m.fecha_ingreso,
                   (select min(f.fecha)
                      from public.asistencias a
                      join public.fiestas f on f.id = a.fiesta_id
                     where a.miembro_id = m.id and a.estado = 'confirmada')
                 ),
    'guia',      (select jsonb_build_object(
                           'sektario', q.nombre_sektario,
                           'nombre',   public.nombre_lindo(q.nombre_real))
                    from public.miembros q where q.id = m.invitado_por),
    'directos',  (select count(*) from rama where profundidad = 1),
    'total',     (select count(*) from rama),
    'ritos',     coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'nombre', f.nombre,
                            'fecha',  f.fecha
                          ) order by f.fecha desc)
                     from public.asistencias a
                     join public.fiestas f on f.id = a.fiesta_id
                    where a.miembro_id = m.id
                      and a.estado = 'confirmada'
                 ), '[]'::jsonb),
    'susurro',   case
                   when m.id = v_yo or m.estado_codigo = 'simbolico' then null
                   else coalesce(
                     (select jsonb_build_object(
                               'mio',   true,
                               'id',    s.id,
                               'texto', s.texto,
                               'desde', s.creado_en,
                               'dias',  greatest(0, 7 - floor(extract(epoch from (now() - s.creado_en)) / 86400)::int))
                        from public.susurros s
                       where s.de = v_yo and s.para = m.id
                         and s.retirado_en is null
                         and s.creado_en > now() - interval '7 days'
                       order by s.creado_en desc
                       limit 1),
                     jsonb_build_object('mio', false))
                 end
  ) into v_res
  from public.miembros m
 where m.id = v_id;

  return v_res;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. moderar sin leer
-- ----------------------------------------------------------------------------
-- No hay ninguna función que le devuelva susurros a un admin. Si alguien
-- avisa que le dejaron algo feo, esto borra los de esa persona a la otra,
-- sin devolver el texto. Hay una pantalla para borrar y no la hay para leer:
-- la diferencia entre poder y hacerlo es la única privacidad honesta que
-- podemos ofrecer.
create or replace function public.admin_borrar_susurros_de(
  p_codigo   text,
  p_de       text,
  p_para     text
)
returns table (borrados int)
language plpgsql
security definer
set search_path = public
as $$
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

  delete from public.susurros s where s.de = v_de and s.para = v_para;
  get diagnostics v_n = row_count;

  insert into public.admin_acciones (admin_id, accion, detalle)
  values (v_admin, 'borrar_susurros',
          jsonb_build_object('de', btrim(p_de), 'para', btrim(p_para), 'cuantos', v_n));

  return query select v_n;
end;
$$;


-- ----------------------------------------------------------------------------
-- 8. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.dejar_susurro(text, text, text)            from public;
revoke all on function public.retirar_susurro(text, uuid)                from public;
revoke all on function public.mis_susurros(text)                         from public;
revoke all on function public.susurros_nuevos(text)                      from public;
revoke all on function public.ficha_del_sekito(text, text)               from public;
revoke all on function public.admin_borrar_susurros_de(text, text, text) from public, anon, authenticated;

grant execute on function public.dejar_susurro(text, text, text) to anon, authenticated;
grant execute on function public.retirar_susurro(text, uuid)     to anon, authenticated;
grant execute on function public.mis_susurros(text)              to anon, authenticated;
grant execute on function public.susurros_nuevos(text)           to anon, authenticated;
grant execute on function public.ficha_del_sekito(text, text)    to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select * from public.dejar_susurro('UNCODIGO', 'OTRO·123', 'qué lindo estabas');
-- select * from public.dejar_susurro('UNCODIGO', 'OTRO·123', 'otra vez');  -> todavia_no
-- select * from public.mis_susurros('ELCODIGODELOTRO');
-- select jsonb_pretty(public.ficha_del_sekito('UNCODIGO','OTRO·123')) ;  -> susurro.mio = true
