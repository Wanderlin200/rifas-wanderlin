// Azul redirige aquí al terminar el pago: /pago/aprobado | /pago/rechazado | /pago/cancelado/<orden>
// Se verifica la firma (AuthHash) antes de dar los boletos por vendidos.
const { env, rpc, findOrderByNumber, azulAmount, azulHash, safeEqual } = require('../lib/comun');

const redirect = (orderId, estado) => ({
  statusCode: 302,
  headers: { Location: `/resultado.html?orden=${orderId || ''}&estado=${estado}`, 'Cache-Control': 'no-store' },
  body: '',
});

exports.handler = async (event) => {
  // Azul puede responder por GET (query) o POST (form)
  let q = event.queryStringParameters || {};
  if (event.httpMethod === 'POST' && event.body) {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
    q = { ...q, ...Object.fromEntries(new URLSearchParams(raw)) };
  }
  const path = event.rawUrl ? new URL(event.rawUrl).pathname : event.path;
  const tipo = (path.match(/\/pago\/(aprobado|rechazado|cancelado)/) || [])[1] || 'rechazado';

  // ----- Cancelado por el cliente -----
  if (tipo === 'cancelado') {
    const num = q.OrderNumber || path.split('/').pop();
    const order = await findOrderByNumber(num).catch(() => null);
    if (order && order.status === 'pending') {
      await rpc('fail_order', { p_order_id: order.id, p_status: 'cancelled', p_msg: 'Cancelado por el cliente' });
    }
    return redirect(order?.id, 'cancelado');
  }

  const order = await findOrderByNumber(q.OrderNumber).catch(() => null);
  if (!order) return redirect('', 'error');

  // ----- Verificar firma de Azul -----
  const expected = azulHash(
    (q.OrderNumber || '') + (q.Amount || '') + (q.AuthorizationCode || '') + (q.DateTime || '') +
    (q.ResponseCode || '') + (q.IsoCode || '') + (q.ResponseMessage || '') + (q.ErrorDescription || '') +
    (q.RRN || '') + env('AZUL_AUTH_KEY')
  );
  if (!safeEqual(expected, q.AuthHash)) {
    console.error('Firma de Azul inválida para la orden', q.OrderNumber);
    return redirect(order.id, 'error');
  }

  const aprobado = q.IsoCode === '00' && azulAmount(order.amount) === String(q.Amount);
  if (aprobado) {
    await rpc('confirm_order', {
      p_order_id: order.id, p_auth: q.AuthorizationCode || null, p_rrn: q.RRN || null, p_msg: q.ResponseMessage || 'APROBADA',
    });
    return redirect(order.id, 'aprobado');
  }

  await rpc('fail_order', {
    p_order_id: order.id, p_status: 'declined',
    p_msg: `${q.ResponseMessage || ''} ${q.ErrorDescription || ''}`.trim() || 'Rechazada',
  });
  return redirect(order.id, 'rechazado');
};
