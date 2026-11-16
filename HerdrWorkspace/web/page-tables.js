(() => {
  "use strict";

  const searchable = (text) => text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
  const tableCollator = new Intl.Collator(undefined, {numeric:true,sensitivity:"base"});

  function enhanceTable(table,index,tableViews) {
    const headings = [...(table.tHead?.rows[0]?.cells || [])];
    const body = table.tBodies[0];
    if (!headings.length || !body?.rows.length) return;
    const names = headings.map((cell,i) => cell.textContent.trim() || `Column ${i+1}`);
    for (const heading of headings) heading.scope = "col";
    const key = JSON.stringify([index,names]);
    const view = tableViews.get(key) || {open:false, query:"", column:"", sort:"", direction:"asc"};
    tableViews.set(key,view);
    const rows = [...body.rows].map((row, original) => {
      const cells = [...row.cells].map((cell) => cell.textContent.trim());
      const search = cells.map(searchable);
      return {row, original, cells, search, all:search.join(" ")};
    });

    const disclosure = document.createElement("details");
    disclosure.className = "page-table-controls";
    disclosure.open = view.open;
    disclosure.addEventListener("toggle", () => { view.open = disclosure.open; });
    const summary = document.createElement("summary");
    summary.textContent = `Filter or sort table ${index+1}`;
    const fields = document.createElement("div");
    fields.className = "page-table-fields";
    function field(title,control) {
      const wrapper = document.createElement("div");
      const label = document.createElement("label");
      label.textContent = title;
      control.id = `page-table-${index}-${fields.children.length}`;
      label.htmlFor = control.id;
      wrapper.append(label,control);
      fields.append(wrapper);
      return control;
    }
    const query = field("Find rows",document.createElement("input"));
    query.type = "search";
    query.maxLength = 160;
    query.value = view.query;
    const column = field("Search in",document.createElement("select"));
    column.append(new Option("All columns",""), ...names.map((name,i) => new Option(name,i)));
    column.value = view.column;
    const sort = field("Sort by",document.createElement("select"));
    sort.append(new Option("Original order",""), ...names.map((name,i) => new Option(name,i)));
    sort.value = view.sort;
    const direction = field("Direction",document.createElement("select"));
    direction.append(new Option("Ascending","asc"),new Option("Descending","desc"));
    direction.value = view.direction;
    const reset = document.createElement("button");
    reset.type = "button";
    reset.textContent = "Reset table view";
    const count = document.createElement("p");
    count.className = "subtle";
    count.setAttribute("role","status");
    disclosure.append(summary,fields,reset,count);

    function filter() {
      view.query = query.value;
      view.column = column.value;
      const words = searchable(query.value.trim()).split(/\s+/u).filter(Boolean);
      let visible = 0;
      for (const entry of rows) {
        const text = view.column === "" ? entry.all : entry.search[Number(view.column)] || "";
        entry.row.hidden = !words.every((word) => text.includes(word));
        if (!entry.row.hidden) ++visible;
      }
      count.textContent = visible ? `${visible} of ${rows.length} ${rows.length === 1 ? "row" : "rows"} shown.` : "No rows match. Try another search or reset the view.";
    }

    function order() {
      view.sort = sort.value;
      view.direction = direction.value;
      direction.disabled = view.sort === "";
      const index = view.sort === "" ? -1 : Number(view.sort);
      const value = (entry) => entry.cells[index] || "";
      const number = (text) => /^[-+]?(?:\d+(?:\.\d+)?|\.\d+)$/u.test(text) && Number.isFinite(Number(text));
      const numeric = index >= 0 && rows.every((entry) => !value(entry) || number(value(entry)));
      const sign = direction.value === "desc" ? -1 : 1;
      const ordered = index < 0 ? rows : [...rows].sort((a,b) => {
        const av = value(a), bv = value(b);
        if (!av || !bv) return Number(!av) - Number(!bv) || a.original - b.original;
        return sign * (numeric ? Number(av)-Number(bv) : tableCollator.compare(av,bv)) || a.original - b.original;
      });
      for (const [i, heading] of headings.entries()) {
        if (i === index) heading.setAttribute("aria-sort", sign < 0 ? "descending" : "ascending");
        else heading.removeAttribute("aria-sort");
      }
      body.append(...ordered.map(({row}) => row));
    }

    query.addEventListener("input",filter);
    column.addEventListener("change",filter);
    sort.addEventListener("change",order);
    direction.addEventListener("change",order);
    reset.addEventListener("click", () => {
      query.value = column.value = sort.value = "";
      direction.value = "asc";
      order();
      filter();
      query.focus();
    });
    const frame = document.createElement("div");
    frame.className = "page-table-scroll";
    frame.tabIndex = 0;
    frame.setAttribute("role","region");
    frame.setAttribute("aria-label",`Table ${index+1}`);
    table.before(disclosure,frame);
    frame.append(table);
    order();
    filter();
  }

  window.renderPageTables = (root, views) => {
    const used = new Map();
    const state = { get:key => views.get(key), set:(key,view) => used.set(key,view) };
    [...root.querySelectorAll("table")].forEach((table,index) => enhanceTable(table,index,state));
    views.clear();
    for (const [key,view] of used) views.set(key,view);
  };
})();
