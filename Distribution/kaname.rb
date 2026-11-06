# Homebrew cask template for Kaname.
#
# This file is a template, not a working cask: version and sha256 are empty
# on purpose. Fill them in when a release is published, then copy the file
# into a Homebrew tap.
#
# Publishing checklist:
#   1. Create (or reuse) a tap repository, e.g. suliveevil/homebrew-tap.
#   2. Copy this file to Casks/kaname.rb in that repository.
#   3. Set version to the release version (for example "1.2.0") and sha256
#      to the digest of build/Kaname-<version>.dmg produced by
#      scripts/build_release.sh:
#        shasum -a 256 build/Kaname-1.2.0.dmg
#   4. Run `brew audit --cask kaname` and `brew install --cask kaname`
#      from a machine with the tap added.
#
# Users then install with:
#   brew tap suliveevil/tap
#   brew install --cask kaname
#
# The DMG URL and file name must match scripts/build_release.sh exactly.
# The GitHub repository is still named Kaname; only the product is Kaname.
cask "kaname" do
  version ""
  sha256 ""

  url "https://github.com/suliveevil/Kaname/releases/download/v#{version}/Kaname-#{version}.dmg",
      verified: "github.com/suliveevil/Kaname/"
  name "Kaname"
  desc "Context-aware keyboard shortcut hints and search for the active macOS app"
  homepage "https://github.com/suliveevil/Kaname"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Kaname"

  # New domain plus the two historical Kaname domains, so uninstalling cleans up
  # both a fresh install and one that was migrated from the old name.
  zap trash: [
    "~/Library/Application Support/Kaname",
    "~/Library/Application Support/Kaname",
    "~/Library/Caches/com.suliveevil.kaname",
    "~/Library/Preferences/com.suliveevil.kaname.plist",
    "~/Library/Saved Application State/com.suliveevil.kaname.savedState",
    "~/Library/Caches/com.suliveevil.kaname",
    "~/Library/Preferences/com.suliveevil.kaname.plist",
    "~/Library/Preferences/com.suliveevil.kaname.plist",
    "~/Library/Saved Application State/com.suliveevil.kaname.savedState",
  ]
end
