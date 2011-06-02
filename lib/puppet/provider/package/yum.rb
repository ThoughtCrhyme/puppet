require 'puppet/util/package'

Puppet::Type.type(:package).provide :yum, :parent => :rpm, :source => :rpm do
  desc "Support via `yum`.

  Using this provider's `uninstallable` feature will not remove dependent packages. To
  remove dependent packages with this provider use the `purgeable` feature, but note this
  feature is destructive and should be used with the utmost care."

  has_feature :versionable

  commands :yum => "yum", :rpm => "rpm", :python => "python"

  YUMHELPER = File::join(File::dirname(__FILE__), "yumhelper.py")

  attr_accessor :latest_info

  if command('rpm')
    confine :true => begin
      rpm('--version')
      rescue Puppet::ExecutionFailure
        false
      else
        true
      end
  end

  defaultfor :operatingsystem => [:fedora, :centos, :redhat]

  def self.prefetch(packages)
    raise Puppet::Error, "The yum provider can only be used as root" if Process.euid != 0
    super
    return unless packages.detect { |name, package| package.should(:ensure) == :latest }

    repoconfig = { }
    repoconfig[""] = [ ]
    packages.each do |name, package|
      if package[:enablerepo].respond_to?("length")
        if package[:enablerepo].length != 0
          if package[:enablerepo].respond_to?("join")
            repoconfig[ package[:enablerepo].join(",") ] = package[:enablerepo]
          else
            repoconfig[ package[:enablerepo] ] = package[:enablerepo]
          end
        end
      end
    end

    updates = {}

    repoconfig.each do |config, enablerepo|
      fullyumhelper = []
      enablerepo.each do |value|
        fullyumhelper += [ "-e", value ]
      end

      # collect our 'latest' info
      python(YUMHELPER, fullyumhelper).each_line do |l|
        l.chomp!
        next if l.empty?
        if l[0,4] == "_pkg"
          hash = nevra_to_hash(l[5..-1])
          ["#{hash[:name]}.#{config}", "#{hash[:name]}.#{hash[:arch]}.#{config}"].each  do |n|
            updates[n] ||= []
            updates[n] << hash
          end
        end
      end
    end

    # Add our 'latest' info to the providers.
    packages.each do |name, package|
      repocfg = ""
      if package[:enablerepo].respond_to?("length")
        if package[:enablerepo].length != 0
          if package[:enablerepo].respond_to?("join")
            repocfg = package[:enablerepo].join(",")
          else
            repocfg = package[:enablerepo]
          end
        end
      end
      if info = updates["#{package[:name]}.#{repocfg}"]
        package.provider.latest_info = info[0]
      end
    end
  end

  def install
    should = @resource.should(:ensure)
    self.debug "Ensuring => #{should}"
    wanted = @resource[:name]
    operation = :install

    fulldisablerepo = []
    disablerepo= @resource[:disablerepo]
    disablerepo.each do |value|
      disablerepo += [ "--disablerepo=" + value ]
    end

    fullenablerepo = []
    enablerepo = @resource[:enablerepo]
    enablerepo.each do |value|
      fullenablerepo += [ "--enablerepo=" + value ]
    end


    case should
    when true, false, Symbol
      # pass
      should = nil
    else
      # Add the package version
      wanted += "-#{should}"
      is = self.query
      if is && Puppet::Util::Package.versioncmp(should, is[:ensure]) < 0
        self.debug "Downgrading package #{@resource[:name]} from version #{is[:ensure]} to #{should}"
        operation = :downgrade
      end
    end

    if fullenablerepo == [] and fulldisablerepo == []
     yum "-d", "0", "-e", "0", "-y", operation, wanted
    else
     yum "-d", "0", "-e", "0", "-y", fulldisablerepo, fullenablerepo, operation, wanted
    end

    is = self.query
    raise Puppet::Error, "Could not find package #{self.name}" unless is

    # FIXME: Should we raise an exception even if should == :latest
    # and yum updated us to a version other than @param_hash[:ensure] ?
    raise Puppet::Error, "Failed to update to version #{should}, got version #{is[:ensure]} instead" if should && should != is[:ensure]
  end

  # What's the latest package version available?
  def latest
    upd = latest_info
    unless upd.nil?
      # FIXME: there could be more than one update for a package
      # because of multiarch
      return "#{upd[:epoch]}:#{upd[:version]}-#{upd[:release]}"
    else
      # Yum didn't find updates, pretend the current
      # version is the latest
      raise Puppet::DevError, "Tried to get latest on a missing package" if properties[:ensure] == :absent
      return properties[:ensure]
    end
  end

  def update
    # Install in yum can be used for update, too
    self.install
  end

  def purge
    yum "-y", :erase, @resource[:name]
  end
end
