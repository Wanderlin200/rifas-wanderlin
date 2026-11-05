// Utilidades compartidas por las funciones serverless
const crypto = require('crypto');

const env = (k, def) => (process.env[k] ?? def);

// Encabezados para Supabase. Sirve con la key nueva (sb_secret_...) y con la antigua service_role (eyJ...)
function sbHeaders(extra = {}) {
  const key = env('SUPABASE_SERVICE_ROLE_KEY');
  const h = { apikey: key, ...extra };
  if (key && key.startsWith('eyJ')) h.Authorization = `Bearer ${key}`;
  return h;
}

// Llamada RPC a Supabase con la llave secreta (nunca se expone al navegador)
async function rpc(fn, args) {
  const res = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: sbHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(args),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error((data && (data.message || data.hint)) || 'Error de base de datos');
  return data;
}

async function findOrderByNumber(orderNumber) {
  const url = `${env('SUPABASE_URL')}/rest/v1/orders?order_number=eq.${encodeURIComponent(orderNumber)}&select=id,amount,status`;
  const res = await fetch(url, { headers: sbHeaders() });
  const rows = await res.json();
  return Array.isArray(rows) ? rows[0] : null;
}

// ---------- AZUL ----------
// Monto en el formato de Azul: sin punto decimal, los últimos 2 dígitos son centavos (RD$150.00 -> "15000")
const azulAmount = (n) => String(Math.round(Number(n) * 100));

// HMAC-SHA512. Azul firma con la AuthKey; por defecto en UTF-16LE (como en sus ejemplos).
// Si Azul te indica otra codificación, cambia AZUL_HASH_ENCODING a "utf8".
function azulHash(str) {
  const encoding = env('AZUL_HASH_ENCODING', 'utf16le');
  const key = env('AZUL_AUTH_KEY');
  return crypto
    .createHmac('sha512', Buffer.from(key, encoding))
    .update(Buffer.from(str, encoding))
    .digest('hex');
}

function safeEqual(a, b) {
  const A = Buffer.from(String(a || '').toLowerCase());
  const B = Buffer.from(String(b || '').toLowerCase());
  return A.length === B.length && crypto.timingSafeEqual(A, B);
}

const json = (status, body) => ({
  statusCode: status,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

module.exports = { env, rpc, sbHeaders, findOrderByNumber, azulAmount, azulHash, safeEqual, json };
