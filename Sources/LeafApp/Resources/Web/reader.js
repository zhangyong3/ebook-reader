/* EPUB.js is bundled locally. Only this trusted parent document can call the native bridge. */
(() => {
  'use strict';
  let book, rendition, pagination, settings, annotations = [], toc = [], history = [], searchVersion = 0;
  const unresolved = new Set();
  const post = (event, data = {}) => window.webkit.messageHandlers.leaf.postMessage({event, ...data});
  const fail = error => post('error', {message: String(error?.message || error)});
  const normalize = text => text.replace(/\s+/g, ' ').trim();
  function flatten(items, depth = 0) {
    return items.flatMap(item => [{label: item.label.trim(), href: item.href, depth}, ...flatten(item.subitems || [], depth + 1)]);
  }
  function chapterName(href) {
    const path = href?.split('#')[0];
    return toc.find(item => item.href.split('#')[0] === path)?.label || '';
  }
  function sanitize(document, section) {
    document.querySelectorAll('script,iframe,object,embed,form,base').forEach(el => el.remove());
    document.querySelectorAll('*').forEach(el => {
      [...el.attributes].forEach(attr => {
        if (/^on/i.test(attr.name) || /^javascript:/i.test(attr.value.trim())) el.removeAttribute(attr.name);
      });
    });
    const base = document.createElement('base');
    base.setAttribute('href',section.url);
    document.head?.prepend(base);
    const meta = document.createElement('meta');
    meta.setAttribute('http-equiv', 'Content-Security-Policy');
    meta.setAttribute('content', "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' leaf: blob:; img-src leaf: data: blob:; font-src leaf: data: blob:; media-src leaf: data: blob:; base-uri leaf:;");
    document.head?.prepend(meta);
  }
  let selectedText = null, lastPointer = {x:24,y:24};
  const overlay = document.createElement('div'); overlay.id='leaf-overlays'; document.body.append(overlay);
  const marks = document.createElement('div'); overlay.append(marks);
  const noteEditors = new Map();
  const toolbar = document.createElement('div'); toolbar.id='leaf-selection-tools'; toolbar.hidden=true; toolbar.setAttribute('role','toolbar'); toolbar.setAttribute('aria-label','选中文字操作');
  const icons = {
    dictionary:'<path d="M3 4h7a3 3 0 0 1 3 3v14a4 4 0 0 0-4-3H3zM21 4h-5a3 3 0 0 0-3 3v14a4 4 0 0 1 4-3h4z"/>',
    analysis:'<path d="M3 5h12M9 3v2M5 5c0 5 4 9 9 11M13 5c0 5-4 9-10 12M14 21l4-11 4 11M15.5 17h5"/>',
    highlight:'<path d="m8 16 8-12 5 4-9 11-4-3ZM8 16l-3 5h6M3 22h13"/>',
    bookmark:'<path d="M7 3h10v6l3 4H4l3-4V3ZM12 13v9"/>'
  };
  for (const [action,label] of [['dictionary','查词'],['analysis','翻译与语句解析'],['highlight','高亮'],['bookmark','书签']]) {
    const button=document.createElement('button'); button.type='button'; button.title=label; button.setAttribute('aria-label',label);
    button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">'+icons[action]+'</svg>';
    button.addEventListener('mousedown',event=>event.preventDefault());
    button.addEventListener('click',()=> { if(selectedText)post('selectionAction',{action}); toolbar.hidden=true; });
    toolbar.append(button);
  }
  document.body.append(toolbar);
  const pageNav=document.createElement('div');pageNav.id='leaf-page-nav';pageNav.setAttribute('aria-label','翻页');
  const pageButtons={};
  for(const [action,label,path] of [['previous','上一页','m15 5-7 7 7 7'],['next','下一页','m9 5 7 7-7 7']]) {
    const button=document.createElement('button');button.type='button';button.className='leaf-page-arrow '+action;button.title=label;button.setAttribute('aria-label',label);button.disabled=true;
    button.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="'+path+'"/></svg>';
    button.addEventListener('mousedown',e=>e.preventDefault());button.addEventListener('click',()=>navigatePage(action==='next'?1:-1).catch(fail));pageButtons[action]=button;pageNav.append(button);
  }
  document.body.append(pageNav);
  function placePageButtons() {
    const r=document.getElementById('viewer').getBoundingClientRect();
    pageButtons.previous.style.left=Math.max(0,Math.min(48,(r.left-28)/2))+'px';
    pageButtons.next.style.right=Math.max(0,Math.min(48,(innerWidth-r.right-28)/2))+'px';
  }
  async function navigatePage(direction) {
    toolbar.hidden=true;selectedText=null;post('selection',{text:''});
    if(pagination)await pagination.next(direction);
    else if(direction>0)await rendition?.next();else await rendition?.prev();
  }
  function parentPoint(contents,event) {
    const rect=contents.window.frameElement.getBoundingClientRect();
    return {x:rect.left+event.clientX,y:rect.top+event.clientY};
  }
  function selection(contents,event,showTools=true) {
    const selected=contents.window.getSelection();
    if(!selected?.rangeCount||selected.isCollapsed) { if(event){toolbar.hidden=true;selectedText=null;post('selection',{text:''});}return; }
    const range=selected.getRangeAt(0),text=range.toString().trim();
    if(!text||text.length>20000)return;
    const before=range.cloneRange();before.selectNodeContents(contents.document.body);before.setEnd(range.startContainer,range.startOffset);
    const after=range.cloneRange();after.selectNodeContents(contents.document.body);after.setStart(range.endContainer,range.endOffset);
    selectedText={cfi:contents.cfiFromRange(range),text,prefix:before.toString().slice(-40),suffix:after.toString().slice(0,40),href:book.spine.get(contents.sectionIndex)?.href||''};
    if(event)lastPointer=parentPoint(contents,event);
    post('selection',selectedText);
    toolbar.hidden=!showTools;
    if(!showTools)return;
    toolbar.style.left=Math.max(8,Math.min(innerWidth-toolbar.offsetWidth-8,lastPointer.x+8))+'px';
    toolbar.style.top=Math.max(8,Math.min(innerHeight-toolbar.offsetHeight-8,lastPointer.y+14))+'px';
  }
  function textAtPoint(contents,event) {
    const range=contents.document.caretRangeFromPoint(event.clientX,event.clientY);
    if(!range||range.startContainer.nodeType!==Node.TEXT_NODE)return null;
    const node=range.startContainer, offset=Math.min(range.startOffset,Math.max(0,node.length-1));
    const glyph=range.cloneRange();glyph.setStart(node,offset);glyph.setEnd(node,Math.min(node.length,offset+1));
    const rect=glyph.getBoundingClientRect();
    if(rect.left<=event.clientX&&rect.right>=event.clientX&&rect.top<=event.clientY&&rect.bottom>=event.clientY&&!/^\s*$/.test(glyph.toString()))return range;
    return null;
  }
  function commandLookup(contents,event) {
    const doc=contents.document,caret=doc.caretRangeFromPoint(event.clientX,event.clientY);
    if(!caret||caret.startContainer.nodeType!==Node.TEXT_NODE)return;
    const node=caret.startContainer;
    // A caret can land after the clicked glyph, especially on its right half.
    let hit=-1;
    for(const offset of [caret.startOffset,caret.startOffset-1]) {
      if(offset<0||offset>=node.length)continue;
      const glyph=doc.createRange();glyph.setStart(node,offset);glyph.setEnd(node,offset+1);
      if([...glyph.getClientRects()].some(r=>event.clientX>=r.left&&event.clientX<=r.right&&event.clientY>=r.top&&event.clientY<=r.bottom)&&!/^\s*$/.test(glyph.toString())){hit=offset;break;}
    }
    if(hit<0)return;
    // Keep inline emphasis inside a word, but do not join adjacent paragraphs.
    const block=node.parentElement.closest('p,li,blockquote,h1,h2,h3,h4,h5,h6,td,th,pre,figcaption,div')||doc.body;
    const walker=doc.createTreeWalker(block,NodeFilter.SHOW_TEXT),nodes=[];let text='',current,index=-1;
    while((current=walker.nextNode())) {
      if(current===node)index=text.length+hit;
      nodes.push({node:current,start:text.length});text+=current.textContent;
    }
    if(index<0)return;
    let word;
    if(typeof Intl.Segmenter==='function') {
      word=[...new Intl.Segmenter(undefined,{granularity:'word'}).segment(text)].find(part=>part.isWordLike&&index>=part.index&&index<part.index+part.segment.length);
    } else {
      const match=[...text.matchAll(/[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*/gu)].find(part=>index>=part.index&&index<part.index+part[0].length);
      if(match)word={index:match.index,segment:match[0]};
    }
    if(!word)return;
    const start=nodes.find(part=>word.index>=part.start&&word.index<part.start+part.node.length);
    const endIndex=word.index+word.segment.length,end=nodes.find(part=>endIndex>part.start&&endIndex<=part.start+part.node.length);
    if(!start||!end)return;
    const range=doc.createRange();range.setStart(start.node,word.index-start.start);range.setEnd(end.node,endIndex-end.start);
    const selected=contents.window.getSelection();selected.removeAllRanges();selected.addRange(range);
    selection(contents,null,false);post('selectionAction',{action:'dictionary'});
  }
  function blankNote(contents,event) {
    if(event.target.closest('a,img,svg,input,textarea,button')||textAtPoint(contents,event))return false;
    const range=contents.document.caretRangeFromPoint(event.clientX,event.clientY);
    if(!range||!contents.document.body.contains(range.startContainer))return false;
    range.collapse(true);
    const rect=range.getBoundingClientRect(),font=parseFloat(contents.window.getComputedStyle(contents.document.body).fontSize)||22;
    const id=(crypto.randomUUID?.()||'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.random()*16|0;return(c==='x'?n:(n&3|8)).toString(16);})).toUpperCase();
    toolbar.hidden=true;selectedText=null;contents.window.getSelection()?.removeAllRanges();post('selection',{text:''});
    post('noteCreate',{id,cfi:contents.cfiFromRange(range),href:book.spine.get(contents.sectionIndex)?.href||'',offsetX:(event.clientX-rect.left)/font,offsetY:(event.clientY-rect.top)/font});
    pendingNoteFocus=id;
    return true;
  }
  let pendingNoteFocus=null;
  function contextAt(contents,event) {
    const match=[...annotations].reverse().find(item=> {
      if(['freeNote','bookmark','queried'].includes(item.kind))return false;
      try{return [...contents.range(item.cfi).getClientRects()].some(r=>event.clientX>=r.left&&event.clientX<=r.right&&event.clientY>=r.top&&event.clientY<=r.bottom);}catch{return false;}
    });
    if(match){event.preventDefault();toolbar.hidden=true;post('context',{id:match.id,...parentPoint(contents,event)});}
  }
  function keyboard(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || /INPUT|TEXTAREA/.test(event.target.tagName)) return;
    if (event.key === 'ArrowRight' || event.key === 'PageDown') { event.preventDefault(); navigatePage(1).catch(fail); }
    if (event.key === 'ArrowLeft' || event.key === 'PageUp') { event.preventDefault(); navigatePage(-1).catch(fail); }
    if(event.key==='Escape'){toolbar.hidden=true;post('selection',{text:''});}
  }
  function styleRendition(target,reading) {
    const palette={light:['#ffffff','#292d28'],paper:['#f7f4ec','#292d28'],dark:['#202320','#e1e5dd']}[reading.theme]||['#f7f4ec','#292d28'];
    target.themes.override('background',palette[0],true);
    target.themes.override('color',palette[1],true);
    target.themes.override('font-size',`${reading.fontSize}px`,true);
    target.themes.override('line-height',String(reading.lineHeight),true);
    target.themes.font(reading.font === 'serif' ? 'Georgia, "Songti SC", "Noto Serif CJK SC", serif' : '-apple-system, "PingFang SC", sans-serif');
    target.themes.default({
      'body': {'padding': '0 28px !important', 'box-sizing': 'border-box'},
      'p,li,blockquote': {'font-size': '1em !important', 'line-height': `${reading.lineHeight} !important`},
      'img,svg': {'max-width':'100% !important', 'object-fit':'contain'},
      'a': {'color': reading.theme === 'dark' ? '#a3c9b1 !important' : '#426653 !important'}
    });
  }
  function applySettings() {
    if (!rendition) return;
    const palette = {light: ['#ffffff','#292d28'], paper: ['#f7f4ec','#292d28'], dark: ['#202320','#e1e5dd']}[settings.theme] || ['#f7f4ec','#292d28'];
    document.documentElement.style.background = palette[0];
    document.documentElement.style.setProperty('--leaf-nav-ink',palette[1]);
    document.documentElement.style.setProperty('--leaf-query-ink',settings.theme==='dark'?'#a3c9b1':'#426653');
    const viewer = document.getElementById('viewer');
    viewer.style.maxWidth = `${settings.width + 64}px`;
    styleRendition(rendition,settings);
    const flow = settings.scrolling ? 'scrolled-doc' : 'paginated';
    if (rendition.settings.flow !== flow) rendition.flow(flow);
    requestAnimationFrame(() => rendition.resize(viewer.clientWidth, viewer.clientHeight));
  }
  // A text quote fallback is allowed only when the full quote + context has a unique match.
  function recoverRange(contents, item) {
    const doc = contents.document, walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    const nodes = []; let joined = '', node;
    while ((node = walker.nextNode())) { nodes.push({node, start: joined.length}); joined += node.textContent; }
    const quote = item.quote; if (!quote) return null;
    let pos = -1, match = null, count = 0;
    while ((pos = joined.indexOf(quote, pos + 1)) >= 0) {
      const prefix = item.prefix || '', suffix = item.suffix || '';
      if (prefix && !joined.slice(0,pos).endsWith(prefix)) continue;
      if (suffix && !joined.slice(pos+quote.length).startsWith(suffix)) continue;
      match = pos; count++;
    }
    if (count !== 1) return null;
    const first = nodes.find(n => match >= n.start && match < n.start+n.node.length);
    const last = nodes.find(n => match+quote.length > n.start && match+quote.length <= n.start+n.node.length);
    if (!first || !last) return null;
    const range = doc.createRange(); range.setStart(first.node,match-first.start); range.setEnd(last.node,match+quote.length-last.start); return range;
  }
  function parentRect(contents,rect) {
    const frame=contents.window.frameElement.getBoundingClientRect();
    return {left:frame.left+rect.left,top:frame.top+rect.top,width:rect.width,height:rect.height};
  }
  function visible(rect) {return rect.left+rect.width>=0&&rect.left<innerWidth&&rect.top+rect.height>=0&&rect.top<innerHeight;}
  const noteMeasure=document.createElement('div');noteMeasure.className='leaf-note-measure';noteMeasure.setAttribute('aria-hidden','true');document.body.append(noteMeasure);
  function fitNote(editor) {
    const point=editor.leafPoint||{x:8,y:8};
    const left=Math.max(8,Math.min(innerWidth-20,point.x)),available=Math.max(12,innerWidth-left-8);
    const style=getComputedStyle(editor);
    for(const key of ['fontFamily','fontSize','fontWeight','fontStyle','letterSpacing','lineHeight','tabSize'])noteMeasure.style[key]=style[key];
    noteMeasure.style.maxWidth=Math.max(6,available-6)+'px';
    noteMeasure.textContent=editor.value+'\u200b';
    editor.style.left=left+'px';
    editor.style.width=Math.min(available,Math.max(12,Math.ceil(noteMeasure.getBoundingClientRect().width)+7))+'px';
    editor.style.height='0px';editor.style.height=(editor.scrollHeight+2)+'px';
    editor.style.top=Math.max(8,Math.min(innerHeight-editor.offsetHeight-8,point.y))+'px';
  }
  function drawNote(item,contents,range) {
    const anchor=parentRect(contents,range.getBoundingClientRect());
    if(!visible(anchor))return false;
    const font=parseFloat(contents.window.getComputedStyle(contents.document.body).fontSize)||22;
    const point={x:anchor.left+(item.placement?.offsetX||0)*font,y:anchor.top+(item.placement?.offsetY||0)*font};
    let editor=noteEditors.get(item.id);
    if(!editor){
      editor=document.createElement('textarea');editor.className='leaf-free-note';editor.setAttribute('aria-label','即时笔记');editor.dataset.id=item.id;editor.rows=1;editor.maxLength=20000;
      editor.addEventListener('input',()=>{fitNote(editor);post('noteSave',{id:item.id,text:editor.value});});
      editor.addEventListener('focus',()=>{toolbar.hidden=true;fitNote(editor);});
      editor.addEventListener('blur',()=>post('noteSave',{id:item.id,text:editor.value,final:true}));
      editor.addEventListener('contextmenu',event=>{event.preventDefault();post('context',{id:item.id,x:event.clientX,y:event.clientY});});
      overlay.append(editor);noteEditors.set(item.id,editor);
    }
    if(document.activeElement!==editor)editor.value=item.note||'';
    const style=item.noteAppearance||{};
    editor.leafPoint=point;
    editor.style.fontFamily=style.font==='serif'?'Georgia,"Songti SC",serif':style.font==='mono'?'Menlo,monospace':'-apple-system,"PingFang SC",sans-serif';
    editor.style.color=style.color||'#292d28';editor.style.fontSize=(style.size||15)+'px';
    fitNote(editor);
    if(pendingNoteFocus===item.id){pendingNoteFocus=null;requestAnimationFrame(()=>editor.focus());}
    return true;
  }
  let paintFrame=0;
  function schedulePaint() {
    if(paintFrame)return;
    paintFrame=requestAnimationFrame(()=>{paintFrame=0;paint();});
  }
  function paint() {
    if(!rendition)return;
    placePageButtons();
    marks.replaceChildren();const shownNotes=new Set();
    for(const contents of rendition.getContents())for(const item of annotations){
      let parsed;try{parsed=new ePub.CFI(item.cfi);}catch{unresolved.add(item.id);continue;}
      if(parsed.spinePos!==contents.sectionIndex)continue;
      let range;try{range=contents.range(item.cfi);}catch{}
      if(!['freeNote','bookmark'].includes(item.kind)&&(!range||normalize(range.toString())!==normalize(item.quote)))range=recoverRange(contents,item);
      if(!range){unresolved.add(item.id);continue;}unresolved.delete(item.id);
      if(item.kind==='freeNote'){if(drawNote(item,contents,range))shownNotes.add(item.id);continue;}
      const rects=[...range.getClientRects()];
      if(item.kind==='bookmark'){
        const r=parentRect(contents,rects[0]||range.getBoundingClientRect());if(!visible(r))continue;
        const pin=document.createElement('button');pin.className='leaf-bookmark-pin';pin.type='button';pin.title='书签：'+(item.quote||'当前阅读位置');pin.setAttribute('aria-label',pin.title);pin.textContent='📌';
        pin.style.left=Math.max(2,r.left-25)+'px';pin.style.top=Math.max(0,r.top)+'px';
        pin.addEventListener('contextmenu',e=>{e.preventDefault();post('context',{id:item.id,x:e.clientX,y:e.clientY});});marks.append(pin);continue;
      }
      const color={yellow:'#e4c74a',green:'#73a887',pink:'#d99aaf',blue:'#7aa8d9'}[item.color]||item.color||'#e4c74a';
      for(const rect of rects){
        const r=parentRect(contents,rect);if(!visible(r)||r.width<1)continue;
        const mark=document.createElement('div');mark.className='leaf-mark '+item.kind;
        Object.assign(mark.style,{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});mark.style.setProperty('--mark-color',color);marks.append(mark);
      }
    }
    for(const [id,editor] of noteEditors)if(!shownNotes.has(id)){editor.remove();noteEditors.delete(id);}
    post('unresolved',{ids:[...unresolved]});
  }
  async function open(command) {
    pagination?.destroy();pagination=null;
    if (book) book.destroy();
    settings = command.settings; annotations = command.annotations; history=[]; unresolved.clear();toolbar.hidden=true;noteEditors.forEach(e=>e.remove());noteEditors.clear();
    book = ePub();
    book.spine.hooks.content.register(sanitize);
    await book.open(command.url, 'opf');
    await book.ready;
    toc = flatten((await book.loaded.navigation).toc);
    post('toc',{items:toc});
    rendition = book.renderTo('viewer',{width:'100%',height:'100%',spread:'none',flow:settings.scrolling?'scrolled-doc':'paginated',// WebKit needs scripts enabled on the frame for trusted parent event callbacks.
      // The injected CSP still forbids every script supplied by the book.
      allowScriptedContent:true});
    rendition.hooks.content.register(contents => {
      contents.document.addEventListener('keydown', keyboard);
      contents.document.addEventListener('mousedown',event=>{if(event.metaKey&&event.button===0)event.preventDefault();},true);
      contents.document.addEventListener('dblclick',event=>{if(event.metaKey)return;if(!blankNote(contents,event))setTimeout(()=>selection(contents,event),0);});
      contents.document.addEventListener('mouseup',event=>{if(event.button===0&&!event.metaKey&&event.detail!==2)setTimeout(()=>selection(contents,event),0);});
      contents.document.addEventListener('contextmenu',event=>contextAt(contents,event));
      contents.document.addEventListener('click',event => {
        if(event.metaKey&&event.button===0){event.preventDefault();event.stopImmediatePropagation();toolbar.hidden=true;commandLookup(contents,event);return;}
        const anchor = event.target.closest('a');
        if (anchor && rendition.location?.start?.cfi) history.push(rendition.location.start.cfi);
      }, true);
    });
    rendition.on('rendered', schedulePaint);
    rendition.on('displayed', schedulePaint);
    rendition.on('resized', schedulePaint);
    rendition.on('relocated', location => {
      const start = location.start;
      const section = book.spine.get(start.index);
      const within = start.displayed?.total ? (start.displayed.page-1)/start.displayed.total : 0;
      const page=pagination?.current()||0,total=pagination?.pages.length||0;
      const progress = total>1 ? (page-1)/(total-1) : location.atEnd ? 1 : (start.index+within)/Math.max(1,book.spine.length);
      post('location',{cfi:start.cfi,progress,chapter:chapterName(section?.href || start.href)});toolbar.hidden=true;schedulePaint();pagination?.publish();
    });
    
    pagination=new LeafPagination({url:command.url,sanitize,style:styleRendition,
      rendition:()=>rendition,settings:()=>settings,geometry:()=>({width:viewer.clientWidth,height:viewer.clientHeight}),
      onChange:state=>{pageButtons.previous.disabled=state.atStart;pageButtons.next.disabled=state.atEnd;post('pagination',state);}});
    rendition.on('displayError', fail);
    applySettings();
    try { await rendition.display(command.location || undefined); }
    catch (error) { if (!command.location) throw error; await rendition.display(); }
    schedulePaint(); post('ready');pagination.update();
  }
  window.readerCommand = async command => {
    try {
      switch (command.action) {
      case 'open': await open(command); break;
      case 'next': await navigatePage(1); break;
      case 'previous': await navigatePage(-1); break;
      case 'page': toolbar.hidden=true;selectedText=null;if(rendition.location?.start?.cfi)history.push(rendition.location.start.cfi);await pagination?.jump(command.page);break;
      case 'paginationInfo': return pagination?{total:pagination.pages.length,current:pagination.current(),sections:[...pagination.sections.entries()],location:rendition.location,scroll:rendition.manager.container.scrollLeft,scrollWidth:rendition.manager.container.scrollWidth,layout:rendition.manager.layout.props,error:pagination.failure||null}:null;
      case 'back': if (history.length) await rendition.display(history.pop()); break;
      case 'focusNote': { const editor=noteEditors.get(command.id);if(editor)editor.focus();break;}
      case 'go': if (rendition.location?.start?.cfi) history.push(rendition.location.start.cfi); await rendition.display(command.target); break;
      case 'settings': {
        const cfi = rendition?.location?.start?.cfi;
        settings=command.settings; applySettings(); if (cfi) await rendition.display(cfi); schedulePaint();pagination?.update(); break;
      }
      case 'annotations': annotations=command.items;toolbar.hidden=true;schedulePaint();break;
      case 'search': {
        const version=++searchVersion, items=[];
        for (const section of book.spine.spineItems) {
          if (version !== searchVersion) return;
          await section.load(book.load.bind(book));
          items.push(...section.find(command.query));
          // Rendered sections must retain their DOM. Only unload search-only sections.
          if (!rendition.getContents().some(c => c.sectionIndex===section.index)) section.unload();
          if (items.length >= 300) break;
        }
        if (version===searchVersion) post('search',{items:items.slice(0,300)});
        break;
      }
      }
    } catch(error) { fail(error); }
  };
  const viewer = document.getElementById('viewer');
  let resizeTimer;
  const geometryObserver=new ResizeObserver(() => {
    // The capped reader can move without changing its own width. Observe the
    // viewport as well, and always repaint independently of EPUB pagination.
    schedulePaint();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      if (rendition?.manager?.stage) rendition.resize(viewer.clientWidth,viewer.clientHeight,rendition.location?.start?.cfi);
      schedulePaint();pagination?.update();
    },60);
  });
  geometryObserver.observe(viewer);
  geometryObserver.observe(document.documentElement);
  window.addEventListener('resize',()=>{toolbar.hidden=true;schedulePaint();});
  document.addEventListener('scroll',schedulePaint,true);
  document.addEventListener('keydown',keyboard);
  window.addEventListener('unhandledrejection',event => { event.preventDefault(); fail(event.reason); });
})();
