# Bundled dependencies

The application ships all JavaScript locally; no CDN or Node.js runtime is required.

| Dependency | Version | License | Source |
|---|---|---|---|
| EPUB.js | 0.3.93 | BSD-2-Clause | https://github.com/futurepress/epub.js |
| JSZip | 3.10.1 | MIT (chosen from its dual license) | https://github.com/Stuk/jszip |

`Sources/LeafApp/Resources/Web/vendor/` contains the upstream minified distributions.
EPUB.js also bundles transitive dependencies. Their license notices, collected from the corresponding
upstream npm packages, are included in `EPUB.js-BUNDLED-LICENSES.txt`.

Native ZIP, MDict, RIPEMD-128 and LZO readers are implemented in this project. Format references:

- https://github.com/zhansliu/writemdict/blob/master/fileformat.md
- https://www.kernel.org/doc/html/latest/staging/lzo.html
- https://www.w3.org/publishing/epub32/epub-ocf.html#sec-resource-obfuscation

No dictionary definitions, fonts, or books from third parties are bundled. The guide and fixture dictionaries are original test content.
