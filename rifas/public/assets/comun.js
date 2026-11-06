// Utilidades del navegador compartidas por todas las páginas
const CFG = window.RIFAS_CONFIG;
const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const money = (n, cur = 'DOP') =>
  (cur === 'USD' ? 'US$' : 'RD$') + Number(n || 0).toLocaleString('es-DO', { minimumFractionDigits: 0, maximumFractionDigits: 2 });

// Cantidad de dígitos según el total: 100 -> 00..99, 1000 -> 000..999
const digits = (total) => String(Math.max(total - 1, 1)).length;
const pad = (n, total) => String(n).padStart(digits(total), '0');

function toast(msg, ms = 2600) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

// Conteo de boletos por estado (rápido, sin descargar las filas)
async function ticketStats(raffleId) {
  const count = async (status) => {
    const { count } = await sb.from('tickets').select('id', { count: 'exact', head: true })
      .eq('raffle_id', raffleId).eq('status', status);
    return count || 0;
  };
  const [sold, reserved] = await Promise.all([count('sold'), count('reserved')]);
  return { sold, reserved };
}

function header() {
  document.title = document.title.replace('{SITE}', CFG.SITE_NAME);
  $$('[data-site]').forEach((el) => (el.textContent = CFG.SITE_NAME));
  $$('[data-wa]').forEach((el) => (el.href = `https://wa.me/${CFG.WHATSAPP}`));
  const y = $('[data-year]');
  if (y) y.textContent = new Date().getFullYear();
}
document.addEventListener('DOMContentLoaded', header);

// ---------- Bancos (para elegir cuenta al transferir) ----------
// Se muestran con sus iniciales y un color de referencia.
const BANKS = [
  { name: 'Banco Popular', short: 'BP', color: '#0a5ca8' },
  { name: 'Banreservas', short: 'BR', color: '#1d4f91' },
  { name: 'BHD', short: 'BHD', color: '#0b8a43' },
  { name: 'Scotiabank', short: 'S', color: '#e3121b' },
  { name: 'Asociación Popular (APAP)', short: 'AP', color: '#f08a00' },
  { name: 'Banco Santa Cruz', short: 'SC', color: '#0f6e57' },
  { name: 'Banesco', short: 'BN', color: '#0a9396' },
  { name: 'Promerica', short: 'PR', color: '#2a9d3f' },
  { name: 'Banco Caribe', short: 'BC', color: '#0b4f8a' },
  { name: 'Banco BDI', short: 'BDI', color: '#7a1e48' },
  { name: 'Banco Vimenca', short: 'V', color: '#c8102e' },
  { name: 'Banco López de Haro', short: 'LH', color: '#14365d' },
  { name: 'Banco Lafise', short: 'LF', color: '#16794a' },
  { name: 'Asociación Cibao (ACAP)', short: 'AC', color: '#0067b1' },
  { name: 'Asociación La Nacional', short: 'LN', color: '#004a8f' },
  { name: 'Qik', short: 'Q', color: '#6c2bd9' },
  { name: 'PayPal', short: 'PP', color: '#003087' },
  { name: 'Otro', short: '$', color: '#3a3a3c' },
];
function bankInfo(name) {
  return BANKS.find((b) => b.name === name) ||
    { name, short: String(name || '?').split(/\s+/).map((w) => w[0]).join('').slice(0, 3).toUpperCase(), color: '#3a3a3c' };
}
function bankLogo(name) {
  const b = bankInfo(name);
  return `<span class="bank-logo" style="background:${b.color}">${esc(b.short)}</span>`;
}
