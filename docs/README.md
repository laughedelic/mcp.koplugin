# Website

The landing page and docs for the plugin, published to GitHub Pages by `.github/workflows/pages.yml`.

- `index.html` is the landing page. It is a plain HTML file.
- `*.md` are the docs pages. They share `_layouts/docs.html`; the sidebar order is in `_data/nav.yml`.
- `assets/` has the styles, fonts, icon and the demo script.
- `mocks/` has alternative landing page ideas, kept for comparison. It isn't linked from the site.

Every link is relative, so the site works at any address and `index.html` opens straight from disk.

## Preview

```sh
gem install github-pages   # once
jekyll serve --source docs
```

## Changing the demo

The conversations on the landing page are written in `index.html`, one `<ol data-scenario>` per tab, next to the two book pages the reader shows. Edit the text there. `assets/demo.js` only plays them and doesn't need to change unless the mechanics do.

## Fonts

[Literata](https://github.com/googlefonts/literata) and [Atkinson Hyperlegible Next](https://www.brailleinstitute.org/freefont/) are served from `assets/fonts/` under the SIL Open Font License 1.1.
