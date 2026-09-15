-- ============================================================================
-- SÉKITO — integridad del linaje
-- ============================================================================
-- Tres reglas que la base va a hacer cumplir por su cuenta, sin depender de
-- que el panel de administración esté bien escrito:
--
--   1. a un miembro no se lo borra: se lo suspende o se lo revoca
--   2. nadie puede ser su propio invitador
--   3. no puede haber círculos en el linaje (A trajo a B, B trajo a C,
--      C trajo a A)
--
-- Por qué en la base y no en el panel: el panel es una pantalla, y siempre hay
-- otra forma de llegar a los datos (el editor de Supabase, una consulta suelta,
-- un bug). Lo que se define acá vale para todos los caminos.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. a los miembros no se los borra
-- ----------------------------------------------------------------------------
-- Borrar un miembro no solo pierde su historia: deja huérfanos a todos los que
-- él invitó (la clave foránea les vacía el invitado_por en silencio) y arrastra
-- sus asistencias y entradas. Un miembro dado de baja sigue siendo parte del
-- árbol; lo que se corta es el acceso, no la existencia.
--
--   estado_codigo = 'suspendido'  -> baja temporal, se puede reactivar
--   estado_codigo = 'revocado'    -> baja definitiva

create or replace function public.miembros_no_se_borran()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'Los miembros no se borran. Usá estado_codigo = ''suspendido'' o ''revocado''.'
    using errcode = 'restrict_violation';
end;
$$;

drop trigger if exists miembros_no_se_borran on public.miembros;

create trigger miembros_no_se_borran
  before delete on public.miembros
  for each row
  execute function public.miembros_no_se_borran();

-- Si alguna vez hiciera falta borrar de verdad (por ejemplo, alguien pide que
-- se eliminen sus datos), se desactiva el candado, se borra y se vuelve a
-- poner. A propósito requiere dos pasos conscientes:
--
--   alter table public.miembros disable trigger miembros_no_se_borran;
--   delete from public.miembros where id = '...';
--   alter table public.miembros enable trigger miembros_no_se_borran;


-- ----------------------------------------------------------------------------
-- 2. nadie es su propio invitador
-- ----------------------------------------------------------------------------
-- El caso más fácil de meter sin querer desde un panel: elegirse a uno mismo
-- en la lista de "quién te trajo".

alter table public.miembros drop constraint if exists miembros_no_autoinvitado;

alter table public.miembros add constraint miembros_no_autoinvitado
  check (invitado_por is null or invitado_por <> id);


-- ----------------------------------------------------------------------------
-- 3. sin círculos en el linaje
-- ----------------------------------------------------------------------------
-- Un círculo no es un árbol. Si A trajo a B, B trajo a C y a C se le pone A
-- como invitador, no existe ningún "primero": cualquier dibujo del árbol que
-- intente subir por esa cadena da vueltas para siempre.
--
-- Cada vez que se asigna un invitador, esto sube por la cadena de invitadores
-- hasta la raíz. Si en el camino se encuentra al propio miembro, lo rechaza.

create or replace function public.miembros_sin_ciclos()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_actual uuid := new.invitado_por;
  v_pasos  int  := 0;
begin
  while v_actual is not null loop
    if v_actual = new.id then
      raise exception
        'Círculo en el linaje: el invitador elegido desciende de este mismo miembro.'
        using errcode = 'check_violation';
    end if;

    -- red de seguridad: si por algún motivo ya existiera un círculo en los
    -- datos, este bucle no terminaría nunca. Ninguna cadena real va a tener
    -- cien eslabones.
    v_pasos := v_pasos + 1;
    if v_pasos > 100 then
      raise exception 'Cadena de linaje demasiado larga (más de 100 invitadores).'
        using errcode = 'check_violation';
    end if;

    select m.invitado_por into v_actual
      from public.miembros m
     where m.id = v_actual;
  end loop;

  return new;
end;
$$;

drop trigger if exists miembros_sin_ciclos on public.miembros;

create trigger miembros_sin_ciclos
  before insert or update of invitado_por on public.miembros
  for each row
  when (new.invitado_por is not null)
  execute function public.miembros_sin_ciclos();


-- ============================================================================
-- Verificación (las tres tienen que FALLAR)
-- ============================================================================
-- delete from public.miembros where codigo_acceso = 'ALGUNCOD';
--   -> "Los miembros no se borran"
--
-- update public.miembros set invitado_por = id where codigo_acceso = 'ALGUNCOD';
--   -> viola "miembros_no_autoinvitado"
--
-- Y con dos miembros A y B donde A invitó a B, poner B como invitador de A:
--   -> "Círculo en el linaje"
