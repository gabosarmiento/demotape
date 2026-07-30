/**
 * Where the caret is inside a field, as an offset from the field's own top-left corner.
 *
 * This runs in the BROWSER (it's handed to `page.evaluate`), and it lives in its own module so it can
 * be tested directly against real fields instead of only being exercised by a full recording run.
 *
 * Why it's not one line: the two kinds of field that matter behave nothing alike.
 *
 *  - `<input>` / `<textarea>` expose `.value` and `.selectionStart`, so the caret is found by
 *    measuring the text up to the selection in the field's own font — minus horizontal scroll, and
 *    counting only the current visual line for a textarea.
 *  - A `contenteditable` div — what most chat composers and rich editors actually use — has **no
 *    `.value` at all**. Measuring `el.value` there yields `undefined`, so an earlier version reported
 *    an offset of zero for every keystroke and the caret appeared pinned to the left edge of the
 *    field. In a zoomed frame that means the camera holds on the start of the input while the sentence
 *    grows off to the right, unread. For these, the selection's own client rect is exact and follows
 *    wrapped lines for free.
 *
 * Returns `{ dx, dy }` in CSS pixels relative to the element, or `null` when the element is gone.
 */
export function caretOffsetInElement(selector) {
  const el = document.querySelector(selector);
  if (!el) return null;
  const rect = el.getBoundingClientRect();
  const tag = (el.tagName || "").toLowerCase();

  const measurer = (element) => {
    const cs = getComputedStyle(element);
    const c = document.createElement("canvas").getContext("2d");
    c.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
    return { ctx: c, cs };
  };

  if (tag === "input" || tag === "textarea") {
    const { ctx, cs } = measurer(el);
    const value = el.value ?? "";
    // Up to the caret, not the whole value: the two differ the moment the caret isn't at the end.
    const upto = value.slice(0, el.selectionStart ?? value.length);
    // A textarea wraps, so only the current visual line contributes to the x offset.
    const line = upto.slice(upto.lastIndexOf("\n") + 1);
    const padLeft = parseFloat(cs.paddingLeft) || 0;
    const lineHeight = parseFloat(cs.lineHeight) || rect.height;
    const rows = (upto.match(/\n/g) || []).length;
    const dx = Math.min(padLeft + ctx.measureText(line).width - (el.scrollLeft || 0),
                        Math.max(0, el.clientWidth - 8));
    const dy = Math.min(rows * lineHeight + lineHeight / 2, Math.max(0, rect.height - 4));
    return { dx: Math.max(0, dx), dy };
  }

  // contenteditable and anything else: ask the selection where it actually is.
  const sel = document.getSelection?.();
  if (sel && sel.rangeCount > 0) {
    const range = sel.getRangeAt(0).cloneRange();
    range.collapse(false);
    let r = range.getBoundingClientRect();
    // A collapsed range at the end of a text node can report an empty rect; fall back to the last
    // rect of the containing element's contents, which is where the text currently ends.
    if (!r || (r.width === 0 && r.height === 0 && r.left === 0)) {
      const rects = range.startContainer?.parentElement?.getClientRects?.();
      if (rects && rects.length) r = rects[rects.length - 1];
    }
    if (r && (r.left || r.top)) {
      return {
        dx: Math.max(0, r.left - rect.left),
        dy: Math.max(0, r.top - rect.top + r.height / 2),
      };
    }
  }

  // Last resort: measure the rendered text of the last line.
  const { ctx, cs } = measurer(el);
  const padLeft = parseFloat(cs.paddingLeft) || 0;
  const text = el.innerText ?? el.textContent ?? "";
  const last = text.slice(text.lastIndexOf("\n") + 1);
  return {
    dx: Math.min(padLeft + ctx.measureText(last).width, Math.max(0, rect.width - 8)),
    dy: rect.height / 2,
  };
}
