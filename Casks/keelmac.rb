cask "keelmac" do
  version "1.0.0"
  sha256 "REPLACED_BY_SCRIPTS_RELEASE_SH"

  url "https://github.com/DarthQach/keelmac/releases/download/v#{version}/KeelMac-#{version}.dmg"
  name "KeelMac"
  desc "Monitor, clean and maintain your Mac, free and open source"
  homepage "https://keelmac.flowrunnerapp.workers.dev/"

  livecheck do
    url "https://keelmac.flowrunnerapp.workers.dev/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "KeelMac.app"

  uninstall launchctl: "mx.cvillegas.keelmac.helper",
            quit:      "mx.cvillegas.keelmac"

  zap trash: [
    "~/Library/Application Support/KeelMac",
    "~/Library/Caches/mx.cvillegas.keelmac",
    "~/Library/HTTPStorages/mx.cvillegas.keelmac",
    "~/Library/Preferences/mx.cvillegas.keelmac.plist",
    "~/Library/Saved Application State/mx.cvillegas.keelmac.savedState",
  ]
end
