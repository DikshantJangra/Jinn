"""
Text-first Mac control for Gemma. The model never sees pixels: the screen is a numbered text menu.
Tiers, cheapest first: web (Chrome DevTools) -> applescript -> Accessibility API -> CGEvent posted to the app's pid.
All input is delivered to the target app only (background-first); the user keeps their cursor and keyboard.
Needs macOS + `pip install jinn[hands]`; every heavy import is lazy so this module imports anywhere.
Run the app as a bundle (py2app) so Jinn itself, not Terminal, holds the Accessibility/Automation permission.
"""

import json
import re
import subprocess
import time
from typing import Any, Callable, Dict, List

CDP_URL = "http://localhost:9222"
CHROME_HINT = ("Chrome is not reachable. Start it with: open -na 'Google Chrome' "
               "--args --remote-debugging-port=9222 --user-data-dir=$HOME/.jinn-chrome")
MAX_NODES = 400
INTERACTIVE = {"AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
               "AXComboBox", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXSearchField", "AXRow"}
BLOCKED_APPS = ("terminal", "iterm", "script editor", "system settings", "system preferences", "keychain", "automator", "shortcuts")
RISKY_CLICK = re.compile(r"submit|send|pay|buy|delete|remove|confirm|place order", re.I)

_labels: Dict[int, str] = {}  # id -> label of the latest snapshot, so the confirm gate can judge a click by what it presses
_els: Dict[int, Any] = {}     # id -> AXUIElement of the latest snapshot (ponytail: one global snapshot; key by app if agents run in parallel)
_pw: Dict[str, Any] = {}      # cached Playwright connection


def _mac():
    try:
        import AppKit, ApplicationServices as AS, Quartz  # noqa: E401
    except ImportError as e:
        raise RuntimeError("macOS only: pip install 'jinn[hands]' (pyobjc)") from e
    return AppKit, AS, Quartz


# ---------- pure helpers (tested without a Mac) ----------

def format_nodes(nodes: List[Dict[str, Any]]) -> str:
    """Numbered text menu the model reads: `[id] Role "label" = "value"`."""
    out = []
    for n in nodes:
        s = f'[{n["id"]}] {n["role"].removeprefix("AX")}'
        if n.get("secure"):
            s += " (password field)"
        if n.get("label"):
            s += f' "{n["label"][:70]}"'
        if n.get("value") and n["value"] != n.get("label"):
            s += f' = "{n["value"][:70]}"'
        out.append(s)
    return "\n".join(out) or "(no elements)"


def wait_idle(idle: Callable[[], float], sleep: Callable[[float], None] = time.sleep, limit: float = 5.0, quiet: float = 0.6) -> float:
    """User-interruption backoff: wait until the user has been idle `quiet` seconds, at most `limit`. Returns seconds waited."""
    waited = 0.0
    while idle() < quiet and waited < limit:
        sleep(0.3)
        waited += 0.3
    return waited


def _idle() -> float:
    _, _, Q = _mac()
    return Q.CGEventSourceSecondsSinceLastEventType(Q.kCGEventSourceStateCombinedSessionState, Q.kCGAnyInputEventType)


# ---------- tier 3: Accessibility API ----------

def _attr(AS, el, name):
    err, val = AS.AXUIElementCopyAttributeValue(el, name, None)
    return val if err == 0 else None


def _find_app(name: str):
    AppKit, _, _ = _mac()
    n = name.lower()
    apps = [a for a in AppKit.NSWorkspace.sharedWorkspace().runningApplications() if a.activationPolicy() == 0]
    hit = next((a for a in apps if (a.localizedName() or "").lower() == n), None) or \
        next((a for a in apps if n in (a.localizedName() or "").lower()), None)
    if not hit:
        raise RuntimeError(f"app not running: {name} (open it first)")
    if any(b in (hit.localizedName() or "").lower() for b in BLOCKED_APPS):
        raise RuntimeError(f"blocked: Jinn does not drive {hit.localizedName()}")
    return hit


def snapshot(app: str) -> str:
    """Text list of the app's front window. Ids are valid until the next snapshot of any app."""
    _, AS, _ = _mac()
    if not AS.AXIsProcessTrusted():
        raise RuntimeError("Accessibility permission is off: System Settings > Privacy & Security > Accessibility")
    target = _find_app(app)
    root = AS.AXUIElementCreateApplication(target.processIdentifier())
    AS.AXUIElementSetAttributeValue(root, "AXManualAccessibility", True)  # wakes Electron/Chromium trees
    win = _attr(AS, root, "AXFocusedWindow") or _attr(AS, root, "AXMainWindow") or (_attr(AS, root, "AXWindows") or [root])[0]
    _els.clear()
    _labels.clear()
    nodes, stack = [], [win]
    seen = 0
    while stack and seen < 3000:
        el = stack.pop()
        seen += 1
        role = _attr(AS, el, "AXRole") or ""
        label = next((v for v in (_attr(AS, el, "AXTitle"), _attr(AS, el, "AXDescription"), _attr(AS, el, "AXPlaceholderValue")) if isinstance(v, str) and v), "")
        val = _attr(AS, el, "AXValue")
        sub = _attr(AS, el, "AXSubrole") or ""
        value = "" if sub == "AXSecureTextField" else (val if isinstance(val, str) else "")
        if (role in INTERACTIVE or label or value) and len(nodes) < MAX_NODES and role not in ("AXGroup", "AXScrollArea", "AXSplitGroup"):
            _els[len(nodes)] = el
            _labels[len(nodes)] = label or value
            nodes.append({"id": len(nodes), "role": role, "label": label, "value": value, "secure": sub == "AXSecureTextField"})
        stack.extend(reversed(_attr(AS, el, "AXChildren") or []))
    if not nodes:
        raise RuntimeError(f"{app} exposes no accessibility tree (no window, or it blocks AX)")
    return f'App: {target.localizedName()}, window "{_attr(AS, win, "AXTitle") or ""}"\n' + format_nodes(nodes)


def _el(element_id: Any):
    try:
        return _els[int(element_id)]
    except (KeyError, ValueError):
        raise RuntimeError("unknown element id; call snapshot again and use its ids")


def _center(AS, el):
    pos, size = _attr(AS, el, "AXPosition"), _attr(AS, el, "AXSize")
    if pos is None or size is None:
        return None
    p = AS.AXValueGetValue(pos, AS.kAXValueCGPointType, None)[1]
    s = AS.AXValueGetValue(size, AS.kAXValueCGSizeType, None)[1]
    return p.x + s.width / 2, p.y + s.height / 2


def click(app: str, element_id: Any) -> str:
    """AXPress first; else a synthetic click posted to the app's pid (no cursor movement)."""
    _, AS, Q = _mac()
    el, pid = _el(element_id), _find_app(app).processIdentifier()
    wait_idle(_idle)
    if AS.AXUIElementPerformAction(el, "AXPress") == 0:
        return f"pressed [{element_id}]"
    c = _center(AS, el)
    if not c:
        raise RuntimeError(f"[{element_id}] cannot be pressed and has no position")
    for kind in (Q.kCGEventLeftMouseDown, Q.kCGEventLeftMouseUp):
        Q.CGEventPostToPid(pid, Q.CGEventCreateMouseEvent(None, kind, c, Q.kCGMouseButtonLeft))
    return f"clicked [{element_id}] at {int(c[0])},{int(c[1])}"


def type_text(app: str, element_id: Any, text: str) -> str:
    """Set the field's AXValue; else focus it and post unicode keystrokes to the app's pid. Never touches password fields."""
    _, AS, Q = _mac()
    el, pid = _el(element_id), _find_app(app).processIdentifier()
    if _attr(AS, el, "AXSubrole") == "AXSecureTextField":
        raise RuntimeError("blocked: Jinn does not fill password fields; ask the user")
    wait_idle(_idle)
    if AS.AXUIElementSetAttributeValue(el, "AXValue", text) == 0:
        return f"set [{element_id}]"
    AS.AXUIElementSetAttributeValue(el, "AXFocused", True)
    for ch in text:
        for down in (True, False):
            ev = Q.CGEventCreateKeyboardEvent(None, 0, down)
            Q.CGEventKeyboardSetUnicodeString(ev, len(ch), ch)
            Q.CGEventPostToPid(pid, ev)
    return f"typed into [{element_id}]"


# ---------- tier 2: AppleScript ----------

def applescript(src: str) -> str:
    r = subprocess.run(["osascript", "-e", src], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError((r.stderr.strip() or "osascript failed") + " (grant Automation to Jinn in System Settings if blocked)")
    return r.stdout.strip()


# ---------- tier 1: web over Chrome DevTools Protocol ----------

def _page(url_contains: str = ""):
    if "browser" not in _pw:
        try:
            from playwright.sync_api import sync_playwright
        except ImportError as e:
            raise RuntimeError("pip install 'jinn[hands]' (Playwright, used only to talk to your running Chrome)") from e
        _pw["p"] = sync_playwright().start()
        try:
            _pw["browser"] = _pw["p"].chromium.connect_over_cdp(CDP_URL)
        except Exception:
            _pw["p"].stop()
            _pw.clear()
            raise RuntimeError(CHROME_HINT)
    pages = [p for c in _pw["browser"].contexts for p in c.pages]
    hit = [p for p in pages if url_contains in p.url or url_contains in p.title()]
    if not hit:
        raise RuntimeError(f"no Chrome tab matches '{url_contains}'")
    return hit[0]


_FIELDS_JS = """() => [...document.querySelectorAll('input,textarea,select,[role=radio],[role=checkbox]')]
 .filter(e => e.offsetParent !== null && !['hidden','submit','button'].includes(e.type)).map(e => {
  const t = n => (n && n.textContent || '').trim(), lb = e.getAttribute('aria-labelledby');
  const label = (lb && lb.split(' ').map(i => t(document.getElementById(i))).join(' ').trim()) || e.getAttribute('aria-label') ||
    e.getAttribute('data-value') || (e.id && t(document.querySelector('label[for="' + CSS.escape(e.id) + '"]'))) || t(e.closest('label')) || e.placeholder || e.name || '';
  const h = e.closest('[role=listitem],fieldset'), q = h && h.querySelector('[role=heading],legend');
  return {label, question: q ? t(q) : '', type: e.type || e.getAttribute('role'), value: e.type === 'password' ? '' : (e.value || '')};
 })"""


def web_read(url_contains: str = "") -> str:
    """Tab title, URL, visible text and form fields (label, question, type, value)."""
    p = _page(url_contains)
    return json.dumps({"title": p.title(), "url": p.url, "text": p.inner_text("body")[:3000], "fields": p.evaluate(_FIELDS_JS)})


def web_fill(target: str, value: str, url_contains: str = "") -> str:
    """Fill by label (fuzzy), then placeholder, then CSS selector. Radios/checkboxes are checked by option text."""
    p = _page(url_contains)
    for loc in (p.get_by_label(target), p.get_by_role("radio", name=target), p.get_by_role("checkbox", name=target),
                p.get_by_placeholder(target)) + ((p.locator(target),) if re.match(r"^[#.\[]|^\w+[#.\[]", target) else ()):
        if loc.count() == 0:
            continue
        el = loc.first
        kind = el.evaluate("e => e.type || e.getAttribute('role') || e.tagName.toLowerCase()")
        if kind == "password":
            raise RuntimeError("blocked: Jinn does not fill password fields; ask the user")
        if kind in ("radio", "checkbox"):
            el.click(timeout=3000)
        elif kind == "select":
            el.select_option(label=value, timeout=3000)
        else:
            el.fill(value, timeout=3000)
        return f"ok: {target}"
    raise RuntimeError(f"no field matches '{target}'. Fields: {[f['label'] or f['question'] for f in json.loads(web_read(url_contains))['fields']]}")


def web_click(target: str, url_contains: str = "") -> str:
    p = _page(url_contains)
    for loc in (p.get_by_role("button", name=target), p.get_by_role("link", name=target), p.get_by_text(target, exact=False)):
        if loc.count():
            loc.first.click(timeout=3000)
            return f"clicked {target}"
    raise RuntimeError(f"nothing to click matching '{target}'")


# ---------- tool surface for Gemma ----------

def _t(name: str, desc: str, **params: str) -> Dict[str, Any]:
    return {"type": "function", "function": {"name": name, "description": desc, "parameters": {
        "type": "object", "properties": {k: {"type": "string", "description": v} for k, v in params.items()},
        "required": [k for k, v in params.items() if not v.startswith("(optional)")]}}}


TOOLS = [
    _t("snapshot", "Read an app's window as a numbered text list of elements. Call before click/type_text.", app="App name, e.g. Mail"),
    _t("click", "Press a button/link/menu item by id from the latest snapshot.", app="App name", element_id="id from snapshot"),
    _t("type_text", "Put text in a field by id from the latest snapshot.", app="App name", element_id="id from snapshot", text="Text"),
    _t("applescript", "Run AppleScript for scriptable apps (Mail, Messages, Finder, Notes, Calendar, Safari). Asks the user first.", src="AppleScript source"),
    _t("web_read", "Read a Chrome tab: title, url, text and form fields. Use for any website or Google Form.", url_contains="(optional) part of tab URL/title"),
    _t("web_fill", "Fill a web field by its label/placeholder/selector; radios and checkboxes by option text.", target="Label or selector", value="Value", url_contains="(optional) tab filter"),
    _t("web_click", "Click a web button/link by its text. Asks the user first for Submit/Send/Pay/Delete.", target="Button text", url_contains="(optional) tab filter"),
]
NEEDS_CONFIRM = {"applescript", "type_text"}


def _web_risky(target: str, url_contains: str) -> bool:
    """Judge the element that would really be clicked (submit button, risky wording), not just the model's words."""
    try:
        p = _page(url_contains)
        for loc in (p.get_by_role("button", name=target), p.get_by_role("link", name=target), p.get_by_text(target, exact=False)):
            if loc.count():
                return bool(loc.first.evaluate(
                    "(e, rx) => e.type === 'submit' || (e.tagName === 'BUTTON' && !!e.closest('form') && e.type !== 'button') || new RegExp(rx, 'i').test(e.innerText || e.value || e.getAttribute('aria-label') || '')",
                    RISKY_CLICK.pattern))
    except Exception:
        pass
    return True  # cannot tell -> ask


def needs_confirm(name: str, args: Dict[str, Any]) -> bool:
    """Fail closed: scripts, typing, and anything that looks like submit/send/pay/delete ask the user first."""
    if name in NEEDS_CONFIRM:
        return True
    if name == "click":
        try:
            return bool(RISKY_CLICK.search(_labels.get(int(args.get("element_id")), "x")))  # unknown id -> label "x" is not risky, call() then errors
        except (TypeError, ValueError):
            return True
    if name == "web_click":
        return bool(RISKY_CLICK.search(str(args.get("target", "")))) or _web_risky(str(args.get("target", "")), str(args.get("url_contains", "")))
    return False


def call(name: str, args: Dict[str, Any]) -> str:
    fn = {"snapshot": snapshot, "click": click, "type_text": type_text, "applescript": applescript,
          "web_read": web_read, "web_fill": web_fill, "web_click": web_click}.get(name)
    if not fn:
        raise RuntimeError(f"unknown tool {name}; available: snapshot, click, type_text, applescript, web_read, web_fill, web_click")
    return str(fn(**{k: v for k, v in args.items() if v is not None}))
