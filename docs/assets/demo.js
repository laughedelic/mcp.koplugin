// Plays the story on the landing page.
// The story itself is the <ol data-story> list in index.html; the comment above it
// explains the format. To change what the demo says or shows, edit that list.
// This file only walks the list: it reveals each step in the chat and passes the
// step's directions (focus, page, mark, caption) on to the two devices.

(function () {
  var demo = document.querySelector("[data-demo]");
  if (!demo) return;

  var reader = demo.querySelector(".reader");
  var touch = demo.querySelector(".reader-touch");
  var caption = demo.querySelector("[data-caption]");
  var typed = demo.querySelector("[data-typed]");
  var replay = demo.querySelector("[data-replay]");
  var steps = Array.prototype.slice.call(demo.querySelectorAll("[data-story] > li"));
  var beats = Array.prototype.slice.call(demo.querySelectorAll("[data-goto]"));
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var timers = [];

  function wait(ms, fn) {
    timers.push(setTimeout(fn, ms));
  }

  function indexOfBeat(button) {
    return steps.indexOf(document.getElementById(button.dataset.goto));
  }

  function showBeat(i) {
    beats.forEach(function (button, n) {
      var next = beats[n + 1] ? indexOfBeat(beats[n + 1]) : steps.length;
      button.setAttribute("aria-pressed", String(i >= indexOfBeat(button) && i < next));
    });
  }

  // The finger that selects the passage: it lands on the first word and drags to the last.
  function press() {
    var mark = reader.querySelector('.reader-page[data-p="' + reader.dataset.page + '"] .passage');
    var rects = mark && mark.getClientRects();
    if (!rects || !rects.length) return;
    var screen = touch.parentNode.getBoundingClientRect();
    var first = rects[0];
    var last = rects[rects.length - 1];
    touch.style.left = first.left - screen.left + "px";
    touch.style.top = first.top - screen.top + first.height / 2 + "px";
    touch.style.setProperty("--drag-x", last.right - first.left + "px");
    touch.style.setProperty("--drag-y", last.top - first.top + "px");
    restart(touch, "is-pressing");
  }

  function restart(element, className) {
    element.classList.remove(className);
    void element.offsetWidth;
    element.classList.add(className);
  }

  function setReader(d, quiet) {
    if (d.page && d.page !== reader.dataset.page) {
      reader.dataset.page = d.page;
      if (!quiet) restart(reader, "is-refreshing");
    }
    if (d.mark) {
      reader.dataset.mark = d.mark;
      if (d.mark === "select" && !quiet) press();
    }
  }

  // Passes a step's directions on to the devices. "quiet" skips the animations.
  function direct(step, quiet) {
    var d = step.dataset;
    var turning = d.focus && d.focus !== demo.dataset.focus;
    if (d.focus) demo.dataset.focus = d.focus;
    if (d.caption) caption.textContent = d.caption;
    if (turning && !quiet) {
      // Let the device come forward first, so the change on it is seen happening.
      wait(700, function () {
        setReader(d);
      });
    } else {
      setReader(d, quiet);
    }
  }

  function reveal(step, quiet) {
    step.classList.remove("is-waiting", "is-working");
    if (!quiet) step.classList.add("is-in");
  }

  function type(text, done) {
    var n = 0;
    (function key() {
      typed.textContent = text.slice(0, n);
      if (n++ < text.length) return wait(22, key);
      wait(450, function () {
        typed.textContent = "";
        done();
      });
    })();
  }

  function play(i) {
    var step = steps[i];
    if (!step) {
      replay.hidden = false;
      return;
    }
    var next = function () {
      play(i + 1);
    };
    var pause = Number(step.dataset.wait);
    showBeat(i);
    direct(step);

    if (step.classList.contains("you")) {
      wait(700, function () {
        type(step.textContent, function () {
          reveal(step);
          wait(pause || 700, next);
        });
      });
    } else if (step.classList.contains("tool")) {
      reveal(step);
      step.classList.add("is-working");
      wait(pause || 1300, function () {
        step.classList.remove("is-working");
        wait(400, next);
      });
    } else if (step.classList.contains("ai")) {
      wait(500, function () {
        reveal(step);
        wait(pause || 1000 + step.textContent.length * 22, next);
      });
    } else {
      wait(pause || 1800, next);
    }
  }

  // Puts the demo in the state it has just before step i, without animating.
  function rewind(i) {
    timers.forEach(clearTimeout);
    timers = [];
    typed.textContent = "";
    replay.hidden = true;
    reader.classList.remove("is-refreshing");
    touch.classList.remove("is-pressing");
    steps.forEach(function (step, n) {
      step.classList.remove("is-in", "is-working");
      step.classList.toggle("is-waiting", n >= i);
      if (n < i) direct(step, true);
    });
  }

  function start(i) {
    if (still) {
      // No motion: show how the chapter ends instead of playing it.
      var beat = beats.filter(function (button) {
        return indexOfBeat(button) <= i;
      }).length;
      var end = beats[beat] ? indexOfBeat(beats[beat]) : steps.length;
      rewind(end);
      showBeat(i);
      return;
    }
    rewind(i);
    play(i);
  }

  beats.forEach(function (button) {
    button.addEventListener("click", function () {
      start(indexOfBeat(button));
    });
  });
  replay.addEventListener("click", function () {
    start(0);
  });
  Array.prototype.forEach.call(demo.querySelectorAll("[data-device]"), function (device) {
    device.addEventListener("click", function () {
      demo.dataset.focus = device.dataset.device;
    });
  });

  // Get ready on the first step, then begin once the demo has scrolled into view.
  rewind(0);
  direct(steps[0], true);
  showBeat(0);
  if (still || !("IntersectionObserver" in window)) {
    start(0);
  } else {
    var seen = new IntersectionObserver(
      function (entries) {
        if (!entries[0].isIntersecting) return;
        seen.disconnect();
        start(0);
      },
      { threshold: 0.6 }
    );
    seen.observe(demo.querySelector(".demo-stage"));
  }
})();
