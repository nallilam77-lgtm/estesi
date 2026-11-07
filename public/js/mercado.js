// =========================================================================
// MERCADO DE CUENTAS: configuración y utilidades compartidas por index.html (tienda) y admin-cuentas.html.
// Necesita supabase-js (UMD) cargado antes. La URL y la publishable key NO son secretas: lo que cada
// quien puede ver o cambiar lo decide supabase/cuentas.sql (RLS + funciones), no el navegador.
// Todo dato de un usuario se pinta con textContent / atributos, nunca con innerHTML.
// =========================================================================
(function () {
  const SUPABASE_URL = 'https://qaxgvfzpzywfgcwnalfr.supabase.co';
  const SUPABASE_PUBLICABLE = 'sb_publishable_iWFflYD8yK3tQIWcORNz7g_OPfvmvng';
  const BUCKET = 'cuentas-fotos';
  const BUCKET_COMPROBANTES = 'comprobantes';   // privado: capturas de pago de las recargas

  // Códigos que lanzan las funciones de supabase/cuentas.sql → texto para el cliente
  const ERRORES = {
    LIMITE_PUBLICACIONES: 'Ya tienes 10 cuentas activas. Elimina alguna para publicar otra.',
    FOTO_INVALIDA: 'Hubo un problema con las fotos. Vuelve a elegirlas.',
    NO_EDITABLE: 'Esa publicación ya no se puede cambiar.',
    NO_PERMITIDO: 'No se puede hacer ese cambio.',
    SIN_SESION: 'Tu sesión venció. Vuelve a entrar.',
    NO_DISPONIBLE: 'Esa cuenta ya no está disponible: alguien más la está comprando o el vendedor la retiró.',
    ES_TUYA: 'No puedes comprar tu propia cuenta.',
    DEMASIADAS_PENDIENTES: 'Ya tienes 2 compras esperando pago. Págalas o cancélalas antes de abrir otra.',
    ESTADO_INVALIDO: 'El trato cambió de estado. Actualizamos la pantalla.',
    DATO_INVALIDO: 'Revisa los datos que escribiste.',
    FUERA_DE_PLAZO: 'Ya pasó el plazo para reclamar.',
    VIDEO_REQUERIDO: 'Sin video no hay reclamo: pega el enlace de tu grabación (Drive, YouTube oculto, etc.).',
    RETIRO_MINIMO: 'El monto es menor que el retiro mínimo.',
    RETIRO_PENDIENTE: 'Ya tienes un retiro pendiente. Espera a que lo paguemos.',
    SALDO_INSUFICIENTE: 'No tienes saldo suficiente para ese retiro.',
    CHAT_CERRADO: 'Este trato ya terminó: el chat está cerrado.',
    DEMASIADOS_MENSAJES: 'Estás enviando mensajes muy rápido. Espera un momento.',
    SOLO_ADMIN: 'Solo un administrador puede hacer eso.',
    SALDO_COMPRA: 'No tienes saldo suficiente. Recarga y vuelve a intentarlo.',
    METODO_NO_DISPONIBLE: 'Ese método de pago no está disponible ahora.',
    RECARGA_MONTO: 'Revisa el monto de la recarga.',
    CAPTURA_REQUERIDA: 'Sube la captura del comprobante de pago.',
    DEMASIADAS_RECARGAS: 'Ya tienes 3 recargas esperando revisión. Espera a que las aprobemos.',
    REFERENCIA_USADA: 'Esa referencia ya se usó en otra recarga.',
    SALDO_GASTADO: 'El usuario ya gastó parte de ese saldo: no se puede descontar completo.',
    APELACION_ACTIVA: 'Ya llamaste a Level Up en este trato: un administrador entrará al chat en breve.',
    YA_CALIFICADO: 'Ya calificaste este trato.',
  };

  const TEXTO_ESTADO_CUENTA = {
    revision: 'En revisión', publicada: 'Publicada', pausada: 'Pausada', reservada: 'Reservada (en un trato)',
    vendida: 'Vendida', rechazada: 'Rechazada',
  };
  const TEXTO_ESTADO_TRATO = {
    pendiente_pago: 'Esperando pago', pagada: 'Pago retenido · esperando entrega', entregada: 'Datos entregados · en revisión',
    en_reclamo: 'En reclamo', cerrada: 'Cerrado', cancelada: 'Cancelado',
  };
  const TEXTO_ROL = { comprador: 'Comprador', vendedor: 'Vendedor', cliente: 'Cliente', admin: 'Level Up', sistema: 'Level Up · Sistema' };
  const TEXTO_ESTADO_RECARGA = { pendiente: 'En revisión', aprobada: 'Aprobada', rechazada: 'Rechazada' };
  // Métodos de recarga: qué pedir como comprobante y qué datos de mercado_config mostrar
  const METODOS_RECARGA = {
    binance: { nombre: 'Binance', referencia: 'Número de orden', ayuda: 'En Binance Pay: Historial → toca el pago → "ID de orden".', datos: [['ID de Binance Pay', 'binance_pay_id'], ['Nombre', 'binance_nombre']] },
    pago_movil: { nombre: 'Pago Móvil', referencia: 'Referencia', ayuda: 'El número de referencia que aparece en el comprobante del banco.', datos: [['Banco', 'pm_banco'], ['Teléfono', 'pm_telefono'], ['Cédula', 'pm_cedula'], ['Titular', 'pm_titular']] },
    paypal: { nombre: 'PayPal', referencia: 'ID de transacción', ayuda: 'En PayPal: Actividad → toca el pago → "ID de transacción".', datos: [['Correo de PayPal', 'paypal_correo'], ['Nombre', 'paypal_nombre']] },
  };
  const CLAVE_METODO = { binance: 'binance_pay_id', pago_movil: 'pm_telefono', paypal: 'paypal_correo' };
  const CONFIG_NUMERICA = ['comision_retiro', 'retiro_minimo', 'garantia_usd', 'horas_pago', 'horas_revision', 'tasa_bs', 'recarga_minima', 'paypal_recargo'];

  let cliente = null;

  const Mercado = {
    SUPABASE_URL,
    BUCKET,
    BUCKET_COMPROBANTES,
    METODOS_RECARGA,
    TEXTO_ESTADO_RECARGA,
    WHATSAPP: '584228887089',
    METODOS: ['Pago Móvil', 'Binance', 'Zinli', 'Otro'],
    TEXTO_ESTADO_CUENTA,
    TEXTO_ESTADO_TRATO,
    TEXTO_ROL,

    cliente() {
      if (!cliente && window.supabase?.createClient) {
        cliente = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLICABLE, {
          auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
        });
      }
      return cliente;
    },

    crear(etiqueta, clase, texto) {
      const el = document.createElement(etiqueta);
      if (clase) el.className = clase;
      if (texto != null) el.textContent = texto;
      return el;
    },

    codigoCuenta: (id) => `FF-${id}`,
    codigoTrato: (id) => `T-${id}`,
    codigoRetiro: (id) => `R-${id}`,
    codigoRecarga: (id) => `RC-${id}`,
    urlFoto: (ruta) => `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${String(ruta).split('/').map(encodeURIComponent).join('/')}`,
    usd: (n) => `${Number(n).toLocaleString('es-VE', { minimumFractionDigits: 0, maximumFractionDigits: 2 })} USD`,
    bs: (n) => `${Number(n).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} Bs`,
    fecha: (iso) => new Date(iso).toLocaleString('es-VE', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }),

    textoError(error, porDefecto) {
      const texto = String(error?.message || '');
      const clave = Object.keys(ERRORES).find((k) => texto.includes(k));
      return clave ? ERRORES[clave] : porDefecto;
    },

    // Llama a una función de supabase/cuentas.sql y lanza un Error con el texto para el cliente
    async rpc(nombre, parametros, porDefecto = 'No pudimos completar la acción. Intenta de nuevo.') {
      const { data, error } = await Mercado.cliente().rpc(nombre, parametros);
      if (error) {
        console.error(nombre, error);
        const e = new Error(Mercado.textoError(error, porDefecto));
        e.estadoCambiado = String(error.message || '').includes('ESTADO_INVALIDO');
        throw e;
      }
      return data;
    },

    // mercado_config → { comision_retiro: 4, ..., instrucciones_pago: '...', binance_pay_id: '...' }
    async config() {
      const valores = { comision_retiro: 4, retiro_minimo: 5, garantia_usd: 1, horas_pago: 2, horas_revision: 24, tasa_bs: 0, recarga_minima: 1, paypal_recargo: 0, instrucciones_pago: '' };
      const { data, error } = await Mercado.cliente().from('mercado_config').select('clave,valor');
      if (!error) {
        for (const { clave, valor } of data) {
          valores[clave] = CONFIG_NUMERICA.includes(clave) ? (Number(valor) || 0) : valor;
        }
      }
      return valores;
    },

    // Métodos de recarga que el admin configuró (los que no tienen datos no se muestran)
    metodosActivos: (config) => Object.keys(METODOS_RECARGA).filter((m) => String(config[CLAVE_METODO[m]] || '').trim()),

    // Lo que hay que enviar por un método (PayPal puede llevar un recargo por su comisión)
    montoPagar: (metodo, monto, config) => (metodo === 'paypal'
      ? Math.round(monto * (1 + (config.paypal_recargo || 0) / 100) * 100) / 100 : monto),

    // Comprime una imagen a WebP (máx. 1280 px, < 1 MB) en el navegador: sube rápido con datos móviles
    async comprimir(archivo, lado = 1280) {
      const bitmap = await createImageBitmap(archivo);
      const escala = Math.min(1, lado / Math.max(bitmap.width, bitmap.height));
      const lienzo = document.createElement('canvas');
      lienzo.width = Math.round(bitmap.width * escala);
      lienzo.height = Math.round(bitmap.height * escala);
      lienzo.getContext('2d').drawImage(bitmap, 0, 0, lienzo.width, lienzo.height);
      bitmap.close?.();
      for (const calidad of [0.82, 0.7, 0.55]) {
        let blob = await new Promise((r) => lienzo.toBlob(r, 'image/webp', calidad));
        if (!blob || blob.type !== 'image/webp') blob = await new Promise((r) => lienzo.toBlob(r, 'image/jpeg', calidad)); // Safari viejo
        if (blob && blob.size <= 1_000_000) return blob;
      }
      throw new Error('FOTO_GRANDE');
    },

    // Enlace temporal (1 h) a una captura del bucket privado
    async urlComprobante(ruta) {
      if (!ruta) return '';   // la captura se borró en una limpieza
      const { data } = await Mercado.cliente().storage.from(BUCKET_COMPROBANTES).createSignedUrl(ruta, 3600);
      return data?.signedUrl || '';
    },

    // Copia un texto y lo marca en el mismo botón
    async copiar(texto, boton) {
      try {
        await navigator.clipboard.writeText(texto);
        if (boton) {
          boton.classList.add('copiado');
          setTimeout(() => boton.classList.remove('copiado'), 1400);
        }
        return true;
      } catch (e) {
        return false;
      }
    },

    // EN VIVO (Supabase Realtime): llama a fn(fila, tabla) cada vez que se inserta/cambia una fila en esas tablas.
    // filtro opcional, p. ej. 'orden=eq.12'. Solo llegan filas que el usuario puede leer (RLS). Devuelve una función para cortar.
    enVivo(nombre, tablas, fn, { filtro, eventos = 'INSERT' } = {}) {
      const c = Mercado.cliente();
      if (!c?.channel) return () => {};
      let canal = c.channel(`${nombre}-${Math.random().toString(36).slice(2, 8)}`);
      for (const tabla of tablas) {
        canal = canal.on('postgres_changes', { event: eventos, schema: 'public', table: tabla, ...(filtro ? { filter: filtro } : {}) },
          (cambio) => fn(cambio.new, tabla, cambio.eventType));
      }
      canal.subscribe();
      return () => { try { c.removeChannel(canal); } catch (e) { /* ya cerrado */ } };
    },

    // ---------- Avisos de la página (en lugar de alert/confirm/prompt del navegador) ----------
    // notificar('Texto', 'exito' | 'error' | 'aviso' | 'info', { titulo, alTocar, duracion })
    notificar(texto, tipo = 'exito', { titulo, alTocar, duracion = 6000 } = {}) {
      let pila = document.getElementById('avisosMercado');
      if (!pila) {
        pila = Mercado.crear('div', 'avisos-mercado');
        pila.id = 'avisosMercado';
        pila.setAttribute('role', 'status');
        pila.setAttribute('aria-live', 'polite');
        document.body.append(pila);
      }
      const TITULOS = { exito: 'Listo', error: 'No se pudo completar', aviso: 'Atención', info: 'Aviso' };
      const caja = Mercado.crear('div', `aviso-mercado aviso-${tipo}${alTocar ? ' aviso-tocable' : ''}`);
      const marca = Mercado.crear('span', 'aviso-marca', { exito: '✓', error: '!', aviso: '!', info: 'i' }[tipo] || 'i');
      marca.setAttribute('aria-hidden', 'true');
      const cuerpo = Mercado.crear('div', 'aviso-cuerpo');
      cuerpo.append(Mercado.crear('strong', null, titulo || TITULOS[tipo] || 'Aviso'), Mercado.crear('p', null, texto));
      const cerrar = Mercado.crear('button', 'aviso-cerrar', '✖');
      cerrar.type = 'button';
      cerrar.setAttribute('aria-label', 'Cerrar aviso');
      const quitar = () => { caja.classList.add('saliendo'); setTimeout(() => caja.remove(), 220); };
      cerrar.addEventListener('click', (e) => { e.stopPropagation(); quitar(); });
      if (alTocar) caja.addEventListener('click', () => { quitar(); alTocar(); });
      caja.append(marca, cuerpo, cerrar);
      pila.append(caja);
      while (pila.children.length > 4) pila.firstChild.remove();
      if (duracion) setTimeout(quitar, duracion);
      return quitar;
    },

    // confirmar({ titulo, texto, aceptar, cancelar, peligro, campo: { etiqueta, valor, placeholder, multilinea, obligatorio, max } })
    // → Promise: null si cancela; { texto } si acepta
    confirmar({ titulo, texto = '', aceptar = 'Aceptar', cancelar = 'Cancelar', peligro = false, campo = null }) {
      let ventana = document.getElementById('dialogoMercado');
      if (!ventana) {
        ventana = Mercado.crear('div', 'ventana oculto dialogo-mercado');
        ventana.id = 'dialogoMercado';
        ventana.setAttribute('role', 'alertdialog');
        ventana.setAttribute('aria-modal', 'true');
        ventana.setAttribute('aria-labelledby', 'dlgTitulo');
        const form = Mercado.crear('form', 'ventana-caja dialogo-caja');
        form.noValidate = true;
        const h = Mercado.crear('h2'); h.id = 'dlgTitulo';
        const pTexto = Mercado.crear('p', 'dialogo-texto'); pTexto.id = 'dlgTexto';
        const zona = Mercado.crear('div', 'campo oculto'); zona.id = 'dlgCampo';
        const botones = Mercado.crear('div', 'dialogo-botones');
        const no = Mercado.crear('button', 'btn-secundario'); no.type = 'button'; no.id = 'dlgNo';
        const si = Mercado.crear('button', 'btn-juego'); si.type = 'submit'; si.id = 'dlgSi';
        botones.append(no, si);
        form.append(h, pTexto, zona, botones);
        ventana.append(form);
        document.body.append(ventana);
      }
      const $d = (id) => document.getElementById(id);
      $d('dlgTitulo').textContent = titulo;
      $d('dlgTexto').textContent = texto;
      $d('dlgTexto').classList.toggle('oculto', !texto);
      $d('dlgNo').textContent = cancelar;
      $d('dlgSi').textContent = aceptar;
      $d('dlgSi').className = peligro ? 'btn-juego btn-peligro-fuerte' : 'btn-juego';
      const zona = $d('dlgCampo');
      zona.replaceChildren();
      zona.classList.toggle('oculto', !campo);
      let entrada = null;
      if (campo) {
        const etiqueta = Mercado.crear('label', null, campo.etiqueta || '');
        etiqueta.htmlFor = 'dlgEntrada';
        entrada = Mercado.crear(campo.multilinea ? 'textarea' : 'input');
        entrada.id = 'dlgEntrada';
        entrada.maxLength = campo.max || 300;
        entrada.placeholder = campo.placeholder || '';
        entrada.value = campo.valor || '';
        if (!campo.multilinea) entrada.type = 'text';
        zona.append(etiqueta, entrada);
      }
      const anterior = document.activeElement;
      ventana.classList.remove('oculto');
      document.body.classList.add('no-scroll');
      setTimeout(() => (entrada || $d('dlgSi')).focus(), 30);
      return new Promise((resolver) => {
        const form = ventana.querySelector('form');
        const terminar = (valor) => {
          ventana.classList.add('oculto');
          if (!document.querySelector('.ventana:not(.oculto)')) document.body.classList.remove('no-scroll');
          form.onsubmit = null; $d('dlgNo').onclick = null; ventana.onclick = null; document.removeEventListener('keydown', tecla, true);
          anterior?.focus?.();
          resolver(valor);
        };
        const tecla = (e) => { if (e.key === 'Escape') { e.stopPropagation(); e.preventDefault(); terminar(null); } };
        document.addEventListener('keydown', tecla, true);
        form.onsubmit = (e) => {
          e.preventDefault();
          const valor = entrada ? entrada.value.trim() : '';
          if (campo?.obligatorio && valor.length < (campo.minimo || 1)) { entrada.focus(); entrada.classList.add('campo-error'); return; }
          terminar({ texto: valor });
        };
        $d('dlgNo').onclick = () => terminar(null);
        ventana.onclick = (e) => { if (e.target === ventana) terminar(null); };
      });
    },

    // Estrellas de texto (★★★★☆) para mostrar una calificación
    estrellas: (n) => '★★★★★'.slice(0, Math.round(n)) + '☆☆☆☆☆'.slice(0, 5 - Math.round(n)),

    mensaje(el, texto, tipo = 'error') {
      el.className = `panel-mensaje ${tipo}`;
      el.textContent = texto;
    },

    // Chat de un trato, de una recarga o de soporte. Los mensajes llegan EN VIVO (Realtime) y, por si la
    // conexión en vivo falla, también se revisa cada 15 s. alNuevo(mensajes) avisa cuando llegan (los del sistema = cambió de estado).
    // Recargas: tabla 'mensajes_recarga', campo 'orden', funcion 'recarga_mensaje', parametro 'p_orden'.
    // Soporte: tabla 'mensajes_soporte', campo 'usuario', funcion 'soporte_mensaje', parametro 'p_usuario'.
    crearChat({ lista, form, input, boton, aviso, yo, alNuevo, nombreDe, tabla = 'mensajes_venta', campo = 'venta', funcion = 'mensaje_enviar', parametro = 'p_venta' }) {
      let venta = null;
      let ultimo = 0;
      let temporizador = null;
      let ocupado = false;
      let otraVez = false;
      let cortarVivo = () => {};

      let ultimoDia = '';
      const hora = (iso) => new Date(iso).toLocaleTimeString('es-VE', { hour: 'numeric', minute: '2-digit' });
      function textoDia(fecha) {
        const hoy = new Date(); const ayer = new Date(Date.now() - 864e5);
        if (fecha.toDateString() === hoy.toDateString()) return 'Hoy';
        if (fecha.toDateString() === ayer.toDateString()) return 'Ayer';
        return fecha.toLocaleDateString('es-VE', { weekday: 'long', day: 'numeric', month: 'long' });
      }
      function burbuja(m) {
        const nodos = [];
        const fecha = new Date(m.creado);
        if (fecha.toDateString() !== ultimoDia) {
          ultimoDia = fecha.toDateString();
          nodos.push(Mercado.crear('div', 'chat-dia', textoDia(fecha)));
        }
        const propio = m.autor && m.autor === yo();
        const apelacion = m.rol === 'sistema' && m.texto.startsWith('APELACIÓN');
        const div = Mercado.crear('div', `msg msg-${m.rol}${propio ? ' msg-mio' : ''}${apelacion ? ' msg-apelacion' : ''}${ultimo ? ' msg-nuevo' : ''}`);
        const cabecera = Mercado.crear('span', 'msg-autor');
        const nombre = !propio && nombreDe?.(m);
        cabecera.append(Mercado.crear('b', null, propio ? 'Tú' : nombre ? `${nombre} (${(TEXTO_ROL[m.rol] || m.rol).toLowerCase()})` : TEXTO_ROL[m.rol] || m.rol), Mercado.crear('time', null, hora(m.creado)));
        cabecera.lastChild.dateTime = m.creado;
        div.append(cabecera, Mercado.crear('p', 'msg-texto', m.texto));
        // Los datos de acceso que entrega el vendedor se copian con un toque
        if (!propio && m.rol !== 'sistema') {
          const copiar = Mercado.crear('button', 'msg-copiar', 'Copiar');
          copiar.type = 'button';
          copiar.addEventListener('click', async () => {
            if (await Mercado.copiar(m.texto, copiar)) { copiar.textContent = 'Copiado'; setTimeout(() => { copiar.textContent = 'Copiar'; }, 1400); }
          });
          div.append(copiar);
        }
        nodos.push(div);
        return nodos;
      }

      async function traer() {
        if (!venta) return;
        if (ocupado) { otraVez = true; return; }
        ocupado = true;
        const pedido = venta;
        const { data, error } = await Mercado.cliente().from(tabla)
          .select('id,autor,rol,texto,creado').eq(campo, pedido).gt('id', ultimo).order('id').limit(200);
        ocupado = false;
        if (otraVez) { otraVez = false; setTimeout(traer, 0); }
        if (error || pedido !== venta || !data.length) return;
        const alFinal = lista.scrollHeight - lista.scrollTop - lista.clientHeight < 80 || ultimo === 0;
        const nuevos = data.filter((m) => m.id > ultimo);
        if (!nuevos.length) return;
        for (const m of nuevos) lista.append(...burbuja(m));
        ultimo = nuevos[nuevos.length - 1].id;
        if (alFinal) lista.scrollTop = lista.scrollHeight;
        alNuevo?.(nuevos);
      }

      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const texto = input.value.trim();
        if (!texto || !venta) return;
        boton.disabled = true;
        try {
          await Mercado.rpc(funcion, { [parametro]: venta, p_texto: texto.slice(0, 1000) }, 'No se pudo enviar el mensaje.');
          input.value = '';
          aviso.textContent = '';
          await traer();
          lista.scrollTop = lista.scrollHeight;
        } catch (error) {
          Mercado.mensaje(aviso, error.message);
        } finally {
          boton.disabled = false;
        }
      });

      // Enter envía (Shift+Enter = nueva línea), como en cualquier chat
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia('(pointer: fine)').matches) {
          e.preventDefault();
          form.requestSubmit();
        }
      });

      return {
        abrir(id) {
          clearInterval(temporizador);
          cortarVivo();
          venta = id;
          ultimo = 0;
          ultimoDia = '';
          lista.replaceChildren();
          aviso.textContent = '';
          traer();
          cortarVivo = Mercado.enVivo(`chat-${tabla}`, [tabla], () => traer(), { filtro: `${campo}=eq.${id}` });
          temporizador = setInterval(() => { if (!document.hidden) traer(); }, 15000);
        },
        cerrar() {
          clearInterval(temporizador);
          cortarVivo();
          cortarVivo = () => {};
          venta = null;
        },
        abierto: () => venta,
        habilitar(si) {
          input.disabled = !si;
          boton.disabled = !si;
          input.placeholder = si ? 'Escribe un mensaje…' : 'Este chat está cerrado';
        },
        traer,
      };
    },
  };

  window.Mercado = Mercado;
})();
