require_relative "test_helper"
require "open3"
require "rbconfig"
load File.join(BIN, "protect-site")

# bin/protect-site: pages encrypted for a list of first name + password (low PBKDF2 cost here).
class TestProtectSite < Minitest::Test
  ITER = 1_000
  USERS = { "élodie" => "secret", "paul" => "p:ss" }.freeze
  PAGE = "<!doctype html><html><head><title>Carte</title></head><body>Refuges « été » </script></body></html>"

  def setup
    @dir = Dir.mktmpdir("ffcam-unit")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def payload_of(html) = JSON.parse(html[/const PAYLOAD = (.*);\n/, 1])

  def test_norm_name
    assert_equal "elodie", SiteLock.norm_name("  Élodie ")
    assert_equal SiteLock.user_id("ELODIE"), SiteLock.user_id("élodie")
  end

  def test_parse_users
    text = "# amis\nÉlodie:secret\n\npaul:p:ss\n"
    assert_equal({ "elodie" => "secret", "paul" => "p:ss" }, SiteLock.parse_users(text))
    assert_equal({}, SiteLock.parse_users(nil))
    assert_raises(ArgumentError) { SiteLock.parse_users("sans-mot-de-passe") }
    assert_raises(ArgumentError) { SiteLock.parse_users("marie:") }
  end

  def test_round_trip
    key, keys = SiteLock.wrap_keys(USERS, ITER)
    payload = JSON.parse(JSON.generate(SiteLock.payload(key, keys, PAGE, ITER)))
    assert_equal PAGE, SiteLock.unlock(payload, "Elodie", "secret")
    assert_equal PAGE, SiteLock.unlock(payload, "paul", "p:ss")
    assert_nil SiteLock.unlock(payload, "elodie", "Secret")
    assert_nil SiteLock.unlock(payload, "marie", "secret")
    refute_includes JSON.generate(payload), "elodie" # names are hashed
  end

  def test_protect_folder
    FileUtils.mkdir_p(File.join(@dir, "releves"))
    File.write(File.join(@dir, "index.html"), PAGE.sub("<head>", %(<head><link rel="icon" type="image/svg+xml" href="data:x">)))
    File.write(File.join(@dir, "releves", "index.html"), PAGE)
    assert_equal 2, SiteLock.protect(@dir, USERS, ITER).size
    map = File.read(File.join(@dir, "index.html"))
    refute_includes map, "Refuges"
    assert_includes map, %(href="data:x")
    assert_includes map, %(name="robots" content="noindex)
    assert_equal PAGE.sub("<head>", %(<head><link rel="icon" type="image/svg+xml" href="data:x">)), SiteLock.unlock(payload_of(map), "élodie", "secret")
    assert_equal PAGE, SiteLock.unlock(payload_of(File.read(File.join(@dir, "releves", "index.html"))), "paul", "p:ss")
  end

  def test_refuses_without_users
    File.write(File.join(@dir, "index.html"), PAGE)
    script = File.join(BIN, "protect-site")
    _, err, status = Open3.capture3({ "SITE_USERS" => nil }, RbConfig.ruby, script, @dir)
    refute status.success?
    assert_includes err, "SITE_USERS is empty"
    assert_equal PAGE, File.read(File.join(@dir, "index.html"))
    _, _, status = Open3.capture3({ "SITE_USERS" => nil }, RbConfig.ruby, script, @dir, "--allow-public")
    assert status.success?
  end
end
