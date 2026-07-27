# Homebrew cask template.
#
# Not submittable yet: homebrew-cask requires a signed and notarized artifact,
# which needs an Apple Developer Program membership. Fill in version and
# sha256 from a tagged release, then open a PR against homebrew/homebrew-cask.
cask "conduit" do
  version "0.1.0"
  sha256 :no_check # replace with: shasum -a 256 dist/Conduit-<version>.dmg

  url "https://github.com/OWNER/conduit/releases/download/v#{version}/Conduit-#{version}.dmg"
  name "Conduit"
  desc "Copy files between a Mac and an Android phone over USB"
  homepage "https://github.com/OWNER/conduit"

  depends_on macos: ">= :sonoma"

  app "Conduit.app"

  caveats <<~EOS
    Conduit needs the Android platform-tools:

      brew install --cask android-platform-tools

    And USB debugging enabled on the phone:
      Settings > About phone > tap Build number seven times
      Settings > System > Developer options > USB debugging
  EOS

  zap trash: [
    "~/Library/Preferences/dev.gopalkannan.conduit.plist",
    "~/Library/Caches/dev.gopalkannan.conduit",
  ]
end
