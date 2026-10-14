source "$OMARCHY_PATH/install/helpers/browser-policy.sh"
browser_policy_setup_dir /etc/chromium/policies/managed
browser_policy_install_chromium_privacy /etc/chromium/policies/managed
browser_policy_setup_firefox_distribution /usr/lib/firefox/distribution
