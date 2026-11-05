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
