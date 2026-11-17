let polarity = "";
let department = "";

async function loadJSON(path) {
  const res = await fetch(path, { cache: "no-store" });
  if (!res.ok) throw new Error(`${path} → ${res.status}`);
  return res.json();
}

function fmtTime(iso) {
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function renderCards(rows) {
  const root = document.getElementById("list");
  root.replaceChildren();
  if (!rows.length) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = "No feedback yet. Staff start with /feedback in a DM with the bot.";
    root.appendChild(p);
    return;
  }
  rows.forEach((row, i) => {
    const card = document.createElement("article");
    card.className = `card ${row.polarity}`;
    card.style.animationDelay = `${Math.min(i, 8) * 40}ms`;

    const meta = document.createElement("div");
    meta.className = "card-meta";

    const bits = [
      [`#${row.id}`, "strong"],
      [row.polarity, "pol"],
      [row.department, "strong"],
      [row.anonymous ? "anonymous" : row.telegram_name || "named", ""],
      [row.board_notify ? "board notified" : "board skipped", ""],
      [fmtTime(row.created_at), ""],
    ];
    for (const [text, cls] of bits) {
      const chip = document.createElement("span");
      chip.className = cls ? `chip ${cls}` : "chip";
      chip.textContent = text;
      meta.appendChild(chip);
    }

    const body = document.createElement("p");
    body.className = "card-body";
    body.textContent = row.body;

    card.append(meta, body);
    root.appendChild(card);
  });
}

async function refresh() {
  const statusEl = document.getElementById("status");
  try {
    const qs = new URLSearchParams();
    if (polarity) qs.set("polarity", polarity);
    if (department) qs.set("department", department);
    const [status, data] = await Promise.all([
      loadJSON("/api/v1/status"),
      loadJSON(`/api/v1/submissions?${qs}`),
    ]);
    statusEl.textContent = `Feedback ${status.version} · ${status.counts.total} notes`;
    document.getElementById("count-total").textContent = String(status.counts.total);
    document.getElementById("count-pos").textContent = String(status.counts.positive);
    document.getElementById("count-neg").textContent = String(status.counts.negative);

    const select = document.getElementById("dept");
    if (select.options.length <= 1) {
      select.replaceChildren();
      const all = document.createElement("option");
      all.value = "";
      all.textContent = "All departments";
      select.appendChild(all);
      for (const d of status.departments || []) {
        const opt = document.createElement("option");
        opt.value = d;
        opt.textContent = d;
        select.appendChild(opt);
      }
      select.value = department;
    }
    renderCards(data.submissions || []);
  } catch (err) {
    statusEl.textContent = `Could not load Feedback: ${err.message}`;
  }
}

document.querySelectorAll(".seg-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".seg-btn").forEach((b) => b.classList.remove("is-on"));
    btn.classList.add("is-on");
    polarity = btn.dataset.polarity || "";
    refresh();
  });
});

document.getElementById("dept").addEventListener("change", (e) => {
  department = e.target.value;
  refresh();
});

refresh();
setInterval(refresh, 12000);
