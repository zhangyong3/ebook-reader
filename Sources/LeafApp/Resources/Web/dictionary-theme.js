/* Runs in WKContentWorld.defaultClient. Dictionary-supplied JavaScript remains disabled.
   CSS cannot override an inline !important, so suspend only authored paint properties
   in dark mode and restore them exactly when returning to light mode. */
(() => {
    const properties = ['color', 'background', 'background-color', '-webkit-text-fill-color', 'text-shadow', 'opacity'];
    const originals = new Map();
    function apply() {
        if (document.documentElement.dataset.leafTheme === 'dark') {
            for (const element of document.querySelectorAll('[style]')) {
                if (originals.has(element)) continue;
                const saved = [];
                for (const property of properties) {
                    const value = element.style.getPropertyValue(property);
                    if (value) saved.push([property, value, element.style.getPropertyPriority(property)]);
                }
                if (!saved.length) continue;
                originals.set(element, saved);
                const hasImage = /url\(/i.test(element.style.getPropertyValue('background'));
                for (const property of properties) {
                    if (property === 'background' && hasImage) continue;
                    element.style.removeProperty(property);
                }
            }
        } else {
            for (const [element, saved] of originals) {
                for (const [property, value, priority] of saved) element.style.setProperty(property, value, priority);
            }
            originals.clear();
        }
    }
    apply();
    window.leafSetDictionaryAppearance = dark => {
        document.documentElement.dataset.leafTheme = dark ? 'dark' : 'light';
        apply();
    };
})();
