/* Original vector interface symbols and synthetic content. No external resources. */
window.SCREENS = [];
window.UI = (() => {
  const paths = {
    back:'<path d="m14 5-7 7 7 7"/>', chevron:'<path d="m9 5 7 7-7 7"/>',
    plus:'<path d="M12 5v14M5 12h14"/>', close:'<path d="m6 6 12 12M6 18 18 6"/>',
    search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
    chat:'<path d="M20 16V5H4v14l4-3z"/>', shield:'<path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6z"/><path d="m8 12 3 3 5-6"/>',
    gear:'<path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3h6l1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3z"/><circle cx="12" cy="12" r="3"/>',
    more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    attach:'<path d="m9 15 7-7a3 3 0 0 0-4-4L5 11a5 5 0 0 0 7 7l7-7"/>',
    send:'<path d="M12 19V5m-6 6 6-6 6 6"/>', mic:'<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M6 11v1a6 6 0 0 0 12 0v-1m-6 7v3m-3 0h6"/>',
    clock:'<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',
    image:'<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="8" cy="9" r="1.5"/><path d="m3 18 6-5 3 2 4-5 5 7"/>',
    file:'<path d="M5 3h9l5 5v13H5zM14 3v5h5M8 12h8M8 16h6"/>',
    computer:'<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M12 17v4m-5 0h10"/>',
    check:'<path d="m5 12 4 4 10-10"/>', person:'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
    people:'<circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2m1-15a3 3 0 0 1 0 6m2 3a5 5 0 0 1 3 5"/>',
    cpu:'<rect x="6" y="6" width="12" height="12" rx="3"/><path d="M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3"/>',
    bell:'<path d="M5 17h14l-2-3V9a5 5 0 0 0-10 0v5zm5 3h4"/>',
    link:'<path d="m10 7 2-2a5 5 0 0 1 7 7l-2 2m-3 3-2 2a5 5 0 0 1-7-7l2-2m2 5 6-6"/>',
    arrow:'<path d="M5 12h14m-6-6 6 6-6 6"/>', lock:'<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    play:'<path d="m8 4 12 8-12 8z"/>', pause:'<path d="M8 5v14M16 5v14"/>',
    copy:'<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M15 8V3H3v12h5"/>',
    share:'<path d="M12 15V3m-4 4 4-4 4 4M6 11H3v10h18V11h-3"/>',
    mail:'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
    wifi:'<path d="M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0m-9 4a5 5 0 0 1 6 0"/><circle cx="12" cy="20" r=".8"/>',
    signal:'<path d="M4 19v-3m5 3v-6m5 6V9m5 10V5"/>', battery:'<rect x="2" y="7" width="17" height="10" rx="2"/><path d="M22 10v4M5 10h11v4H5z"/>',
    sparkle:'<path d="m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3z"/>', chart:'<path d="M4 3v18h17M9 17V9m5 8V5m5 12v-5"/>',
    refresh:'<path d="M20 7v5h-5M4 17v-5h5M5 8a8 8 0 0 1 13-3l2 3M4 16l2 3a8 8 0 0 0 13-3"/>',
    keyboard:'<rect x="2" y="6" width="20" height="13" rx="3"/><path d="M6 10h1m3 0h1m3 0h1m3 0h1M6 14h1m3 0h1m3 0h1m3 0h1M8 17h8"/>',
    camera:'<path d="M3 7h4l2-3h6l2 3h4v14H3z"/><circle cx="12" cy="13" r="4"/>',
    download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
    globe:'<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c6 6 6 12 0 18-6-6-6-12 0-18"/>',
    heart:'<path d="M12 20 4 12a5 5 0 0 1 8-6 5 5 0 0 1 8 6z"/>'
  };
  const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.sparkle}</svg>`;
  const esc = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const mark = (color='blue',large=false) => `<span class="mark ${color} ${large?'large':''}" aria-hidden="true"><span class="head"></span></span>`;
  const groupMark = () => `<span class="group-mark" aria-hidden="true">${mark()}${mark('orange')}</span>`;
  const ib = (name,label,route,extra='') => `<button type="button" class="icon-button ${extra}" aria-label="${esc(label)}" ${route?`data-go="${route}"`:`data-action="${esc(label)}"`}>${icon(name)}</button>`;
  const button = (text,route,style='primary',action='') => `<button type="button" class="${style}" ${route?`data-go="${route}"`:`data-action="${esc(action||text)}"`}>${text}</button>`;
  const row = (name,description,symbol='chevron',route='',tail='') => `<button class="row" ${route?`data-go="${route}"`:`data-action="${esc(name)}"`}>${symbol==='none'?'':symbol.startsWith('mark:')?mark(symbol.split(':')[1]):icon(symbol)}<span class="row-text"><strong>${name}</strong>${description?`<small>${description}</small>`:''}</span>${tail||icon('chevron')}</button>`;
  const nav = (title,back='chats',subtitle='',color='',next='') => {
    const interactive=title==='Atlas'||title==='Launch team';
    const tag=interactive?'button':'div';
    return `<div class="navbar">${ib('back','Back',back)}<${tag} class="heading" ${interactive?`type="button" data-go="${title==='Launch team'?'members':'overview'}"`:''}>${color?mark(color):''}<span><strong>${title}</strong>${subtitle?`<small>${subtitle}</small>`:''}</span></${tag}>${next||ib('more','More options','editor')}</div>`;
  };
  const tabs = (selected='chats') => `<div class="tabbar">${[['chats','chat','Chats'],['approvals','shield','Approvals'],['settings','gear','Settings']].map(([route,i,title])=>`<button data-go="${route}" class="${selected===route?'active':''}">${icon(i)}${title}${route==='approvals'?'<span class="badge">2</span>':''}</button>`).join('')}</div>`;
  const page = body => `<div class="scroll"><div class="page">${body}</div></div>`;
  const title = (name,description='',plus='') => `<div class="title-row"><h1 class="large-title">${name}</h1>${plus?ib('plus','Add',plus,'quiet'):''}</div>${description?`<p class="secondary">${description}</p>`:''}`;
  const field = (label,value='',type='text') => `<label class="field"><span>${label}</span>${type==='textarea'?`<textarea>${esc(value)}</textarea>`:`<input type="${type}" value="${esc(value)}" placeholder="${type==='password'?'Enter your server key':''}" autocomplete="off">`}</label>`;
  const section = name => `<div class="section-label">${name}</div>`;
  const pill = (text,tone='') => `<span class="pill ${tone}">${text}</span>`;
  const banner = (text,neutral=false) => `<div class="banner ${neutral?'neutral':''}">${text}</div>`;
  const toggle = (name,description,on=false) => `<button class="row" data-toggle aria-pressed="${on}"><span class="row-text"><strong>${name}</strong><small>${description}</small></span><span class="switch ${on?'on':''}" aria-hidden="true"></span></button>`;
  const segments = names => `<div class="segments">${names.map((name,index)=>`<button data-segment aria-pressed="${index===0}">${name}</button>`).join('')}</div>`;
  const search = placeholder => `<label class="search">${icon('search')}<input data-search placeholder="${esc(placeholder)}" aria-label="${esc(placeholder)}"></label>`;
  const meta = (label,value) => `<div class="meta-line"><span>${label}</span><span>${value}</span></div>`;
  const file = (name,desc='PDF · 284 KB',route='preview') => `<button class="inline-file" data-go="${route}">${icon('file')}<span><strong>${name}</strong><small>${desc}</small></span></button>`;
  const composer = (placeholder='Message Atlas…',running=false) => `<div class="composer-wrap">${running?'<div class="runbar"><span>Atlas is working · guidance can steer this turn</span><button data-action="stop">Stop</button></div>':''}<form class="composer" data-composer>${ib('plus','Add attachment','attachments')}<input aria-label="Message" placeholder="${placeholder}" autocomplete="off">${ib('mic','Record voice memo','voice')}<button type="submit" class="icon-button send" aria-label="${running?'Steer running turn':'Send message'}">${icon('send')}</button></form></div>`;
  const message = (text,type='assistant',name='Atlas',color='blue') => `<div class="message ${type}">${type==='assistant'?`<div class="author">${mark(color)}${name}</div>`:''}${text}</div>`;
  const bottom = (text,route) => `<div class="bottom-action">${button(text,route)}</div>`;
  const register = (id,slug,name,group,notes,dependency,links,render) => window.SCREENS.push({id,slug,name,group,notes,dependency,links,render});
  const shell = screen => `<div class="phone" data-screen="${screen.slug}" aria-label="${screen.id} ${screen.name} drawing"><div class="statusbar"><span>9:41</span><span class="island" aria-hidden="true"></span><span class="system-status">${icon('signal')}${icon('wifi')}${icon('battery')}</span></div>${screen.render()}<div class="home-indicator" aria-hidden="true"></div></div>`;
  return {icon,esc,mark,groupMark,ib,button,row,nav,tabs,page,title,field,section,pill,banner,toggle,segments,search,meta,file,composer,message,bottom,register,shell};
})();
