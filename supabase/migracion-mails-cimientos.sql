-- ============================================================================
-- SÉKITO — los cimientos para poder mandar mails
-- ============================================================================
-- Todavía no manda nada. Esto es lo que hace falta ANTES, y que no depende de
-- qué servicio terminemos usando:
--
--   · pg_net, que le da a la base la capacidad de hacer llamadas HTTP. Sin
--     esto no hay forma de avisar nada desde acá sin montar un servidor.
--
--   · poder decir que no. Hoy no existe: si a alguien le molestan los mails,
--     no tiene manera de frenarlos. Eso se agrega antes del primer envío, no
--     después del primer enojo.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. que la base pueda hablar con afuera
-- ----------------------------------------------------------------------------
-- pg_net encola los pedidos y los manda en segundo plano: un mail que tarda
-- no deja colgado a quien apretó el botón.
create extension if not exists pg_net with schema extensions;


-- ----------------------------------------------------------------------------
-- 2. poder decir que no
-- ----------------------------------------------------------------------------
-- El token va en el link de "no quiero más mails" que se pone al pie de cada
-- envío. Es al azar y no dice nada de la persona: quien lo tenga solo puede
-- dar de baja esa casilla, no entrar al portal ni ver nada.
alter table public.miembros
  add column if not exists acepta_mails boolean not null default true,
  add column if not exists baja_mails   uuid;

update public.miembros
   set baja_mails = gen_random_uuid()
 where baja_mails is null;

alter table public.miembros
  alter column baja_mails set default gen_random_uuid(),
  alter column baja_mails set not null;

create unique index if not exists miembros_baja_mails_idx
  on public.miembros (baja_mails);


-- ----------------------------------------------------------------------------
-- 3. darse de baja
-- ----------------------------------------------------------------------------
-- Sin código de acceso a propósito: quien quiere dejar de recibir mails tiene
-- que poder hacerlo de un toque desde el mail, sin entrar a ningún lado.
-- Poner un login en el medio de una baja es una manera elegante de no dejar
-- que se den de baja.
--
-- Nunca devuelve error por token inexistente: decir "ese token no existe"
-- sería confirmarle a cualquiera cuáles sí existen.
create or replace function public.baja_de_mails(p_token uuid)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.miembros m
     set acepta_mails = false
   where m.baja_mails = p_token;

  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. volver a aceptarlos
-- ----------------------------------------------------------------------------
-- Desde adentro del portal, con el código propio: para volver a entrar en la
-- lista sí hay que ser quien uno dice ser.
create or replace function public.acepto_mails_de_nuevo(p_codigo text)
returns table (ok boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  update public.miembros m set acepta_mails = true where m.id = v_yo;
  return query select true;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. permisos
-- ----------------------------------------------------------------------------
revoke all on function public.baja_de_mails(uuid)          from public;
revoke all on function public.acepto_mails_de_nuevo(text)  from public;

grant execute on function public.baja_de_mails(uuid)         to anon, authenticated;
grant execute on function public.acepto_mails_de_nuevo(text) to anon, authenticated;


-- ============================================================================
-- Verificación
-- ============================================================================
-- select count(*) filter (where acepta_mails) as aceptan, count(*) from public.miembros;
-- select extname from pg_extension where extname = 'pg_net';
