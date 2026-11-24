cask "claudedock" do
  version "0.2.0"
  sha256 "43d99260dc08ec23dbed5795cdba79ce95b07057832535bfd257bae596bbe82f"

  url "https://github.com/designfuchen/ClaudeDock/releases/download/v#{version}/ClaudeDock-#{version}-universal.dmg"
  name "ClaudeDock"
  desc "Multi-account workbench for Claude Desktop and Claude Code"
  homepage "https://github.com/designfuchen/ClaudeDock"

  depends_on macos: ">= :sonoma"

  app "ClaudeDock.app"
  binary "#{appdir}/ClaudeDock.app/Contents/MacOS/claudedock"

  zap trash: [
    "~/.claudedock",
  ]
end
