import Foundation

/// Page-side form engine, injected fresh on every call (no state survives between calls, so a reload cannot break it).
/// Design, from how Playwright/agent-browser locate controls: resolve by the visible question text (label), tolerate
/// wording differences with a normalized + token score, act by control kind, then report what is still unanswered so the
/// model can keep going instead of asking. Google Forms: each question is a [role=listitem] with a [role=heading];
/// options are [role=radio|checkbox], dropdowns are [role=listbox] whose [role=option] list only exists once opened.
/// No line comments and every statement ends in ';': the AppleScript transport flattens newlines.
extension Chrome {
    static let lib = #"""
    const norm=s=>(s||'').toLowerCase().replace(/\(required\)|required|\*/g,' ').replace(/[^\p{L}\p{N}]+/gu,' ').trim();
    const txt=e=>((e&&e.textContent)||'').trim();
    const vis=e=>!!e&&(e.offsetParent!==null||e.getClientRects().length>0);
    const checked=e=>e.checked===true||e.getAttribute('aria-checked')==='true';
    const lab=e=>{const lb=e.getAttribute('aria-labelledby');
      return (lb&&lb.split(' ').map(i=>txt(document.getElementById(i))).join(' ').trim())||e.getAttribute('aria-label')||e.getAttribute('data-value')||(e.id&&txt(document.querySelector('label[for="'+CSS.escape(e.id)+'"]')))||txt(e.closest('label'))||e.placeholder||e.name||txt(e)};
    const score=(a,b)=>{a=norm(a);b=norm(b);if(!a||!b)return 0;if(a===b)return 1;if(a.includes(b)||b.includes(a))return .85;
      const A=a.split(' '),B=b.split(' ');const hit=A.filter(w=>B.some(x=>x===w||(w.length>3&&x.length>3&&x.startsWith(w.slice(0,4))))).length;if(hit===A.length)return .85;return .8*hit/Math.max(A.length,B.length)};
    const best=(items,want,get,min)=>{let r={item:null,s:0};for(const it of items){const s=score(want,get(it));if(s>r.s)r={item:it,s}}return r.s>=(min||.45)?r:{item:null,s:r.s}};
    const press=e=>{['mousedown','mouseup','click'].forEach(t=>e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window})))};
    const fire=e=>{e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))};
    const skip=['hidden','radio','checkbox','submit','button','file','image','reset'];
    const scan=()=>{const qs=[];
      const add=(title,kind,el,opts,req,box)=>{const q={id:qs.length,title:title||('field '+qs.length),kind,el,opts:opts||[],req:!!req,box};
        q.answered=kind==='radio'||kind==='checkbox'?q.opts.some(checked):kind==='dropdown'?[...(box||el).querySelectorAll('[role=option][aria-selected=true]')].some(o=>o.getAttribute('data-value')):kind==='other'?false:!!(el&&el.value);qs.push(q)};
      const sel='input:not([type=hidden]),textarea,select,[role=radio],[role=checkbox],[role=listbox]';
      const boxes=[...document.querySelectorAll('[role=listitem]')].filter(b=>vis(b)&&b.querySelector(sel));
      for(const b of boxes){const h=b.querySelector('[role=heading]');const title=txt(h).replace(/\s*\*\s*$/,'').trim();
        const req=/\*/.test(txt(h))||!!b.querySelector('[aria-required=true]');
        const rd=[...b.querySelectorAll('[role=radio],input[type=radio]')].filter(vis),cb=[...b.querySelectorAll('[role=checkbox],input[type=checkbox]')].filter(vis);
        const lb=b.querySelector('[role=listbox]'),se=b.querySelector('select'),ta=b.querySelector('textarea'),inp=[...b.querySelectorAll('input')].find(e=>!skip.includes(e.type)&&vis(e));
        if(rd.length)add(title,'radio',null,rd,req,b);else if(cb.length)add(title,'checkbox',null,cb,req,b);else if(lb)add(title,'dropdown',lb,[],req,b);
        else if(se)add(title,'select',se,[],req,b);else if(ta)add(title,'paragraph',ta,[],req,b);
        else if(inp)add(title,['date','time'].includes(inp.type)?inp.type:'text',inp,[],req,b);else if(b.querySelector('input[type=file]'))add(title,'file',null,[],req,b);}
      if(!qs.length){const seen=new Set();
        for(const e of document.querySelectorAll('input,textarea,select')){if(!vis(e)||e.type==='hidden'||['submit','button','image','reset'].includes(e.type))continue;
          if(e.type==='radio'||e.type==='checkbox'){const k=e.type+':'+(e.name||'');if(seen.has(k))continue;seen.add(k);
            const g=[...document.querySelectorAll('input[type='+e.type+']')].filter(x=>vis(x)&&(x.name||'')===(e.name||''));
            const fs=e.closest('fieldset,[role=radiogroup],[role=group]');add(txt(fs&&fs.querySelector('legend,[role=heading]'))||e.name,e.type,null,g,e.required,fs);}
          else if(e.type!=='file')add(lab(e),e.tagName==='SELECT'?'select':e.tagName==='TEXTAREA'?'paragraph':['date','time'].includes(e.type)?e.type:e.type==='password'?'password':'text',e,[],e.required,null);}}
      return qs};
    const optsOf=q=>q.kind==='dropdown'?[...(q.box||document).querySelectorAll('[role=option]')].map(o=>o.getAttribute('data-value')||txt(o)).filter(Boolean):q.kind==='select'?[...q.el.options].map(o=>o.text).filter(Boolean):q.opts.map(lab);
    const nav=()=>[...document.querySelectorAll('[role=button],button,input[type=submit]')].filter(vis).map(e=>norm(txt(e)||e.value||e.getAttribute('aria-label'))).filter(t=>/^(next|back|continue|submit|review|previous)$/.test(t));
    const status=()=>{const qs=scan();return {title:document.title,questions:qs.slice(0,40).map(q=>({id:q.id,question:q.title.slice(0,120),kind:q.kind,required:q.req,answered:q.answered,options:['text','paragraph','date','time','password','file'].includes(q.kind)?undefined:optsOf(q).slice(0,15)})),
      unanswered_required:qs.filter(q=>q.req&&!q.answered).map(q=>'#'+q.id+' '+q.title.slice(0,80)),buttons:nav()}};
    const setText=(el,v)=>{if(el.type==='password')return 'refused: Jinn does not fill passwords';el.focus();
      const p=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(p,'value').set.call(el,v);fire(el);el.blur();
      return el.value===v?'ok':'page changed the value to "'+el.value+'"'};
    const iso=v=>{if(/^\d{4}-\d{2}-\d{2}$/.test(v))return v;const d=new Date(v);if(isNaN(d))return null;const z=n=>String(n).padStart(2,'0');return d.getFullYear()+'-'+z(d.getMonth()+1)+'-'+z(d.getDate())};
    const one=(q,v)=>{
      if(q.kind==='radio'||q.kind==='checkbox'){const want=q.kind==='checkbox'?v.split(',').map(s=>s.trim()).filter(Boolean):[v];const res=[];
        for(const w of want){const b=best(q.opts,w,lab,.5);if(!b.item){res.push('option "'+w+'" not found; options: '+q.opts.map(lab).join(' | '));continue}
          if(!(q.kind==='checkbox'&&checked(b.item)))b.item.click();res.push('ok: '+lab(b.item))}
        return res.join('; ')}
      if(q.kind==='dropdown')return 'PENDING';
      if(q.kind==='select'){const b=best([...q.el.options],v,o=>o.text,.5);if(!b.item)return 'option not found; options: '+optsOf(q).join(' | ');q.el.value=b.item.value;fire(q.el);return 'ok: '+b.item.text}
      if(q.kind==='date'){const d=iso(v);if(!d)return 'give the date as YYYY-MM-DD';return setText(q.el,d)}
      if(q.kind==='file')return 'file upload is not supported; ask the user to attach it';
      return setText(q.el,v)};
    const fill=map=>{const qs=scan(),out={};
      for(const [k,v] of Object.entries(map)){const q=/^#?\d+$/.test(k)?qs[+k.replace('#','')]:best(qs,k,x=>x.title).item;
        out[k]=q?'#'+q.id+' '+one(q,String(v)):'no question matches "'+k+'". Questions: '+qs.map(x=>'#'+x.id+' '+x.title.slice(0,60)).join(' | ')}
      return out};
    const openDD=id=>{const q=scan()[id];if(!q||q.kind!=='dropdown')return 'not a dropdown';q.el.scrollIntoView({block:'center'});press(q.el);return 'opened'};
    const pickDD=(id,v)=>{const q=scan()[id];if(!q)return 'question gone';let os=[...(q.box||document).querySelectorAll('[role=option]')].filter(o=>vis(o)&&(o.getAttribute('data-value')||txt(o)));
      if(!os.length)os=[...document.querySelectorAll('[role=option]')].filter(o=>vis(o)&&(o.getAttribute('data-value')||txt(o)));
      const g=o=>o.getAttribute('data-value')||txt(o);const b=best(os,v,g,.5);if(!b.item)return os.length?'option not found; options: '+os.map(g).join(' | '):'dropdown did not open';press(b.item);return 'ok: '+g(b.item)};
    const next=()=>{const e=[...document.querySelectorAll('[role=button],button')].filter(vis).find(x=>/^(next|continue|review)$/.test(norm(txt(x)||x.getAttribute('aria-label'))));if(!e)return 'no Next button';e.click();return 'clicked '+txt(e)};
    const IS='a[href],button,[role=button],[role=link],[role=row],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=radio],[role=textbox],input,textarea,select,[contenteditable=true],[contenteditable=plaintext-only],[g_editable=true]';
    const elLabel=e=>(e.getAttribute('aria-label')||e.getAttribute('data-tooltip')||e.value||e.placeholder||(e.innerText||txt(e))||e.title||'').replace(/\s+/g,' ').trim().slice(0,100);
    const els=()=>[...document.querySelectorAll(IS)].filter(e=>vis(e)&&e.type!=='hidden'&&elLabel(e));
    const editable=e=>e.isContentEditable||['INPUT','TEXTAREA'].includes(e.tagName)||e.getAttribute('role')==='textbox';
    const list=()=>els().slice(0,80).map((e,i)=>'#'+i+' '+(e.getAttribute('role')||e.tagName.toLowerCase())+' "'+elLabel(e).slice(0,70)+'"').join('\n');
    const pick=(t,lab)=>{const all=els();if(/^#\d+$/.test(t)){const e=all[+t.slice(1)];if(e&&(!lab||elLabel(e)===lab))return {e,all};const b=lab?best(all,lab,elLabel,.7):{item:null};return {e:b.item,all}}const b=best(all,t,elLabel,.5);return {e:b.item,all}};
    const listJ=()=>els().slice(0,80).map(e=>({role:e.getAttribute('role')||e.tagName.toLowerCase(),label:elLabel(e).slice(0,70)}));
    const clickT=(t,lab)=>{const r=pick(t,lab);if(!r.e)return 'not found; elements: '+r.all.slice(0,25).map(e=>elLabel(e).slice(0,40)).join(' | ');r.e.scrollIntoView({block:'center'});press(r.e);return 'clicked "'+elLabel(r.e).slice(0,60)+'"'};
    const typeT=(t,v,lab)=>{let e=t?pick(t,lab).e:document.activeElement;if(!e||!editable(e))return 'no editable element'+(t?' matching "'+t+'"':' focused; pass a target');
      if(e.type==='password')return 'refused: Jinn does not fill passwords';
      if(e.isContentEditable){e.focus();document.execCommand('insertText',false,v);return txt(e).includes(v.slice(0,30))?'ok':'text did not land'}
      return setText(e,v)};
    const gThread=()=>[...document.querySelectorAll('div[data-message-id]')].some(vis);
    const gTitle=()=>txt(document.querySelector('h2.hP,[role=main] h2'));
    const gReply=all=>{const want=all?/^reply all/i:/^reply$/i;const e=els().find(x=>want.test((x.getAttribute('aria-label')||x.getAttribute('data-tooltip')||txt(x)).trim())&&!x.closest('[role=dialog]'));if(!e)return 'no Reply button';e.scrollIntoView({block:'center'});press(e);return 'clicked'};
    const gBody=()=>[...document.querySelectorAll('div[role=textbox][aria-label*="Message Body" i],div[g_editable=true],div[contenteditable=true][aria-label*="Message Body" i]')].filter(vis).pop();
    const gType=v=>{const b=gBody();if(!b)return 'no compose box';b.focus();document.execCommand('insertText',false,v);return txt(b).includes(v.slice(0,30))?'ok':'text did not land'};
    const gSend=()=>{const e=[...document.querySelectorAll('[role=button]')].filter(vis).find(x=>/^send\b/i.test(x.getAttribute('aria-label')||x.getAttribute('data-tooltip')||''));if(!e)return 'no Send button';press(e);return 'clicked'};
    """#

    /// Wraps a body expression with the library so each call is self-contained (an IIFE: repeated evaluations never collide on `const`).
    static func run(_ body: String) -> String { "(()=>{" + lib.replacingOccurrences(of: "\n", with: " ") + "return " + body + "})()" }
}
