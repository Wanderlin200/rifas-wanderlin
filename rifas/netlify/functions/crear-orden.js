// POST /api/crear-orden
// Reserva los boletos y devuelve el formulario firmado para la Página de Pagos de Azul
// (donde el cliente paga con tarjeta, Apple Pay o Google Pay).
const { env, rpc, azulAmount, azulHash, json } = require('../lib/comun');

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Método no permitido' });

  let body;
  try { body = JSON.parse(event.body || '{}'); } catch { return json(400, { error: 'Datos inválidos' }); }

  const name = String(body.name || '').trim().slice(0, 80);
  const phone = String(body.phone || '').replace(/[^\d+]/g, '').slice(0, 20);
  const email = String(body.email || '').trim().slice(0, 120);
  const numbers = Array.isArray(body.numbers) ? body.numbers.map(Number).filter(Number.isInteger).slice(0, 200) : [];
  const quantity = parseInt(body.quantity, 10) || 0;

  if (name.length < 3) return json(400, { error: 'Escribe tu nombre completo' });
  if (phone.replace(/\D/g, '').length < 10) return json(400, { error: 'Escribe un teléfono válido' });
  if (!body.raffle_id) return json(400, { error: 'Rifa no indicada' });

  let order;
  try {
    order = await rpc('reserve_tickets', {
      p_raffle_id: body.raffle_id, p_numbers: numbers.length ? numbers : null, p_quantity: quantity,
      p_name: name, p_phone: phone, p_email: email, p_method: 'azul',
    });
  } catch (e) {
    return json(409, { error: e.message });
  }

  // ---------- Modo demo: sin cuenta de Azul todavía ----------
  if (env('DEMO_MODE', 'true') === 'true' || !env('AZUL_MERCHANT_ID')) {
    return json(200, { demo: true, order });
  }

  // ---------- Página de Pagos de Azul ----------
  const site = env('SITE_URL', env('URL')).replace(/\/$/, '');
  const itbisRate = Number(env('AZUL_ITBIS_RATE', '0')); // ej. 0.18 si el ITBIS va incluido y debes desglosarlo
  const itbis = itbisRate ? order.amount - order.amount / (1 + itbisRate) : 0;

  const f = {
    MerchantId: env('AZUL_MERCHANT_ID'),
    MerchantName: env('AZUL_MERCHANT_NAME', 'Rifas'),
    MerchantType: env('AZUL_MERCHANT_TYPE', 'ECommerce'),
    CurrencyCode: '$',
    OrderNumber: String(order.order_number),
    Amount: azulAmount(order.amount),
    ITBIS: itbis ? azulAmount(itbis) : '000',
    ApprovedUrl: `${site}/pago/aprobado`,
    DeclinedUrl: `${site}/pago/rechazado`,
    CancelUrl: `${site}/pago/cancelado/${order.order_number}`,
    UseCustomField1: '1',
    CustomField1Label: 'Rifa',
    CustomField1Value: String(order.title).slice(0, 40),
    UseCustomField2: '1',
    CustomField2Label: 'Boletos',
    CustomField2Value: order.numbers.join(', ').slice(0, 40),
  };
  f.AuthHash = azulHash(
    f.MerchantId + f.MerchantName + f.MerchantType + f.CurrencyCode + f.OrderNumber + f.Amount + f.ITBIS +
    f.ApprovedUrl + f.DeclinedUrl + f.CancelUrl +
    f.UseCustomField1 + f.CustomField1Label + f.CustomField1Value +
    f.UseCustomField2 + f.CustomField2Label + f.CustomField2Value +
    env('AZUL_AUTH_KEY')
  );
  f.ShowTransactionResult = '0';
  f.Locale = 'ES';

  return json(200, {
    demo: false,
    order,
    action: env('AZUL_PAYMENT_URL', 'https://pruebas.azul.com.do/PaymentPage/'),
    fields: f,
  });
};
