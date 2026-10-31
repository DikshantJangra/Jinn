import Foundation

let chromeTools: [Tool] = [
    Tool(name: "chrome_tabs", description: "List the open Chrome tabs (title | url). Use a part of the url or title as url_contains in the other chrome tools.") { _ in
        try await Chrome.tabs()
    },
    Tool(name: "chrome_page", description: "Read a Chrome tab: title, URL and visible text. Works on tabs in the background.",
         params: ["url_contains": "(optional) part of the tab URL or title; default is the active tab"]) { a in
        try await Chrome.eval(Chrome.page, tab: a.opt("url_contains"))
    },
    Tool(name: "chrome_read_form", description: "List the input fields (label, question group, type, value) of a Chrome page, e.g. a Google Form",
         params: ["url_contains": "(optional) part of the tab URL or title to pick the tab"]) { a in
        try await Chrome.eval("JSON.stringify(\(Chrome.fields)().map(e=>({label:\(Chrome.label)(e),question:\(Chrome.group)(e),type:e.type||e.getAttribute('role'),value:e.type==='password'?'':(e.value||''),checked:!!(e.checked||e.getAttribute('aria-checked')==='true')})))", tab: a.opt("url_contains"))
    },
    Tool(name: "chrome_fill_form", description: "Fill fields on a Chrome page without taking focus. Text fields: label -> text. Multiple choice: question -> option text (comma separated for checkboxes). Does not submit.",
         params: ["fields": "JSON object, e.g. {\"Email\":\"a@b.com\",\"Gender\":\"Male\"}",
                  "url_contains": "(optional) part of the tab URL or title to pick the tab"], risk: .confirm) { a in
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(try a.str("fields").utf8))) as? [String: Any]
        else { throw JinnError("fields must be a JSON object mapping label to value, e.g. {\"Email\":\"a@b.com\"}") }
        let data = try JSONSerialization.data(withJSONObject: obj.mapValues { "\($0)" })
        let r = try await Chrome.eval("""
        ((map)=>{const els=\(Chrome.fields)(),out={},lab=\(Chrome.label),grp=\(Chrome.group);
        const choice=e=>/radio|checkbox/.test(e.type||e.getAttribute('role'));
        for(const [k,v] of Object.entries(map)){const q=k.toLowerCase();
          const opts=els.filter(e=>choice(e)&&grp(e).toLowerCase().includes(q));
          if(opts.length){const want=String(v).split(',').map(s=>s.trim().toLowerCase());
            const hit=opts.filter(e=>want.includes(lab(e).toLowerCase()));
            if(!hit.length){out[k]='option not found; options: '+opts.map(lab).join(' | ');continue}
            hit.forEach(e=>{if(!(e.checked||e.getAttribute('aria-checked')==='true'))e.click()});out[k]='ok';continue}
          const el=els.find(e=>lab(e).toLowerCase()===q)||els.find(e=>lab(e).toLowerCase().includes(q))||els.find(e=>grp(e).toLowerCase().includes(q));
          if(!el){out[k]='not found';continue}
          if(el.type==='password'){out[k]='refused: Jinn does not fill passwords';continue}
          if(choice(el)){el.click()}
          else{const p=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:el.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype;
            let val=String(v);if(el.tagName==='SELECT'){const o=[...el.options].find(o=>o.text.toLowerCase()===val.toLowerCase());if(o)val=o.value}
            Object.getOwnPropertyDescriptor(p,'value').set.call(el,val);
            el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))}
          out[k]='ok'}
        return JSON.stringify(out)})(JSON.parse(\(Chrome.jsString(String(decoding: data, as: UTF8.self)))))
        """, tab: a.opt("url_contains"))
        return r + Interrupt.note(busy)
    },
    Tool(name: "chrome_click", description: "Click a button or link on a Chrome page by its text (e.g. Submit). Only when the user asked.",
         params: ["text": "Button or link text", "url_contains": "(optional) part of the tab URL or title to pick the tab"], risk: .confirm, alwaysAsk: true) { a in
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        let r = try await Chrome.eval("""
        ((t)=>{t=t.toLowerCase();const el=[...document.querySelectorAll('button,[role=button],a,input[type=submit]')]
          .find(e=>((e.textContent||'')+(e.getAttribute('aria-label')||'')+(e.value||'')).toLowerCase().includes(t));
          if(!el)return 'not found';el.click();return 'clicked'})(\(Chrome.jsString(try a.str("text"))))
        """, tab: a.opt("url_contains"))
        return r + Interrupt.note(busy)
    },
]
