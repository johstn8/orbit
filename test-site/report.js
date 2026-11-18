// Reports page events to the local test server.
window.report = (type, data = {}) =>
  fetch("/event", { method: "POST", body: JSON.stringify({ type, page: location.pathname + location.search, ...data }) }).catch(() => {});
report("page_loaded", { title: document.title });
