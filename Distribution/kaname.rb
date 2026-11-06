# Homebrew cask for Kaname. Users install with:
#   brew tap suliveevil/tap
#   brew install --cask kaname
#
# The DMG URL and asset name must match scripts/build_release.sh exactly.
#
# TEMPLATE-ONLY-BEGIN
# Distribution/kaname.rb is a TEMPLATE, not an installable cask: `version` and `sha256`
# are filled in by `scripts/publish_release.sh` from the DMG it just uploaded, and only
# the rendered build/kaname.rb is pushed to Casks/kaname.rb of suliveevil/homebrew-tap.
# The rendering step strips this block, so the published cask carries no template notes.
# TEMPLATE-ONLY-END
cask "kaname" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/suliveevil/kaname/releases/download/v#{version}/Kaname-#{version}.dmg"
  name "Kaname"
  desc "Context-aware keyboard shortcut hints and search for the active macOS app"
  homepage "https://github.com/suliveevil/kaname"

  livecheck do
    url :url
    strategy :github_latest
  end

  # 14.0, matching LSMinimumSystemVersion in scripts/Info.plist.
  depends_on macos: :sonoma

  # Apple Silicon is the only supported configuration. The DMG built by
  # scripts/build_release.sh is universal (x86_64 + arm64), but Intel is untested, so
  # the cask rejects Intel Macs at install time by choice rather than shipping an
  # unsupported configuration. This is a deliberate support decision, not a statement
  # about the binary's architectures.
  depends_on arch: :arm64

  # Homebrew 7 takes the stanza argument literally: without the extension it looks for a
  # staged item named "Kaname" and fails with "App source … is not there".
  app "Kaname.app"

  # Kaname is an LSUIElement menu bar app: replacing the bundle while the old process
  # still runs leaves it holding a deleted binary and the event tap. `login_item` is
  # best effort (the app registers through SMAppService, while Homebrew uses the
  # legacy AppleScript login-item API); a leftover entry is removed in System
  # Settings → General → Login Items.
  uninstall quit: "com.suliveevil.kaname",
            login_item: "Kaname"

  caveats <<~EOS
    Kaname is signed with a local certificate and is not notarized by Apple, so
    macOS blocks its first launch. Approve it once in
    System Settings → Privacy & Security ("Open Anyway"). Homebrew downloads a
    fresh copy on every `brew upgrade`, so the same approval is needed again
    after each upgrade.
  EOS

  zap trash: [
    "~/Library/Application Support/Kaname",
    "~/Library/Caches/com.suliveevil.kaname",
    "~/Library/Preferences/com.suliveevil.kaname.plist",
    "~/Library/Saved Application State/com.suliveevil.kaname.savedState",
  ]
end
