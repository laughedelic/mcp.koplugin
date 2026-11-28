// Plays the story on the landing page.
// The story itself is the <ol data-story> list in index.html; the comment above it
// explains the format. To change what the demo says or shows, edit that list.
// This file only walks the list: it reveals each step in the chat and passes the
// step's directions (focus, page, mark, caption) on to the two devices.
//
// Time is kept by one clock that only runs while the story is playing. That is what
// makes pausing possible, and what the chapter bars measure.

(function () {
  var demo = document.querySelector("[data-demo]");
  if (!demo) return;

  var reader = demo.querySelector(".reader");
  var touch = demo.querySelector(".reader-touch");
  var caption = demo.querySelector("[data-caption]");
  var typed = demo.querySelector("[data-typed]");
  var replay = demo.querySelector("[data-replay]");
  var toggle = demo.querySelector("[data-toggle]");
  var steps = Array.prototype.slice.call(demo.querySelectorAll("[data-story] > li"));
  var beats = Array.prototype.slice.call(demo.querySelectorAll("[data-goto]"));
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var clock = 0; // milliseconds of story played so far
  var base = 0; // the moment "now" for whoever is scheduling
  var queue = [];
  var frame = 0;
  var lastFrame = 0;
  var chapter = { from: 0, length: 1, index: 0 };
  var started = false;

  function wait(ms, fn) {
    queue.push({ at: base + ms, fn: fn });
  }

  function tick(now) {
    clock += Math.min(now - lastFrame, 100);
    lastFrame = now;
    for (;;) {
      queue.sort(function (a, b) {
        return a.at - b.at;
      });
      if (!queue.length || queue[0].at > clock) break;
      var due = queue.shift();
      base = due.at;
      due.fn();
    }
    base = clock;
    drawProgress();
    if (demo.dataset.state === "playing") frame = requestAnimationFrame(tick);
  }

  function setState(state) {
    demo.dataset.state = state;
    toggle.setAttribute("aria-label", { playing: "Pause", paused: "Play", ended: "Play again" }[state]);
    replay.hidden = state !== "ended";
    cancelAnimationFrame(frame);
    if (state === "playing") {
      lastFrame = performance.now();
      frame = requestAnimationFrame(tick);
    }
  }

  // How long each part of a step takes. play() and the chapter bars both use this.
  function timing(step) {
    var hold = Number(step.dataset.wait);
    var letters = step.textContent.trim().length;
    if (step.classList.contains("you")) return { lead: 700, typing: letters * 22 + 450, hold: hold || 700 };
    if (step.classList.contains("tool")) return { lead: 0, typing: 0, hold: (hold || 1300) + 400 };
    if (step.classList.contains("ai")) return { lead: 500, typing: 0, hold: hold || 1000 + letters * 22 };
    return { lead: 0, typing: 0, hold: hold || 1800 };
  }

  function beatAt(i) {
    var n = 0;
    beats.forEach(function (button, k) {
      if (indexOfBeat(button) <= i) n = k;
    });
    return n;
  }

  function endOfBeat(n) {
    return beats[n + 1] ? indexOfBeat(beats[n + 1]) : steps.length;
  }

  function drawProgress(done) {
    beats.forEach(function (button, n) {
      var played = n < chapter.index ? 1 : n > chapter.index ? 0 : (clock - chapter.from) / chapter.length;
      button.style.setProperty("--played", done ? 1 : Math.max(0, Math.min(1, played)));
      button.setAttribute("aria-current", String(n === chapter.index));
    });
  }

  // Called when step i begins: notes which chapter it is in and how long that chapter runs.
  function enterChapter(i) {
    var n = beatAt(i);
    if (i !== indexOfBeat(beats[n]) && n === chapter.index) return;
    var length = 0;
    for (var k = i; k < endOfBeat(n); k++) {
      var t = timing(steps[k]);
      length += t.lead + t.typing + t.hold;
    }
    chapter = { from: base, length: length, index: n };
  }

  function indexOfBeat(button) {
    return steps.indexOf(document.getElementById(button.dataset.goto));
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
      drawProgress(true);
      setState("ended");
      return;
    }
    var t = timing(step);
    var next = function () {
      play(i + 1);
    };
    enterChapter(i);
    direct(step);

    if (step.classList.contains("you")) {
      wait(t.lead, function () {
        type(step.textContent.trim(), function () {
          reveal(step);
          wait(t.hold, next);
        });
      });
    } else if (step.classList.contains("tool")) {
      reveal(step);
      step.classList.add("is-working");
      wait(t.hold - 400, function () {
        step.classList.remove("is-working");
        wait(400, next);
      });
    } else if (step.classList.contains("ai")) {
      wait(t.lead, function () {
        reveal(step);
        wait(t.hold, next);
      });
    } else {
      wait(t.hold, next);
    }
  }

  // Puts the demo in the state it has just before step i, without animating.
  function rewind(i) {
    queue = [];
    base = clock;
    typed.textContent = "";
    reader.classList.remove("is-refreshing");
    touch.classList.remove("is-pressing");
    steps.forEach(function (step, n) {
      step.classList.remove("is-in", "is-working");
      step.classList.toggle("is-waiting", n >= i);
      if (n < i) direct(step, true);
    });
    chapter = { from: clock, length: 1, index: beatAt(Math.min(i, steps.length - 1)) };
  }

  function start(i) {
    if (still) {
      // No motion: show how the chapter ends instead of playing it.
      var n = beatAt(i);
      rewind(endOfBeat(n));
      chapter.index = n;
      drawProgress();
      beats[n].style.setProperty("--played", 1);
      return;
    }
    started = true;
    rewind(i);
    play(i);
    setState("playing");
  }

  beats.forEach(function (button) {
    button.addEventListener("click", function () {
      start(indexOfBeat(button));
    });
  });
  replay.addEventListener("click", function () {
    start(0);
  });
  toggle.addEventListener("click", function () {
    var state = demo.dataset.state;
    if (state === "ended" || !started) start(0);
    else setState(state === "playing" ? "paused" : "playing");
  });
  Array.prototype.forEach.call(demo.querySelectorAll("[data-device]"), function (device) {
    device.addEventListener("click", function () {
      demo.dataset.focus = device.dataset.device;
    });
  });

  // Get ready on the first step, then begin once the demo has scrolled into view.
  rewind(0);
  direct(steps[0], true);
  drawProgress();
  toggle.hidden = still;
  if (still) {
    start(0);
  } else if (!("IntersectionObserver" in window)) {
    start(0);
  } else {
    demo.dataset.state = "paused";
    var seen = new IntersectionObserver(
      function (entries) {
        if (!entries[0].isIntersecting) return;
        seen.disconnect();
        if (!started) start(0);
      },
      { threshold: 0.6 }
    );
    seen.observe(demo.querySelector(".demo-stage"));
  }
})();
