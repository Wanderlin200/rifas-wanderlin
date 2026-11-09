// Página de detalle y compra de una rifa
const BLOCK = 100;
let R = null;            // rifa
let mode = 'pick';       // pick | random
let selected = new Set();
let blockStart = 0;
let blockData = [];
let pendingOrder = null;
let payMethod = 'azul';  // azul | transfer

const slug = new URLSearchParams(location.search).get('r');

init();

async function init() {
  const { data: r } = await sb.from('raffles').select('*').eq('slug', slug).maybeSingle();
  if (!r) { $('#loading').textContent = 'Esta rifa no existe o ya no está disponible.'; return; }
  R = r;
  R.mode = 'random'; // solo números al azar
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
  const blocks = Math.ceil(r.total_tickets / BLOCK);
  if (r.total_tickets <= BLOCK) sel.classList.add('hidden');
  else if (blocks <= 200) {
    for (let a = 0; a < r.total_tickets; a += BLOCK) {
      const b = Math.min(a + BLOCK - 1, r.total_tickets - 1);
      sel.insertAdjacentHTML('beforeend', `<option value="${a}">${pad(a, r.total_tickets)} – ${pad(b, r.total_tickets)}</option>`);
    }
  } else {
    // Rifas grandes: botones ‹ › y buscador en vez de una lista gigante
    sel.outerHTML = `<div id="block" class="block-nav"><button type="button" class="btn btn-ghost btn-sm" id="prevB">‹</button><span id="blockLabel"></span><button type="button" class="btn btn-ghost btn-sm" id="nextB">›</button></div>`;
    $('#prevB').onclick = () => loadBlock(Math.max(0, blockStart - BLOCK));
    $('#nextB').onclick = () => loadBlock(Math.min((blocks - 1) * BLOCK, blockStart + BLOCK));
  }
  if ($('#block').tagName === 'SELECT') $('#block').onchange = () => loadBlock(+$('#block').value);
  $('#search').oninput = onSearch;
  $('#lucky').onclick = lucky;

  // Aleatorio: paquetes + cantidad personalizada
  const max = r.max_per_order, min = minQty();
  $('#qty').max = max; $('#qty').min = min; $('#qty').value = min;
  $('#minNote').textContent = `Compra mínima: ${min} número${min === 1 ? '' : 's'} · máximo ${max}`;
  const pk = (r.packages || []).filter((n) => n >= min && n <= max);
  $('#pkgs').innerHTML = pk.map((n, i) => {
    const tag = pk.length >= 4 && i === pk.length - 1 ? 'MÁXIMO' : pk.length >= 4 && i === pk.length - 2 ? 'VIP' : i === Math.min(2, pk.length - 1) && pk.length >= 3 ? '★ POPULAR' : '';
    return `<button type="button" class="pkg" data-q="${n}">${tag ? `<i>${tag}</i>` : ''}<b>${n}</b><span>NÚMEROS</span><em>${money(n * r.ticket_price, r.currency)}</em></button>`;
  }).join('');
  $('#pkgs').previousElementSibling.classList.toggle('hidden', !pk.length);
  $$('#pkgs .pkg').forEach((b) => (b.onclick = () => { $('#qty').value = b.dataset.q; updateSummary(); }));
  $('#minus').onclick = () => { $('#qty').value = Math.max(min, +$('#qty').value - 1); updateSummary(); };
  $('#plus').onclick = () => { $('#qty').value = Math.min(max, +$('#qty').value + 1); updateSummary(); };
  $('#qty').oninput = updateSummary;

  // Métodos de pago habilitados en esta rifa
  const online = R.pay_online !== false, transfer = !!R.pay_transfer;
  payMethod = online ? 'azul' : 'transfer';
  if (online && transfer) {
    $('#methodBox').classList.remove('hidden');
    $$('.pay-opt input').forEach((i) => (i.onchange = () => setPayMethod(i.value)));
  }
  setPayMethod(payMethod);

  $('#form').onsubmit = pay;
  $('#demoOk').onclick = () => demoPay(true);
  $('#demoNo').onclick = () => demoPay(false);

  // Si la rifa permite ambas modalidades y tiene paquetes, se muestran primero los paquetes
  if (r.mode === 'both' && $$('#pkgs .pkg').length) setMode('random');
  await loadBlock(0);
  updateSummary();
  setInterval(() => { if (mode === 'pick') loadBlock(blockStart, true); refreshStats(); }, 20000);
}

// Números premiados: se marcan "¡SALIÓ!" cuando alguien los compra
async function renderBonus() {
  const nums = R.bonus_numbers || [];
  if (!nums.length) return;
  const { data } = await sb.from('tickets').select('number').eq('raffle_id', R.id).eq('status', 'sold').in('number', nums);
  if (data) data.splice(0, data.length, ...data.filter((t) => !t.status || t.status === 'sold'));
  const out = new Set((data || []).map((t) => t.number).filter((n) => nums.includes(n)));
  const box = $('#bonusBox');
  box.classList.remove('hidden');
  box.innerHTML = `<div class="crown">👑</div>
    <h4>Si te sale uno de estos números ganas</h4>
    <div class="amount">${esc(R.bonus_prize || '')}</div>
    <div class="bonus-grid">${nums.map((n) => out.has(n)
      ? `<div class="bonus-num out"><s>${pad(n, R.total_tickets)}</s><small>👑 ¡SALIÓ!</small></div>`
      : `<div class="bonus-num">${pad(n, R.total_tickets)}</div>`).join('')}</div>
    <div class="muted" style="font-size:13px">Quedan <b style="color:var(--text)">${nums.length - out.size} de ${nums.length}</b> · ${R.mode === 'pick' ? 'búscalos en la cuadrícula' : 'se asignan al azar al comprar'}</div>`;
}

async function refreshStats() {
  renderBonus();
  const mn = minQty();
  $('#minLabel').textContent = mn > 1 ? `Mín: ${mn} números` : '';
  const st = await ticketStats(R.id);
  const pct = Math.round((st.sold / R.total_tickets) * 100);
  $('#bar').style.width = pct + '%';
  $('#pct').textContent = `${pct}% vendido`;
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
  if ($('#blockLabel')) $('#blockLabel').textContent = `${pad(start, R.total_tickets)} – ${pad(end, R.total_tickets)}`;
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
  if (start !== blockStart) { if ($('#block').tagName === 'SELECT') $('#block').value = start; await loadBlock(start); }
  renderGrid(n);
}

function lucky() {
  const free = blockData.filter((t) => isFree(t) && !selected.has(t.number));
  if (!free.length) return toast('No quedan números libres en este bloque');
  toggle(free[Math.floor(Math.random() * free.length)].number);
}

function count() { return mode === 'pick' ? selected.size : Math.max(0, Math.min(R.max_per_order, parseInt($('#qty').value, 10) || 0)); }

function setPayMethod(m) {
  payMethod = m;
  $$('.pay-opt').forEach((o) => {
    o.classList.toggle('on', o.dataset.method === m);
    o.querySelector('input').checked = o.dataset.method === m;
  });
  $('#secureNote').textContent = m === 'transfer'
    ? '🏦 Al reservar verás los datos de la cuenta. Tus números quedan apartados 2 horas para que transfieras y subas la captura.'
    : '🔒 Pago seguro con tarjeta, Apple Pay o Google Pay a través de AZUL';
  updateSummary();
}

function minQty() { return Math.max(1, R.min_per_order || 1); }

function updateSummary() {
  const c = count(), min = minQty();
  $$('#pkgs .pkg').forEach((b) => b.classList.toggle('on', mode === 'random' && +b.dataset.q === c));
  $('#countLabel').textContent = `${c} boleto${c === 1 ? '' : 's'}`;
  $('#total').textContent = money(c * R.ticket_price, R.currency);
  $('#payBtn').disabled = c < min;
  $('#payBtn').textContent = c < min ? (min > 1 ? `Compra mínima: ${min} números${mode === 'pick' && c ? ` (llevas ${c})` : ''}` : 'Elige al menos un boleto')
    : payMethod === 'transfer' ? `Reservar y pagar por transferencia (${money(c * R.ticket_price, R.currency)})`
    : `Pagar ${money(c * R.ticket_price, R.currency)}`;
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
        method: payMethod,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'No se pudo crear la orden');

    if (data.transfer) {
      location.href = `/resultado.html?orden=${data.order.order_id}&estado=transferencia`;
      return;
    }

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
