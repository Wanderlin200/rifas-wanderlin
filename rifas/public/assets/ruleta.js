// Ruleta animada. El ganador lo decide la base de datos (draw_winner);
// la ruleta solo gira hasta detenerse en ese número.
const Ruleta = (() => {
  const LIGHT = ['#0a84ff', '#bf5af2', '#ff9f0a'];
  const DARK = ['#5e5ce6', '#ff375f', '#30d158'];
  let canvas, ctx, labels = [], rot = 0, audio;

  function setup(el, items) {
    canvas = el; ctx = canvas.getContext('2d');
    labels = items; rot = 0; draw();
  }

  function draw() {
    const W = canvas.width, c = W / 2, r = c - 12, n = labels.length, seg = (Math.PI * 2) / n;
    ctx.clearRect(0, 0, W, W);
    // aro exterior
    ctx.beginPath(); ctx.arc(c, c, r + 8, 0, Math.PI * 2); ctx.fillStyle = '#3a3a3c'; ctx.fill();
    for (let i = 0; i < n; i++) {
      const a0 = rot + i * seg - Math.PI / 2, a1 = a0 + seg;
      ctx.beginPath(); ctx.moveTo(c, c); ctx.arc(c, c, r, a0, a1); ctx.closePath();
      const isLight = i % 2 === 0 && !(n % 2 && i === n - 1 && n > 1);
      ctx.fillStyle = isLight ? LIGHT[(i / 2) % 3] : DARK[i % 3];
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,.25)'; ctx.lineWidth = 2; ctx.stroke();
      // texto
      ctx.save(); ctx.translate(c, c); ctx.rotate(a0 + seg / 2);
      ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
      ctx.fillStyle = '#ffffff';
      const fs = Math.max(16, Math.min(46, (seg * r) * 0.55));
      ctx.font = `800 ${fs}px -apple-system, BlinkMacSystemFont, Inter, sans-serif`;
      ctx.fillText(labels[i], r - 22, 0);
      ctx.restore();
    }
    // luces del borde
    for (let i = 0; i < 36; i++) {
      const a = (i / 36) * Math.PI * 2;
      ctx.beginPath(); ctx.arc(c + Math.cos(a) * (r + 2), c + Math.sin(a) * (r + 2), 5, 0, Math.PI * 2);
      ctx.fillStyle = ['#0a84ff', '#bf5af2', '#ff375f', '#ff9f0a', '#30d158', '#64d2ff'][i % 6]; ctx.fill();
    }
  }

  function tick() {
    try {
      audio = audio || new (window.AudioContext || window.webkitAudioContext)();
      const o = audio.createOscillator(), g = audio.createGain();
      o.type = 'triangle'; o.frequency.value = 900;
      g.gain.setValueAtTime(0.08, audio.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, audio.currentTime + 0.05);
      o.connect(g).connect(audio.destination); o.start(); o.stop(audio.currentTime + 0.05);
    } catch (_) {}
  }

  // Gira hasta dejar el índice `idx` bajo el puntero (arriba)
  function spinTo(idx, duration = 7000) {
    const n = labels.length, seg = (Math.PI * 2) / n;
    const jitter = (Math.random() - 0.5) * seg * 0.6;
    const base = -(idx + 0.5) * seg + jitter;
    const turns = 7 + Math.floor(Math.random() * 3);
    const start = rot;
    let target = base + Math.PI * 2 * Math.ceil((start - base) / (Math.PI * 2)) + Math.PI * 2 * turns;
    const t0 = performance.now();
    let lastSeg = Math.floor(start / seg);
    return new Promise((resolve) => {
      const step = (now) => {
        const p = Math.min(1, (now - t0) / duration);
        const e = 1 - Math.pow(1 - p, 4); // easeOutQuart
        rot = start + (target - start) * e;
        const s = Math.floor(rot / seg);
        if (s !== lastSeg) { lastSeg = s; tick(); }
        draw();
        p < 1 ? requestAnimationFrame(step) : resolve();
      };
      requestAnimationFrame(step);
    });
  }

  function confetti(el, ms = 4500) {
    el.classList.remove('hidden');
    const c = el.getContext('2d');
    el.width = innerWidth; el.height = innerHeight;
    const parts = Array.from({ length: 220 }, () => ({
      x: innerWidth / 2, y: innerHeight / 2.4,
      vx: (Math.random() - 0.5) * 18, vy: Math.random() * -18 - 4,
      s: 6 + Math.random() * 6, r: Math.random() * 6, vr: (Math.random() - 0.5) * 0.3,
      col: ['#0a84ff', '#5e5ce6', '#bf5af2', '#ff375f', '#ff9f0a', '#30d158', '#64d2ff', '#ffd60a'][Math.floor(Math.random() * 6)],
    }));
    const t0 = performance.now();
    const loop = (now) => {
      c.clearRect(0, 0, el.width, el.height);
      parts.forEach((p) => {
        p.vy += 0.45; p.vx *= 0.99; p.x += p.vx; p.y += p.vy; p.r += p.vr;
        c.save(); c.translate(p.x, p.y); c.rotate(p.r); c.fillStyle = p.col; c.fillRect(-p.s / 2, -p.s / 4, p.s, p.s / 2); c.restore();
      });
      now - t0 < ms ? requestAnimationFrame(loop) : el.classList.add('hidden');
    };
    requestAnimationFrame(loop);
  }

  return { setup, spinTo, confetti, get labels() { return labels; } };
})();
