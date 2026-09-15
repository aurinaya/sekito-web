# SÉKITO — acceso

## Probar en local

**No abras `index.html` con doble clic.** El sitio usa `<canvas>` para generar la imagen de "compartir código" y una máscara CSS (`mask-image`) para el abanico animado. Ambas cosas dependen de que las imágenes en `images/` se carguen desde el mismo origen que la página — algo que los navegadores garantizan por `http(s)://`, pero no por `file://` (ahí cada archivo local se trata como un origen distinto, y el navegador bloquea el canvas y la máscara por seguridad).

Por eso, para probarlo local hay que servirlo con un servidor simple:

```bash
python3 -m http.server 8000
```

y abrir `http://localhost:8000/index.html`.

Una vez desplegado en un hosting real (GitHub Pages, etc.) esto no es un problema — el sitio se sirve por `https://` y todo funciona normal.

## El panel de administración

Está en `/admin/` (`https://www.sekito.ar/admin/`). No está enlazado desde
ninguna parte del sitio y lleva `noindex`, así que no aparece en Google: hay
que escribir la dirección.

Se entra con un **código de administración** de 16 caracteres, uno por
persona, distinto del código de miembro. El código queda guardado sólo
mientras la pestaña esté abierta; al cerrarla hay que volver a ponerlo.

Desde ahí se puede: ver a todos los miembros con su contacto, generar códigos
para gente nueva, suspender y reactivar, corregir datos, ver el linaje y
exportar todo a CSV.

**A un miembro no se lo borra nunca.** Se lo suspende (baja temporal) o se lo
revoca (definitiva). La base lo impide directamente, no es una decisión de esta
pantalla: borrarlo dejaría huérfanos a todos los que esa persona invitó.

## Invitaciones entre miembros

Cualquier miembro activo genera desde su perfil un link de un solo uso:

```
sekito.ar/i/CODIGO
```

El que lo recibe toca, cae en el formulario de bienvenida con su referente ya
cargado, y al terminar recibe un código de acceso propio y permanente. **Ese
código se muestra una sola vez**; si se pierde, está en el panel.

Reglas: un solo uso, vence a los 7 días, hasta 5 abiertas por miembro.

### Por qué existe 404.html

GitHub Pages sirve archivos, no entiende direcciones inventadas: `/i/CODIGO`
no es ninguna carpeta. Pero sirve `404.html` para toda dirección que no
existe, así que ese archivo lee el código y redirige a `/?i=CODIGO`, que sí es
una página real. **Si se borra 404.html, todos los links de invitación dejan
de funcionar.**

Efecto secundario: esa dirección responde 404 antes de redirigir, así que
WhatsApp e Instagram no le arman la tarjetita de vista previa. Para la persona
que lo toca es invisible.

## Los ritos

Cada miembro declara a qué fiestas vino y nombra **dos testigos**. Cuando los
dos dan fe, ese rito queda **atestiguado**. Está en el perfil, botón
*mis ritos*.

**Solo puede dar fe quien ya está atestiguado en esa misma fiesta.** Se puede
nombrar a alguien que todavía no lo está: el pedido espera a que esa persona se
atestigüe y recién ahí puede contestar.

**Los tres fundadores arrancan atestiguados en las 10 fiestas ya pasadas.** Sin
esa siembra el sistema no arranca: si para dar fe hay que estar atestiguado y
nadie lo está, la puerta queda cerrada con la llave adentro. Desde ellos la red
se expande sola.

**LA SEKTA** también puede ser testigo; de esa mitad dan fe los admins, en la
pestaña *validaciones* del panel.

No existe rechazar. Quien no quiere dar fe simplemente no contesta, y el que
pidió puede cambiar de testigo. El botón *avisale* abre WhatsApp con el mensaje
escrito — sin el número de teléfono, para que el sitio no reparta los contactos
de la gente entre sí.

## La base de datos

Vive en Supabase. Las seis tablas están cerradas con RLS y sin políticas: con
la clave pública del sitio no se lee ni se escribe nada directamente. El único
camino son las funciones `SECURITY DEFINER`, que devuelven lo mínimo necesario.

Los archivos `supabase/*.sql` son la fuente de verdad de la estructura. Todos
se pueden correr más de una vez sin romper nada. **Ninguno contiene códigos
reales** — este repositorio es público.
