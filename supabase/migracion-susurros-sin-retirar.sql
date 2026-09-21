-- ============================================================================
-- SÉKITO — el susurro no se retira
-- ============================================================================
-- Estaba la posibilidad de sacar el susurro que dejaste. MAU la mandó a
-- volar: "bancate decir algo, bancate haberlo dicho".
--
-- Y tiene razón: retirar era una puerta de atrás para el arrepentimiento, y
-- el arrepentimiento es parte del gesto. Un susurro que se puede deshacer es
-- un borrador.
--
-- Con esto, la espera de siete días también se vuelve firme: no hay forma de
-- acortarla.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

drop function if exists public.retirar_susurro(text, uuid);

-- la columna se va con la función: si nada la escribe, es un campo que
-- miente sobre lo que el sistema puede hacer
alter table public.susurros drop column if exists retirado_en;


-- ----------------------------------------------------------------------------
-- las funciones, sin la condición que ya no existe
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
                and s.creado_en > now() - interval '7 days') then
    raise exception 'todavia_no';
  end if;

  insert into public.susurros (de, para, texto) values (v_yo, v_otro, v_txt);
  return query select true;
end;
$$;


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
     order by s.creado_en desc;

  update public.susurros s
     set leido_en = now()
   where s.para = v_yo and s.leido_en is null;
end;
$$;


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
     where s.para = v_yo;
end;
$$;


-- la ficha: 'susurro.mio' ahora es solo para mostrarte lo que dijiste y
-- cuánto falta. Ya no viene con un id, porque no hay nada que hacerle.
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
                               'texto', s.texto,
                               'desde', s.creado_en,
                               'dias',  greatest(0, 7 - floor(extract(epoch from (now() - s.creado_en)) / 86400)::int))
                        from public.susurros s
                       where s.de = v_yo and s.para = m.id
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


revoke all on function public.dejar_susurro(text, text, text) from public;
revoke all on function public.mis_susurros(text)              from public;
revoke all on function public.susurros_nuevos(text)           from public;
revoke all on function public.ficha_del_sekito(text, text)    from public;

grant execute on function public.dejar_susurro(text, text, text) to anon, authenticated;
grant execute on function public.mis_susurros(text)              to anon, authenticated;
grant execute on function public.susurros_nuevos(text)           to anon, authenticated;
grant execute on function public.ficha_del_sekito(text, text)    to anon, authenticated;
