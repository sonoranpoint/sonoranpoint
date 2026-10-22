/* Light/dark switch. Nothing saved = follow the device. The choice is kept in this browser under "sp.theme",
   the same key the dashboard uses, so the demo dashboard opens in the same mode. */
(function () {
  var root = document.documentElement;
  try { var saved = localStorage.getItem("sp.theme"); if (saved === "light" || saved === "dark") root.dataset.theme = saved; } catch (e) {}
  function current() {
    if (root.dataset.theme) return root.dataset.theme;
    return window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  function label(btn) {
    var dark = current() === "dark";
    btn.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
    btn.setAttribute("aria-pressed", dark ? "true" : "false");
    btn.title = dark ? "Light mode" : "Dark mode";
  }
  document.addEventListener("DOMContentLoaded", function () {
    var btns = document.querySelectorAll("[data-theme-toggle]");
    btns.forEach(function (btn) {
      label(btn);
      btn.addEventListener("click", function () {
        var next = current() === "dark" ? "light" : "dark";
        root.dataset.theme = next;
        try { localStorage.setItem("sp.theme", next); } catch (e) {}
        btns.forEach(label);
      });
    });
    if (window.matchMedia) matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () { btns.forEach(label); });
  });
})();
