# Website

The landing page and docs for the plugin, published to GitHub Pages by `.github/workflows/pages.yml`.

- `index.html` is the landing page. It is a plain HTML file.
- `*.md` are the docs pages. They share `_layouts/docs.html`; the sidebar order is in `_data/nav.yml`.
- `assets/` has the styles, fonts, icon and the demo script.

Every link is relative, so the site works at any address and `index.html` opens straight from disk.

## Preview

```sh
gem install github-pages   # once
jekyll serve --source docs
```

## Changing the demo

The demo on the landing page is one story, written in `index.html` as the list `<ol data-story>`: chat lines, plus cues that say which device is in focus, what the reader shows and what the caption says. The comment above the list explains the format. Edit the list to change the demo. A step with an `id` starts a chapter, and each chapter has a button with a progress bar above the devices. `assets/demo.js` only plays the list and works out the timing from it, so it doesn't need to change unless the mechanics do.

## Fonts

[Literata](https://github.com/googlefonts/literata) and [Atkinson Hyperlegible Next](https://www.brailleinstitute.org/freefont/) are served from `assets/fonts/` under the SIL Open Font License 1.1.
