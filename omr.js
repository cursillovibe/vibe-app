/* VIBE · Hoja de respuestas: el diseño (PDF) y la lectura con la cámara (OMR).
   Todo sale de las mismas medidas en milímetros, así lo que se imprime es exactamente lo que se lee.
   Sin dependencias: funciona en el navegador (window.OMR) y en Node (pruebas). */
(function (root) {
  'use strict';

  const FORMATOS = {
    ing:   { id: 'ing',   cod: 0, nombre: 'Ingeniería', preguntas: 20, opciones: 5, geo: 'vibe' },
    becas: { id: 'becas', cod: 1, nombre: 'Becas',      preguntas: 40, opciones: 4, geo: 'vibe' },
    med:   { id: 'med',   cod: 2, nombre: 'Medicina',   preguntas: 60, opciones: 5, geo: 'unca' },
  };
  const LETRAS = 'abcde';

  // ---------- medidas de la hoja (A4, mm) ----------
  const MK = { s: 10, pts: [[14, 14], [196, 14], [196, 283], [14, 283]] };   // marcas: arriba izq, arriba der, abajo der, abajo izq
  const ORI = { x: 27.5, y: 14, s: 4.5 };                                    // marca chica: dice dónde está "arriba"
  const COD = { y: 14, s: 4, xs: [88, 105, 122] };                           // código del formato (un cuadradito lleno)
  const TEL = '0994 214 571';                                                // WhatsApp del cursillo
  // dos diseños: 'vibe' (la matriz de siempre de Ingeniería y Becas: datos a la izquierda, cédula a la derecha)
  // y 'unca' (copia de la hoja de Medicina de la UNCA: cédula a la izquierda, datos a la derecha)
  const GEO = {
    vibe: { ci: { cols: 7, x0: 112, dx: 9, y0: 57.5, dy: 6.2, r: 2.4, cajaY: 44, cajaH: 7.5 },
            fila: { n: 2, x: 181, y0: 57.5, dy: 6.2, r: 2.4 },
            res: { y0: 136, dy: 7.2, r: 2.7, dx: 8.2, porCol: 20, lx: 8, b0: 14, cols: [22, 84] },
            letras: 'abcde', nombre: [48, 41.5] },
    unca: { ci: { cols: 8, x0: 25.5, dx: 7.5, y0: 72, dy: 6, r: 2.3, cajaY: 58.5, cajaH: 7 },
            fila: { n: 4, x: 93, y0: 72, dy: 6, r: 2.3 },
            res: { y0: 146, dy: 6.75, r: 2.5, dx: 7.4, porCol: 20, lx: 7.5, b0: 12.5 },
            letras: 'ABCDE', nombre: [140, 58] },
  };

  function layout(fid) {
    const f = FORMATOS[fid]; if (!f) throw new Error('Formato de hoja desconocido: ' + fid);
    const b = [];                                       // todas las burbujas: {x, y, r, blk}
    const add = (x, y, r, blk) => (b.push({ x, y, r, blk }), b.length - 1);
    const G = GEO[f.geo], CI = G.ci, FILA = G.fila, RES = G.res;
    const ci = [];
    for (let c = 0; c < CI.cols; c++) { const col = []; for (let d = 0; d < 10; d++) col.push(add(CI.x0 + c * CI.dx, CI.y0 + d * CI.dy, CI.r, 0)); ci.push(col); }
    const fila = []; for (let k = 0; k < FILA.n; k++) fila.push(add(FILA.x, FILA.y0 + k * FILA.dy, FILA.r, 0));
    const ncol = Math.ceil(f.preguntas / RES.porCol);
    let xs = RES.cols;
    if (!xs) {
      const ancho = RES.b0 + (f.opciones - 1) * RES.dx + RES.r, gap = ncol === 3 ? 16 : ncol === 2 ? 30 : 0, x1 = 105 - (ncol * ancho + (ncol - 1) * gap) / 2;
      xs = Array.from({ length: ncol }, (_, c) => x1 + c * (ancho + gap));
    }
    const preg = [];
    for (let q = 0; q < f.preguntas; q++) {
      const c = Math.floor(q / RES.porCol), i = q % RES.porCol, x0 = xs[c], y = RES.y0 + i * RES.dy;
      const blk = 1 + c * 2 + (i < 10 ? 0 : 1);         // cada media columna se alinea por su cuenta (hoja un poco doblada)
      const ops = []; for (let j = 0; j < f.opciones; j++) ops.push(add(x0 + RES.b0 + j * RES.dx, y, RES.r, blk));
      preg.push({ n: q + 1, lx: x0 + RES.lx, y, ops });
    }
    return { f, G, b, ci, fila, preg, nblk: 1 + ncol * 2, cajaY: CI.cajaY, cajaH: CI.cajaH, nombre: G.nombre };
  }

  // ---------- PDF (jsPDF) ----------
  // o: { logo: {data, w, h}, tel, examen, fecha }
  function pdf(doc, fid, o) {
    o = o || {};
    const L = layout(fid), f = L.f, G = L.G, CI = G.ci, FILA = G.fila, tel = o.tel || TEL;
    const T = (s, x, y, opt) => doc.text(String(s), x, y, opt || {});
    const tinta = () => doc.setTextColor(26, 26, 26);
    doc.setFillColor(0, 0, 0);
    MK.pts.forEach(([x, y]) => doc.rect(x - MK.s / 2, y - MK.s / 2, MK.s, MK.s, 'F'));
    doc.rect(ORI.x - ORI.s / 2, ORI.y - ORI.s / 2, ORI.s, ORI.s, 'F');
    doc.rect(COD.xs[f.cod] - COD.s / 2, COD.y - COD.s / 2, COD.s, COD.s, 'F');
    const burbuja = (i, txt, fs) => { const p = L.b[i]; doc.setDrawColor(0, 0, 0); doc.setLineWidth(0.4); doc.circle(p.x, p.y, p.r, 'S'); doc.setTextColor(150, 150, 150); doc.setFont('helvetica', 'bold'); doc.setFontSize(fs); T(txt, p.x, p.y + fs * 0.125, { align: 'center' }); };
    const cajasCI = () => {
      doc.setDrawColor(0, 0, 0); doc.setLineWidth(0.3);
      for (let c = 0; c < CI.cols; c++) doc.rect(CI.x0 + c * CI.dx - CI.dx / 2, CI.cajaY, CI.dx, CI.cajaH, 'S');
      doc.rect(FILA.x - CI.dx / 2, CI.cajaY, CI.dx, CI.cajaH, 'S');
      L.ci.forEach(col => col.forEach((i, d) => burbuja(i, d, 6)));
      L.fila.forEach((i, k) => burbuja(i, k + 1, 6));
    };
    const linea = (lab, x, y, x2, val, punteada) => { T(lab, x, y); const w = doc.getTextWidth(lab) + 1.5; if (punteada) doc.setLineDashPattern([0.5, 0.8], 0); doc.setDrawColor(punteada ? 120 : 0); doc.setLineWidth(punteada ? 0.3 : 0.35); doc.line(x + w, y + 0.6, x2, y + 0.6); doc.setLineDashPattern([], 0); if (val) { doc.setFont('helvetica', 'normal'); T(val, x + w + 1, y - 0.3); doc.setFont('helvetica', 'bold'); } };

    if (f.geo === 'vibe') {
      // la matriz de siempre: teléfono del cursillo y logo arriba, datos y ejemplo a la izquierda, cédula a la derecha
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(12); T(tel, 22, 29);
      if (o.logo && o.logo.data) { const w = 38, h = w * o.logo.h / o.logo.w; doc.addImage(o.logo.data, 'PNG', 188 - w, 26.5 - h / 2, w, h); }
      else { doc.setFontSize(13); T('Cursillo VIBE', 188, 29, { align: 'right' }); }
      doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(130, 130, 130);
      T(`Hoja de respuestas · ${f.nombre}`, 105, 29, { align: 'center' });
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(10);
      linea('Nombres:', 22, 42, 100); linea('Apellidos:', 22, 50, 100);
      if (o.examen || o.fecha) { doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(90, 90, 90); T([o.examen, o.fecha].filter(Boolean).join(' · '), 22, 34.5); tinta(); }
      // ejemplo del llenado
      doc.setDrawColor(0, 0, 0); doc.setLineWidth(0.4); doc.rect(22, 56, 82, 62, 'S');
      doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); tinta();
      ['Ejemplo del', 'llenado correcto de', 'celdas y burbujas'].forEach((t, k) => T(t, 25, 70 + k * 5.2));
      doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); T('Marca correcta', 27, 93);
      doc.setFillColor(60, 60, 60); doc.circle(37, 99, 1.9, 'F');
      ['a', 'b', 'c', 'd'].forEach((l, k) => { const x = 27 + k * 6.2, y = 107.5; doc.setDrawColor(0); doc.setLineWidth(0.3); if (k === 1) { doc.setFillColor(60, 60, 60); doc.circle(x, y, 1.9, 'FD'); } else { doc.circle(x, y, 1.9, 'S'); doc.setTextColor(150, 150, 150); doc.setFontSize(5.5); T(l, x, y + 0.7, { align: 'center' }); } });
      doc.setTextColor(90, 90, 90); doc.setFontSize(7); T('Usá bolígrafo negro o azul.', 25, 115);
      const ej = '4173820';
      for (let c = 0; c < 7; c++) {
        const x = 63.5 + c * 5; doc.setDrawColor(0); doc.setLineWidth(0.3); doc.rect(x - 2.5, 59, 5, 6, 'S');
        doc.setTextColor(70, 70, 70); doc.setFont('helvetica', 'normal'); doc.setFontSize(9); T(ej[c], x, 63.6, { align: 'center' });
        for (let d = 0; d < 10; d++) { const y = 69.5 + d * 4.55; if (+ej[c] === d) { doc.setFillColor(60, 60, 60); doc.circle(x, y, 1.3, 'F'); } else { doc.setDrawColor(0); doc.setLineWidth(0.2); doc.circle(x, y, 1.3, 'S'); doc.setTextColor(150, 150, 150); doc.setFontSize(3.8); T(d, x, y + 0.5, { align: 'center' }); } }
      }
      // cédula y fila
      doc.setDrawColor(0, 0, 0); doc.setLineWidth(0.4); doc.rect(106, 36, 84, 82, 'S');
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5);
      T('Número de Cédula de Identidad:', 109, 41.5); T('Fila:', FILA.x, 41.5, { align: 'center' });
      cajasCI();
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5);
      T('RESPUESTAS DE LOS ITEMS PROPUESTOS', 105, 128.5, { align: 'center' });
      // sello de agua, donde no hay burbujas
      if (o.logo && o.logo.data && doc.GState) { try { doc.saveGraphicsState(); doc.setGState(new doc.GState({ opacity: 0.07 })); const w = 52, h = w * o.logo.h / o.logo.w; doc.addImage(o.logo.data, 'PNG', 160 - w / 2, 210, w, h); doc.restoreGraphicsState(); } catch (e) { /* sin sello */ } }
    } else {
      // copia de la hoja de Medicina de la UNCA
      if (o.logo && o.logo.data) { const w = 40, h = w * o.logo.h / o.logo.w; doc.addImage(o.logo.data, 'PNG', 22, 27 - h / 2 + 3, w, h); }
      else { doc.setFont('helvetica', 'bold'); doc.setFontSize(18); tinta(); T('VIBE', 22, 32); }
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(15);
      T('HOJA DE RESPUESTAS', 128, 27, { align: 'center' });
      doc.setFont('helvetica', 'normal'); doc.setFontSize(10);
      T(`Cursillo VIBE · ${f.nombre} · ${f.preguntas} preguntas (${'ABCDE'.slice(0, f.opciones).split('').join(', ')})`, 128, 33, { align: 'center' });
      doc.setFontSize(9); doc.setTextColor(90, 90, 90); T(tel, 128, 38.5, { align: 'center' });
      doc.setDrawColor(251, 133, 0); doc.setLineWidth(0.7); doc.line(22, 44, 188, 44);
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(9);
      T('Cédula de identidad', 22, 55.5); T('Fila', FILA.x, 55.5, { align: 'center' });
      cajasCI();
      doc.setDrawColor(60, 60, 60); doc.setLineWidth(0.3); doc.roundedRect(104, 50, 86, 41, 2, 2, 'S');
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(9);
      linea('Nombre y apellido:', 108, 59, 186, '', true);
      linea('Grupo:', 108, 68, 146, '', true); linea('Fecha:', 149, 68, 186, o.fecha || '', true);
      linea('Examen:', 108, 77, 186, o.examen || '', true);
      linea('Firma:', 108, 86, 186, '', true);
      doc.setDrawColor(60, 60, 60); doc.setLineWidth(0.3); doc.roundedRect(104, 95, 86, 33, 2, 2, 'S');
      doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5); T('Cómo llenar la hoja', 108, 100.5);
      doc.setFont('helvetica', 'normal'); doc.setFontSize(7.3); doc.setTextColor(40, 40, 40);
      ['1. Usá bolígrafo negro o azul (no lápiz).', '2. Rellená el círculo completo, sin salirte.', '3. Escribí tu cédula en los cuadros (desde', '    la izquierda) y marcá cada número abajo.', '4. Marcá la fila de tu examen.', '5. No dobles la hoja ni tapes los cuadrados', '    negros de las esquinas.'].forEach((t, k) => T(t, 108, 105 + k * 3.25));
      doc.setFont('helvetica', 'bold'); doc.setFontSize(7.5); tinta();
      T('Correcto', 167, 104); T('Incorrecto', 167, 114.5);
      doc.setDrawColor(0, 0, 0); doc.setLineWidth(0.35); doc.setFillColor(0, 0, 0);
      doc.circle(170, 108.3, 1.9, 'FD');
      const cx = [169, 175, 181], cy = 118.8;
      cx.forEach(x => doc.circle(x, cy, 1.9, 'S'));
      doc.setLineWidth(0.5);
      doc.line(cx[0] - 1, cy, cx[0] - 0.2, cy + 0.9); doc.line(cx[0] - 0.2, cy + 0.9, cx[0] + 1.2, cy - 1.1);
      doc.line(cx[1] - 1.1, cy - 1.1, cx[1] + 1.1, cy + 1.1); doc.line(cx[1] - 1.1, cy + 1.1, cx[1] + 1.1, cy - 1.1);
      doc.setLineWidth(0.9); doc.line(cx[2] - 0.6, cy - 1.3, cx[2] - 0.6, cy + 1.3); doc.line(cx[2] - 1.2, cy - 0.8, cx[2] - 1.2, cy + 0.8);
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(11);
      T('RESPUESTAS DE LOS EJERCICIOS', 105, 137.5, { align: 'center' });
    }

    // respuestas
    const fsN = f.geo === 'vibe' ? 10 : 9, fsL = f.geo === 'vibe' ? 7.5 : 6.5;
    L.preg.forEach(p => {
      tinta(); doc.setFont('helvetica', 'bold'); doc.setFontSize(fsN);
      T(p.n, p.lx, p.y + fsN * 0.13, { align: 'right' });
      p.ops.forEach((i, j) => burbuja(i, G.letras[j], fsL));
    });
    doc.setTextColor(120, 120, 120); doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5);
    T(`Cursillo VIBE · ${tel} · No dobles la hoja ni tapes los cuadrados negros`, 105, 284.2, { align: 'center' });
    return doc;
  }

  // ---------- lectura ----------
  function gris(rgba, w, h) {
    const g = new Uint8Array(w * h);
    for (let i = 0, j = 0; i < g.length; i++, j += 4) g[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
    return g;
  }

  function homografia(src, dst) {   // src: puntos de la hoja (mm), dst: puntos de la imagen (px)
    const A = [], B = [];
    for (let i = 0; i < 4; i++) {
      const [X, Y] = src[i], [x, y] = dst[i];
      A.push([X, Y, 1, 0, 0, 0, -X * x, -Y * x]); B.push(x);
      A.push([0, 0, 0, X, Y, 1, -X * y, -Y * y]); B.push(y);
    }
    for (let c = 0; c < 8; c++) {
      let p = c; for (let r = c + 1; r < 8; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
      if (Math.abs(A[p][c]) < 1e-12) return null;
      [A[c], A[p]] = [A[p], A[c]]; [B[c], B[p]] = [B[p], B[c]];
      for (let r = 0; r < 8; r++) if (r !== c) { const k = A[r][c] / A[c][c]; if (k) { for (let j = c; j < 8; j++) A[r][j] -= k * A[c][j]; B[r] -= k * B[c]; } }
    }
    const h = B.map((v, i) => v / A[i][i]); h.push(1); return h;
  }
  const proyectar = (H, X, Y) => { const w = H[6] * X + H[7] * Y + 1; return [(H[0] * X + H[1] * Y + H[2]) / w, (H[3] * X + H[4] * Y + H[5]) / w]; };

  function muestreador(g, w, h) {
    return (x, y) => {
      if (x < 0) x = 0; else if (x > w - 1.001) x = w - 1.001;
      if (y < 0) y = 0; else if (y > h - 1.001) y = h - 1.001;
      const x0 = x | 0, y0 = y | 0, fx = x - x0, fy = y - y0, i = y0 * w + x0;
      const a = g[i] + (g[i + 1] - g[i]) * fx, b = g[i + w] + (g[i + w + 1] - g[i + w]) * fx;
      return a + (b - a) * fy;
    };
  }

  // busca las 4 marcas negras de las esquinas en una versión chica de la imagen
  function buscarMarcas(g, w, h) {
    const k = Math.max(1, Math.round(Math.max(w, h) / 900)), sw = Math.floor(w / k), sh = Math.floor(h / k);
    let s = g;
    if (k > 1) {
      s = new Uint8Array(sw * sh); const kk = k * k;
      for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) { let t = 0; for (let yy = 0; yy < k; yy++) { const o = (y * k + yy) * w + x * k; for (let xx = 0; xx < k; xx++) t += g[o + xx]; } s[y * sw + x] = t / kk; }
    }
    // umbral adaptativo (Bradley) con imagen integral
    const I = new Float64Array((sw + 1) * (sh + 1));
    for (let y = 0; y < sh; y++) { let fila = 0; for (let x = 0; x < sw; x++) { fila += s[y * sw + x]; I[(y + 1) * (sw + 1) + x + 1] = I[y * (sw + 1) + x + 1] + fila; } }
    const R = Math.max(8, Math.round(Math.max(sw, sh) / 14)), bin = new Uint8Array(sw * sh);
    for (let y = 0; y < sh; y++) {
      const y1 = Math.max(0, y - R), y2 = Math.min(sh, y + R + 1);
      for (let x = 0; x < sw; x++) {
        const x1 = Math.max(0, x - R), x2 = Math.min(sw, x + R + 1), n = (x2 - x1) * (y2 - y1);
        const t = I[y2 * (sw + 1) + x2] - I[y1 * (sw + 1) + x2] - I[y2 * (sw + 1) + x1] + I[y1 * (sw + 1) + x1];
        if (s[y * sw + x] * n < t * 0.8) bin[y * sw + x] = 1;
      }
    }
    // componentes conectadas
    const lab = new Int32Array(sw * sh), st = new Int32Array(sw * sh), comps = [];
    const md = Math.max(sw, sh), minA = Math.max(12, (md * 0.008) ** 2), maxA = (md * 0.13) ** 2;
    let n = 0;
    for (let p0 = 0; p0 < sw * sh; p0++) {
      if (!bin[p0] || lab[p0]) continue;
      n++; let top = 0; st[top++] = p0; lab[p0] = n;
      let a = 0, sx = 0, sy = 0, x1 = sw, x2 = 0, y1 = sh, y2 = 0;
      while (top) {
        const p = st[--top], x = p % sw, y = (p - x) / sw;
        a++; sx += x; sy += y; if (x < x1) x1 = x; if (x > x2) x2 = x; if (y < y1) y1 = y; if (y > y2) y2 = y;
        for (let dy = -1; dy <= 1; dy++) { const yy = y + dy; if (yy < 0 || yy >= sh) continue; for (let dx = -1; dx <= 1; dx++) { const xx = x + dx; if (xx < 0 || xx >= sw) continue; const q = yy * sw + xx; if (bin[q] && !lab[q]) { lab[q] = n; st[top++] = q; } } }
      }
      if (a < minA || a > maxA) continue;
      const bw = x2 - x1 + 1, bh = y2 - y1 + 1, asp = bw / bh, fill = a / (bw * bh);
      if (asp < 0.35 || asp > 2.8 || fill < 0.45) continue;
      if (x1 === 0 || y1 === 0 || x2 === sw - 1 || y2 === sh - 1) continue;
      comps.push({ a, x: sx / a, y: sy / a, fill });
    }
    comps.sort((p, q) => q.a - p.a);
    const C = comps.slice(0, 24), tw = MK.pts[1][0] - MK.pts[0][0], th = MK.pts[3][1] - MK.pts[0][1];
    const quads = [];
    for (let i = 0; i < C.length; i++) for (let j = i + 1; j < C.length; j++) for (let l = j + 1; l < C.length; l++) for (let m = l + 1; m < C.length; m++) {
      const P = [C[i], C[j], C[l], C[m]];
      const amax = Math.max(P[0].a, P[1].a, P[2].a, P[3].a), amin = Math.min(P[0].a, P[1].a, P[2].a, P[3].a);
      if (amax > amin * 4.5) continue;
      const cx = (P[0].x + P[1].x + P[2].x + P[3].x) / 4, cy = (P[0].y + P[1].y + P[2].y + P[3].y) / 4;
      P.sort((p, q) => Math.atan2(p.y - cy, p.x - cx) - Math.atan2(q.y - cy, q.x - cx));
      let area = 0, conv = true, sg = 0;
      for (let t = 0; t < 4; t++) {
        const A = P[t], B = P[(t + 1) % 4], D = P[(t + 2) % 4];
        area += A.x * B.y - B.x * A.y;
        const cr = (B.x - A.x) * (D.y - B.y) - (B.y - A.y) * (D.x - B.x);
        if (!sg) sg = Math.sign(cr); else if (Math.sign(cr) !== sg) conv = false;
      }
      area = Math.abs(area) / 2; if (!conv || !(area > 0)) continue;
      // cada marca tiene que medir lo que corresponde a su esquina (con perspectiva, las cercanas se ven más grandes)
      let mal = false;
      for (let t = 0; t < 4 && !mal; t++) {
        const A = P[t], B1 = P[(t + 1) % 4], B2 = P[(t + 3) % 4];
        const loc = Math.abs((B1.x - A.x) * (B2.y - A.y) - (B1.y - A.y) * (B2.x - A.x)) / (tw * th), esp = MK.s * MK.s * loc;
        if (A.a < esp * 0.4 || A.a > esp * 2.2) mal = true;
      }
      if (mal) continue;
      const d = (A, B) => Math.hypot(A.x - B.x, A.y - B.y);
      const l1 = (d(P[0], P[1]) + d(P[2], P[3])) / 2, l2 = (d(P[1], P[2]) + d(P[3], P[0])) / 2;
      const rel = Math.max(l1, l2) / Math.min(l1, l2);
      if (rel < 1.1 || rel > 2.1) continue;
      quads.push({ area, P });
    }
    // de mayor a menor; si la primera no resulta ser la hoja (algo oscuro del fondo), se prueban las siguientes
    quads.sort((a, b) => b.area - a.area);
    return quads.slice(0, 6).map(q => q.P.map(p => [(p.x + 0.5) * k - 0.5, (p.y + 0.5) * k - 0.5]));
  }

  const RING = 12, CS = [], SN = [];
  for (let t = 0; t < RING; t++) { CS.push(Math.cos(2 * Math.PI * t / RING)); SN.push(Math.sin(2 * Math.PI * t / RING)); }
  const DISCO = [[0, 0]];
  for (let t = 0; t < 6; t++) DISCO.push([0.3 * Math.cos(t * Math.PI / 3), 0.3 * Math.sin(t * Math.PI / 3)]);
  for (let t = 0; t < 12; t++) DISCO.push([0.6 * Math.cos((t + 0.5) * Math.PI / 6), 0.6 * Math.sin((t + 0.5) * Math.PI / 6)]);

  // img: { data: gris (Uint8Array), w, h }  ·  o: { fmt: formato esperado (opcional) }
  function leer(img, o) {
    o = o || {};
    const { data: g, w, h } = img, at = muestreador(g, w, h);
    const cands = buscarMarcas(g, w, h);
    if (!cands.length) return { ok: false, error: 'sin-marcas', msg: 'Buscando la hoja… que se vean las 4 esquinas negras' };
    let primero = null;
    for (const esq of cands) {
      const r = leerCon(esq);
      if (r.ok || (r.error !== 'orientacion' && r.error !== 'formato')) return r;
      if (!primero) primero = r;
    }
    return primero;

    function leerCon(esq) {
      // orientación: probamos los 4 giros y nos quedamos con el que pone la marca chica arriba a la izquierda
      const disco = (H, X, Y, rr) => { let t = 0; for (const [u, v] of DISCO) { const [x, y] = proyectar(H, X + u * rr, Y + v * rr); t += at(x, y); } return t / DISCO.length; };
      const anillo = (H, X, Y, rr) => { let t = 0; for (let k = 0; k < RING; k++) { const [x, y] = proyectar(H, X + rr * CS[k], Y + rr * SN[k]); t += at(x, y); } return t / RING; };
      // lo más oscuro alrededor de un punto (la hoja puede estar un poco doblada y el punto corrido)
      const oscuro = (H, X, Y, rr) => { let m = 255; for (let dx = -2.4; dx <= 2.41; dx += 0.6) for (let dy = -2.4; dy <= 2.41; dy += 0.6) { const v = disco(H, X + dx, Y + dy, rr); if (v < m) m = v; } return m; };
      const giros = [0, 1, 2, 3].map(s => { const H = homografia(MK.pts, [0, 1, 2, 3].map(i => esq[(i + s) % 4])); if (!H) return null; const pap = anillo(H, ORI.x, ORI.y, 5.5); return { H, d: 1 - oscuro(H, ORI.x, ORI.y, 1.3) / Math.max(pap, 1) }; }).filter(Boolean);
      giros.sort((a, b) => b.d - a.d);
      if (!giros.length || giros[0].d < 0.3 || (giros[1] && giros[1].d > giros[0].d * 0.6)) return { ok: false, error: 'orientacion', esquinas: esq, msg: 'No encuentro la marca de arriba. Acomodá la hoja.' };
      const H = giros[0].H;
      // papel: brillo del blanco en una grilla (sirve con sombras y luz despareja)
      const PX0 = 20, PY0 = 20, PS = 10, PNX = 18, PNY = 27, pap = new Float64Array(PNX * PNY), tmp = new Float64Array(25);
      for (let j = 0; j < PNY; j++) for (let i = 0; i < PNX; i++) {
        const X = PX0 + i * PS, Y = PY0 + j * PS; let t = 0;
        for (let a = -2; a <= 2; a++) for (let c = -2; c <= 2; c++) { const [x, y] = proyectar(H, X + a * 2, Y + c * 2); tmp[t++] = at(x, y); }
        tmp.sort(); pap[j * PNX + i] = Math.max(tmp[20], 8);
      }
      const papel = (X, Y) => {
        let fx = (X - PX0) / PS, fy = (Y - PY0) / PS; fx = Math.min(PNX - 1.001, Math.max(0, fx)); fy = Math.min(PNY - 1.001, Math.max(0, fy));
        const i = fx | 0, j = fy | 0, u = fx - i, v = fy - j, p = pap;
        return (p[j * PNX + i] * (1 - u) + p[j * PNX + i + 1] * u) * (1 - v) + (p[(j + 1) * PNX + i] * (1 - u) + p[(j + 1) * PNX + i + 1] * u) * v;
      };
      // formato
      const cod = COD.xs.map(x => 1 - oscuro(H, x, COD.y, 1.1) / papel(x, COD.y + 6));
      const enc = cod.map((d, i) => d > 0.35 ? i : -1).filter(i => i >= 0);
      if (enc.length !== 1) return { ok: false, error: 'formato', esquinas: esq, msg: 'No reconozco esta hoja. ¿Es la hoja de respuestas VIBE?' };
      const fid = Object.keys(FORMATOS).find(k => FORMATOS[k].cod === enc[0]);
      if (o.fmt && o.fmt !== fid) return { ok: false, error: 'otro-formato', fmt: fid, esquinas: esq, msg: `Esta es la hoja de ${FORMATOS[fid].nombre} (${FORMATOS[fid].preguntas}). El examen usa la de ${FORMATOS[o.fmt].nombre} (${FORMATOS[o.fmt].preguntas}).` };
      const L = layout(fid), B = L.b;
      const pb = B.map(p => papel(p.x, p.y));
      // alineación fina por bloque: el contorno de las burbujas tiene que caer justo en el anillo
      const off = [], nit = [];
      for (let k = 0; k < L.nblk; k++) {
        const ids = []; B.forEach((p, i) => { if (p.blk === k) ids.push(i); });
        const rng = k === 0 ? 2.4 : 3.0;
        const ev = (dx, dy) => {
          let s = 0;
          for (const i of ids) {
            const p = B[i], r1 = p.r, r2 = p.r * 1.5; let a = 0;
            for (let t = 0; t < RING; t++) {
              let X = p.x + dx + r1 * CS[t], Y = p.y + dy + r1 * SN[t], ww = H[6] * X + H[7] * Y + 1;
              a -= at((H[0] * X + H[1] * Y + H[2]) / ww, (H[3] * X + H[4] * Y + H[5]) / ww);
              X = p.x + dx + r2 * CS[t]; Y = p.y + dy + r2 * SN[t]; ww = H[6] * X + H[7] * Y + 1;
              a += at((H[0] * X + H[1] * Y + H[2]) / ww, (H[3] * X + H[4] * Y + H[5]) / ww);
            }
            s += a / (RING * pb[i]);
          }
          return s / ids.length;
        };
        let bx = 0, by = 0, bv = -Infinity;
        for (let dx = -rng; dx <= rng + 1e-9; dx += 0.6) for (let dy = -rng; dy <= rng + 1e-9; dy += 0.6) { const v = ev(dx, dy); if (v > bv) { bv = v; bx = dx; by = dy; } }
        const cx = bx, cy = by;
        for (let dx = cx - 0.4; dx <= cx + 0.4 + 1e-9; dx += 0.2) for (let dy = cy - 0.4; dy <= cy + 0.4 + 1e-9; dy += 0.2) { const v = ev(dx, dy); if (v > bv) { bv = v; bx = dx; by = dy; } }
        off.push([bx, by]); nit.push(bv);
      }
      const nitidez = Math.min(...nit);
      if (nitidez < 0.12) return { ok: false, error: 'borrosa', esquinas: esq, nitidez, msg: 'Se ve borroso o muy inclinado. Poné el celu derecho sobre la hoja y quedate quieto.' };
      // relleno de cada burbuja
      const sc = B.map((p, i) => { const [dx, dy] = off[p.blk]; return Math.max(0, Math.min(1, 1 - disco(H, p.x + dx, p.y + dy, p.r) / pb[i])); });
      // umbral: entre el nivel de las burbujas vacías (la mayoría) y el de las marcadas (la más oscura de cada pregunta)
      const med = a => { const t = [...a].sort((x, y) => x - y); return t.length ? t[t.length >> 1] : 0; };
      const emp = med(sc), mk0 = med(L.preg.map(p => Math.max(...p.ops.map(i => sc[i])))), mk = mk0 - emp < 0.2 ? emp + 0.5 : mk0;
      const thr = Math.min(0.45, Math.max(0.2, emp + 0.45 * (mk - emp))), seg = emp + 0.62 * (mk - emp), dud = emp + 0.25 * (mk - emp);
      const pos = i => { const p = B[i], [dx, dy] = off[p.blk]; return proyectar(H, p.x + dx, p.y + dy); };
      // cédula
      const cols = L.ci.map(col => { const m = col.filter(i => sc[i] >= thr); return m.length === 0 ? '' : m.length === 1 ? String(col.indexOf(m[0])) : '*'; });
      let ci = null, ciError = null;
      if (cols.includes('*')) ciError = 'doble';
      else {
        const ds = cols.map(c => c === '' ? ' ' : c).join('').trim();
        if (!ds) ciError = 'vacia'; else if (ds.includes(' ')) ciError = 'incompleta'; else if (ds.length < 5) ciError = 'corta'; else ci = ds;
      }
      // fila
      const fm = L.fila.filter(i => sc[i] >= thr);
      const fila = fm.length === 1 ? L.fila.indexOf(fm[0]) + 1 : null, filaError = fm.length > 1 ? 'doble' : null;
      // respuestas
      let resp = ''; const dudosas = [];
      L.preg.forEach((p, q) => {
        const v = p.ops.map(i => sc[i]), m = v.map((x, j) => x >= thr ? j : -1).filter(j => j >= 0);
        resp += m.length === 0 ? '-' : m.length === 1 ? LETRAS[m[0]] : '*';
        const orden = [...v].sort((a, b) => b - a);
        if ((m.length === 0 && orden[0] >= dud) || (m.length === 1 && (orden[1] >= dud || orden[0] < seg)) || (m.length > 1 && orden[1] < seg)) dudosas.push(q);
      });
      return {
        ok: true, fmt: fid, ci, ciError, ciCols: cols, fila, filaError, resp, dudosas, umbral: thr, nitidez, esquinas: esq,
        pos: { resp: L.preg.map((p, q) => { const j = LETRAS.indexOf(resp[q]); return j >= 0 ? pos(p.ops[j]) : null; }), preg: L.preg.map(p => pos(p.ops[0])), ci: L.ci.map((col, c) => cols[c] && cols[c] !== '*' ? pos(col[+cols[c]]) : null), fila: fila ? pos(L.fila[fila - 1]) : null },
      };
    }
  }

  function corregir(resp, clave) {
    let buenas = 0, mal = 0, blancas = 0, dobles = 0;
    for (let i = 0; i < clave.length; i++) { const r = resp[i] || '-'; if (r === clave[i]) buenas++; else if (r === '-') blancas++; else if (r === '*') dobles++; else mal++; }
    return { buenas, mal, blancas, dobles };
  }

  const OMR = { FORMATOS, LETRAS, layout, pdf, gris, leer, corregir, homografia, proyectar, _buscarMarcas: buscarMarcas };
  if (typeof module !== 'undefined' && module.exports) module.exports = OMR; else root.OMR = OMR;
})(typeof window !== 'undefined' ? window : this);
