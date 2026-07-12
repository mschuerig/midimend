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
    # The executable loads Bootstrap.js from a resource bundle looked up
    # next to the real binary, so both live in libexec and bin gets a shim
    # (a bin symlink would leave the bundle unfound).
    libexec.install ".build/release/midimend",
                    ".build/release/midimend_Midimend.bundle"
    bin.write_exec_script libexec/"midimend"
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
