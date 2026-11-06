cask "burrow" do
  version :latest
  sha256 :no_check

  url "https://github.com/MaciejWlodarski/burrow/releases/latest/download/Burrow.dmg"
  name "Burrow"
  desc "Dual-pane file manager with a whole-disk map and a CLI for scripts and agents"
  homepage "https://github.com/MaciejWlodarski/burrow"

  depends_on macos: ">= :sequoia"

  app "Burrow.app"
  binary "#{appdir}/Burrow.app/Contents/Helpers/burrow"

  zap trash: [
    "~/Library/Caches/Burrow",
    "~/Library/Preferences/com.burrow.macos.plist",
    "~/Library/Saved Application State/com.burrow.macos.savedState",
  ]

  caveats <<~EOS
    Burrow is not notarized by Apple, so macOS asks you to confirm it once:
    open Burrow, click Done, then choose Open Anyway in System Settings >
    Privacy & Security and open it again. From Terminal:
      xattr -dr com.apple.quarantine #{appdir}/Burrow.app
  EOS
end
