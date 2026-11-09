-- SUSURROS DE LA SEKTA PARA SEKI 7 (textos cerrados con Mau el 09/11/2026)
--
-- Tres grupos, un susurro por persona, de LA SEKTA:
--   A  tiene entradas sin asignar (sin contar las guardadas en links)
--   B  del portal sin entrada, lo trajo alguien que va
--   C  del portal sin entrada, no lo trajo nadie que vaya
-- Afuera: fundadores, Diego e Ine (Mau les habló por IG), Hanae (compró el
-- 09/11) y Ailén (lo suyo es un link para juli, que se deja estar).
--
-- Primero se mira la vista susurros_s7 (quién y qué). Mandar es el insert
-- del final: cada susurro dispara el aviso "te susurraron" por la fila.

create or replace view public.susurros_s7 as
with sekta as (
  select id from public.miembros where nombre_sektario = 'LA SEKTA' and estado_codigo = 'simbolico'
),
con_entrada as (
  select distinct x.m from (
    select e.duenio m from public.entradas e where e.evento = 'seki7' and e.anulada_en is null and e.duenio is not null
    union all
    select e.tenedor from public.entradas e where e.evento = 'seki7' and e.anulada_en is null
    union all
    select c.comprador from public.compras c where c.estado in ('a_revisar', 'confirmada')
  ) x
),
afuera as (
  select m.id from public.miembros m
   where m.nota_admin in ('mau · DIEGO', 'link de venta · ine contino')
      or m.nota_admin like 'pedido de llave · Hanae Oka%'
      or m.nombre_sektario = 'LNT·999'                        -- Ailén
),
numero(n, dice) as (values (1,'una'),(2,'dos'),(3,'tres'),(4,'cuatro'),(5,'cinco'),(6,'seis'),(7,'siete')),
a as (
  select e.tenedor para, count(*)::int n
    from public.entradas e
   where e.evento = 'seki7' and e.anulada_en is null and e.duenio is null
     and e.externo_nombre is null and e.para_invitacion is null
   group by e.tenedor
),
grupos as (
  select 'A'::text grupo, m.id para,
         case when a.n = 1
              then 'la sekta sabe que tenés una entrada sin dueñx. asignala, así puede cruzar la puerta.'
              else 'la sekta sabe que tenés ' || nu.dice || ' entradas sin dueñx. asignalas, así pueden cruzar la puerta.'
         end texto
    from a join public.miembros m on m.id = a.para join numero nu on nu.n = a.n
   where m.estado_codigo = 'activo' and not m.es_fundador

  union all

  select case when r.es_fundador or (r.estado_codigo = 'activo' and r.id in (select ce.m from con_entrada ce))
              then 'B' else 'C' end,
         m.id,
         case when r.es_fundador or (r.estado_codigo = 'activo' and r.id in (select ce.m from con_entrada ce))
              then 'entraste de la mano de ' || public.como_le_dicen(r.apodo, coalesce(r.nombre_real, r.nombre_sektario)) ||
                   ', que viene el 14. vos no tenés entrada.. qué esperás?'
              else 'el sékito se vuelve a reunir el sábado. la sekta sabe que no tenés entrada. qué esperás?'
         end
    from public.miembros m
    left join public.miembros r on r.id = m.invitado_por
   where m.estado_codigo = 'activo' and m.nombre_real is not null and not m.es_fundador
     and m.id not in (select ce.m from con_entrada ce)
)
select g.grupo, g.para, public.como_le_dicen(m.apodo, m.nombre_real) nombre, m.email,
       g.texto, char_length(g.texto) largo
  from grupos g join public.miembros m on m.id = g.para
 where g.para not in (select id from afuera)
   -- uno por par cada 7 días, como cualquier susurro
   and not exists (select 1 from public.susurros s, sekta
                    where s.de = sekta.id and s.para = g.para and s.creado_en > now() - interval '7 days');

revoke all on public.susurros_s7 from public, anon, authenticated;

-- MANDAR (solo con el OK de Mau):
-- insert into public.susurros (de, para, texto)
-- select (select id from public.miembros where nombre_sektario = 'LA SEKTA'), para, texto
--   from public.susurros_s7 where largo <= 90;
