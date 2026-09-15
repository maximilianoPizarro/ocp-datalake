(function () {
  var root = document.getElementById("journey-carousel");
  if (!root) return;
  var slides = Array.prototype.slice.call(root.querySelectorAll(".journey-slide"));
  var dotsWrap = document.getElementById("journey-dots");
  var statusEl = document.getElementById("journey-status");
  var prevBtn = document.getElementById("journey-prev");
  var nextBtn = document.getElementById("journey-next");
  var fsBtn = document.getElementById("journey-fs");
  var chapters = Array.prototype.slice.call(document.querySelectorAll("[data-slide]"));
  var index = 0;
  var timer = null;
  var touchX = null;
  var fsOpen = false;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var chapterAt = chapters.map(function (b) {
    return parseInt(b.getAttribute("data-slide"), 10);
  });

  function setFullscreen(on) {
    fsOpen = on;
    root.classList.toggle("is-fullscreen", on);
    document.body.classList.toggle("journey-fs-open", on);
    if (fsBtn) {
      fsBtn.setAttribute("aria-pressed", on ? "true" : "false");
      fsBtn.textContent = on ? "Salir" : "Fullscreen";
    }
    if (on) stop();
    else restart();
  }

  slides.forEach(function (_, i) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "journey-dot";
    b.setAttribute("role", "tab");
    b.setAttribute("aria-label", "Ir al paso " + (i + 1));
    b.addEventListener("click", function () {
      go(i, true);
    });
    dotsWrap.appendChild(b);
  });

  function chapterFor(i) {
    var current = 0;
    chapterAt.forEach(function (n, idx) {
      if (i >= n) current = idx;
    });
    return current;
  }

  function go(n, user) {
    index = (n + slides.length) % slides.length;
    slides.forEach(function (s, i) {
      var on = i === index;
      s.classList.toggle("is-active", on);
      if (on) s.removeAttribute("hidden");
      else s.setAttribute("hidden", "");
      s.setAttribute("aria-hidden", on ? "false" : "true");
    });
    Array.prototype.forEach.call(dotsWrap.children, function (d, i) {
      if (i === index) d.setAttribute("aria-current", "true");
      else d.removeAttribute("aria-current");
    });
    chapters.forEach(function (b, i) {
      if (i === chapterFor(index)) b.setAttribute("aria-current", "true");
      else b.removeAttribute("aria-current");
    });
    statusEl.textContent = index + 1 + " / " + slides.length;
    if (user) {
      history.replaceState(null, "", "#journey-slide-" + index);
    }
    if (user && !fsOpen) restart();
  }

  function restart() {
    stop();
    if (!reduced) timer = setInterval(function () {
      go(index + 1, false);
    }, 8000);
  }
  function stop() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  if (prevBtn)
    prevBtn.addEventListener("click", function () {
      go(index - 1, true);
    });
  if (nextBtn)
    nextBtn.addEventListener("click", function () {
      go(index + 1, true);
    });
  if (fsBtn)
    fsBtn.addEventListener("click", function () {
      setFullscreen(!fsOpen);
    });
  chapters.forEach(function (b) {
    b.addEventListener("click", function () {
      go(parseInt(b.getAttribute("data-slide"), 10), true);
      root.focus({ preventScroll: true });
    });
  });

  root.addEventListener("keydown", function (e) {
    if (e.key === "ArrowLeft") {
      go(index - 1, true);
      e.preventDefault();
    } else if (e.key === "ArrowRight") {
      go(index + 1, true);
      e.preventDefault();
    } else if (e.key === "f" || e.key === "F") {
      setFullscreen(!fsOpen);
      e.preventDefault();
    } else if (e.key === "Escape" && fsOpen) {
      setFullscreen(false);
      e.preventDefault();
    }
  });
  root.addEventListener("mouseenter", stop);
  root.addEventListener("mouseleave", function () {
    if (!fsOpen) restart();
  });
  root.addEventListener("touchstart", function (e) {
    touchX = e.changedTouches[0].screenX;
  }, { passive: true });
  root.addEventListener("touchend", function (e) {
    if (touchX === null) return;
    var dx = e.changedTouches[0].screenX - touchX;
    touchX = null;
    if (Math.abs(dx) > 40) go(dx < 0 ? index + 1 : index - 1, true);
  }, { passive: true });

  root.querySelectorAll(".journey-slide img").forEach(function (img) {
    img.addEventListener("click", function () {
      if (!fsOpen) setFullscreen(true);
    });
  });

  function applyHash() {
    var m = (location.hash || "").match(/^#journey-slide-(\d+)$/);
    if (!m) return;
    var n = parseInt(m[1], 10);
    if (isNaN(n) || n < 0 || n >= slides.length) return;
    go(n, true);
  }

  window.addEventListener("hashchange", applyHash);
  go(0, false);
  restart();
  applyHash();
  root.focus({ preventScroll: true });
})();
