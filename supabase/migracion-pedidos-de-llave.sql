-- ---------------------------------------------------------------------------
-- PEDIR LA LLAVE SIN ESCRIBIR POR PRIVADO (21/10)
--
-- Se suma al DM, no lo reemplaza. En "no tengo mi llave" alguien deja nombre,
-- su instagram, su mail y cómo llegó al sékito. El pedido le aparece al panel:
-- miran su instagram como siempre y, si le abren la puerta, la base crea la
-- llave (como "crear una llave"), se la manda por mail, y el panel les da el
-- mensaje listo para mandársela también por DM, que es lo más personal.
-- "No" cierra el pedido sin avisarle nada.
--
-- Cualquiera puede pedir (no hace falta llave): por eso hay topes. Un mismo
-- mail o instagram no puede tener dos pedidos abiertos, y entran a lo sumo
-- 40 pedidos por día entre todos.
-- ---------------------------------------------------------------------------

create table if not exists public.pedidos_llave (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  instagram     text not null,
  email         text not null,
  como_llego    text,
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'abierto', 'cerrado')),
  creado_en     timestamptz not null default now(),
  resuelto_en   timestamptz,
  resuelto_por  uuid references public.admins(id),
  miembro_id    uuid references public.miembros(id)
);
alter table public.pedidos_llave enable row level security;

create or replace function public.pedir_llave(p_nombre text, p_instagram text, p_email text, p_como_llego text)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_nombre text := left(btrim(coalesce(p_nombre, '')), 80);
  v_ig     text := lower(left(regexp_replace(btrim(coalesce(p_instagram, '')), '^@+|^https?://(www\.)?instagram\.com/|/.*$', '', 'g'), 40));
  v_mail   text := lower(left(btrim(coalesce(p_email, '')), 120));
  v_como   text := nullif(left(btrim(coalesce(p_como_llego, '')), 500), '');
begin
  if v_nombre = '' or v_ig = '' or v_mail = '' then raise exception 'faltan_datos'; end if;
  if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'mail_invalido'; end if;
  if v_ig !~ '^[a-z0-9._]+$' then raise exception 'instagram_invalido'; end if;

  -- el mismo, dos veces: no hace falta, ya está esperando
  if exists (select 1 from public.pedidos_llave p
              where p.estado = 'pendiente' and (p.email = v_mail or p.instagram = v_ig)) then
    return query select true; return;
  end if;
  if (select count(*) from public.pedidos_llave p where p.creado_en > now() - interval '1 day') >= 40 then
    raise exception 'muchos_pedidos';
  end if;

  insert into public.pedidos_llave (nombre, instagram, email, como_llego)
  values (v_nombre, v_ig, v_mail, v_como);
  return query select true;
end;
$$;
grant execute on function public.pedir_llave(text, text, text, text) to anon;

create or replace function public.admin_pedidos_llave(p_codigo text)
returns table(id uuid, nombre text, instagram text, email text, como_llego text, estado text,
              creado_en timestamptz, resuelto_en timestamptz, resuelto_por text, codigo_acceso text,
              ya_entro boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_id_de(p_codigo);
  return query
    select p.id, p.nombre, p.instagram, p.email, p.como_llego, p.estado, p.creado_en, p.resuelto_en,
           a.nombre, m.codigo_acceso, (m.nombre_real is not null)
      from public.pedidos_llave p
      left join public.admins a   on a.id = p.resuelto_por
      left join public.miembros m on m.id = p.miembro_id
     order by (p.estado = 'pendiente') desc, p.creado_en desc;
end;
$$;

-- el mail con la llave: el mismo sobre de siempre
create or replace function public.mail_tu_llave(p_codigo text, p_baja uuid)
returns text language sql immutable set search_path = public as $$
  select public.mail_sobre(
    '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:19px;letter-spacing:.1em;color:#F2F2F2;padding:0 0 18px">LA SEKTA TE ABRIÓ LA PUERTA</td></tr>'
    || '<tr><td align="center" style="padding:0 0 30px">'
    ||   '<table role="presentation" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="border:1px solid #2A2A2A;background:#141414"><tr><td align="center" style="padding:22px 40px">'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:9px;'
    ||     'letter-spacing:.22em;color:#93A8AC;text-transform:uppercase">tu llave</div>'
    ||     '<div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:30px;'
    ||     'letter-spacing:.2em;color:#F2F2F2;padding-top:12px">' || p_codigo || '</div>'
    ||   '</td></tr></table>'
    || '</td></tr>'
    || '<tr><td align="center" style="font-family:ui-monospace,Menlo,Consolas,monospace;'
    || 'font-size:12px;line-height:1.9;color:#93A8AC;padding:0 0 32px">'
    || '<span style="color:#F2F2F2">Escribila en el portal y entrás.</span><br>'
    || 'Guardala. No la compartas.</td></tr>',
    p_baja, 'https://www.sekito.ar/', 'entrar al sékito');
$$;
revoke execute on function public.mail_tu_llave(text, uuid) from public, anon, authenticated;

create or replace function public.admin_abrir_pedido(p_codigo text, p_pedido uuid)
returns table(codigo_acceso text, instagram text)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
  v_p     record;
  v_nuevo record;
  v_q     record;
begin
  select * into v_p from public.pedidos_llave p where p.id = p_pedido for update;
  if v_p.id is null then raise exception 'pedido_no_existe'; end if;
  if v_p.estado <> 'pendiente' then raise exception 'pedido_resuelto'; end if;

  -- la llave, como "crear una llave" del panel (la trae LA SEKTA)
  select * into v_nuevo from public.admin_crear_miembro(p_codigo,
    'pedido de llave · ' || v_p.nombre || ' · @' || v_p.instagram ||
    coalesce(' · ' || v_p.como_llego, ''), null);

  -- su mail queda puesto (al registrarse lo confirma o lo cambia)
  update public.miembros m set email = v_p.email where m.id = v_nuevo.id;

  update public.pedidos_llave p
     set estado = 'abierto', resuelto_en = now(), resuelto_por = v_admin, miembro_id = v_nuevo.id
   where p.id = p_pedido;

  select q.email, q.baja into v_q from public.a_quien_escribirle(v_nuevo.id) q;
  if v_q.email is not null then
    perform public.encolar_mail(v_q.email, 'tu llave del sékito',
                                public.mail_tu_llave(v_nuevo.codigo_acceso, v_q.baja), 1::smallint);
  end if;

  return query select v_nuevo.codigo_acceso, v_p.instagram;
end;
$$;

create or replace function public.admin_cerrar_pedido(p_codigo text, p_pedido uuid)
returns table(ok boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := public.admin_id_de(p_codigo);
begin
  update public.pedidos_llave p
     set estado = 'cerrado', resuelto_en = now(), resuelto_por = v_admin
   where p.id = p_pedido and p.estado = 'pendiente';
  return query select true;
end;
$$;
