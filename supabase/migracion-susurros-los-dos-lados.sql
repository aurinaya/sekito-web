-- ============================================================================
-- SÉKITO — en mis susurros están los dos lados
-- ============================================================================
-- Estaban solo los que te dejaron. Faltaba lo que dijiste vos: sin eso, una
-- semana después no te acordás a quién le susurraste ni qué le pusiste, y
-- justamente no se puede retirar ni volver a mandar hasta los siete días.
--
-- Una sola función para los dos lados, con una marca de quién es cada uno:
-- son la misma cosa mirada desde las dos puntas.
--
-- Se puede correr más de una vez sin romper nada.
-- ============================================================================

drop function if exists public.mis_susurros(text);

create or replace function public.mis_susurros(p_codigo text)
returns table (
  id        uuid,
  mio       boolean,   -- true: lo dejé yo. false: me lo dejaron.
  sektario  text,      -- la otra punta: a quién, o de quién
  nombre    text,
  texto     text,
  creado_en timestamptz,
  es_nuevo  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yo uuid := public.miembro_de(p_codigo);
begin
  return query
    select s.id, false, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           s.texto, s.creado_en, (s.leido_en is null)
      from public.susurros s
      join public.miembros m on m.id = s.de
     where s.para = v_yo

    union all

    -- los que dejé yo: "es_nuevo" no aplica y va en false. El que los mandó
    -- no tiene que enterarse de si los leyeron, ni siquiera cuando es uno mismo.
    select s.id, true, m.nombre_sektario, public.nombre_lindo(m.nombre_real),
           s.texto, s.creado_en, false
      from public.susurros s
      join public.miembros m on m.id = s.para
     where s.de = v_yo

     order by 2, 6 desc;   -- primero los que me dejaron, y dentro de cada lado lo más nuevo

  update public.susurros s
     set leido_en = now()
   where s.para = v_yo and s.leido_en is null;
end;
$$;

revoke all on function public.mis_susurros(text) from public;
grant execute on function public.mis_susurros(text) to anon, authenticated;
