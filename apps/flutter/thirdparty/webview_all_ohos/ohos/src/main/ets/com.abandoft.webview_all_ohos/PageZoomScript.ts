/** Builds page-wide content zoom for ArkWeb versions without absolute page zoom. */
export function buildPageZoomScript(factor: number): string {
  if (!Number.isFinite(factor) || factor <= 0) throw new Error('Invalid page zoom factor');
  return `(function() {
    if (window.top !== window) return;
    var factor = ${factor};
    function apply() {
      var root = document.documentElement;
      if (!root) return false;
      var key = '__operitPageZoomState';
      var state = root[key];
      if (!state) {
        if (factor === 1) return true;
        state = {
          value: root.style.getPropertyValue('zoom'),
          priority: root.style.getPropertyPriority('zoom'),
          base: parseFloat(getComputedStyle(root).zoom) || 1
        };
        root[key] = state;
      }
      if (factor === 1) {
        if (state.value) root.style.setProperty('zoom', state.value, state.priority);
        else root.style.removeProperty('zoom');
        delete root[key];
      } else {
        root.style.setProperty('zoom', String(state.base * factor), 'important');
      }
      return true;
    }
    if (!apply()) {
      var observer = new MutationObserver(function() {
        if (apply()) observer.disconnect();
      });
      observer.observe(document, {childList: true, subtree: true});
    }
  })();`;
}
