-- El link de Flor (31/10), como el de Mau y el Tano pero sin el precio de 35 (cupo 0, desde el 01/11).
-- Hasta el 14/11 a las 20.
insert into public.anfitriones (palabra, anfitrion, frase, tanda_cumple, tanda_bancar, cupo, hasta,
                                es_cumple, quien_dice, foto, instagram, precio_remil)
select 'flor', m.id, 'La Reina te llama...',
       (select t.id from public.tandas t where t.nombre = 'hermética'),
       (select t.id from public.tandas t where t.nombre = 'abierta'),
       0, '2026-11-14 20:00:00-03'::timestamptz,
       false, 'la Reina', 'flr-000', 'flordirocco', 50000
  from public.miembros m where m.nombre_sektario = 'FLR·000';
