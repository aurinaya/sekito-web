-- Los dos links sin cumple (31/10). Se corre después de migracion-link-sin-cumple.sql
-- y con el sitio nuevo ya publicado: antes, estas palabras se verían como un cumple.
-- Sin cupo: 500 es el máximo de la columna, más que todo el lugar.
insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil)
select v.palabra, m.id, v.frase,
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       500, '2026-11-14 20:00:00-03'::timestamptz,
       false, v.quien, v.foto, v.instagram, 50000
  from (values
    ('mau',  'MAU·000', 'Mau te llama...',     'Mau',     'mau-000', 'maurosantiagob'),
    ('tano', 'NYA·000', 'El Tano te llama...', 'el Tano', 'nya-000', 'creoquenaya')
  ) as v(palabra, sektario, frase, quien, foto, instagram)
  join public.miembros m on m.nombre_sektario = v.sektario;
