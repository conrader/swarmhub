/* Local drawing state only. No credentials, persistence, API calls or analytics. */
(() => {
  const screens = SCREENS.sort((a,b)=>a.id.localeCompare(b.id));
  const bySlug = new Map(screens.map(screen=>[screen.slug,screen]));
  const explorer = document.getElementById('explorer');
  const mount = document.getElementById('phone-mount');
  const board = document.getElementById('board');
  const index = document.getElementById('screen-index');
  const notes = document.getElementById('screen-notes');
  const feedback = document.getElementById('feedback');
  const core = ['chats','chat','overview','routines','approvals','settings'];
  const work = ['group','thread','media','computer','models','import-preview'];
  let current = 'chats';
  let mode = 'explore';
  let feedbackTimer;
  function notify(text) {
    feedback.textContent = text;
    feedback.hidden = false;
    clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(()=>feedback.hidden=true,4000);
  }
  function setTheme(theme) {
    const effective = theme==='system' ? (matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light') : theme;
    document.body.dataset.theme = effective;
    const control = document.getElementById('theme-toggle');
    control.textContent = effective==='dark'?'Light':'Dark';
    control.setAttribute('aria-label',`Switch to ${effective==='dark'?'light':'dark'} appearance`);
    document.querySelectorAll('[data-product-theme]').forEach(button=>button.setAttribute('aria-pressed',button.dataset.productTheme===theme));
  }
  const groupOrder = ['Setup','Conversations','Agents','Work','Review','Settings','Import'];
  index.innerHTML = groupOrder.map(group=>`<div class="index-group">${group}</div>${screens.filter(screen=>screen.group===group).map(screen=>`<button data-go="${screen.slug}"><span>${screen.id}</span>${screen.name}</button>`).join('')}`).join('');
  function render() {
    explorer.hidden = mode!=='explore';
    board.hidden = mode==='explore';
    document.querySelectorAll('[data-mode]').forEach(button=>button.setAttribute('aria-pressed',button.dataset.mode===mode));
    if (mode==='explore') {
      const screen = bySlug.get(current);
      mount.innerHTML = UI.shell(screen);
      notes.innerHTML = `<p class="eyebrow">${screen.id} / ${screen.group.toUpperCase()}</p><h2>${screen.name}</h2><p>${screen.notes}</p><div class="note-label">Backend boundary</div><p>${screen.dependency}</p><div class="note-label">Continue to</div><div class="route-list">${screen.links.map(slug=>`<button data-go="${slug}">${bySlug.get(slug).name} →</button>`).join('')}</div>`;
      index.querySelectorAll('[data-go]').forEach(button=>button.dataset.go===current?button.setAttribute('aria-current','page'):button.removeAttribute('aria-current'));
    } else {
      const selected = mode==='all'?screens:(mode==='core'?core:work).map(slug=>bySlug.get(slug));
      board.innerHTML = selected.map(screen=>`<article class="board-item"><div class="board-label"><button data-go="${screen.slug}">${screen.name}</button><span>${screen.id}</span></div>${UI.shell(screen)}</article>`).join('');
    }
  }
  function routeFromHash() {
    feedback.hidden=true;
    clearTimeout(feedbackTimer);
    const hash = location.hash.slice(1);
    if (['board-core','board-work','board-all'].includes(hash)) { mode=hash.split('-')[1]; }
    else { mode='explore'; current=bySlug.has(hash)?hash:'chats'; }
    render();
  }
  function go(slug) { location.hash = bySlug.has(slug)?slug:'chats'; }
  function sheet(phone,title,content) {
    phone.querySelector('.overlay')?.remove();
    const overlay = document.createElement('div');
    overlay.className = 'overlay';
    overlay.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="${title}"><div class="title-row"><strong>${title}</strong>${UI.ib('close','Close menu',null)}</div>${content}</div>`;
    phone.append(overlay);
    overlay.querySelector('button')?.focus();
  }
  document.addEventListener('click',event=>{
    const control = event.target.closest('button');
    if (!control || control.disabled) return;
    if (control.id==='theme-toggle') { setTheme(document.body.dataset.theme==='light'?'dark':'light'); return; }
    if (control.dataset.mode) { const next=control.dataset.mode; location.hash=next==='explore'?current:`board-${next}`; return; }
    if (control.dataset.go) {
      if (control.closest('[data-screen="chats"]') && control.getAttribute('aria-label')==='Add') {
        sheet(control.closest('.phone'),'New conversation',UI.row('Create an agent','Local identity and app instructions','plus','editor')+UI.row('Ask your manager','Create or change a server agent','people','management')+UI.row('Create a group','Choose agents for a shared outcome','people','members')+UI.row('Import an agent','Use a template or bundle','download','import'));
      } else go(control.dataset.go);
      return;
    }
    if (control.dataset.productTheme) { setTheme(control.dataset.productTheme); return; }
    if (control.hasAttribute('data-toggle')) {
      const selected=control.getAttribute('aria-pressed')!=='true';
      control.setAttribute('aria-pressed',selected);
      control.querySelector('.switch').classList.toggle('on',selected);
      return;
    }
    if (control.hasAttribute('data-select-agent')) {
      const selected=control.getAttribute('aria-pressed')!=='true';
      control.setAttribute('aria-pressed',selected);
      const checkbox=control.querySelector('.checkbox');
      checkbox.classList.toggle('selected',selected);
      checkbox.innerHTML=selected?UI.icon('check'):'';
      const phone=control.closest('.phone');
      const count=phone.querySelectorAll('[data-select-agent][aria-pressed="true"]').length;
      const add=phone.querySelector('.bottom-action button');
      add.textContent=`Add ${count} sample agent${count===1?'':'s'}`;
      add.disabled=count===0;
      return;
    }
    if (control.hasAttribute('data-segment') || control.hasAttribute('data-swatch')) {
      control.parentElement.querySelectorAll('button').forEach(button=>button.setAttribute('aria-pressed',button===control));
      const phone=control.closest('.phone');
      if(phone.dataset.screen==='approvals'&&control.textContent==='History') go('audit');
      if(phone.dataset.screen==='media') {
        const selected=control.textContent;
        phone.querySelectorAll('.media-grid button').forEach(item=>item.hidden=selected==='Links'||(selected==='Images'&&!!item.querySelector('.document'))||(selected==='Files'&&!item.querySelector('.document')));
      }
      return;
    }
    const action=control.dataset.action;
    if(!action) return;
    if(action==='Close menu') { control.closest('.overlay')?.remove(); return; }
    if(action==='model-catalog') { control.closest('.phone').querySelector('[data-model-catalog]').hidden=false; return; }
    if(action==='pause-routine') { control.textContent=control.textContent==='Pause'?'Resume':'Pause'; notify('Sample routine state changed locally.'); return; }
    if(action==='approve'||action==='decline') {
      const phone=control.closest('.phone');
      phone.querySelectorAll('.bottom-action button').forEach(button=>button.disabled=true);
      control.textContent=action==='approve'?'Approved · sample':'Declined · sample';
      notify('Sample decision only. No agent or server received an approval.');
      return;
    }
    if(action==='stop') { control.textContent='Stop requested'; notify('Preview only: a real stop must be acknowledged by the server.'); return; }
    if(action==='Sample avatar changed') { const mark=control.closest('.identity').querySelector('.mark'); mark.classList.toggle('orange'); return; }
    notify(`${action}. Preview only.`);
  });
  document.addEventListener('submit',event=>{
    const form=event.target.closest('[data-composer]');
    if(!form) return;
    event.preventDefault();
    const input=form.querySelector('input');
    if(!input.value.trim()) { notify('Enter a sample message first.'); return; }
    const phone=form.closest('.phone');
    const list=phone.querySelector('.message-list');
    list.insertAdjacentHTML('beforeend',UI.message(`${UI.esc(input.value)}<div class="stamp">Preview only · not sent</div>`,'user'));
    input.value='';
    list.parentElement.scrollTop=list.parentElement.scrollHeight;
  });
  document.addEventListener('input',event=>{
    const input=event.target;
    if(input.hasAttribute('data-archive-search')) {
      input.closest('.phone').querySelectorAll('[data-archive-entry]').forEach(entry=>entry.hidden=!entry.textContent.toLowerCase().includes(input.value.toLowerCase()));
    } else if(input.hasAttribute('data-search')) {
      const phone=input.closest('.phone');
      phone.querySelectorAll('.row').forEach(row=>row.hidden=!row.textContent.toLowerCase().includes(input.value.toLowerCase()));
      if(phone.dataset.screen==='chats' && input.value.trim()) {
        let link=phone.querySelector('.search-more');
        if(!link) { link=document.createElement('button'); link.className='inline-link search-more'; link.dataset.go='search'; link.textContent='Search cached conversations, files and routines →'; input.closest('.search').after(link); }
      }
    }
  });
  document.addEventListener('keydown',event=>{if(event.key==='Escape') document.querySelector('.overlay')?.remove();});
  window.addEventListener('hashchange',routeFromHash);
  setTheme('dark');
  routeFromHash();
  window.SwarmHubDrawings = {screens,go,setTheme};
})();
