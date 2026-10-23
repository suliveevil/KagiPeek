# Homebrew cask template for KagiPeek.
#
# This file is a template, not a working cask: version and sha256 are empty
# on purpose. Fill them in when a release is published, then copy the file
# into a Homebrew tap.
#
# Publishing checklist:
#   1. Create (or reuse) a tap repository, e.g. suliveevil/homebrew-tap.
#   2. Copy this file to Casks/kagipeek.rb in that repository.
#   3. Set version to the release version (for example "1.2.0") and sha256
#      to the digest of build/KagiPeek-<version>.dmg produced by
#      scripts/build_release.sh:
#        shasum -a 256 build/KagiPeek-1.2.0.dmg
#   4. Run `brew audit --cask kagipeek` and `brew install --cask kagipeek`
#      from a machine with the tap added.
#
# Users then install with:
#   brew tap suliveevil/tap
#   brew install --cask kagipeek
#
# The DMG URL and file name must match scripts/build_release.sh exactly.
cask "kagipeek" do
  version ""
  sha256 ""

  url "https://github.com/suliveevil/KagiPeek/releases/download/v#{version}/KagiPeek-#{version}.dmg",
      verified: "github.com/suliveevil/KagiPeek/"
  name "KagiPeek"
  desc "Context-aware keyboard shortcut hints and search for the active macOS app"
  homepage "https://github.com/suliveevil/KagiPeek"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "KagiPeek"

  # Settings and usage statistics live in UserDefaults, so the two plists
  # cover both the v1.2 domain and the legacy v1.1 domain.
  zap trash: [
    "~/Library/Caches/com.voltline.kagipeek",
    "~/Library/Preferences/com.voltline.kagipeek.plist",
    "~/Library/Preferences/com.Voltline.KagiPeek.plist",
    "~/Library/Saved Application State/com.voltline.kagipeek.savedState",
  ]
end