// Use the embedded New Computer Modern base and load supplemental SVG paths from the app.
window.MathJax = {
  loader: {paths: {fonts: '[mathjax]/stix'}},
  startup: {
    typeset: false,
    ready() {
      const svg = MathJax.config.svg;
      class OfflineFont extends svg.fontData {}
      OfflineFont.dynamicFiles = OfflineFont.defineDynamicFiles(window.SimaGlyphRanges);
      svg.fontData = OfflineFont;
      svg.dynamicPrefix = '[mathjax]/stix';
      MathJax.startup.defaultReady();
      MathJax.startup.document.addStyleSheet();
    }
  },
  tex: {tags: 'ams'},
  svg: {fontCache: 'none'}
};
