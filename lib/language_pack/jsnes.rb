require "tmpdir"
require "language_pack"
require "language_pack/base"

# base JSNES Language Pack. This is for any base ruby app.
class LanguagePack::JSNES < LanguagePack::Base
  BUNDLER_VERSION     = "1.1.rc"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  JSNES_GIT_URL       = "https://github.com/hone/jsnes.git"

  # detects if this is a valid JSNES app
  # @return [Boolean] always true
  def self.use?
    true
  end

  def name
    "JSNES"
  end

  def default_addons
    []
  end

  def default_config_vars
    {
      "LANG"     => "en_US.UTF-8",
      "PATH"     => default_path,
      "GEM_PATH" => slug_vendor_base,
      "RACK_ENV" => "production"
    }
  end

  def default_process_types
    {
      "web" => "bundle exec rackup config.ru -p $PORT"
    }
  end

  def compile
    Dir.chdir(build_path)
    setup_language_pack_environment
    install_ruby
    allow_git do
      setup_jsnes
      install_language_pack_gems
      build_bundler
      install_binaries
      run_jake
      generate_index_html
    end
  end

private

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    "bin:#{slug_vendor_base}/bin:/usr/local/bin:/usr/bin:/bin"
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_base
    "vendor/bundle/ruby/1.9.1"
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "vendor/#{ruby_version}"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/tmp/#{ruby_version}"
  end

  # fetch the ruby version from the enviroment
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    ENV["RUBY_VERSION"]
  end

  # list the available valid ruby versions
  # @note the value is memoized
  # @return [Array] list of Strings of the ruby versions available
  def ruby_versions
    return @ruby_versions if @ruby_versions

    Dir.mktmpdir("ruby_versions-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("curl -O #{VENDOR_URL}/ruby_versions.yml")
        @ruby_versions = YAML::load_file("ruby_versions.yml")
      end
    end

    @ruby_versions
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    default_config_vars.each do |key, value|
      ENV[key] ||= value
    end
    ENV["GEM_HOME"] = slug_vendor_base
    ENV["PATH"] = ruby_version ? "#{build_ruby_path}/bin:" : ""
    ENV["PATH"] += "#{default_config_vars["PATH"]}"
  end

  # install the vendored ruby
  # @note this only installs if we detect RUBY_VERSION in the environment
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    return false unless ruby_version

    invalid_ruby_version_message = <<ERROR
Invalid RUBY_VERSION specified: #{ruby_version}
Valid versions: #{ruby_versions.join(", ")}
ERROR

    FileUtils.mkdir_p(build_ruby_path)
    Dir.chdir(build_ruby_path) do
      run("curl #{VENDOR_URL}/#{ruby_version.sub("ruby", "ruby-build")}.tgz -s -o - | tar zxf -")
    end
    error invalid_ruby_version_message unless $?.success?

    FileUtils.mkdir_p(slug_vendor_ruby)
    Dir.chdir(slug_vendor_ruby) do
      run("curl #{VENDOR_URL}/#{ruby_version}.tgz -s -o - | tar zxf -")
    end
    error invalid_ruby_version_message unless $?.success?

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    run("cp #{slug_vendor_ruby}/bin/* #{bin_dir}")
    Dir["bin/*"].each {|path| run("chmod +x #{path}") }

    topic "Using RUBY_VERSION: #{ruby_version}"

    true
  end

  # list of default gems to vendor into the slug
  # @return [Array] resluting list of gems
  def gems
    [BUNDLER_GEM_PATH]
  end

  # installs vendored gems into the slug
  def install_language_pack_gems
    FileUtils.mkdir_p(slug_vendor_base)
    Dir.chdir(slug_vendor_base) do |dir|
      gems.each do |gem|
        run("curl #{VENDOR_URL}/#{gem}.tgz -s -o - | tar xzf -")
      end
      Dir["bin/*"].each {|path| run("chmod 755 #{path}") }
    end
  end

  # default set of binaries to install
  # @return [Array] resulting list
  def binaries
    []
  end

  # vendors binaries into the slug
  def install_binaries
    binaries.each {|binary| install_binary(binary) }
    Dir["bin/*"].each {|path| run("chmod +x #{path}") }
  end

  # vendors individual binary into the slug
  # @param [String] name of the binary package from S3.
  #   Example: https://s3.amazonaws.com/language-pack-ruby/node-0.4.7.tgz, where name is "node-0.4.7"
  def install_binary(name)
    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir.chdir(bin_dir) do |dir|
      run("curl #{VENDOR_URL}/#{name}.tgz -s -o - | tar xzf -")
    end
  end

  # removes a binary from the slug
  # @param [String] relative path of the binary on the slug
  def uninstall_binary(path)
    FileUtils.rm File.join('bin', File.basename(path)), :force => true
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      bundle_command = "bundle install --deployment"

      cache_load ".bundle"
      cache_load "vendor/bundle"

      version = run("bundle version").strip
      topic("Installing dependencies using #{version}")

      pwd            = run("pwd").chomp
      # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
      # codon since it uses bundler.
      env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config"
      puts "Running: #{bundle_command}"
      pipe("#{env_vars} #{bundle_command} 2>&1")

      if $?.success?
        log "bundle", :status => "success"
        cache_store ".bundle"
        cache_store "vendor/bundle"
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        error error_message
      end
    end
  end

  # executes the block without GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # clones the jsnes git repo and copies the roms into the right directory
  def setup_jsnes
    Dir.mktmpdir("jsnes-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("git clone #{JSNES_GIT_URL} .")
        FileUtils.mkdir_p("local-roms")
        run("mv #{build_path}/* local-roms/") # copy roms
        run("mv * #{build_path}")
      end
    end
  end

  # we need to run jake to build the js files
  def run_jake
    topic("Running jake")
    pipe("bundle exec jake")
  end

  # generates the index.html
  def generate_index_html
    local_roms = Dir['local-roms/*.nes'].map do |rom|
      name = rom.sub(/\.nes$/, '').sub(%r{^local-roms/}, '')
      "{\"name\": \"#{name}\", \"file\":\"#{rom}\"}"
    end.join(",\n")
    local_roms = '[' + local_roms + ']'

    topic("Writing index.html")
    File.open('games.json', 'w') {|file| file.puts local_roms }
  end
end
