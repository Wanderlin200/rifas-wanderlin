// Página de detalle y compra de una rifa
const BLOCK = 100;
let R = null;            // rifa
let mode = 'pick';       // pick | random
let selected = new Set();
let blockStart = 0;
let blockData = [];
let pendingOrder = null;

const slug = new URLSearchParams(location.search).get('r');

init();

async function init() {
  const { data: r } = await sb.from('raffles').select('*').eq('slug', slug).maybeSingle();
  if (!r) { $('#loading').textContent = 'Esta rifa no existe o ya no está disponible.'; return; }
  R = r;
  document.title = `${r.title} · ${CFG.SITE_NAME}`;
  $('#loading').classList.add('hidden');
  $('#detail').classList.remove('hidden');

  $('#img').style.backgroundImage = r.image_url ? `url('${r.image_url}')` : '';
  $('#title').textContent = r.title;
  $('#price').innerHTML = `${money(r.ticket_price, r.currency)} <small>por boleto</small>`;
  $('#prize').textContent = r.prize ? `Premio: ${r.prize}` : '';
  $('#desc').textContent = r.description || '';
  await refreshStats();

  if (r.draw_date && r.status === 'active') startCountdown(new Date(r.draw_date));

  if (r.status === 'drawn') return showWinner();
  if (r.status !== 'active') {
    $('#buyBox').innerHTML = '<h2 style="font-size:20px">Venta cerrada</h2><p class="muted">Ya no se venden boletos para esta rifa. El ganador se anunciará pronto.</p>';
    return;
  }

  // Modo de venta
  if (r.mode === 'pick') $('#tabs').classList.add('hidden');
  if (r.mode === 'random') { $('#tabs').classList.add('hidden'); setMode('random'); }
  $$('#tabs button').forEach((b) => (b.onclick = () => setMode(b.dataset.m)));

  // Bloques de 100 números
  const sel = $('#block');
  if (r.total_tickets <= BLOCK) sel.classList.add('hidden');
  for (let a = 0; a < r.total_tickets; a += BLOCK) {
    const b = Math.min(a + BLOCK - 1, r.total_tickets - 1);
    sel.insertAdjacentHTML('beforeend', `<option value="${a}">${pad(a, r.total_tickets)} – ${pad(b, r.total_tickets)}</option>`);
  }
  sel.onchange = () => loadBlock(+sel.value);
  $('#search').oninput = onSearch;
  $('#lucky').onclick = lucky;

  // Aleatorio
  const max = r.max_per_order;
  $('#qty').max = max;
  [1, 3, 5, 10, 20].filter((n) => n <= max).forEach((n) =>
    $('#quick').insertAdjacentHTML('beforeend', `<button class="btn btn-ghost btn-sm" data-q="${n}">${n} boletos</button>`));
  $$('#quick button').forEach((b) => (b.onclick = () => { $('#qty').value = b.dataset.q; updateSummary(); }));
  $('#minus').onclick = () => { $('#qty').value = Math.max(1, +$('#qty').value - 1); updateSummary(); };
  $('#plus').onclick = () => { $('#qty').value = Math.min(max, +$('#qty').value + 1); updateSummary(); };
  $('#qty').oninput = updateSummary;

  $('#form').onsubmit = pay;
  $('#demoOk').onclick = () => demoPay(true);
  $('#demoNo').onclick = () => demoPay(false);

  await loadBlock(0);
  updateSummary();
  setInterval(() => { if (mode === 'pick') loadBlock(blockStart, true); refreshStats(); }, 20000);
}

async function refreshStats() {
  const st = await ticketStats(R.id);
  const pct = Math.round((st.sold / R.total_tickets) * 100);
  $('#bar').style.width = pct + '%';
  $('#pct').textContent = `${pct}% vendido`;
  $('#avail').textContent = `${R.total_tickets - st.sold - st.reserved} disponibles de ${R.total_tickets}`;
}

function setMode(m) {
  mode = m;
  $$('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.m === m));
  $('#pickPane').classList.toggle('hidden', m !== 'pick');
  $('#randomPane').classList.toggle('hidden', m !== 'random');
  $('#chipsWrap').classList.toggle('hidden', m !== 'pick');
  updateSummary();
}

const isFree = (t) => t.status === 'available' || (t.status === 'reserved' && t.reserved_until && new Date(t.reserved_until) < new Date());

async function loadBlock(start, silent) {
  blockStart = start;
  const end = Math.min(start + BLOCK - 1, R.total_tickets - 1);
  const { data } = await sb.from('tickets').select('number,status,reserved_until')
    .eq('raffle_id', R.id).gte('number', start).lte('number', end).order('number');
  blockData = data || [];
  // Si alguien compró un número que yo tenía seleccionado, lo quito
  blockData.forEach((t) => { if (!isFree(t) && selected.has(t.number)) { selected.delete(t.number); if (silent) toast(`El número ${pad(t.number, R.total_tickets)} acaba de venderse`); } });
  renderGrid();
  updateSummary();
}

function renderGrid(highlight) {
  $('#numbers').innerHTML = blockData.map((t) => {
    const free = isFree(t);
    const cls = ['num', selected.has(t.number) ? 'sel' : '', highlight === t.number ? 'hl' : ''].join(' ');
    return `<button type="button" class="${cls}" data-n="${t.number}" ${free ? '' : 'disabled'}>${pad(t.number, R.total_tickets)}</button>`;
  }).join('');
  $$('#numbers .num').forEach((b) => (b.onclick = () => toggle(+b.dataset.n)));
  if (highlight != null) $(`.num[data-n="${highlight}"]`)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

function toggle(n) {
  if (selected.has(n)) selected.delete(n);
  else {
    if (selected.size >= R.max_per_order) return toast(`Máximo ${R.max_per_order} boletos por compra`);
    selected.add(n);
  }
  renderGrid();
  updateSummary();
}

async function onSearch(e) {
  const v = e.target.value.replace(/\D/g, '');
  if (!v) return renderGrid();
  const n = parseInt(v, 10);
  if (n >= R.total_tickets) return;
  const start = Math.floor(n / BLOCK) * BLOCK;
  if (start !== blockStart) { $('#block').value = start; await loadBlock(start); }
  renderGrid(n);
}

function lucky() {
  const free = blockData.filter((t) => isFree(t) && !selected.has(t.number));
  if (!free.length) return toast('No quedan números libres en este bloque');
  toggle(free[Math.floor(Math.random() * free.length)].number);
}

function count() { return mode === 'pick' ? selected.size : Math.max(0, Math.min(R.max_per_order, parseInt($('#qty').value, 10) || 0)); }

function updateSummary() {
  const c = count();
  $('#countLabel').textContent = `${c} boleto${c === 1 ? '' : 's'}`;
  $('#total').textContent = money(c * R.ticket_price, R.currency);
  $('#payBtn').disabled = c < 1;
  $('#payBtn').textContent = c ? `Pagar ${money(c * R.ticket_price, R.currency)}` : 'Elige al menos un boleto';
  const nums = [...selected].sort((a, b) => a - b);
  $('#chips').innerHTML = nums.length
    ? nums.map((n) => `<span class="chip">${pad(n, R.total_tickets)}</span>`).join('')
    : '<span class="muted" style="font-size:13px">Aún no has elegido.</span>';
}

async function pay(e) {
  e.preventDefault();
  $('#err').classList.add('hidden');
  const btn = $('#payBtn');
  btn.disabled = true;
  btn.textContent = 'Reservando tus boletos…';
  try {
    const res = await fetch('/api/crear-orden', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        raffle_id: R.id,
        numbers: mode === 'pick' ? [...selected] : [],
        quantity: count(),
        name: $('#name').value, phone: $('#phone').value, email: $('#email').value,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'No se pudo crear la orden');

    if (data.demo) {
      pendingOrder = data.order;
      $('#demoChips').innerHTML = data.order.numbers.map((n) => `<span class="chip">${pad(n, R.total_tickets)}</span>`).join('');
      $('#demoModal').classList.remove('hidden');
      return;
    }

    // Enviar al cliente a la Página de Pagos de AZUL (tarjeta / Apple Pay / Google Pay)
    btn.textContent = 'Redirigiendo al pago seguro…';
    const f = document.createElement('form');
    f.method = 'POST';
    f.action = data.action;
    Object.entries(data.fields).forEach(([k, v]) => {
      const i = document.createElement('input');
      i.type = 'hidden'; i.name = k; i.value = v;
      f.appendChild(i);
    });
    document.body.appendChild(f);
    f.submit();
  } catch (err) {
    $('#err').textContent = err.message;
    $('#err').classList.remove('hidden');
    updateSummary();
    if (mode === 'pick') loadBlock(blockStart);
  }
}

async function demoPay(aprobar) {
  $('#demoOk').disabled = $('#demoNo').disabled = true;
  await fetch('/api/demo-pago', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ order_id: pendingOrder.order_id, aprobar }),
  });
  location.href = `/resultado.html?orden=${pendingOrder.order_id}&estado=${aprobar ? 'aprobado' : 'rechazado'}`;
}

function startCountdown(target) {
  $('#countdownBox').classList.remove('hidden');
  const tick = () => {
    let s = Math.max(0, Math.floor((target - new Date()) / 1000));
    const d = Math.floor(s / 86400); s %= 86400;
    const h = Math.floor(s / 3600); s %= 3600;
    const m = Math.floor(s / 60); s %= 60;
    $('#countdown').innerHTML = [[d, 'días'], [h, 'horas'], [m, 'min'], [s, 'seg']]
      .map(([v, l]) => `<div><b>${String(v).padStart(2, '0')}</b><small>${l}</small></div>`).join('');
  };
  tick();
  setInterval(tick, 1000);
}

async function showWinner() {
  $('#buyBox').classList.add('hidden');
  const { data: w } = await sb.rpc('public_winner', { p_raffle_id: R.id });
  if (!w) return;
  const box = $('#winnerBox');
  box.classList.remove('hidden');
  box.innerHTML = `<div class="muted">🏆 Número ganador</div><div class="n">${pad(w.number, R.total_tickets)}</div>
    <div style="font-size:18px;font-weight:600">${esc(w.name)}</div>
    <div class="muted" style="font-size:13px;margin-top:6px">Sorteado el ${new Date(w.drawn_at).toLocaleString('es-DO')}</div>`;
}
