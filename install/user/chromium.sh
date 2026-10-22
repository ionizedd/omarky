# Chromium is no longer in the base packages (Firefox is). If someone installed it
# before this ran, wire up its native messaging hosts; otherwise there is nothing
# to do — omarchy-install-browser chromium does it when Chromium is added.
if omarchy-cmd-present chromium; then
  omarchy-install-chromium-copy-url
  omarchy-install-chromium-ytdlp
fi
