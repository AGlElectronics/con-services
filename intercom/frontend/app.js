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

function renderList(el, rows, emptyLabel, pick) {
  el.replaceChildren();
  if (!rows.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = emptyLabel;
    el.appendChild(li);
    return;
  }
  for (const row of rows) {
    const li = document.createElement("li");
    const meta = document.createElement("span");
    meta.className = "meta";
    meta.textContent = pick.meta(row);
    const body = document.createElement("p");
    body.className = "body";
    body.textContent = pick.body(row);
    li.append(meta, body);
    el.appendChild(li);
  }
}

async function refresh() {
  const statusEl = document.getElementById("status");
  try {
    const [status, relays, ideas] = await Promise.all([
      loadJSON("/api/v1/status"),
      loadJSON("/api/v1/board-relays"),
      loadJSON("/api/v1/ideas"),
    ]);
    const tg = status.telegram ? "bot on" : "bot token missing";
    const board = status.board_chat_id
      ? `board chat ${status.board_chat_id}`
      : "board chat not set";
    statusEl.textContent = `Intercom ${status.version} · ${tg} · ${board}`;

    renderList(document.getElementById("relays"), relays.relays || [], "No /board questions yet.", {
      meta: (r) => `#${r.id} · ${r.source_chat_title || r.source_chat_id} · ${r.source_user_name} · ${fmtTime(r.created_at)}`,
      body: (r) => r.question,
    });
    renderList(document.getElementById("ideas"), ideas.ideas || [], "No /idea captures yet.", {
      meta: (r) => {
        const task = r.task_key ? ` · ${r.task_key}` : "";
        return `#${r.id}${task} · ${r.source_chat_title || r.source_chat_id} · ${r.source_user_name} · ${fmtTime(r.created_at)}`;
      },
      body: (r) => r.body,
    });
  } catch (err) {
    statusEl.textContent = `Could not load Intercom: ${err.message}`;
  }
}

refresh();
setInterval(refresh, 15000);
