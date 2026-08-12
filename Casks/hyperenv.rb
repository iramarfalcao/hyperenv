cask "hyperenv" do
  version "1.0.0"
  sha256 "4e547a3d26fd74bbc0528952a76f25e7d36f24983d6f01f79a7cbaa03d9b9447"

  url "https://github.com/iramarfalcao/hyperenv/releases/download/v#{version}/HyperEnv-#{version}.dmg"
  name "HyperEnv"
  desc "Switches the environment variables new terminals inherit, per project"
  homepage "https://github.com/iramarfalcao/hyperenv"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "HyperEnv.app"

  # Everything HyperEnv writes outside its own bundle. The hook it adds to
  # ~/.zprofile is guarded by `[ -r ... ]`, so removing these leaves a working
  # login shell even with the block still in the file — but the block itself is
  # the user's dotfile and is deliberately not touched here.
  zap trash: [
    "~/.config/hyperenv",
    "~/Library/Preferences/com.falcaosl.hyperenv.plist",
    "~/Library/Saved Application State/com.falcaosl.hyperenv.savedState",
  ]

  caveats <<~EOS
    This build is signed ad-hoc rather than with a paid Apple Developer ID, so
    Gatekeeper rejects it and the first launch is blocked. The download carries
    a quarantine attribute that Homebrew does not strip. Run this once:

      xattr -dr com.apple.quarantine "#{appdir}/HyperEnv.app"

    HyperEnv adds three lines to ~/.zprofile, but only when you press
    "Install Hook" in the app. It backs the file up first and writes only
    between its own markers.

    Uninstalling does not remove that block. Remove the hook from within the app
    first, or delete the marked lines by hand. A leftover block is harmless — it
    is guarded and does nothing once the files are gone.
  EOS
end
