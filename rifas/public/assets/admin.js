// Panel de administración
let raffles = [];
let current = null;      // rifa abierta
let orders = [];         // órdenes de la rifa abierta (con sus números)
let editing = null;      // rifa en edición (null = nueva)

const show = (id) => ['loginView', 'listView', 'raffleView'].forEach((v) => $('#' + v).classList.toggle('hidden', v !== id));
const openModal = (id) => $('#' + id).classList.remove('hidden');
const closeModals = () => $$('.modal').forEach((m) => m.classList.add('hidden'));
$$('[data-close]').forEach((b) => (b.onclick = closeModals));

const slugify = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 50);
const STATUS = { draft: 'Borrador', active: 'Activa', closed: 'Cerrada', drawn: 'Sorteada', paid: 'Pagada', pending: 'Pendiente', declined: 'Rechazada', cancelled: 'Cancelada', expired: 'Vencida' };
const badge = (s) => `<span class="badge b-${s}">${STATUS[s] || s}</span>`;

// Descarga todas las filas paginando de 1000 en 1000 (límite de Supabase)
async function fetchAll(build) {
  let out = [], from = 0;
  for (;;) {
    const { data, error } = await build().range(from, from + 999);
    if (error) throw error;
    out = out.concat(data);
    if (data.length < 1000) return out;
    from += 1000;
  }
}

// ---------------- SESIÓN ----------------
(async () => {
  const { data: { session } } = await sb.auth.getSession();
  session ? enter() : show('loginView');
})();

$('#loginForm').onsubmit = async (e) => {
  e.preventDefault();
  $('#lerr').classList.add('hidden');
  const { error } = await sb.auth.signInWithPassword({ email: $('#lemail').value, password: $('#lpass').value });
  if (error) { $('#lerr').textContent = 'Correo o contraseña incorrectos'; $('#lerr').classList.remove('hidden'); return; }
  enter();
};
$('#logout').onclick = async (e) => { e.preventDefault(); await sb.auth.signOut(); location.reload(); };

async function enter() {
  const { data: isAdmin } = await sb.rpc('is_admin');
  if (!isAdmin) {
    show('loginView');
    $('#lerr').textContent = 'Este usuario no es administrador. Revisa el paso final del README.';
    $('#lerr').classList.remove('hidden');
    return;
  }
  $('#logout').classList.remove('hidden');
  loadList();
}

// ---------------- LISTA ----------------
async function loadList() {
  show('listView');
  const { data } = await sb.from('raffles').select('*').order('created_at', { ascending: false });
  raffles = data || [];
  if (!raffles.length) { $('#list').innerHTML = '<div class="empty" style="border:0">Aún no tienes rifas. Crea la primera con “Nueva rifa”.</div>'; return; }
  const rows = await Promise.all(raffles.map(async (r) => {
    const st = await ticketStats(r.id);
    return `<div class="item">
      <div class="thumb" style="background-image:url('${esc(r.image_url || '')}')"></div>
      <div><div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap"><b>${esc(r.title)}</b>${badge(r.status)}</div>
        <div class="muted" style="font-size:13px">${st.sold}/${r.total_tickets} vendidos · ${money(r.ticket_price, r.currency)} c/u · ${money(st.sold * r.ticket_price, r.currency)} recaudado</div></div>
      <div class="actions"><button class="btn btn-ghost btn-sm" data-edit="${r.id}">Editar</button><button class="btn btn-gold btn-sm" data-open="${r.id}">Ventas y sorteo</button></div>
    </div>`;
  }));
  $('#list').innerHTML = rows.join('');
  $$('[data-edit]').forEach((b) => (b.onclick = () => openEdit(raffles.find((r) => r.id === b.dataset.edit))));
  $$('[data-open]').forEach((b) => (b.onclick = () => openRaffle(b.dataset.open)));
}

// ---------------- CREAR / EDITAR ----------------
$('#newBtn').onclick = () => openEdit(null);
$('#eTitle').oninput = () => { if (!editing) $('#eSlug').value = slugify($('#eTitle').value); };

function openEdit(r) {
  editing = r;
  $('#editTitle').textContent = r ? 'Editar rifa' : 'Nueva rifa';
  $('#eErr').classList.add('hidden');
  $('#eTitle').value = r?.title || '';
  $('#ePrize').value = r?.prize || '';
  $('#eSlug').value = r?.slug || '';
  $('#eDesc').value = r?.description || '';
  $('#eImg').value = '';
  $('#ePrice').value = r?.ticket_price || '';
  $('#eCur').value = r?.currency || 'DOP';
  $('#eTotal').value = r?.total_tickets || 100;
  $('#eTotal').disabled = !!r;
  $('#eMax').value = r?.max_per_order || 50;
  $('#eMode').value = r?.mode || 'both';
  $('#eDate').value = r?.draw_date ? new Date(new Date(r.draw_date).getTime() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16) : '';
  $('#eStatus').value = r?.status === 'drawn' ? 'closed' : r?.status || 'draft';
  $('#eStatus').disabled = r?.status === 'drawn';
  openModal('editModal');
}

$('#editForm').onsubmit = async (e) => {
  e.preventDefault();
  const btn = $('#eSave'); btn.disabled = true; btn.textContent = 'Guardando…';
  try {
    let image_url = editing?.image_url || null;
    const file = $('#eImg').files[0];
    if (file) {
      const path = `${Date.now()}-${slugify(file.name.replace(/\.[^.]+$/, ''))}.${file.name.split('.').pop()}`;
      const { error } = await sb.storage.from('rifas').upload(path, file, { upsert: false });
      if (error) throw error;
      image_url = sb.storage.from('rifas').getPublicUrl(path).data.publicUrl;
    }
    const row = {
      title: $('#eTitle').value.trim(), prize: $('#ePrize').value.trim(), slug: slugify($('#eSlug').value),
      description: $('#eDesc').value, image_url, ticket_price: +$('#ePrice').value, currency: $('#eCur').value,
      max_per_order: +$('#eMax').value, mode: $('#eMode').value,
      draw_date: $('#eDate').value ? new Date($('#eDate').value).toISOString() : null,
    };
    if (editing?.status !== 'drawn') row.status = $('#eStatus').value;
    const q = editing
      ? sb.from('raffles').update(row).eq('id', editing.id)
      : sb.from('raffles').insert({ ...row, total_tickets: +$('#eTotal').value });
    const { error } = await q;
    if (error) throw error;
    closeModals();
    toast('Rifa guardada');
    current ? openRaffle(current.id) : loadList();
  } catch (err) {
    $('#eErr').textContent = err.message.includes('duplicate') ? 'Ese enlace (slug) ya existe, usa otro.' : err.message;
    $('#eErr').classList.remove('hidden');
  } finally { btn.disabled = false; btn.textContent = 'Guardar'; }
};

// ---------------- DETALLE / VENTAS ----------------
$('#back').onclick = (e) => { e.preventDefault(); current = null; loadList(); };

async function openRaffle(id) {
  show('raffleView');
  const { data: r } = await sb.from('raffles').select('*').eq('id', id).single();
  current = r;
  $('#rTitle').innerHTML = `${esc(r.title)} ${badge(r.status)}`;

  const [ord, tix] = await Promise.all([
    fetchAll(() => sb.from('orders').select('*').eq('raffle_id', id).order('created_at', { ascending: false })),
    fetchAll(() => sb.from('tickets').select('number,order_id,status').eq('raffle_id', id).not('order_id', 'is', null)),
  ]);
  const byOrder = {};
  tix.forEach((t) => (byOrder[t.order_id] = byOrder[t.order_id] || []).push(t.number));
  orders = ord.map((o) => ({ ...o, numbers: (byOrder[o.id] || []).sort((a, b) => a - b) }));

  const paid = orders.filter((o) => o.status === 'paid');
  const sold = paid.reduce((s, o) => s + o.numbers.length, 0);
  const revenue = paid.reduce((s, o) => s + Number(o.amount), 0);
  const pending = orders.filter((o) => o.status === 'pending').length;
  $('#rStats').innerHTML = [
    [`${sold}/${r.total_tickets}`, 'Boletos vendidos'],
    [money(revenue, r.currency), 'Recaudado'],
    [paid.length, 'Compradores'],
    [pending, 'Pagos pendientes'],
  ].map(([v, l]) => `<div class="card stat"><b>${v}</b><span>${l}</span></div>`).join('');

  // Acciones
  const a = [`<a class="btn btn-ghost btn-sm" href="/rifa.html?r=${encodeURIComponent(r.slug)}" target="_blank">Ver página</a>`,
    `<button class="btn btn-ghost btn-sm" id="aEdit">Editar</button>`];
  if (r.status === 'draft' || r.status === 'closed') a.push(`<button class="btn btn-ghost btn-sm" data-st="active">Activar venta</button>`);
  if (r.status === 'active') a.push(`<button class="btn btn-ghost btn-sm" data-st="closed">Cerrar venta</button>`);
  if (r.status !== 'drawn') a.push(`<button class="btn btn-ghost btn-sm" id="aManual">+ Venta manual</button>`);
  if (r.status !== 'drawn') a.push(`<button class="btn btn-gold btn-sm" id="aDraw" ${sold ? '' : 'disabled title="No hay boletos vendidos"'}>🎡 Elegir ganador</button>`);
  else a.push(`<button class="btn btn-gold btn-sm" id="aWinner">🏆 Ver ganador</button>`);
  $('#rActions').innerHTML = a.join('');
  $('#aEdit').onclick = () => openEdit(r);
  $$('[data-st]').forEach((b) => (b.onclick = async () => { await sb.from('raffles').update({ status: b.dataset.st }).eq('id', r.id); openRaffle(r.id); }));
  $('#aManual') && ($('#aManual').onclick = () => { $('#manualForm').reset(); $('#mErr').classList.add('hidden'); openModal('manualModal'); });
  $('#aDraw') && ($('#aDraw').onclick = openWheel);
  $('#aWinner') && ($('#aWinner').onclick = showSavedWinner);

  renderOrders();
}

$('#fStatus').onchange = renderOrders;
$('#fSearch').oninput = renderOrders;

function filteredOrders() {
  const st = $('#fStatus').value, q = $('#fSearch').value.trim().toLowerCase();
  return orders.filter((o) => (!st || o.status === st) && (!q ||
    o.buyer_name.toLowerCase().includes(q) || o.buyer_phone.includes(q) ||
    o.numbers.some((n) => pad(n, current.total_tickets) === q.padStart(digits(current.total_tickets), '0'))));
}

function renderOrders() {
  const list = filteredOrders();
  const T = current.total_tickets;
  $('#orders').innerHTML = list.length ? list.map((o) => `
    <tr>
      <td class="muted">${o.order_number}</td>
      <td><b>${esc(o.buyer_name)}</b><br><a class="muted" href="https://wa.me/${o.buyer_phone.replace(/\D/g, '').replace(/^(8[024]9)/, '1$1')}" target="_blank">${esc(o.buyer_phone)}</a>${o.buyer_email ? `<br><span class="muted" style="font-size:12px">${esc(o.buyer_email)}</span>` : ''}</td>
      <td class="nums-cell">${o.numbers.map((n) => pad(n, T)).join(', ') || '—'}</td>
      <td>${money(o.amount, current.currency)}<br><span class="muted" style="font-size:12px">${o.payment_method === 'manual' ? 'Manual' : 'AZUL'}${o.auth_code && o.auth_code !== 'MANUAL' ? ' · ' + esc(o.auth_code) : ''}</span></td>
      <td>${badge(o.status)}${o.response_msg?.startsWith('REVISAR') ? `<br><span style="color:var(--red);font-size:12px">${esc(o.response_msg)}</span>` : ''}</td>
      <td class="muted" style="font-size:13px">${new Date(o.created_at).toLocaleString('es-DO', { dateStyle: 'short', timeStyle: 'short' })}</td>
      <td>${o.status === 'pending' && current.status !== 'drawn' ? `<button class="btn btn-ghost btn-sm" data-paid="${o.id}">Marcar pagada</button>` : ''}</td>
    </tr>`).join('') : '<tr><td colspan="7" class="muted" style="text-align:center;padding:30px">Sin ventas con este filtro.</td></tr>';
  $$('[data-paid]').forEach((b) => (b.onclick = async () => {
    if (!confirm('¿Confirmas que recibiste este pago (transferencia/efectivo)?')) return;
    const { error } = await sb.rpc('admin_mark_paid', { p_order_id: b.dataset.paid });
    error ? toast(error.message) : openRaffle(current.id);
  }));
}

$('#csvBtn').onclick = () => {
  const T = current.total_tickets;
  const rows = [['Orden', 'Nombre', 'Telefono', 'Correo', 'Numeros', 'Monto', 'Estado', 'Metodo', 'Autorizacion', 'Fecha']]
    .concat(filteredOrders().map((o) => [o.order_number, o.buyer_name, o.buyer_phone, o.buyer_email || '', o.numbers.map((n) => pad(n, T)).join(' '),
      o.amount, STATUS[o.status], o.payment_method, o.auth_code || '', new Date(o.created_at).toLocaleString('es-DO')]));
  const csv = '﻿' + rows.map((r) => r.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(',')).join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  a.download = `ventas-${current.slug}.csv`;
  a.click();
};

// ---------------- VENTA MANUAL ----------------
$('#manualForm').onsubmit = async (e) => {
  e.preventDefault();
  const nums = $('#mNums').value.split(/[,\s]+/).filter(Boolean).map((n) => parseInt(n, 10)).filter(Number.isInteger);
  const { data, error } = await sb.rpc('admin_manual_sale', {
    p_raffle_id: current.id, p_numbers: nums.length ? nums : null, p_quantity: +$('#mQty').value || 0,
    p_name: $('#mName').value, p_phone: $('#mPhone').value,
  });
  if (error) { $('#mErr').textContent = error.message; $('#mErr').classList.remove('hidden'); return; }
  closeModals();
  toast(`Venta registrada: ${data.numbers.map((n) => pad(n, current.total_tickets)).join(', ')}`, 4000);
  openRaffle(current.id);
};

// ---------------- RULETA ----------------
const MAX_SEGMENTS = 36;
let soldNumbers = [];

function shuffle(a) { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }

function openWheel() {
  const T = current.total_tickets;
  soldNumbers = orders.filter((o) => o.status === 'paid').flatMap((o) => o.numbers);
  const sample = shuffle([...soldNumbers]).slice(0, MAX_SEGMENTS);
  Ruleta.setup($('#wheel'), sample.map((n) => pad(n, T)));
  $('#wTitle').textContent = `Sorteo: ${current.title}`;
  $('#wInfo').textContent = `${soldNumbers.length} boletos vendidos participan${soldNumbers.length > MAX_SEGMENTS ? ` (la ruleta muestra ${MAX_SEGMENTS}, pero todos tienen la misma probabilidad)` : ''}.`;
  $('#wResult').innerHTML = '';
  $('#spinBtn').disabled = false;
  $('#spinBtn').classList.remove('hidden');
  openModal('wheelModal');
}

$('#spinBtn').onclick = async () => {
  if (!confirm('El ganador quedará registrado de forma definitiva. ¿Girar la ruleta?')) return;
  $('#spinBtn').disabled = true;
  const { data: w, error } = await sb.rpc('draw_winner', { p_raffle_id: current.id });
  if (error) { toast(error.message); $('#spinBtn').disabled = false; return; }

  const T = current.total_tickets;
  const label = pad(w.number, T);
  // Asegurar que el número ganador esté en la ruleta
  let labels = Ruleta.labels;
  let idx = labels.indexOf(label);
  if (idx < 0) {
    idx = Math.floor(Math.random() * labels.length);
    labels[idx] = label;
    Ruleta.setup($('#wheel'), labels);
  }
  await Ruleta.spinTo(idx);
  revealWinner(w);
};

function revealWinner(w) {
  const T = current.total_tickets;
  $('#spinBtn').classList.add('hidden');
  $('#wResult').innerHTML = `
    <div class="winner-box winner-reveal" style="margin-top:6px">
      <div class="muted">🏆 ¡Tenemos ganador!</div>
      <div class="n">${pad(w.number, T)}</div>
      <div style="font-size:20px;font-weight:700">${esc(w.buyer_name)}</div>
      <div class="muted">${esc(w.buyer_phone)} · Orden #${w.order_number}</div>
      <a class="btn btn-green btn-sm" style="margin-top:12px" target="_blank"
         href="https://wa.me/${String(w.buyer_phone).replace(/\D/g, '').replace(/^(8[024]9)/, '1$1')}?text=${encodeURIComponent(`¡Felicidades ${w.buyer_name}! 🎉 Tu boleto #${pad(w.number, T)} ganó la rifa "${current.title}".`)}">Avisar por WhatsApp</a>
    </div>`;
  Ruleta.confetti($('#confetti'));
  $$('#wheelModal [data-close]').forEach((b) => (b.onclick = () => { closeModals(); openRaffle(current.id); }));
}

async function showSavedWinner() {
  const { data: t } = await sb.from('tickets').select('number,order_id').eq('id', current.winner_ticket_id).single();
  const o = orders.find((x) => x.id === t.order_id) || {};
  Ruleta.setup($('#wheel'), [pad(t.number, current.total_tickets)]);
  $('#wTitle').textContent = `Ganador: ${current.title}`;
  $('#wInfo').textContent = `Sorteado el ${new Date(current.drawn_at).toLocaleString('es-DO')}`;
  openModal('wheelModal');
  revealWinner({ number: t.number, buyer_name: o.buyer_name, buyer_phone: o.buyer_phone, order_number: o.order_number });
}
