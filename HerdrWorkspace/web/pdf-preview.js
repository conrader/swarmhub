import { AnnotationMode, GlobalWorkerOptions, PDFWorker, getDocument } from "/vendor/pdfjs/pdf.min.mjs";

const assets = new URL("/vendor/pdfjs/", import.meta.url);
const asset = (name) => new URL(name, assets).href;
GlobalWorkerOptions.rendererSrc = asset("pdf.renderer.min.mjs");

function element(tag, className, label) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (label) node.textContent = label;
  return node;
}

export async function openPdf(bytes, mount, signal, onError, onReady) {
  const port = new Worker(asset("pdf.worker.min.mjs"), { type: "module" });
  const worker = PDFWorker.create({ port });
  const task = getDocument({
    data: bytes,
    worker,
    cMapUrl: asset("cmaps/"),
    standardFontDataUrl: asset("standard_fonts/"),
    iccUrl: asset("iccs/"),
    wasmUrl: asset("wasm/"),
    maxImageSize: 20_000_000,
    canvasMaxAreaInBytes: 48_000_000,
    stopAtErrors: true,
  });
  let render;
  let textReader;
  let timer;
  let page;
  let current = 0;
  let busy = true;
  const startTimer = () => {
    clearTimeout(timer);
    timer = setTimeout(onError, 20000);
  };
  const failWorker = () => onError();
  const cancelText = () => {
    if (textReader) void textReader.cancel().catch(() => {});
    textReader = null;
  };
  const release = () => {
    clearTimeout(timer);
    render?.cancel();
    cancelText();
    port.removeEventListener("error", failWorker);
    const terminate = () => { worker.destroy(); port.terminate(); };
    const hardStop = setTimeout(terminate, 1000);
    void task.destroy().catch(() => {}).finally(() => {
      clearTimeout(hardStop);
      if (!worker.destroyed) terminate();
    });
  };
  signal.addEventListener("abort", release, { once: true });
  port.addEventListener("error", failWorker);
  if (signal.aborted) return release();
  startTimer();
  const pdf = await task.promise;
  if (signal.aborted) return;
  if (!pdf.numPages) throw new Error("PDF has no pages.");

  const toolbar = element("div", "pdf-toolbar");
  const previous = element("button", "", "Previous");
  const next = element("button", "", "Next");
  previous.type = next.type = "button";
  previous.setAttribute("aria-label", "Previous PDF page");
  next.setAttribute("aria-label", "Next PDF page");
  const position = element("span");
  position.setAttribute("role", "status");
  toolbar.append(previous, position, next);
  const viewport = element("div", "pdf-page");
  viewport.setAttribute("aria-label", "PDF page");
  viewport.tabIndex = 0;
  const text = element("details", "pdf-text");
  const transcript = element("pre");
  text.append(element("summary", "", "Page text"), transcript);
  mount.replaceChildren(toolbar, viewport, text);

  text.addEventListener("toggle", async () => {
    if (!text.open || !page || busy || textReader || transcript.textContent || signal.aborted) return;
    const reader = page.streamTextContent().getReader();
    textReader = reader;
    transcript.textContent = "Extracting page text…";
    let content = "";
    const limit = 32000;
    try {
      while (content.length < limit) {
        const { done, value } = await reader.read();
        if (textReader !== reader || signal.aborted || done) break;
        for (const item of value.items) {
          if ("str" in item) content += item.str.slice(0, limit - content.length) + (item.hasEOL ? "\n" : " ");
          if (content.length >= limit) break;
        }
      }
      if (textReader === reader) {
        transcript.textContent = content.length >= limit ? content.trimEnd() + "\n…" : content.trim() || "No selectable text on this page.";
      }
    } catch {
      if (textReader === reader) transcript.textContent = "Page text is unavailable.";
    } finally {
      if (textReader === reader) textReader = null;
      void reader.cancel().catch(() => {});
    }
  });

  const draw = async (number) => {
    busy = true;
    viewport.setAttribute("aria-busy", "true");
    // Keep the navigation controls focused during rendering; guard clicks below.
    previous.setAttribute("aria-disabled", "true");
    next.setAttribute("aria-disabled", "true");
    cancelText();
    text.open = false;
    transcript.textContent = "";
    startTimer();
    try {
      const nextPage = await pdf.getPage(number);
      if (signal.aborted) return;
      const base = nextPage.getViewport({ scale: 1 });
      if (!Number.isFinite(base.width) || !Number.isFinite(base.height) || base.width <= 0 || base.height <= 0) {
        throw new Error("Invalid PDF page size.");
      }
      const scale = Math.min(2.5, 1400 / base.width, 2000 / base.height);
      const view = nextPage.getViewport({ scale });
      const canvas = element("canvas");
      canvas.width = Math.max(1, Math.floor(view.width));
      canvas.height = Math.max(1, Math.floor(view.height));
      canvas.style.maxWidth = `${canvas.width}px`;
      canvas.setAttribute("role", "img");
      canvas.setAttribute("aria-label", `PDF page ${number} of ${pdf.numPages}`);
      render = nextPage.render({ canvas, viewport: view, annotationMode: AnnotationMode.DISABLE });
      await render.promise;
      if (signal.aborted) return;
      viewport.replaceChildren(canvas);
      viewport.scrollTop = 0;
      page?.cleanup();
      page = nextPage;
      current = number;
      position.textContent = `Page ${current} of ${pdf.numPages}`;
      previous.setAttribute("aria-disabled", String(current === 1));
      next.setAttribute("aria-disabled", String(current === pdf.numPages));
      mount.hidden = false;
      onReady();
    } catch (error) {
      onError(error);
    } finally {
      clearTimeout(timer);
      render = null;
      busy = false;
      viewport.setAttribute("aria-busy", "false");
    }
  };
  previous.addEventListener("click", () => { if (!busy && current > 1) void draw(current - 1); });
  next.addEventListener("click", () => { if (!busy && current < pdf.numPages) void draw(current + 1); });
  await draw(1);
}
