/* Whole-book pagination, measured chapter by chapter in an isolated renderer. */
(() => {
  'use strict';
  const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
  const frame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
  class LeafPagination {
    constructor(options) {
      this.options=options;this.pages=[];this.sections=new Map();this.generation=0;
      this.key='';this.loading=true;this.error=null;this.worker=Promise.resolve();this.timer=0;
    }
    update() {
      const {width,height}=this.options.geometry(),settings={...this.options.settings()};
      if(width<1||height<1)return;
      const key=JSON.stringify([width,height,settings.font,settings.fontSize,settings.lineHeight,settings.scrolling]);
      if(key===this.key)return;
      this.key=key;const generation=++this.generation;
      this.pages=[];this.sections.clear();this.loading=true;this.error=null;this.failure=null;this.publish();
      clearTimeout(this.timer);
      this.timer=setTimeout(()=>{
        this.worker=this.worker.catch(()=>{}).then(()=>this.build(generation,settings,width,height));
      },250);
    }
    destroy() { ++this.generation;clearTimeout(this.timer);this.pages=[];this.sections.clear(); }
    current() {
      if(!this.pages.length)return 0;
      const location=this.options.rendition()?.location,start=location?.start;
      if(!start)return 1;
      const section=this.sections.get(start.index);
      if(!section)return location.atEnd?this.pages.length:1;
      const main=this.options.rendition(),manager=main.manager,view=manager.views.find(main.book.spine.get(start.index));
      if(!view)return section.start;
      const bounds=manager.container.getBoundingClientRect(),position=view.position(),vertical=this.options.settings().scrolling;
      const step=vertical?manager.layout.height:manager.layout.pageWidth;
      const offset=vertical?bounds.top-position.top:manager.settings.direction==='rtl'?position.right-bounds.right:bounds.left-position.left;
      let local=vertical?Math.floor(Math.max(0,offset)/step+.001):Math.round(Math.max(0,offset)/step);
      if(vertical&&offset>=view.height()-step-1)local=section.count-1;
      return section.start+Math.max(0,Math.min(section.count-1,local));
    }
    publish() {
      const location=this.options.rendition()?.location,current=this.current(),total=this.pages.length;
      this.options.onChange({current,total,loading:this.loading,error:this.error,
        atStart:total?current<=1:!!location?.atStart,atEnd:total?current>=total:!!location?.atEnd});
    }
    async jump(page) {
      if(this.loading||!Number.isInteger(page)||page<1||page>this.pages.length)return;
      const item=this.pages[page-1],main=this.options.rendition();
      if(!main)return;
      // Move by the measured viewport, avoiding ambiguous text at page boundaries.
      await main.display(item.href);
      const contents=main.getContents()[0];
      if(contents?.document.fonts)await contents.document.fonts.ready;
      // Let the newly displayed chapter finish its initial location report and
      // font-driven layout before moving away from the chapter opening.
      await frame();
      main.manager.views.first()?.expand();
      await frame();
      const vertical=this.options.settings().scrolling,layout=main.manager.layout;
      main.manager.moveTo({left:vertical?0:item.page*layout.delta,top:vertical?item.page*layout.height:0},0);
      await main.reportLocation();
      this.publish();
    }
    async next(direction) {
      const main=this.options.rendition();if(!main)return;
      if(this.options.settings().scrolling&&this.pages.length&&!this.loading) return this.jump(this.current()+direction);
      if(direction>0)await main.next();else await main.prev();
    }
    async build(generation,settings,width,height) {
      if(generation!==this.generation)return;
      const host=document.createElement('div');host.className='leaf-pagination-probe';
      host.setAttribute('aria-hidden','true');host.style.width=width+'px';host.style.height=height+'px';document.body.append(host);
      let indexBook,indexRendition;
      try {
        indexBook=ePub();indexBook.spine.hooks.content.register(this.options.sanitize);
        await indexBook.open(this.options.url,'opf');await indexBook.ready;
        if(generation!==this.generation)return;
        indexRendition=indexBook.renderTo(host,{width,height,spread:'none',flow:settings.scrolling?'scrolled-doc':'paginated',allowScriptedContent:true});
        this.options.style(indexRendition,settings);
        const pages=[],sections=new Map();let previous;
        for(const section of indexBook.spine.spineItems.filter(item=>item.linear)) {
          if(generation!==this.generation)return;
          await indexRendition.display(section.href);
          if(previous)previous.unload();previous=section;
          const contents=indexRendition.getContents()[0];
          if(contents)await Promise.all([...contents.document.images].map(image=>image.complete?Promise.resolve():new Promise(resolve=>{image.addEventListener('load',resolve,{once:true});image.addEventListener('error',resolve,{once:true});})));
          if(contents?.document.fonts)await contents.document.fonts.ready;
          await frame();
          if(generation!==this.generation)return;
          const view=indexRendition.manager.views.first();view.expand();
          const count=Math.max(1,settings.scrolling?Math.ceil(view.height()/height):indexRendition.manager.layout.count(view.width()).pages);
          sections.set(section.index,{start:pages.length+1,count});
          for(let page=0;page<count;page++) {
            if(generation!==this.generation)return;
            pages.push({index:section.index,href:section.href,page});
            if(page%8===7)await tick();
          }
          await tick();
        }
        if(generation!==this.generation)return;
        this.pages=pages;this.sections=sections;this.loading=false;this.publish();
      } catch(error) {
        if(generation===this.generation){this.loading=false;this.failure=String(error?.message||error);this.error='暂时无法计算全书页数';this.publish();}
      } finally {
        try{indexRendition?.destroy();}catch{}
        try{indexBook?.destroy();}catch{}
        host.remove();
      }
    }
  }
  window.LeafPagination=LeafPagination;
})();
