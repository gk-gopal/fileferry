# Homebrew cask template.
#
# Not submittable yet: homebrew-cask requires a signed and notarized artifact,
# which needs an Apple Developer Program membership. Fill in version and
# sha256 from a tagged release, then open a PR against homebrew/homebrew-cask.
cask "fileferry" do
  version "0.1.0"
  sha256 :no_check # replace with: shasum -a 256 dist/FileFerry-<version>.dmg

  url "https://github.com/OWNER/fileferry/releases/download/v#{version}/FileFerry-#{version}.dmg"
  name "FileFerry"
  desc "Copy files between a Mac and an Android phone over USB"
  homepage "https://github.com/OWNER/fileferry"

  depends_on macos: ">= :sonoma"

  app "FileFerry.app"

  caveats <<~EOS
    FileFerry needs the Android platform-tools:

      brew install --cask android-platform-tools

    And USB debugging enabled on the phone:
      Settings > About phone > tap Build number seven times
      Settings > System > Developer options > USB debugging
  EOS

  zap trash: [
    "~/Library/Preferences/app.fileferry.FileFerry.plist",
    "~/Library/Caches/app.fileferry.FileFerry",
  ]
end
