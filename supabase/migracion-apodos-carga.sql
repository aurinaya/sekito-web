-- ============================================================================
-- SÉKITO — los apodos de los que ya tenían perfil con nombre propio
-- ============================================================================
-- Hasta acá el título del perfil de seis personas era un apodo elegido a
-- mano en el código (MAU, LUCHI, NAYA…). Ahora el apodo vive con cada
-- persona, así que se les carga el mismo: el título no cambia, y desde ahora
-- también se los ve así en devotxs, la rama, los pedidos de fe y los
-- susurros. Cada uno lo puede cambiar desde su perfil.
--
-- Va en el mismo momento en que se publica el sitio que lee el apodo de la
-- base. Sólo pisa a quien todavía no eligió uno.
-- ============================================================================

update public.miembros m
   set apodo = v.apodo
  from (values ('MAU·000', 'MAU'),
               ('LCN·105', 'LUCHI'),
               ('NYA·000', 'NAYA'),
               ('MDL·842', 'MAIA'),
               ('FLR·000', 'FLOR'),
               ('VLR·173', 'VALE')) as v(sektario, apodo)
 where m.nombre_sektario = v.sektario
   and m.apodo is null;
