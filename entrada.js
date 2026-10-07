/* ===========================================================================
   LA ENTRADA DE SEKI 7 — la tarjeta

   La dibujan el portal (la tuya, para guardarla) y el panel (la de alguien
   de afuera, para mandársela por WhatsApp). Es la misma imagen en los dos
   lados, y es la misma que se ve y la que se guarda.

   window.dibujarEntrada({ codigo, tipo, nombre, apellido, apodo, sektario })
   devuelve un canvas de 1080 × 1000.
   =========================================================================== */
(function(){
  /* --- la tarjeta de la entrada ---
     Dibujada a mano para que la imagen que se guarda sea idéntica a la que
     se ve. La identidad del portal: negro, el abanico, la tipografía de
     siempre, y el bordo del cartel de SEKI 7 como una mancha difusa detrás
     del QR. El QR va negro sobre blanco: invertido lo leen peor algunas
     cámaras, y en la puerta no hay tiempo para probar dos veces. */
  const LIB_QR = 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js';
  let qrListo = null;
  function cargarQR(){
    if (window.qrcode) return Promise.resolve();
    if (!qrListo) qrListo = new Promise((ok, mal) => {
      const sc = document.createElement('script');
      sc.src = LIB_QR; sc.onload = ok; sc.onerror = mal;
      document.head.appendChild(sc);
    });
    return qrListo;
  }
  function imagen(src){
    return new Promise((ok, mal) => { const i = new Image(); i.onload = () => ok(i); i.onerror = mal; i.src = src; });
  }
  // Texto con tracking. Alinea al centro o a la izquierda; si no entra en
  // "max", achica la letra hasta que entre
  function letras(x, px, y, txt, peso, tam, color, ls, alinear, max){
    txt = String(txt || '');
    let t = tam;
    const medir = () => {
      x.font = peso + ' ' + t + 'px ' + MONO;
      return [...txt].reduce((a, c) => a + x.measureText(c).width, 0) + ls * Math.max(txt.length - 1, 0);
    };
    let total = medir();
    while (max && total > max && t > 12){ t -= 1; total = medir(); }
    x.fillStyle = color; x.textBaseline = 'middle'; x.textAlign = 'left';
    let p = alinear === 'izq' ? px : px - total / 2;
    for (const c of txt){ x.fillText(c, p, y); p += x.measureText(c).width + ls; }
  }
  // un nombre largo se parte en dos renglones antes de achicarse
  function partir(x, txt, peso, tam, ls, max){
    x.font = peso + ' ' + tam + 'px ' + MONO;
    const ancho = s => [...s].reduce((a, c) => a + x.measureText(c).width, 0) + ls * Math.max(s.length - 1, 0);
    if (ancho(txt) <= max) return [txt];
    const palabras = txt.split(' ');
    for (let k = palabras.length - 1; k > 0; k--){
      const uno = palabras.slice(0, k).join(' ');
      if (ancho(uno) <= max) return [uno, palabras.slice(k).join(' ')];
    }
    return [txt];
  }

  const MONO = '"IBM Plex Mono", ui-monospace, monospace';
  const BLANCO = '#F2F2F2', CLARO = '#C9D3D5', GRIS = '#93A8AC', BORDO_CLARO = '#C9566E';

  /* "La entrada de papel": arriba la fiesta, una línea de troquel, y abajo
     el QR a la izquierda y la persona a la derecha. 1080 × 1000, casi
     cuadrada: entra entera en la pantalla del celu sin achicar el QR. */
  window.dibujarEntrada = async function dibujarEntrada(e){
    await Promise.all([
      cargarQR(),
      document.fonts.load('400 40px "IBM Plex Mono"'),
      document.fonts.load('500 40px "IBM Plex Mono"'),
    ]);
    const abanico = await imagen('/images/abanico-seki.svg');

    const W = 1080, H = 1000, cx = W / 2;
    const c = document.createElement('canvas'); c.width = W; c.height = H;
    const x = c.getContext('2d');
    const QR_X = 84, QR_Y = 432, QR_L = 400;

    // el fondo, y la mancha bordo difusa del cartel, detrás del QR
    x.fillStyle = '#0D0D0D'; x.fillRect(0, 0, W, H);
    const g = x.createRadialGradient(QR_X + QR_L / 2, QR_Y + QR_L / 2, 30, QR_X + QR_L / 2, QR_Y + QR_L / 2, 520);
    g.addColorStop(0, 'rgba(128,0,32,.85)');
    g.addColorStop(.45, 'rgba(128,0,32,.36)');
    g.addColorStop(1, 'rgba(128,0,32,0)');
    x.fillStyle = g; x.fillRect(0, 0, W, H);

    // arriba: el abanico y la fiesta
    const aw = 104;
    x.drawImage(abanico, cx - aw / 2, 58, aw, aw * 335.754 / 516.569);
    letras(x, cx, 182, 'SEKI 7', 500, 54, BLANCO, 12);
    letras(x, cx, 250, 'SÁBADO 14 · NOVIEMBRE · 23 H', 400, 23, CLARO, 6);
    letras(x, cx, 296, 'DORREGO 1735 · PALERMO · BS AS', 400, 21, CLARO, 5);

    // la línea punteada del troquel, como una entrada de verdad
    x.strokeStyle = 'rgba(201,211,213,.35)'; x.setLineDash([10, 10]); x.lineWidth = 2;
    x.beginPath(); x.moveTo(60, 372); x.lineTo(W - 60, 372); x.stroke(); x.setLineDash([]);

    // el QR: el código, nada más. Negro sobre blanco, en píxeles enteros (si
    // no, entre cuadradito y cuadradito quedan rayitas)
    const qr = window.qrcode(0, 'M'); qr.addData(e.codigo); qr.make();
    const n = qr.getModuleCount(), margen = Math.round(QR_L * .075);
    const celda = Math.floor((QR_L - margen * 2) / n), lado = celda * n;
    const qx = Math.round(QR_X + (QR_L - lado) / 2), qy = Math.round(QR_Y + (QR_L - lado) / 2);
    x.fillStyle = BLANCO; x.beginPath(); x.roundRect(QR_X, QR_Y, QR_L, QR_L, 20); x.fill();
    x.fillStyle = '#0D0D0D';
    for (let r = 0; r < n; r++) for (let k = 0; k < n; k++)
      if (qr.isDark(r, k)) x.fillRect(qx + k * celda, qy + r * celda, celda, celda);

    // a la derecha: el código y la persona
    const L = 548, ANCHO = W - L - 70;
    letras(x, L, 482, e.codigo, 500, 44, BLANCO, 8, 'izq', ANCHO);
    x.fillStyle = 'rgba(201,211,213,.3)'; x.fillRect(L, 528, 300, 1);

    const titulo = (e.apodo || e.nombre || '').toUpperCase();
    const completo = [e.nombre, e.apellido].filter(Boolean).join(' ');
    letras(x, L, 590, titulo, 500, 42, BLANCO, 6, 'izq', ANCHO);
    // el nombre completo va siempre que diga algo más que el título: con
    // apodo, el nombre; sin apodo, el nombre con el apellido
    let y = 646;
    if (completo && completo.toUpperCase() !== titulo){
      for (const renglon of partir(x, completo, 400, 26, 2, ANCHO)){
        letras(x, L, y, renglon, 400, 26, CLARO, 2, 'izq', ANCHO);
        y += 38;
      }
      y += 12;
    }
    letras(x, L, y, e.sektario || 'de afuera', 400, 24, GRIS, 5, 'izq', ANCHO);

    // qué entrada es
    const tipo = (e.tipo === 'staff' || e.tipo === 'free') ? e.tipo : 'tanda ' + e.tipo;
    letras(x, L, 790, tipo.toUpperCase(), 400, 21, BORDO_CLARO, 6, 'izq', ANCHO);
    letras(x, cx, 930, 'SEKITO.AR', 400, 18, 'rgba(147,168,172,.6)', 6);

    return c;
  };
})();
