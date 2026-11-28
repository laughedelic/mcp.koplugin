// Plays the conversations on the landing page.
// The conversations themselves live in index.html: one <ol data-scenario> per tab.
// To change the demo, edit the HTML. This file only reveals the lines in turn
// and moves the reader from its "before" state to its "after" state.

(function () {
  var demo = document.querySelector("[data-demo]");
  if (!demo) return;

  var reader = demo.querySelector(".reader");
  var caption = demo.querySelector(".demo-caption");
  var tabs = Array.prototype.slice.call(demo.querySelectorAll(".demo-tabs button"));
  var scenarios = Array.prototype.slice.call(demo.querySelectorAll("[data-scenario]"));
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var timers = [];

  function later(ms, fn) {
    timers.push(setTimeout(fn, ms));
  }

  function setReader(page, mark) {
    if (reader.dataset.page !== page && !still) {
      reader.classList.remove("is-refreshing");
      void reader.offsetWidth; // restart the animation
      reader.classList.add("is-refreshing");
    }
    reader.dataset.page = page;
    reader.dataset.mark = mark;
  }

  function show(line) {
    line.classList.remove("is-waiting");
    line.classList.add("is-in");
  }

  function play(scenario) {
    timers.forEach(clearTimeout);
    timers = [];

    tabs.forEach(function (tab) {
      tab.setAttribute("aria-pressed", String(tab.dataset.play === scenario.id));
    });
    scenarios.forEach(function (s) {
      s.hidden = s !== scenario;
    });
    caption.textContent = scenario.dataset.caption;

    var d = scenario.dataset;
    var lines = Array.prototype.slice.call(scenario.children);
    var tools = scenario.querySelectorAll(".tool");
    var lastTool = tools[tools.length - 1];

    if (still) {
      lines.forEach(function (line) {
        line.classList.remove("is-waiting", "is-working", "is-in");
      });
      setReader(d.pageAfter, d.markAfter);
      return;
    }

    reader.classList.remove("is-refreshing");
    reader.dataset.page = d.pageBefore;
    reader.dataset.mark = d.markBefore;
    lines.forEach(function (line) {
      line.classList.remove("is-in", "is-working");
      line.classList.add("is-waiting");
    });

    var t = 500;
    lines.forEach(function (line) {
      if (line.classList.contains("tool")) {
        later(t, function () {
          line.classList.add("is-working");
          show(line);
        });
        t += 1100;
        later(t, function () {
          line.classList.remove("is-working");
          if (line === lastTool) {
            setReader(d.pageAfter, d.markAfter);
          }
        });
        t += 500;
      } else {
        later(t, function () {
          show(line);
        });
        t += 900;
      }
    });
  }

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      play(document.getElementById(tab.dataset.play));
    });
  });

  play(scenarios[0]);
})();
