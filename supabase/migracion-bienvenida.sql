-- ============================================================================
-- SÉKITO — formulario de bienvenida: estructura, datos y funciones
-- ============================================================================
-- Pegalo completo en Supabase → SQL Editor → Run.
-- Se puede correr más de una vez sin romper nada.
--
-- Este archivo SÍ va al repo: no contiene ningún código de acceso real.
-- (schema.sql queda actualizado con lo mismo, para una instalación desde cero.)
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. columnas nuevas
-- ----------------------------------------------------------------------------
alter table public.fiestas  add column if not exists lugar         text;
alter table public.miembros add column if not exists apellido      text;
alter table public.miembros add column if not exists como_llegaste text;

comment on column public.miembros.como_llegaste is
  'Nota libre que deja la persona al registrarse cuando no hay un referente claro. Solo para revisar desde administración.';

-- el nombre sektario se genera recién al registrarse, así que deja de ser
-- obligatorio: un miembro puede existir (con su código) antes de tener nombre
alter table public.miembros alter column nombre_sektario drop not null;

-- un estado más: FISURA existe como opción de "quién te trajo" pero nunca
-- puede entrar. 'simbolico' en vez de 'revocado' porque no fue revocada:
-- nunca fue una persona.
alter table public.miembros drop constraint if exists miembros_estado_codigo_check;
alter table public.miembros add  constraint miembros_estado_codigo_check
  check (estado_codigo in ('activo', 'suspendido', 'revocado', 'simbolico'));

-- evita cargar dos veces la misma fiesta
create unique index if not exists fiestas_nombre_key on public.fiestas (nombre);


-- ----------------------------------------------------------------------------
-- 2. las fiestas
-- ----------------------------------------------------------------------------
-- las fechas llevan el huso -03 explícito para que el día sea el correcto
-- en Argentina y no se corra al guardarse en UTC
insert into public.fiestas (nombre, fecha, lugar) values
  ('Seki 1',        '2023-10-27 00:00:00-03', 'Serrano'),
  ('Seki 2',        '2024-04-05 00:00:00-03', 'Rincón'),
  ('Seki 3',        '2024-10-05 00:00:00-03', 'Santa Fe'),
  ('Seki 4',        '2025-04-30 00:00:00-03', 'Palacete'),
  ('Seki 5',        '2025-10-18 00:00:00-03', 'Shamrock'),
  ('Seki 6',        '2026-05-09 00:00:00-03', 'Wax'),
  ('Seki 7',        '2026-11-14 00:00:00-03', 'Frida Club'),   -- sede tentativa
  ('Burning Party', '2025-07-19 00:00:00-03', 'Shamrock'),
  ('COLAPSO',       '2026-07-25 00:00:00-03', 'The Lift'),
  ('Tiny Sekta 1',  '2025-10-25 00:00:00-03', 'casa de Panchito'),
  ('Tiny Sekta 2',  '2026-05-23 00:00:00-03', 'casa de Nahue')
on conflict (nombre) do nothing;


-- ----------------------------------------------------------------------------
-- 3. FISURA
-- ----------------------------------------------------------------------------
-- Para quienes llegaron sin un referente puntual. Es la única "persona" que se
-- carga desde el repo, porque no es una persona: no tiene datos reales y su
-- código no sirve para entrar (estado 'simbolico', que validar_codigo filtra).
insert into public.miembros (codigo_acceso, nombre_sektario, estado_codigo, es_fundador)
values ('NOLOGIN', 'FISURA', 'simbolico', false)
on conflict (codigo_acceso) do nothing;


-- ----------------------------------------------------------------------------
-- 4. generar_nombre_sektario()
-- ----------------------------------------------------------------------------
-- Arma el nombre público a partir del nombre real: tres consonantes + un
-- número sorteado entre 001 y 999 (el 000 queda reservado a los fundadores).
--
-- Para que dos personas de nombre parecido no compartan las mismas tres
-- letras, toma TODAS las consonantes disponibles y prueba las combinaciones
-- de a tres, en el orden en que las letras aparecen en el nombre, hasta dar
-- con un prefijo que nadie esté usando. Juan Pérez (J,N,P,R,Z) da diez:
--   JNP · JNR · JNZ · JPR · JPZ · JRZ · NPR · NPZ · NRZ · PRZ
-- El primer Juan Pérez se lleva JNP; el segundo, JNR; y así.
--
-- Si se agotaran las diez, vuelve a la primera y distingue por número: nunca
-- se queda sin nombres, solo vuelve al comportamiento anterior.
--
-- Usa random() y no un generador criptográfico a propósito: el número de
-- miembro es público, no es una credencial. El código de acceso, que sí lo es,
-- se sortea aparte y fuera de la base.
create or replace function public.generar_nombre_sektario(p_nombre text, p_apellido text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_texto text;
  v_cons  text := '';   -- todas las consonantes, en orden
  v_resto text := '';   -- vocales de reserva, por si no llega a tres
  v_pref  text;
  v_cand  text;
  n       int;
  a int; b int; c int; i int;
  ch text;
begin
  -- saca tildes sin depender de la extensión unaccent
  v_texto := upper(translate(
    coalesce(p_nombre, '') || coalesce(p_apellido, ''),
    'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ',
    'aaaaaeeeeiiiiooooouuuuAAAAAEEEEIIIIOOOOOUUUU'));

  for i in 1..length(v_texto) loop
    ch := substr(v_texto, i, 1);
    if ch ~ '[A-ZÑ]' then
      if ch in ('A','E','I','O','U') then
        v_resto := v_resto || ch;
      else
        v_cons := v_cons || ch;
      end if;
    end if;
  end loop;

  -- nombres sin tres consonantes (Ana, Aia): se completa con vocales, y si aún
  -- falta, con X
  while length(v_cons) < 3 loop
    if length(v_resto) > 0 then
      v_cons  := v_cons || substr(v_resto, 1, 1);
      v_resto := substr(v_resto, 2);
    else
      v_cons := v_cons || 'X';
    end if;
  end loop;

  n := length(v_cons);

  -- 1) la primera combinación de tres que no use nadie
  for a in 1 .. n - 2 loop
    for b in a + 1 .. n - 1 loop
      for c in b + 1 .. n loop
        v_pref := substr(v_cons, a, 1) || substr(v_cons, b, 1) || substr(v_cons, c, 1);
        if not exists (
          select 1 from public.miembros m where m.nombre_sektario like v_pref || '·%'
        ) then
          return v_pref || '·' || lpad((floor(random() * 999) + 1)::int::text, 3, '0');
        end if;
      end loop;
    end loop;
  end loop;

  -- 2) todas tomadas: vuelve a la primera y que distinga el número
  v_pref := substr(v_cons, 1, 3);
  for i in 1..200 loop
    v_cand := v_pref || '·' || lpad((floor(random() * 999) + 1)::int::text, 3, '0');
    if not exists (select 1 from public.miembros m where m.nombre_sektario = v_cand) then
      return v_cand;
    end if;
  end loop;

  raise exception 'no quedan nombres libres para %', v_cons;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. buscar_miembros() — el autocompletado de "¿quién te trajo?"
-- ----------------------------------------------------------------------------
-- Exige un código válido, mínimo 3 letras y devuelve como máximo 8. Nunca
-- devuelve teléfono ni mail. Acota el volcado de la lista, no lo impide:
-- quien tenga un código y paciencia puede recorrerla.
create or replace function public.buscar_miembros(p_codigo text, p_query text)
returns table (
  id               uuid,
  nombre_sektario  text,
  nombre_real      text,
  apellido         text
)
language sql
security definer
set search_path = public
as $$
  select m.id, m.nombre_sektario, m.nombre_real, m.apellido
    from public.miembros m
   where exists (
           select 1 from public.miembros c
            where c.codigo_acceso = upper(btrim(p_codigo))
              and c.estado_codigo = 'activo'
         )
     and length(btrim(coalesce(p_query, ''))) >= 3
     -- solo miembros vigentes y FISURA: un código suspendido o revocado no
     -- tiene por qué seguir ofreciéndose como "quién te trajo"
     and m.estado_codigo in ('activo', 'simbolico')
     and (
           m.nombre_sektario ilike '%' || btrim(p_query) || '%'
        or m.nombre_real     ilike '%' || btrim(p_query) || '%'
        or m.apellido        ilike '%' || btrim(p_query) || '%'
         )
   order by m.nombre_real nulls last, m.nombre_sektario
   limit 8;
$$;


-- ----------------------------------------------------------------------------
-- 6. completar_registro()
-- ----------------------------------------------------------------------------
-- Guarda los datos de la persona del código y de nadie más.
-- Dos recaudos:
--   * solo funciona si el registro no estaba completo, así un código filtrado
--     no sirve para pisarle los datos a alguien que ya se registró;
--   * solo genera el nombre sektario si está vacío, para no sobrescribir el de
--     quien ya tiene uno (los fundadores y sus ·000).
-- se le cambió el retorno (ahora incluye nombre_real), y Postgres no permite
-- eso con "create or replace": hay que borrarla y recrearla. Al borrarla se
-- pierden los permisos, por eso se vuelven a otorgar más abajo.
drop function if exists public.completar_registro(text, text, text, text, text, uuid, text);

create function public.completar_registro(
  p_codigo        text,
  p_nombre        text,
  p_apellido      text,
  p_email         text,
  p_telefono      text,
  p_invitado_por  uuid,
  p_como_llegaste text
)
returns table (
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
  v_id         uuid;
  v_sektario   text;
  v_fundador   boolean;
  v_ya         boolean;
  v_cand       text;
  i            int;
begin
  select m.id, m.nombre_sektario, m.es_fundador, (m.nombre_real is not null)
    into v_id, v_sektario, v_fundador, v_ya
    from public.miembros m
   where m.codigo_acceso = upper(btrim(p_codigo))
     and m.estado_codigo = 'activo';

  if v_id is null then
    raise exception 'codigo_invalido';
  end if;

  if v_ya then
    raise exception 'registro_ya_completo';
  end if;

  if btrim(coalesce(p_nombre, ''))   = '' or btrim(coalesce(p_apellido, '')) = ''
  or btrim(coalesce(p_email, ''))    = '' or btrim(coalesce(p_telefono, '')) = '' then
    raise exception 'faltan_datos';
  end if;

  -- a los fundadores no los trajo nadie; al resto sí
  if not v_fundador and p_invitado_por is null then
    raise exception 'falta_invitado_por';
  end if;

  for i in 1..50 loop
    begin
      if v_sektario is null then
        v_cand := public.generar_nombre_sektario(p_nombre, p_apellido);
      else
        v_cand := v_sektario;
      end if;

      update public.miembros m set
        nombre_real     = btrim(p_nombre),
        apellido        = btrim(p_apellido),
        email           = btrim(p_email),
        telefono        = btrim(p_telefono),
        invitado_por    = p_invitado_por,
        como_llegaste   = nullif(btrim(coalesce(p_como_llegaste, '')), ''),
        nombre_sektario = v_cand
      where m.id = v_id;

      exit;  -- salió bien
    exception when unique_violation then
      -- si ya tenía nombre, la colisión no es del número: que salte
      if v_sektario is not null then
        raise;
      end if;
      -- si no, el loop vuelve a sortear
    end;
  end loop;

  return query
    select m.nombre_sektario,
           m.nombre_real,
           m.pantalla,
           m.fecha_ingreso,
           m.es_fundador,
           quien.nombre_sektario,
           true
      from public.miembros m
      left join public.miembros quien on quien.id = m.invitado_por
     where m.id = v_id;
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. validar_codigo() ahora dice si la persona ya se registró
-- ----------------------------------------------------------------------------
-- cambia el tipo de retorno, así que hay que borrarla y recrearla; eso borra
-- los permisos, por eso se vuelven a otorgar al final
drop function if exists public.validar_codigo(text);

create function public.validar_codigo(p_codigo text)
returns table (
  nombre_sektario      text,
  nombre_real          text,
  pantalla             text,
  fecha_ingreso        timestamptz,
  es_fundador          boolean,
  invitado_por_nombre  text,
  registro_completo    boolean
)
language sql
security definer
set search_path = public
as $$
  select
    m.nombre_sektario,
    m.nombre_real,
    m.pantalla,
    m.fecha_ingreso,
    m.es_fundador,
    quien.nombre_sektario           as invitado_por_nombre,
    (m.nombre_real is not null)     as registro_completo
  from public.miembros m
  left join public.miembros quien on quien.id = m.invitado_por
  where m.codigo_acceso = upper(btrim(p_codigo))
    and m.estado_codigo = 'activo'
  limit 1;
$$;


-- ----------------------------------------------------------------------------
-- 8. permisos
-- ----------------------------------------------------------------------------
-- generar_nombre_sektario NO se expone: solo la usa completar_registro desde
-- adentro de la base. Si fuera pública, cualquiera podría quemar prefijos.
revoke all on function public.generar_nombre_sektario(text, text) from public, anon, authenticated;

revoke all on function public.validar_codigo(text) from public;
grant execute on function public.validar_codigo(text) to anon, authenticated;

revoke all on function public.buscar_miembros(text, text) from public;
grant execute on function public.buscar_miembros(text, text) to anon, authenticated;

revoke all on function public.completar_registro(text, text, text, text, text, uuid, text) from public;
grant execute on function public.completar_registro(text, text, text, text, text, uuid, text) to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select nombre, to_char(fecha, 'DD/MM/YYYY') as fecha, lugar
--   from public.fiestas order by fecha;                    -> 11 fiestas
--
-- select * from public.validar_codigo('NOLOGIN');          -> 0 filas (FISURA no entra)
-- select * from public.validar_codigo('TGV725');           -> registro_completo = false
-- select * from public.buscar_miembros('TGV725', 'fis');   -> FISURA
