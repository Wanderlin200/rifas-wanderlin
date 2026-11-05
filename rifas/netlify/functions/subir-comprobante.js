// POST /api/subir-comprobante  { order_id, image: "data:image/jpeg;base64,..." }
// Guarda la captura de la transferencia en un almacenamiento PRIVADO de Supabase
// (solo el administrador puede verla) y aparta los números 72 horas mientras se verifica.
const { env, rpc, sbHeaders, json } = require('../lib/comun');

const MAX_BYTES = 4 * 1024 * 1024; // 4 MB

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Método no permitido' });

  let body;
  try { body = JSON.parse(event.body || '{}'); } catch { return json(400, { error: 'Datos inválidos' }); }

  const orderId = String(body.order_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) return json(400, { error: 'Orden inválida' });

  const m = String(body.image || '').match(/^data:(image\/(jpeg|png|webp));base64,(.+)$/);
  if (!m) return json(400, { error: 'Adjunta una imagen (foto o captura de pantalla)' });
  const buf = Buffer.from(m[3], 'base64');
  if (buf.length > MAX_BYTES) return json(400, { error: 'La imagen es muy pesada (máximo 4 MB)' });

  // Comprobar la orden antes de subir nada
  let status;
  try { status = await rpc('order_status', { p_order_id: orderId }); } catch { status = null; }
  if (!status) return json(404, { error: 'No encontramos esta orden' });
  if (status.method !== 'transfer' || status.status !== 'pending') return json(409, { error: 'Esta orden ya no acepta comprobantes' });

  const ext = m[2] === 'jpeg' ? 'jpg' : m[2];
  const path = `${status.order_number}-${Date.now()}.${ext}`;

  const up = await fetch(`${env('SUPABASE_URL')}/storage/v1/object/comprobantes/${path}`, {
    method: 'POST',
    headers: sbHeaders({ 'Content-Type': m[1], 'x-upsert': 'false' }),
    body: buf,
  });
  if (!up.ok) {
    console.error('Error subiendo comprobante', up.status, await up.text());
    return json(500, { error: 'No se pudo guardar la imagen. Inténtalo de nuevo.' });
  }

  try {
    await rpc('attach_receipt', { p_order_id: orderId, p_path: path });
  } catch (e) {
    return json(409, { error: e.message });
  }
  return json(200, { ok: true });
};
