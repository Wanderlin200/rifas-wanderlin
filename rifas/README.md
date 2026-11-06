# Rifas en línea · Supabase + Netlify + AZUL

Página web para hacer rifas de cualquier cosa. Los clientes eligen sus números (o los reciben al azar) y pagan con tarjeta, **Apple Pay o Google Pay** a través de la Página de Pagos de AZUL. Tú manejas todo desde `/admin.html` y eliges al ganador con una ruleta.

## Qué incluye

| Archivo | Qué hace |
|---|---|
| `public/index.html` | Portada con rifas activas y finalizadas (con el número ganador) |
| `public/rifa.html` | Detalle de la rifa: cuadrícula de números, compra al azar, cuenta regresiva y pago |
| `public/resultado.html` | Confirmación del pago con los números comprados |
| `public/admin.html` | Panel: crear/editar rifas, ver ventas, venta manual, exportar CSV, **ruleta para elegir ganador** |
| `netlify/functions/crear-orden.js` | Reserva los boletos 15 min y firma el formulario de pago de AZUL |
| `netlify/functions/azul-respuesta.js` | Recibe la respuesta de AZUL, **verifica la firma** y marca los boletos como vendidos |
| `netlify/functions/demo-pago.js` | Simulador de pago para probar antes de tener AZUL |
| `supabase/schema.sql` | Base de datos completa con seguridad (RLS) |

**Seguridad:** el ganador lo elige la base de datos con un generador aleatorio criptográfico; la ruleta solo lo muestra. Solo se puede sortear una vez. Los datos de los compradores solo los ve el admin. Dos personas no pueden comprar el mismo número.

---

## 1. Supabase (10 min)

1. Crea un proyecto en supabase.com.
2. Ve a **SQL Editor → New query**, pega todo `supabase/schema.sql` y dale **Run**.
3. **Authentication → Users → Add user**: crea tu usuario (correo + contraseña, marca "Auto confirm").
4. En el SQL Editor ejecuta (con tu correo):
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'TU_CORREO@gmail.com';
   ```
5. **Project Settings → API**: copia la `Project URL`, la `anon public` key y la `service_role` key.

## 2. Configura el sitio

Edita `public/assets/config.js`: nombre del sitio, tu WhatsApp, `SUPABASE_URL` y `SUPABASE_ANON_KEY`.

## 3. Netlify

1. Sube la carpeta a GitHub y conéctala en Netlify (o arrastra la carpeta con Netlify CLI: `netlify deploy --prod`).
2. **Site configuration → Environment variables**:

| Variable | Valor |
|---|---|
| `SUPABASE_URL` | URL de tu proyecto |
| `SUPABASE_SERVICE_ROLE_KEY` | la service_role (¡nunca la pongas en config.js!) |
| `SITE_URL` | `https://tu-dominio.com` |
| `DEMO_MODE` | `true` mientras pruebas · `false` en producción |
| `AZUL_MERCHANT_ID` | te lo da AZUL |
| `AZUL_MERCHANT_NAME` | nombre del comercio registrado en AZUL |
| `AZUL_MERCHANT_TYPE` | te lo da AZUL (por defecto `ECommerce`) |
| `AZUL_AUTH_KEY` | llave de autenticación de la Página de Pagos |
| `AZUL_PAYMENT_URL` | pruebas: `https://pruebas.azul.com.do/PaymentPage/` · producción: la que te indique AZUL |
| `AZUL_HASH_ENCODING` | `utf16le` (por defecto). Si AZUL te dice otra, pon `utf8` |
| `AZUL_ITBIS_RATE` | `0` (o `0.18` si debes desglosar ITBIS) |

3. Entra a `https://tu-dominio.com/admin.html`, crea una rifa, ponla **Activa** y haz una compra de prueba en modo demo.

## 4. AZUL (lo que debes pedir)

Al afiliarte como comercio de e-commerce con AZUL (Banco Popular), pide:

- **Página de Pagos (Payment Page)** con credenciales de pruebas y producción.
- Que te **habiliten Apple Pay y Google Pay** dentro de la Página de Pagos (los botones aparecen solos cuando AZUL los activa en tu cuenta; Apple Pay solo se ve en iPhone/Safari).
- Registra estas URLs de retorno:
  - Aprobado: `https://tu-dominio.com/pago/aprobado`
  - Rechazado: `https://tu-dominio.com/pago/rechazado`
  - Cancelado: `https://tu-dominio.com/pago/cancelado`
- Confirma con ellos el **orden de los campos del AuthHash** y la codificación. El código ya sigue el formato de su documentación, pero haz la primera transacción en su ambiente de pruebas.

Cuando todo funcione en pruebas, cambia `AZUL_PAYMENT_URL` a producción y `DEMO_MODE` a `false`.

## Cómo funciona una compra

1. El cliente elige números → `crear-orden` los **reserva 15 minutos**.
2. Se le envía a la Página de Pagos de AZUL (tarjeta / Apple Pay / Google Pay).
3. AZUL regresa a `/pago/aprobado` → se verifica la firma y el monto → los boletos pasan a **vendidos**.
4. Si cancela, el banco rechaza o no paga a tiempo → los números se liberan solos.
5. Si un pago llega después de vencida la reserva, la orden aparece en el panel con la nota **REVISAR**.

## Ventas en efectivo o transferencia

En el panel: **+ Venta manual** (los boletos quedan vendidos al instante) o **Marcar pagada** en una orden pendiente.

## Elegir ganador

Panel → rifa → **🎡 Elegir ganador** → **¡Girar la ruleta!**. El resultado queda guardado, se publica en la página (nombre parcial: "Ana L.") y tienes un botón para avisarle por WhatsApp.

## Importante antes de vender

- En República Dominicana las rifas con fines comerciales generalmente necesitan **autorización** (Ministerio de Hacienda / Lotería Nacional). Consúltalo antes de lanzar.
- Algunos procesadores clasifican las rifas como "juegos de azar". Dile a AZUL desde el inicio que es para rifas para que aprueben tu tipo de comercio.
- Publica las bases de cada rifa en la descripción (premio, fecha, cómo se entrega).

## Pago por transferencia bancaria

Al crear o editar una rifa eliges **Pago electrónico**, **Transferencia bancaria** o ambas, y escribes los datos de la cuenta.

1. El cliente elige sus números y "Transferencia" → los números quedan apartados **2 horas** y ve los datos de la cuenta.
2. Sube la captura de la transferencia → los números quedan apartados **72 horas** mientras verificas.
3. En el panel aparece "N por verificar" → **Revisar comprobante** → **Aprobar pago** (números vendidos) o **Rechazar** (números liberados).

Los comprobantes se guardan en un almacenamiento privado de Supabase (`comprobantes`) que solo ve el administrador.
Si ya tenías la base de datos instalada, ejecuta una vez `supabase/actualizacion-transferencias.sql`.

## v3: Números premiados, paquetes, cuentas bancarias y verificador

Ejecuta una vez `supabase/actualizacion-v3.sql`.

- **Números premiados:** en cada rifa escribe el premio (ej. RD$5,000) y genera o escribe los números. En la rifa se muestran y se marcan "¡SALIÓ!" al venderse; en el panel ves quién se los ganó.
- **Paquetes y compra mínima:** cantidades separadas por coma (ej. 2, 5, 10, 25, 50, 100) y la compra mínima por rifa.
- **Cuentas bancarias:** Panel → 🏦 Cuentas bancarias. El cliente elige a cuál transfirió y lo ves al revisar el comprobante.
- **Verificador:** `/verificador.html`. El cliente escribe su teléfono y ve sus números, el estado del pago y si le salió un número premiado.
