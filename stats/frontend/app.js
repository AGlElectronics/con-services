const number = new Intl.NumberFormat();

function text(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setFigure(id, value, { hot = false } = {}) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = value;
  if (hot) el.dataset.hot = "true";
  else delete el.dataset.hot;
}

function metricRow(metric) {
  const item = document.createElement("div");
  item.className = "metric";
  const value = document.createElement("strong");
  value.textContent = number.format(metric.value);
  const label = document.createElement("span");
  label.textContent = `${metric.label} · ${metric.unit}`;
  item.append(value, label);
  return item;
}

function sourceRow(source, index) {
  const row = document.createElement("article");
  row.className = "source";
  row.style.animationDelay = `${0.05 + index * 0.05}s`;

  const meta = document.createElement("div");
  const title = document.createElement("h3");
  title.className = "source-name";
  title.textContent = source.name;
  const status = document.createElement("span");
  status.className = "source-status";
  status.dataset.state = source.status;
  status.textContent = source.status;
  meta.append(title, status);

  const body = document.createElement("div");
  body.className = "metric-list";

  if (source.error) {
    const error = document.createElement("p");
    error.className = "source-error";
    error.textContent = source.error;
    body.append(error);
  }

  if (!source.metrics || source.metrics.length === 0) {
    const waiting = document.createElement("p");
    waiting.className = "muted";
    waiting.textContent = "No aggregate values received yet.";
    body.append(waiting);
  } else {
    source.metrics.forEach((metric) => body.append(metricRow(metric)));
  }

  row.append(meta, body);
  return row;
}

async function refresh() {
  const pulse = document.getElementById("updated");
  const empty = document.getElementById("empty");
  const loadError = document.getElementById("load-error");
  const list = document.getElementById("source-list");

  try {
    const response = await fetch("/api/v1/dashboard", { headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error(`Dashboard API returned ${response.status}`);
    const dashboard = await response.json();

    setFigure("reporting", `${dashboard.summary.reporting_sources}/${dashboard.summary.configured_sources}`);
    setFigure("metrics", number.format(dashboard.summary.metrics));
    setFigure("count-total", number.format(dashboard.summary.count_total));
    setFigure("stale", number.format(dashboard.summary.stale_sources), {
      hot: dashboard.summary.stale_sources > 0,
    });

    const when = new Date(dashboard.generated_at).toLocaleTimeString();
    pulse.classList.remove("is-error");
    pulse.textContent = `Live · updated ${when}`;
    text(
      "poll-hint",
      dashboard.poll_interval_seconds
        ? `Pull every ${dashboard.poll_interval_seconds}s`
        : "",
    );

    list.replaceChildren(...dashboard.sources.map(sourceRow));
    empty.hidden = dashboard.sources.length !== 0;
    loadError.hidden = true;
  } catch (error) {
    pulse.classList.add("is-error");
    pulse.textContent = "Offline";
    empty.hidden = true;
    loadError.hidden = false;
    text("load-error-detail", error.message);
  }
}

refresh();
setInterval(refresh, 30_000);
