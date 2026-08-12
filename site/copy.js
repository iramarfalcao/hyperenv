/*
  The one script on this site: a copy button for the install command.

  Written as an enhancement rather than a feature. The button is created here,
  in JavaScript, so a browser that cannot run it — or a request that fails to
  fetch it — is left with the command still selectable by a single click, rather
  than with a button that does nothing when pressed.

  The Clipboard API needs a secure context. Over https or on localhost that is
  satisfied; anywhere else the click falls back to selecting the text so the
  keyboard shortcut still works.
*/

(function () {
  "use strict";

  var blocks = document.querySelectorAll("[data-copy]");
  if (!blocks.length) return;

  Array.prototype.forEach.call(blocks, function (block) {
    var source = block.querySelector("code");
    if (!source) return;

    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button";
    button.setAttribute("aria-label", "Copy the install command");

    var label = document.createElement("span");
    label.className = "copy-label";
    label.textContent = "Copy";
    button.appendChild(label);

    // Announces the result to a screen reader without moving focus, which
    // pressing a button and having nothing said would otherwise fail to do.
    var status = document.createElement("span");
    status.className = "visually-hidden";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    block.appendChild(status);

    var revert;
    function report(text, ok) {
      label.textContent = text;
      button.classList.toggle("is-done", ok === true);
      button.classList.toggle("is-failed", ok === false);
      status.textContent = text === "Copy" ? "" : text;

      clearTimeout(revert);
      revert = setTimeout(function () {
        label.textContent = "Copy";
        button.classList.remove("is-done", "is-failed");
        status.textContent = "";
      }, 2200);
    }

    function selectCommand() {
      var range = document.createRange();
      range.selectNodeContents(source);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }

    button.addEventListener("click", function () {
      var text = source.textContent.trim();

      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(
          function () { report("Copied", true); },
          function () { selectCommand(); report("Press ⌘C", false); }
        );
        return;
      }

      // No Clipboard API: select it so the keyboard shortcut still works.
      selectCommand();
      report("Press ⌘C", false);
    });

    block.appendChild(button);
    block.classList.add("has-copy");
  });
})();
