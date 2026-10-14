echo "Remove the Google and YouTube web apps that no longer ship"

applications="$HOME/.local/share/applications"
removed=false
for app in "Google Contacts" "Google Maps" "Google Messages" "Google Photos" "YouTube"; do
  launcher="$applications/$app.desktop"
  # Only the stock launchers: one that opens somewhere else is the user's own.
  if [[ -f $launcher ]] &&
    grep -qE '^Exec=omarchy-launch-webapp https://(contacts\.google\.com|maps\.google\.com|messages\.google\.com|photos\.google\.com|youtube\.com)' "$launcher"; then
    rm -f "$launcher"
    removed=true
  fi
done

if [[ $removed == "true" ]]; then
  update-desktop-database "$applications"
fi

# A dock that still uses the default pins already lost YouTube with them.
if omarchy-dock pinned | grep -qx YouTube; then
  omarchy-dock unpin YouTube >/dev/null
fi
