require "tmpdir"
require "language_pack"
require "language_pack/base"

# base Ruby Language Pack. This is for any base ruby app.
class LanguagePack::Ruby < LanguagePack::Base
  LIBYAML_VERSION     = "0.1.4"
  LIBYAML_PATH        = "libyaml-#{LIBYAML_VERSION}"
  BUNDLER_VERSION     = "1.1.rc"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  JSNES_GIT_URL       = "https://github.com/hone/jsnes.git"

  # detects if this is a valid Ruby app
  # @return [Boolean] true if it's a Ruby app
  def self.use?
    File.exist?("Gemfile")
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
    }
  end

  def default_process_types
    {
      "rake"    => "bundle exec rake",
      "console" => "bundle exec irb"
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

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    FileUtils.mkdir_p dir
    Dir.chdir(dir) do |dir|
      run("curl #{VENDOR_URL}/#{LIBYAML_PATH}.tgz -s -o - | tar xzf -")
    end
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      bundle_without = ENV["BUNDLE_WITHOUT"] || "development:test"
      bundle_command = "bundle install --without #{bundle_without} --path vendor/bundle"

      unless File.exist?("Gemfile.lock")
        error "Gemfile.lock is required. Please run \"bundle install\" locally\nand commit your Gemfile.lock."
      end

      if has_windows_gemfile_lock?
        log("bundle", "has_windows_gemfile_lock")
        File.unlink("Gemfile.lock")
      else
        # using --deployment is preferred if we can
        bundle_command += " --deployment"
        cache_load ".bundle"
      end

      cache_load "vendor/bundle"

      version = run("bundle version").strip
      topic("Installing dependencies using #{version}")

      Dir.mktmpdir("libyaml-") do |tmpdir|
        libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
        install_libyaml(libyaml_dir)

        # need to setup compile environment for the psych gem
        yaml_include   = File.expand_path("#{libyaml_dir}/include")
        yaml_lib       = File.expand_path("#{libyaml_dir}/lib")
        pwd            = run("pwd").chomp
        # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
        # codon since it uses bundler.
        env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config CPATH=#{yaml_include}:$CPATH CPPATH=#{yaml_include}:$CPPATH LIBRARY_PATH=#{yaml_lib}:$LIBRARY_PATH"
        puts "Running: #{bundle_command}"
        pipe("#{env_vars} #{bundle_command} --no-clean 2>&1")
      end

      if $?.success?
        log "bundle", :status => "success"
        puts "Cleaning up the bundler cache."
        run "bundle clean"
        cache_store ".bundle"
        cache_store "vendor/bundle"
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        if gem_is_bundled?("sqlite3")
          error_message += <<ERROR


Detected sqlite3 gem which is not supported on Heroku.
http://devcenter.heroku.com/articles/how-do-i-use-sqlite3-for-development
ERROR
        end

        error error_message
      end
    end
  end

  # add bundler to the load path
  # @note it sets a flag, so the path can only be loaded once
  def add_bundler_to_load_path
    return if @bundler_loadpath
    $: << File.expand_path(Dir["#{slug_vendor_base}/gems/bundler*/lib"].first)
    @bundler_loadpath = true
  end

  # detects whether the Gemfile.lock contains the Windows platform
  # @return [Boolean] true if the Gemfile.lock was created on Windows
  def has_windows_gemfile_lock?
    lockfile_parser.platforms.detect do |platform|
      /mingw|mswin/.match(platform.os) if platform.is_a?(Gem::Platform)
    end
  end

  # detects if a gem is in the bundle.
  # @param [String] name of the gem in question
  # @return [String, nil] if it finds the gem, it will return the line from bundle show or nil if nothing is found.
  def gem_is_bundled?(gem)
    @bundler_gems ||= lockfile_parser.specs.map(&:name)
    @bundler_gems.include?(gem)
  end

  # setup the lockfile parser
  # @return [Bundler::LockfileParser] a Bundler::LockfileParser
  def lockfile_parser
    add_bundler_to_load_path
    require "bundler"
    @lockfile_parser ||= Bundler::LockfileParser.new(File.read("Gemfile.lock"))
  end

  # detects if a rake task is defined in the app
  # @param [String] the task in question
  # @return [Boolean] true if the rake task is defined in the app
  def rake_task_defined?(task)
    run("env PATH=$PATH bundle exec rake #{task} --dry-run") && $?.success?
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
    run("bundle exec jake")
  end
end
