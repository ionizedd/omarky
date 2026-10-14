# Chromium is optional (Firefox is the default browser), and fresh installs mark
# every migration as already applied. When an image does ship Chromium, its
# bundled extensions still need a native messaging host to talk to.
if omarchy-cmd-present chromium; then
  omarchy-install-chromium-copy-url
  omarchy-install-chromium-ytdlp
fi
