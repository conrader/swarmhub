(() => {
  "use strict";

  const svgNamespace = "http://www.w3.org/2000/svg";
  const compact = new Intl.NumberFormat(undefined,{maximumSignificantDigits:5});
  const scientific = new Intl.NumberFormat(undefined,{notation:"scientific",maximumSignificantDigits:4});
  const tick = (value) => (value !== 0 && (Math.abs(value) < 0.001 || Math.abs(value) >= 1e8) ? scientific : compact).format(value);

  function text(tag, content, className) {
    const element = document.createElement(tag);
    element.textContent = content;
    if (className) element.className = className;
    return element;
  }

  function svg(tag, attributes, content) {
    const node = document.createElementNS(svgNamespace,tag);
    for (const [key,value] of Object.entries(attributes)) node.setAttribute(key,value);
    if (content !== undefined) node.textContent = content;
    return node;
  }

  function readChart(source) {
    const record = (value) => value != null && typeof value === "object" && !Array.isArray(value);
    const keys = (value, names) => Object.keys(value).every((key) => names.includes(key));
    const label = (value,length) => typeof value === "string" && value.trim() && value.length <= length && !/\p{Cc}/u.test(value);
    if (source.length > 16384) return null;
    const chart = JSON.parse(source);
    if (!record(chart) || !keys(chart,["type","title","unit","points"]) || !["bar","line"].includes(chart.type)
      || !label(chart.title,120) || (chart.unit !== undefined && !label(chart.unit,32)) || !Array.isArray(chart.points)
      || chart.points.length < (chart.type === "line" ? 2 : 1) || chart.points.length > 48) return null;
    if (!chart.points.every((point) => record(point) && keys(point,["label","value"]) && label(point.label,100)
      && Number.isFinite(point.value) && Math.abs(point.value) <= 1e12)) return null;
    return chart;
  }

  function chartData(chart) {
    const details = document.createElement("details");
    details.className = "page-chart-data";
    const table = document.createElement("table");
    const header = table.createTHead().insertRow();
    for (const title of ["Label", chart.unit ? `Value (${chart.unit})` : "Value"]) {
      const column = text("th",title);
      column.scope = "col";
      header.append(column);
    }
    const body = table.createTBody();
    for (const {label,value} of chart.points) {
      const row = body.insertRow();
      const title = text("th",label);
      title.scope = "row";
      row.append(title,text("td",String(value)));
    }
    details.append(text("summary","Show chart data"),table);
    return details;
  }

  function drawBars(chart,low,high) {
    const list = document.createElement("ul");
    list.className = "page-chart-bars";
    const scale = (value) => high === low ? 0 : (value-low)/(high-low)*100;
    const zero = scale(0);
    for (const {label,value} of chart.points) {
      const row = document.createElement("li");
      const track = document.createElement("span");
      track.className = "page-chart-track";
      track.setAttribute("aria-hidden","true");
      track.style.setProperty("--chart-zero",`${zero}%`);
      const bar = document.createElement("span");
      bar.className = "page-chart-bar";
      const end = scale(value);
      bar.style.insetInlineStart = `${Math.min(zero,end)}%`;
      bar.style.width = `${Math.abs(end-zero)}%`;
      track.append(bar);
      row.append(text("span",label),text("strong",String(value)),track);
      list.append(row);
    }
    return list;
  }

  function drawLine(chart,low,high) {
    const graph = svg("svg",{viewBox:"0 0 520 216",role:"img",
      "aria-label":`Line chart with ${chart.points.length} data points. The full values are in Show chart data.`});
    const [left,top,right,bottom] = [77,20,500,176];
    const x = (index) => left + (right-left)*index/(chart.points.length-1);
    if (low === high) {
      const margin = Math.abs(low) * 0.1 || 1;
      low -= margin;
      high += margin;
    }
    const y = (value) => bottom - (bottom-top)*(value-low)/(high-low);
    const guides = (low < 0 && high > 0 ? [high,0,low] : [high,low]);
    for (const value of guides) {
      graph.append(svg("line",{x1:left,y1:y(value),x2:right,y2:y(value),class:"page-chart-grid"}),
        svg("text",{x:left-8,y:y(value)+5,"text-anchor":"end",class:"page-chart-tick"},tick(value)));
    }
    const coordinates = chart.points.map(({value},index) => [x(index),y(value)]);
    graph.append(svg("polyline",{points:coordinates.map((pair) => pair.join(",")).join(" "),class:"page-chart-line"}));
    for (const [cx,cy] of coordinates) graph.append(svg("circle",{cx,cy,r:3,class:"page-chart-point"}));
    const shorten = (label) => [...label].length > 18 ? [...label].slice(0,17).join("")+"…" : label;
    graph.append(svg("text",{x:left,y:203,class:"page-chart-tick"},shorten(chart.points[0].label)),
      svg("text",{x:right,y:203,"text-anchor":"end",class:"page-chart-tick"},shorten(chart.points.at(-1).label)));
    return graph;
  }

  window.renderPageCharts = (preview) => {
    for (const code of preview.querySelectorAll("pre > code.language-chart")) {
      let chart;
      try { chart = readChart(code.textContent); } catch { /* Invalid JSON is still readable as code. */ }
      const pre = code.parentElement;
      if (!chart) {
        pre.before(text("p","This chart couldn’t be rendered. Its source data is below.","subtle"));
        continue;
      }
      const figure = document.createElement("figure");
      figure.className = "page-chart";
      const caption = text("figcaption",chart.title);
      if (chart.unit) caption.append(text("small",chart.unit));
      const values = chart.points.map(({value}) => value);
      const low = Math.min(...values), high = Math.max(...values);
      const plot = chart.type === "bar" ? drawBars(chart,Math.min(0,low),Math.max(0,high)) : drawLine(chart,low,high);
      figure.append(caption,plot,chartData(chart));
      pre.replaceWith(figure);
    }
  };
})();
