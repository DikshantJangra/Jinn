import Foundation

let chromeTools: [Tool] = [
    Tool(name: "chrome_read_form", description: "List the input fields (label, type, current value) of the open Chrome page, e.g. a Google Form",
         params: ["url_contains": "(optional) part of the tab URL to pick the tab"]) { a in
        try await Chrome.eval("JSON.stringify(\(Chrome.fields)().map(e=>({label:\(Chrome.label)(e),type:e.type||e.getAttribute('role'),value:e.type==='password'?'':(e.value||'')})))", tab: a.opt("url_contains"))
    },
    Tool(name: "chrome_fill_form", description: "Fill fields on the open Chrome page without taking focus. Does not submit.",
         params: ["fields": "JSON object mapping field label to value, e.g. {\"Email\":\"a@b.com\"}",
                  "url_contains": "(optional) part of the tab URL to pick the tab"], risk: .confirm) { a in
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        // model output is parsed and re-serialized in Swift so it can only reach the page as data, never as code
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(try a.str("fields").utf8))) as? [String: Any]
        else { throw JinnError("fields must be a JSON object mapping label to value, e.g. {\"Email\":\"a@b.com\"}") }
        let data = try JSONSerialization.data(withJSONObject: obj.mapValues { "\($0)" })
        let r = try await Chrome.eval("""
        ((map)=>{const els=\(Chrome.fields)(),out={};
        for(const [k,v] of Object.entries(map)){const q=k.toLowerCase();
          const el=els.find(e=>\(Chrome.label)(e).toLowerCase()===q)||els.find(e=>\(Chrome.label)(e).toLowerCase().includes(q));
          if(!el){out[k]='not found';continue}
          if(el.type==='password'){out[k]='refused: Jinn does not fill passwords';continue}
          if(/radio|checkbox/.test(el.type||el.getAttribute('role'))){el.click()}
          else{const p=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:el.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(p,'value').set.call(el,String(v));
            el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))}
          out[k]='ok'}
        return JSON.stringify(out)})(JSON.parse(\(Chrome.jsString(String(decoding: data, as: UTF8.self)))))
        """, tab: a.opt("url_contains"))
        return r + Interrupt.note(busy)
    },
    Tool(name: "chrome_click", description: "Click a button or link on the open Chrome page by its text (e.g. Submit). Only when the user asked.",
         params: ["text": "Button or link text", "url_contains": "(optional) part of the tab URL to pick the tab"], risk: .confirm) { a in
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        let r = try await Chrome.eval("""
        ((t)=>{t=t.toLowerCase();const el=[...document.querySelectorAll('button,[role=button],a,input[type=submit]')]
          .find(e=>((e.textContent||'')+(e.getAttribute('aria-label')||'')+(e.value||'')).toLowerCase().includes(t));
          if(!el)return 'not found';el.click();return 'clicked'})(\(Chrome.jsString(try a.str("text"))))
        """, tab: a.opt("url_contains"))
        return r + Interrupt.note(busy)
    },
]
