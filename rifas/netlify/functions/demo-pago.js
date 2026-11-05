// SOLO PARA PRUEBAS: simula la respuesta del banco mientras no tengas cuenta de Azul.
// Se desactiva sola cuando pones DEMO_MODE=false en Netlify.
const { env, rpc, json } = require('../lib/comun');

exports.handler = async (event) => {
  if (env('DEMO_MODE', 'true') !== 'true') return json(403, { error: 'Modo demo desactivado' });
  if (event.httpMethod !== 'POST') return json(405, { error: 'Método no permitido' });
  const { order_id, aprobar } = JSON.parse(event.body || '{}');
  if (!order_id) return json(400, { error: 'Falta la orden' });
  try {
    if (aprobar) await rpc('confirm_order', { p_order_id: order_id, p_auth: 'DEMO', p_rrn: null, p_msg: 'APROBADA (demo)' });
    else await rpc('fail_order', { p_order_id: order_id, p_status: 'declined', p_msg: 'Rechazada (demo)' });
    return json(200, { ok: true });
  } catch (e) {
    return json(400, { error: e.message });
  }
};
