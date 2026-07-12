# Draft — the published copy lives in mschuerig/homebrew-tap as
# Formula/midimend.rb. Before it works there:
#   1. push the midimend repo and tag a release (the `url` below),
#   2. fill in sha256:  curl -L <url> | shasum -a 256
class Midimend < Formula
  desc "Mend your MIDI before the DAW sees it"
  homepage "https://github.com/mschuerig/midimend"
  url "https://github.com/mschuerig/midimend/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE-AFTER-TAGGING"
  license :public_domain
  head "https://github.com/mschuerig/midimend.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/midimend"
    man1.install "packaging/midimend.1"
    zsh_completion.install "packaging/completions/_midimend"
    bash_completion.install "packaging/completions/midimend.bash" => "midimend"
    pkgshare.install "examples"
  end

  # Starts at login; `crashed: true` restarts after crashes but not after
  # deliberate exits (e.g. missing config), avoiding a respawn loop.
  service do
    run opt_bin/"midimend"
    keep_alive crashed: true
    log_path var/"log/midimend.log"
    error_log_path var/"log/midimend.log"
  end

  def caveats
    <<~EOS
      Started without arguments (as `brew services start midimend` does),
      midimend reads ~/Music/Midimend/config.json. Generate a skeleton:
        midimend --init your-script.js > ~/Music/Midimend/config.json
      Example scripts: #{opt_pkgshare}/examples
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/midimend --help")
  end
end
