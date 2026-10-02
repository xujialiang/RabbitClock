/* ================================================================
   悬浮时钟 · 高保真原型交互脚本（纯原生 JS，无依赖）
   ================================================================ */
"use strict";

const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const pad = (n, l = 2) => String(Math.floor(n)).padStart(l, "0");
const WEEK = ["日", "一", "二", "三", "四", "五", "六"];

/* ───────── 全局状态 ───────── */
const S = {
  mode: "clock",                       // clock | stopwatch | countdown
  color: "#22d3ee",
  bg: "capsule",                       // capsule | card | outline
  size: 1.15, opacity: 1,
  msDigits: 0,                         // 毫秒位数：0=关，1~3=位数（默认 1 位）
  elems: { sec: true, date: false, week: false, batt: false },
  snap: true, minimized: false, fcHidden: false,
};

const SW = { running: false, elapsed: 0, base: 0, laps: [] };     // 秒表
const CD = { running: false, total: 5 * 60_000, remain: 5 * 60_000, end: 0, finished: false }; // 倒计时

const fc      = $("#floatClock");
const screen  = $("#demoScreen");
const alertBadge = $("#fcAlert");
const BATT = 78;

/* ───────── 时间格式化 ───────── */
const nowStr  = () => { const d = new Date(); return pad(d.getHours()) + ":" + pad(d.getMinutes()); };
const secStr  = () => pad(new Date().getSeconds());
const dateLine = () => { const d = new Date(); return `${d.getMonth() + 1}月${d.getDate()}日`; };
const weekStr  = () => "周" + WEEK[new Date().getDay()];
const dateWeek = () => `${dateLine()} ${weekStr()}`;

function fmtSW(ms, withMs = true) {
  const t = Math.max(0, ms);
  const h = Math.floor(t / 3_600_000), m = Math.floor(t / 60_000) % 60, s = Math.floor(t / 1000) % 60;
  const base = pad(m) + ":" + pad(s);
  const ms3 = "." + pad(t % 1000, 3);
  return (h ? pad(h) + ":" : "") + base + (withMs ? ms3 : "");
}
function fmtCD(ms) {
  const t = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60;
  return (h ? pad(h) + ":" : "") + pad(m) + ":" + pad(s);
}
const swElapsed = () => SW.running ? SW.base + (performance.now() - SW.startStamp) : SW.base;
const cdRemain  = () => CD.running ? Math.max(0, CD.end - Date.now()) : CD.remain;

/* ───────── 悬浮窗渲染 ───────── */
function renderFloatClock() {
  fc.classList.toggle("min", S.minimized);
  fc.style.setProperty("--fc", S.color);
  fc.style.setProperty("--fs", S.size);
  fc.style.setProperty("--fo", S.opacity);
  fc.className = fc.className.replace(/\bfc-(capsule|card|outline)\b/g, "").trim();
  fc.classList.add("fc-" + S.bg, "float-clock");
  if (S.minimized || S.fcHidden) return;

  const tEl = $("[data-fc-time]", fc), sEl = $("[data-fc-sec]", fc),
        mEl = $("[data-fc-ms]", fc),  sub = $("[data-fc-sub]", fc);

  if (S.mode === "clock") {
    tEl.textContent = nowStr();
    sEl.hidden = !S.elems.sec; sEl.textContent = ":" + secStr();
    mEl.hidden = S.msDigits === 0;
    if (S.msDigits > 0) mEl.textContent = "." + pad(Date.now() % 1000, 3).slice(0, S.msDigits);
  } else if (S.mode === "stopwatch") {
    const d = Math.max(1, S.msDigits);
    tEl.textContent = fmtSW(swElapsed(), false);
    sEl.hidden = true;
    mEl.hidden = false; mEl.textContent = "." + pad(swElapsed() % 1000, 3).slice(0, d);
  } else {
    tEl.textContent = fmtCD(cdRemain());
    sEl.hidden = true; mEl.hidden = true;
  }

  const bits = [];
  if (S.elems.date) bits.push(dateLine());
  if (S.elems.week) bits.push(weekStr());
  if (S.mode === "stopwatch" && SW.laps.length) bits.push(`已计 ${SW.laps.length} 次`);
  if (S.elems.batt) bits.push(BATT + "%");
  sub.hidden = bits.length === 0;
  sub.textContent = bits.join(" · ");
}

/* ───────── 悬浮窗拖拽 / 吸附 / 双击 ───────── */
(function initDrag() {
  let drag = null, moved = false;
  fc.addEventListener("pointerdown", e => {
    if (S.minimized) return;
    fc.setPointerCapture(e.pointerId);
    const r = fc.getBoundingClientRect(), sr = screen.getBoundingClientRect();
    drag = { dx: e.clientX - r.left, dy: e.clientY - r.top, sr };
    moved = false;
    fc.classList.remove("snap-anim");
  });
  fc.addEventListener("pointermove", e => {
    if (!drag) return;
    moved = true;
    const x = e.clientX - drag.sr.left - drag.dx, y = e.clientY - drag.sr.top - drag.dy;
    const maxX = drag.sr.width  - fc.offsetWidth, maxY = drag.sr.height - fc.offsetHeight;
    fc.style.left = Math.min(Math.max(x, -fc.offsetWidth * .55), maxX + fc.offsetWidth * .25) + "px";
    fc.style.top  = Math.min(Math.max(y, 52), maxY) + "px";
  });
  const release = () => {
    if (!drag) return;
    const sr = drag.sr; drag = null;
    $("#dragHint").style.opacity = "0";
    if (S.snap && moved) {
      fc.classList.add("snap-anim");
      const cx = fc.offsetLeft + fc.offsetWidth / 2;
      fc.style.left = (cx < sr.width / 2 ? 10 : sr.width - fc.offsetWidth - 10) + "px";
    }
    try { localStorage.setItem("fcPos", JSON.stringify({ l: fc.style.left, t: fc.style.top })); } catch (_) {}
  };
  fc.addEventListener("pointerup", release);
  fc.addEventListener("pointercancel", release);
  fc.addEventListener("dblclick", () => { S.minimized = !S.minimized; renderFloatClock(); });

  const saved = (() => { try { return JSON.parse(localStorage.getItem("fcPos")); } catch (_) { return null; } })();
  requestAnimationFrame(() => {
    if (saved) { fc.style.left = saved.l; fc.style.top = saved.t; }
    else fc.style.left = (screen.offsetWidth - fc.offsetWidth) / 2 + "px";
  });
})();

/* 尺寸/内容变化后把悬浮窗收回屏内，避免贴边时调大被裁剪 */
function clampFullyVisible() {
  const W = screen.offsetWidth, H = screen.offsetHeight;
  const w = fc.offsetWidth, h = fc.offsetHeight;
  fc.style.left = Math.min(Math.max(fc.offsetLeft, 8), Math.max(8, W - w - 8)) + "px";
  fc.style.top  = Math.min(Math.max(fc.offsetTop, 52), Math.max(52, H - h - 8)) + "px";
}

/* ───────── 秒表 / 倒计时 引擎操作 ───────── */
const swStartBtn = $("#swStart"), cdStartBtn = $("#cdStart"), appSwBtn = $("#appSwBtn"), appCdBtn = $("#appCdBtn");

function swToggle() {
  if (SW.running) { SW.base = swElapsed(); SW.running = false; }
  else { SW.startStamp = performance.now(); SW.running = true; }
  syncEngineButtons(); renderAll();
}
function swReset() {
  SW.running = false; SW.base = 0; SW.laps = [];
  $("#swLaps").innerHTML = "";
  syncEngineButtons(); renderAll();
}
function swLap() {
  if (!SW.running) return;
  SW.laps.unshift(swElapsed());
  $("#swLaps").insertAdjacentHTML("afterbegin",
    `<li><span>#${SW.laps.length}</span><b>${fmtSW(SW.laps[0])}</b></li>`);
}

function cdSetMinutes(min) {
  CD.total = CD.remain = min * 60_000; CD.running = false; CD.finished = false;
  fc.classList.remove("alert"); alertBadge.hidden = true;
  $$("#cdPresets .chip").forEach(c => c.classList.toggle("active", +c.dataset.min === min));
  $$("#tab-appui .mcard .chip").forEach(c => c.classList.toggle("active", +c.dataset.min === min));
  syncEngineButtons(); renderAll();
}
function cdToggle() {
  if (CD.finished) { cdSetMinutes(CD.total / 60_000); return; }
  if (CD.running) { CD.remain = cdRemain(); CD.running = false; }
  else { CD.end = Date.now() + CD.remain; CD.running = true; }
  syncEngineButtons();
}
function cdFinish() {
  CD.running = false; CD.finished = true; CD.remain = 0;
  fc.classList.add("alert"); alertBadge.hidden = false;
  syncEngineButtons(); renderAll();
}
function cdCancel() {
  CD.running = false; CD.finished = false; CD.remain = CD.total;
  fc.classList.remove("alert"); alertBadge.hidden = true;
  syncEngineButtons(); renderAll();
}
function syncEngineButtons() {
  swStartBtn.textContent = SW.running ? "暂停" : (SW.base ? "继续" : "启动");
  appSwBtn.textContent   = SW.running ? "暂停" : (SW.base ? "继续" : "启动");
  cdStartBtn.textContent = CD.finished ? "重新开始" : CD.running ? "暂停" : (CD.remain < CD.total ? "继续" : "开始");
  appCdBtn.textContent   = CD.running ? "暂停倒计时" : "开始倒计时";
}
alertBadge.addEventListener("click", () => { fc.classList.remove("alert"); alertBadge.hidden = true; });

/* ───────── 控制面板绑定 ───────── */
$("#modeSeg").addEventListener("click", e => {
  const b = e.target.closest("button[data-mode]"); if (!b) return;
  $$("#modeSeg button").forEach(x => x.classList.toggle("active", x === b));
  S.mode = b.dataset.mode;
  $("#modePill").textContent = b.textContent;
  $("#exStopwatch").hidden = S.mode !== "stopwatch";
  $("#exCountdown").hidden = S.mode !== "countdown";
  renderFloatClock();
});
swStartBtn.addEventListener("click", swToggle);
$("#swReset").addEventListener("click", swReset);
$("#swLap").addEventListener("click", swLap);
cdStartBtn.addEventListener("click", cdToggle);
$("#cdReset").addEventListener("click", () => cdSetMinutes(CD.total / 60_000));
$("#cdPresets").addEventListener("click", e => {
  const c = e.target.closest(".chip[data-min]"); if (c) cdSetMinutes(+c.dataset.min);
});

$("#swatches").addEventListener("click", e => {
  const b = e.target.closest("button[data-c]"); if (!b) return;
  $$("#swatches button").forEach(x => x.classList.toggle("active", x === b));
  S.color = b.dataset.c; renderFloatClock();
});
$("#bgSeg").addEventListener("click", e => {
  const b = e.target.closest("button[data-bg]"); if (!b) return;
  $$("#bgSeg button").forEach(x => x.classList.toggle("active", x === b));
  S.bg = b.dataset.bg; renderFloatClock();
});
$("#sizeRange").addEventListener("input", e => {
  S.size = e.target.value / 100; $("#sizeOut").textContent = fmtScale(+e.target.value); updateRangeFill(e.target); renderFloatClock(); clampFullyVisible();
});
$("#opaRange").addEventListener("input", e => {
  S.opacity = e.target.value / 100; $("#opaOut").textContent = e.target.value + "%"; updateRangeFill(e.target); renderFloatClock();
});
$("#elemChips").addEventListener("click", e => {
  const c = e.target.closest(".chip[data-e]"); if (!c) return;
  c.classList.toggle("active");
  S.elems[c.dataset.e] = c.classList.contains("active");
  renderFloatClock(); clampFullyVisible();
});
$("#snapChip").addEventListener("click", e => { e.target.classList.toggle("active"); S.snap = e.target.classList.contains("active"); });
$("#msdChips").addEventListener("click", e => {
  const c = e.target.closest(".chip[data-msd]"); if (!c) return;
  S.msDigits = +c.dataset.msd;
  $$("#msdChips .chip").forEach(x => x.classList.toggle("active", x === c));
  renderFloatClock();
});

/* ───────── Tab / 平台切换 ───────── */
$("#tabs").addEventListener("click", e => {
  const b = e.target.closest("button[data-tab]"); if (!b) return;
  $$("#tabs button").forEach(x => x.classList.toggle("active", x === b));
  $$(".tab-panel").forEach(p => p.classList.toggle("active", p.id === "tab-" + b.dataset.tab));
  window.scrollTo({ top: 0, behavior: "smooth" });
});
$("#platSwitch").addEventListener("click", e => {
  const b = e.target.closest("button[data-plat]"); if (!b) return;
  $$("#platSwitch button").forEach(x => x.classList.toggle("active", x === b));
  document.body.dataset.platform = b.dataset.plat;
});

/* ───────── App 界面（Tab3）联动 ───────── */
$("#appTabs").addEventListener("click", e => {
  const b = e.target.closest("button[data-view]"); if (!b) return;
  $$("#appTabs button").forEach(x => x.classList.toggle("active", x === b));
  $$("#appUI .a-view").forEach(v => v.classList.toggle("active", v.dataset.view === b.dataset.view));
});
$("#tab-appui").addEventListener("click", e => {
  const el = e.target.closest("[data-act], .chip[data-min]"); if (!el) return;
  if (el.dataset.min) { cdSetMinutes(+el.dataset.min); return; }
  const act = el.dataset.act;
  if (act === "sw-toggle") swToggle();
  else if (act === "sw-reset") swReset();
  else if (act === "cd-start") { if (!CD.running && !CD.finished && CD.remain === CD.total && S.mode !== "countdown") { setMode("countdown"); } cdToggle(); }
  else if (act === "cd-cancel") cdCancel();
  else if (act === "fc-show") {
    S.fcHidden = !S.fcHidden;
    fc.style.visibility = S.fcHidden ? "hidden" : "visible";
    el.textContent = S.fcHidden ? "显示悬浮窗" : "隐藏悬浮窗";
  }
});
function setMode(m) { $(`#modeSeg button[data-mode="${m}"]`).click(); }

/* ───────── 样式预设库（Tab2） ───────── */
const PRESETS = [
  { name: "清爽时钟", desc: "默认样式 · 时:分:秒 + 日期电量", tags: ["胶囊", "秒", "日期", "电量"],
    mode: "clock", color: "#22d3ee", bg: "capsule", size: 1, opa: 1, msd: 0, elems: { sec: true, date: true, week: true, batt: true }, ticker: "clock" },
  { name: "极简白", desc: "无背景描边 · 不遮挡游戏画面", tags: ["描边", "秒", "低遮挡"],
    mode: "clock", color: "#f4f7ff", bg: "outline", size: 1.15, opa: .95, msd: 0, elems: { sec: true, date: false, week: false, batt: false }, ticker: "clock" },
  { name: "考试倒计时", desc: "考卷倒计时 · 剩余时间醒目", tags: ["方卡", "倒计时", "25分钟"],
    mode: "countdown", color: "#ffb454", bg: "card", size: 1.1, opa: 1, msd: 0, elems: { sec: true, date: true, week: false, batt: false }, ticker: "cd", min: 25 },
  { name: "抢购毫秒", desc: "毫秒级对时 · 秒杀卡点", tags: ["胶囊", "毫秒·3位", "高对比"],
    mode: "clock", color: "#ff6b6b", bg: "capsule", size: 1.05, opa: 1, msd: 3, elems: { sec: true, date: false, week: false, batt: false }, ticker: "clock" },
  { name: "运动秒表", desc: "正计时 · 计次状态常显", tags: ["方卡", "秒表", "百分秒"],
    mode: "stopwatch", color: "#34d399", bg: "card", size: 1.1, opa: 1, msd: 2, elems: { sec: true, date: false, week: false, batt: false }, ticker: "sw" },
  { name: "夜间床头", desc: "低亮度紫色 · 夜间不刺眼", tags: ["胶囊", "80%透明度"],
    mode: "clock", color: "#a78bfa", bg: "capsule", size: 1.3, opa: .8, msd: 0, elems: { sec: true, date: true, week: false, batt: false }, ticker: "clock" },
];

const styleGrid = $("#styleGrid");
PRESETS.forEach((p, i) => {
  styleGrid.insertAdjacentHTML("beforeend", `
    <div class="preset-card">
      <div class="preset-preview">
        <span class="pv fc-${p.bg}" style="--fc:${p.color};--fs:${p.size}">
          <span class="fc-main"><span data-pv-t></span><span class="fc-sec" data-pv-s></span><span class="fc-ms" data-pv-m></span></span>
          <span class="fc-sub" data-pv-sub></span>
        </span>
      </div>
      <div class="preset-meta">
        <div><b>${p.name}</b><span>${p.desc}</span></div>
        <button class="btn primary sm" data-apply="${i}">应用</button>
      </div>
      <div class="preset-tags">${p.tags.map(t => `<i>${t}</i>`).join("")}</div>
    </div>`);
  const pv = styleGrid.lastElementChild;
  pv._preset = p;
  p._els = { t: $("[data-pv-t]", pv), s: $("[data-pv-s]", pv), m: $("[data-pv-m]", pv), sub: $("[data-pv-sub]", pv) };
});

function renderPresets() {
  const elapsed = (Date.now() - BOOT) / 1000;
  PRESETS.forEach(p => {
    const e = p._els; if (!e.t) return;
    if (p.ticker === "clock") {
      e.t.textContent = nowStr(); e.s.hidden = !p.elems.sec; e.s.textContent = ":" + secStr();
      e.m.hidden = !(p.msd > 0);
      if (p.msd > 0) e.m.textContent = "." + pad(Date.now() % 1000, 3).slice(0, p.msd);
    } else if (p.ticker === "cd") {
      const rem = (p.min * 60) - (elapsed % (p.min * 60));
      e.t.textContent = fmtCD(rem * 1000); e.s.hidden = true; e.m.hidden = true;
    } else {
      const ms = elapsed * 1000;
      e.t.textContent = fmtSW(ms, false); e.s.hidden = true;
      e.m.hidden = false; e.m.textContent = "." + pad(ms % 1000, 3).slice(0, Math.max(1, p.msd || 1));
    }
    const bits = [];
    if (p.elems.date) bits.push(dateLine());
    if (p.elems.week) bits.push(weekStr());
    if (p.elems.batt) bits.push(BATT + "%");
    e.sub.hidden = !bits.length; e.sub.textContent = bits.join(" · ");
    // App 内迷你样式格子同步走字
    if (p._elsApp) { p._elsApp.t.textContent = nowStr(); p._elsApp.s.textContent = ":" + secStr(); }
  });
}

function applyPreset(p) {
  S.color = p.color; S.bg = p.bg; S.size = p.size; S.opacity = p.opa;
  S.msDigits = p.msd || 0;
  Object.assign(S.elems, p.elems);
  syncControls();
  setMode(p.mode);
  if (p.mode === "countdown") cdSetMinutes(p.min || 25);
  renderFloatClock(); clampFullyVisible();
  $('[data-tab="demo"]').click();
}
styleGrid.addEventListener("click", e => {
  const b = e.target.closest("[data-apply]"); if (b) applyPreset(PRESETS[+b.dataset.apply]);
});

/* App 内迷你样式格子（复用预设，点击即应用） */
const appGrid = $("#appStyleGrid");
PRESETS.forEach((p, i) => {
  appGrid.insertAdjacentHTML("beforeend",
    `<div class="msl"><span class="pv fc-${p.bg}" style="--fc:${p.color};--fs:.75">
      <span class="fc-main"><span data-pv-t></span><span class="fc-sec" data-pv-s></span></span>
    </span></div>`);
  const el = appGrid.lastElementChild;
  el.addEventListener("click", () => applyPreset(p));
  p._elsApp = { t: $("[data-pv-t]", el), s: $("[data-pv-s]", el) };
});

function syncControls() {
  $$("#swatches button").forEach(b => b.classList.toggle("active", b.dataset.c === S.color));
  $$("#bgSeg button").forEach(b => b.classList.toggle("active", b.dataset.bg === S.bg));
  $("#sizeRange").value = Math.round(S.size * 100); $("#sizeOut").textContent = fmtScale(Math.round(S.size * 100));
  $("#opaRange").value  = Math.round(S.opacity * 100); $("#opaOut").textContent = Math.round(S.opacity * 100) + "%";
  updateRangeFill($("#sizeRange")); updateRangeFill($("#opaRange"));
  $$("#elemChips .chip").forEach(c => c.classList.toggle("active", !!S.elems[c.dataset.e]));
  $$("#msdChips .chip").forEach(c => c.classList.toggle("active", +c.dataset.msd === S.msDigits));
}

/* 进度条式滑杆填充 */
function updateRangeFill(el) {
  const min = +el.min || 0, max = +el.max || 100;
  const p = ((+el.value - min) / (max - min)) * 100;
  el.style.background =
    `linear-gradient(90deg, var(--acc1) 0%, var(--acc2) ${p}%, rgba(255,255,255,.1) ${p}%)`;
}
const fmtScale = v => (v / 100).toFixed(2).replace(/0+$/, "").replace(/\.$/, "") + "×";

/* ───────── 权限引导演示（Tab4） ───────── */
const ovTgl = $("#ovTgl");
ovTgl.addEventListener("click", () => {
  ovTgl.classList.toggle("on");
  ovTgl.setAttribute("aria-checked", ovTgl.classList.contains("on"));
});
$("#hmAllow").addEventListener("click", () => { $("#hmDialog").hidden = true; $("#hmOk").hidden = false; });
$("#hmDeny").addEventListener("click", () => {
  const d = $("#hmDialog");
  d.animate([{ transform: "translateX(0)" }, { transform: "translateX(-8px)" }, { transform: "translateX(8px)" }, { transform: "translateX(0)" }], { duration: 260 });
});

/* ───────── 主刷新循环 ───────── */
const BOOT = Date.now();
let lastSec = -1;

function renderClocks() {
  $$("[data-sbtime]").forEach(el => el.textContent = nowStr());
  $$('[data-live="clock"]').forEach(el => el.textContent = nowStr());
  $$('[data-live="clock-s"]').forEach(el => el.textContent = ":" + secStr());
  $$('[data-live="clock-s2"]').forEach(el => el.textContent = secStr());
  $$('[data-live="date-line"]').forEach(el => el.textContent = dateWeek());
}

function renderAll() {
  const swv = fmtSW(swElapsed()), cdv = fmtCD(cdRemain()),
        bar = CD.total ? Math.max(0, Math.min(100, cdRemain() / CD.total * 100)) : 0;
  $$('[data-live="sw"]').forEach(el => el.textContent = swv);
  $$('[data-live="cd"]').forEach(el => el.textContent = CD.finished ? "00:00" : cdv);
  $$("[data-live=cd-bar]").forEach(el => el.style.width = bar + "%");
  $("#cdBar").style.width = bar + "%";
  renderFloatClock();
}

setInterval(() => {
  const s = new Date().getSeconds();
  if (s !== lastSec) { lastSec = s; renderClocks(); }
  if (CD.running && cdRemain() <= 0) cdFinish();
  renderAll();
  renderPresets();   // 毫秒三位数需要高频刷新（20fps）
}, 50);

/* 初始化 */
renderClocks(); syncEngineButtons(); renderAll();
