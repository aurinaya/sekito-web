-- 18/11/2026 · los siete pecados, de qué estás manija, y la placa de S7
--
-- Va DESPUÉS de lo-que-dejo-s7.sql (usa estuvo_en_s7).
--
-- 1. Los siete pecados. Las estampitas de S7, en el portal: cada uno tiene las
--    siete para ofrendar, una a cada quien (a cualquiera del sékito). El pecado
--    es de quien la da y quien la recibe es la causa; los textos viven en el
--    portal, acá solo el pecado. Siempre anónimas: quien recibe ve una pista
--    (se arma al ofrendar y no cambia). Cuando ofrendaste las siete, podés
--    preguntar UNA sola vez quién te dio una.
-- 2. El aviso: "alguien cayó en pecado por vos", al toque, cada vez que alguien
--    te ofrenda una (sale por la fila de mails). No dice quién ni qué dice la
--    carta: avisa, el portal cuenta. Publicar esto no manda ningún mail: solo
--    salen cuando alguien ofrenda.
-- 3. Lo próximo: de qué estás manija (SEKI, COLAPSO, TINY SEKTA o una
--    propuesta). Una sola, se puede cambiar. El resultado lo ve el panel.
-- 4. La placa de S7 en devotxs y en la ficha: buscar_en_el_sekito y
--    ficha_del_sekito devuelven estuvo_s7.
--
-- Se puede correr más de una vez.

-- ================================================================ tablas
create table if not exists public.ofrendas (
  id         uuid primary key default gen_random_uuid(),
  de         uuid not null references public.miembros(id),
  para       uuid not null references public.miembros(id),
  pecado     text not null check (pecado in ('soberbia','avaricia','lujuria','ira','gula','envidia','pereza')),
  pista      text,
  creada_en  timestamptz not null default now(),
  vista_en   timestamptz,
  avisado_en timestamptz,
  constraint ofrenda_no_a_vos   check (de <> para),
  constraint ofrenda_un_pecado  unique (de, pecado),   -- cada carta, una vez
  constraint ofrenda_una_por_persona unique (de, para) -- una a cada quien
);
create index if not exists ofrendas_para on public.ofrendas (para);
create index if not exists ofrendas_sin_avisar on public.ofrendas (para) where avisado_en is null;
alter table public.ofrendas enable row level security;

-- la única pregunta de cada uno
create table if not exists public.ofrendas_reveladas (
  miembro_id uuid primary key references public.miembros(id),
  ofrenda_id uuid not null unique references public.ofrendas(id),
  creada_en  timestamptz not null default now()
);
alter table public.ofrendas_reveladas enable row level security;

create table if not exists public.manija (
  miembro_id   uuid primary key references public.miembros(id),
  opcion       text not null check (opcion in ('seki','colapso','tiny','otro')),
  idea         text check (idea is null or char_length(idea) <= 60),
  cambiado_en  timestamptz not null default now()
);
alter table public.manija enable row level security;

-- ================================================================ la pista
-- de qué fundador (o de LA SEKTA) cuelga cada uno: "tu misma rama"
create or replace function public.raiz_de(p_miembro uuid)
returns uuid language sql stable security definer set search_path = public as $$
  with recursive arriba as (
    select m.id, m.invitado_por, 0 as n from public.miembros m where m.id = p_miembro
    union all
    select m.id, m.invitado_por, a.n + 1
      from public.miembros m join arriba a on m.id = a.invitado_por
     where a.n < 30
  )
  select id from arriba order by n desc limit 1;
$$;

create or replace function public.pista_de(p_de uuid, p_para uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  d record; p record; op text[] := '{}';
begin
  select * into d from public.miembros where id = p_de;
  select * into p from public.miembros where id = p_para;
  op := op || case when public.estuvo_en_s7(p_de) then 'estuvo en S7.' else 'no estuvo en S7.' end;
  op := op || case when coalesce(d.registrado_en, d.creado_en) < coalesce(p.registrado_en, p.creado_en)
                   then 'llegó a la sekta antes que vos.' else 'llegó a la sekta después que vos.' end;
  if public.raiz_de(p_de) = public.raiz_de(p_para) then
    op := op || 'es de tu misma rama del árbol.'::text;
  end if;
  op := op || ('su nombre sektario empieza con ' || left(d.nombre_sektario, 1) || '.');
  return op[1 + floor(random() * array_length(op, 1))::int];
end;
$$;

-- ================================================================ el aviso por mail
-- Sale una por cada carta, al toque, desde ofrendar_pecado. Nunca dice quién ni qué.
create or replace function public.mail_ofrendas(p_nombre text, p_pecados text[], p_baja uuid)
returns text language sql immutable set search_path = public as $$
  select public.mail_sobre(
    '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:10px;letter-spacing:.22em;'
    || 'color:#93A8AC;text-transform:uppercase;padding:0 0 18px">los siete pecados</td></tr>'
    || case when array_length(p_pecados, 1) = 1 then
         '<tr><td align="center" style="padding:0 0 24px"><img src="https://www.sekito.ar/images/estampitas/' || p_pecados[1]
         || '.jpg" width="130" alt="" style="display:block;border:0;width:130px"></td></tr>'
       else '' end
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;line-height:1.7;'
    || 'color:#F2F2F2;padding:0 0 6px">' || coalesce(p_nombre, '') || ',</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:19px;line-height:1.5;'
    || 'letter-spacing:.1em;color:#F2F2F2;padding:0 0 14px">'
    || case when array_length(p_pecados, 1) = 1
            then 'ALGUIEN CAYÓ EN ' || upper(p_pecados[1]) || '<br>POR VOS'
            else array_length(p_pecados, 1) || ' CAYERON EN PECADO<br>POR VOS' end
    || '</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;line-height:1.7;'
    || 'color:#93A8AC;padding:0 0 30px">'
    || case when array_length(p_pecados, 1) = 1
            then 'te dejó una confesión en tu altar.<br>no sabés quién fue. todavía.'
            else 'te dejaron sus confesiones en tu altar.<br>no sabés quiénes fueron. todavía.' end
    || '</td></tr>',
    p_baja, 'https://www.sekito.ar/', 'ver mi altar');
$$;

-- ================================================================ portal
-- todo lo de cada uno, de una: las que dio, las que le dieron y su pregunta
create or replace function public.mis_ofrendas(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_yo  uuid := public.miembro_de(p_codigo);
  v_rev uuid := (select r.ofrenda_id from public.ofrendas_reveladas r where r.miembro_id = v_yo);
begin
  return jsonb_build_object(
    'dadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pecado', o.pecado, 'a', public.como_le_dicen(m.apodo, m.nombre_real),
               'a_sektario', m.nombre_sektario, 'cuando', o.creada_en) order by o.creada_en)
        from public.ofrendas o join public.miembros m on m.id = o.para
       where o.de = v_yo), '[]'::jsonb),
    'recibidas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'pecado', o.pecado, 'cuando', o.creada_en, 'pista', o.pista,
               'nueva', o.vista_en is null,
               'quien',          case when o.id = v_rev then public.como_le_dicen(m.apodo, m.nombre_real) end,
               'quien_sektario', case when o.id = v_rev then m.nombre_sektario end,
               'quien_s7',       case when o.id = v_rev then public.estuvo_en_s7(m.id) end) order by o.creada_en)
        from public.ofrendas o join public.miembros m on m.id = o.de
       where o.para = v_yo), '[]'::jsonb),
    'revelada', v_rev
  );
end;
$$;

-- a quién: cualquiera del sékito menos vos y LA SEKTA
create or replace function public.buscar_para_ofrendar(p_codigo text, p_query text)
returns table(sektario text, titulo text, estuvo_s7 boolean, ya_le_di boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_q  text := btrim(coalesce(p_query, ''));
begin
  if length(v_q) < 2 then return; end if;
  return query
    select m.nombre_sektario, public.como_le_dicen(m.apodo, m.nombre_real), public.estuvo_en_s7(m.id),
           exists (select 1 from public.ofrendas o where o.de = v_yo and o.para = m.id)
      from public.miembros m
     where m.estado_codigo = 'activo'
       and m.nombre_sektario is not null
       and m.nombre_real is not null
       and m.id <> v_yo
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
     order by public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc, m.nombre_real
     limit 8;
end;
$$;

create or replace function public.ofrendar_pecado(p_codigo text, p_pecado text, p_sektario text)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo    uuid := public.miembro_de(p_codigo);
  v_para  uuid;
  v_id    uuid;
  v_quien record;
begin
  if p_pecado not in ('soberbia','avaricia','lujuria','ira','gula','envidia','pereza') then
    raise exception 'pecado_invalido';
  end if;
  select m.id into v_para from public.miembros m
   where m.nombre_sektario = btrim(coalesce(p_sektario, ''))
     and m.estado_codigo = 'activo' and m.nombre_real is not null;
  if v_para is null then raise exception 'no_esta_en_el_padron'; end if;
  if v_para = v_yo then raise exception 'a_vos_no'; end if;
  if exists (select 1 from public.ofrendas o where o.de = v_yo and o.pecado = p_pecado) then raise exception 'ya_ofrendada'; end if;
  if exists (select 1 from public.ofrendas o where o.de = v_yo and o.para = v_para) then raise exception 'ya_le_diste'; end if;
  insert into public.ofrendas (de, para, pecado, pista)
  values (v_yo, v_para, p_pecado, public.pista_de(v_yo, v_para))
  returning id into v_id;
  -- el aviso, al toque (quien no recibe mails igual lo ve en el portal)
  select * into v_quien from public.a_quien_escribirle(v_para);
  if v_quien.email is not null then
    perform public.encolar_mail(
      v_quien.email, 'alguien cayó en pecado por vos',
      public.mail_ofrendas((select public.como_le_dicen(m.apodo, m.nombre_real) from public.miembros m where m.id = v_para),
                           array[p_pecado], v_quien.baja),
      3::smallint);
  end if;
  update public.ofrendas set avisado_en = now() where id = v_id;
  return query select true;
exception when unique_violation then
  raise exception 'ya_ofrendada';
end;
$$;

-- la miró: deja de ser nueva
create or replace function public.ver_ofrenda(p_codigo text, p_id uuid)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare v_yo uuid := public.miembro_de(p_codigo);
begin
  update public.ofrendas set vista_en = now() where id = p_id and para = v_yo and vista_en is null;
  return query select true;
end;
$$;

-- la única pregunta: después de ofrendar las siete, y por una que te dieron a vos
create or replace function public.revelar_ofrenda(p_codigo text, p_id uuid)
returns table(quien text, quien_sektario text, quien_s7 boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
  v_de uuid;
begin
  if (select count(*) from public.ofrendas o where o.de = v_yo) < 7 then raise exception 'faltan_ofrendar'; end if;
  select o.de into v_de from public.ofrendas o where o.id = p_id and o.para = v_yo;
  if v_de is null then raise exception 'no_es_tuya'; end if;
  insert into public.ofrendas_reveladas (miembro_id, ofrenda_id) values (v_yo, p_id)
  on conflict (miembro_id) do nothing;
  if not found then raise exception 'ya_preguntaste'; end if;
  return query
    select public.como_le_dicen(m.apodo, m.nombre_real), m.nombre_sektario, public.estuvo_en_s7(m.id)
      from public.miembros m where m.id = v_de;
end;
$$;

-- lo próximo: de qué estás manija, y si pidió enterarse
create or replace function public.mi_proximo(p_codigo text)
returns table(manija text, idea text, quiero_saber boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_yo uuid := public.miembro_de(p_codigo);
begin
  return query select
    (select x.opcion from public.manija x where x.miembro_id = v_yo),
    (select x.idea from public.manija x where x.miembro_id = v_yo),
    exists (select 1 from public.quieren_saber q where q.miembro_id = v_yo);
end;
$$;

create or replace function public.elegir_manija(p_codigo text, p_opcion text, p_idea text)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_yo   uuid := public.miembro_de(p_codigo);
  v_idea text := nullif(btrim(coalesce(p_idea, '')), '');
begin
  if p_opcion not in ('seki','colapso','tiny','otro') then raise exception 'opcion_invalida'; end if;
  if p_opcion = 'otro' and v_idea is null then raise exception 'falta_la_propuesta'; end if;
  if p_opcion <> 'otro' then v_idea := null; end if;
  insert into public.manija (miembro_id, opcion, idea) values (v_yo, p_opcion, left(v_idea, 60))
  on conflict (miembro_id) do update set opcion = excluded.opcion, idea = excluded.idea, cambiado_en = now();
  return query select true;
end;
$$;

-- ================================================================ la placa en devotxs y en la ficha
drop function if exists public.buscar_en_el_sekito(text, text);
create function public.buscar_en_el_sekito(p_codigo text, p_query text)
 returns table(sektario text, nombre text, pantalla text, es_sekta boolean, nombre_completo text, estuvo_s7 boolean)
 language plpgsql security definer set search_path to 'public'
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
           public.nombre_con_inicial(m.nombre_real, m.apellido),
           public.estuvo_en_s7(m.id)
      from public.miembros m
     where m.estado_codigo in ('activo', 'simbolico')
       and m.nombre_sektario is not null
       and public.coincide(v_q, m.nombre_sektario, m.nombre_real, public.inicial_apellido(m.apellido), m.apodo)
     order by
       public.empieza(v_q, m.nombre_sektario, m.nombre_real, m.apodo) desc,
       m.nombre_real nulls last
     limit 8;

  perform v_yo;
end;
$function$;
grant execute on function public.buscar_en_el_sekito(text, text) to anon, authenticated;

create or replace function public.ficha_del_sekito(p_codigo text, p_sektario text)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $function$
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
    'nombre',    public.como_le_dicen(m.apodo, m.nombre_real),
    'pantalla',  m.pantalla,
    'fundador',  m.es_fundador,
    'es_sekta',  (m.estado_codigo = 'simbolico'),
    'es_vos',    (m.id = v_yo),
    'estuvo_s7', public.estuvo_en_s7(m.id),
    'desde',     least(
                   m.fecha_ingreso,
                   (select min(f.fecha)
                      from public.asistencias a
                      join public.fiestas f on f.id = a.fiesta_id
                     where a.miembro_id = m.id and a.estado = 'confirmada')
                 ),
    'guia',      (select jsonb_build_object(
                           'sektario', q.nombre_sektario,
                           'nombre',   public.como_le_dicen(q.apodo, q.nombre_real))
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
$function$;

-- ================================================================ panel
create or replace function public.admin_pecados(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return jsonb_build_object(
    'ofrendas',   (select count(*) from public.ofrendas),
    'dieron',     (select count(distinct de) from public.ofrendas),
    'las_siete',  (select count(*) from (select de from public.ofrendas group by de having count(*) = 7) x),
    'recibieron', (select count(distinct para) from public.ofrendas),
    'preguntas',  (select count(*) from public.ofrendas_reveladas),
    'por_pecado', coalesce((select jsonb_object_agg(pecado, n) from
                    (select pecado, count(*) n from public.ofrendas group by pecado) x), '{}'::jsonb)
  );
end;
$$;

create or replace function public.admin_manija(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return jsonb_build_object(
    'por_opcion', coalesce((select jsonb_object_agg(opcion, n) from
                    (select opcion, count(*) n from public.manija group by opcion) x), '{}'::jsonb),
    'propuestas', coalesce((select jsonb_agg(jsonb_build_object(
                    'sektario', m.nombre_sektario, 'nombre', public.como_le_dicen(m.apodo, m.nombre_real),
                    'idea', x.idea, 'cuando', x.cambiado_en) order by x.cambiado_en desc)
                    from public.manija x join public.miembros m on m.id = x.miembro_id
                   where x.opcion = 'otro'), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.mis_ofrendas(text), public.buscar_para_ofrendar(text, text),
  public.ofrendar_pecado(text, text, text), public.ver_ofrenda(text, uuid), public.revelar_ofrenda(text, uuid),
  public.mi_proximo(text), public.elegir_manija(text, text, text),
  public.admin_pecados(text), public.admin_manija(text) to anon, authenticated;
revoke execute on function public.raiz_de(uuid), public.pista_de(uuid, uuid),
  public.mail_ofrendas(text, text[], uuid) from public, anon, authenticated;
