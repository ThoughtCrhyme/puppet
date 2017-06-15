require 'puppet/application'
require 'puppet/error'
require 'puppet/util/execution'

# A general class for triggering a run of another
# class.
class Puppet::Agent
  require 'puppet/agent/locker'
  include Puppet::Agent::Locker

  require 'puppet/agent/disabler'
  include Puppet::Agent::Disabler

  require 'puppet/util/splayer'
  include Puppet::Util::Splayer

  attr_reader :client_class, :client, :should_fork

  def initialize(client_class, should_fork=true)
    @should_fork = can_fork? && should_fork
    @client_class = client_class
  end

  def can_fork?
    Puppet.features.posix? && RUBY_PLATFORM != 'java'
  end

  def needing_restart?
    Puppet::Application.restart_requested?
  end

  # Perform a run with our client.
  def run(client_options = {})
    if disabled?
      Puppet.notice "Skipping run of #{client_class}; administratively disabled (Reason: '#{disable_message}');\nUse 'puppet agent --enable' to re-enable."
      return
    end

    result = nil
    block_run = Puppet::Application.controlled_run do
      splay client_options.fetch :splay, Puppet[:splay]
      result = run_in_fork(should_fork) do
        with_client(client_options[:transaction_uuid]) do |client|
          client_args = client_options.merge(:pluginsync => Puppet::Configurer.should_pluginsync?)
          begin
            lock { client.run(client_args) }
          rescue Puppet::LockError
            retry if enforce_runtimeout

            Puppet.notice "Run of #{client_class} already in progress; skipping  (#{lockfile_path} exists)"
            return
          rescue StandardError => detail
            Puppet.log_exception(detail, "Could not run #{client_class}: #{detail}")
          end
        end
      end
      true
    end
    Puppet.notice "Shutdown/restart in progress (#{Puppet::Application.run_status.inspect}); skipping run" unless block_run
    result
  end

  def stopping?
    Puppet::Application.stop_requested?
  end

  def run_in_fork(forking = true)
    return yield unless forking or Puppet.features.windows?

    child_pid = Kernel.fork do
      $0 = "puppet agent: applying configuration"
      begin
        exit(yield)
      rescue SystemExit
        exit(-1)
      rescue NoMemoryError
        exit(-2)
      end
    end

    exit_code = if Puppet[:runtimeout] > 0
                  Puppet::Util::Execution.wait_with_timeout(child_pid, Puppet[:runtimeout])
                else
                  Process.waitpid2(child_pid)
                end

    case exit_code[1].exitstatus
    when -1
      raise SystemExit
    when -2
      raise NoMemoryError
    end
    exit_code[1].exitstatus
  end

  private

  # Create and yield a client instance, keeping a reference
  # to it during the yield.
  def with_client(transaction_uuid)
    begin
      @client = client_class.new(Puppet::Configurer::DownloaderFactory.new, transaction_uuid)
    rescue StandardError => detail
      Puppet.log_exception(detail, "Could not create instance of #{client_class}: #{detail}")
      return
    end
    yield @client
  ensure
    @client = nil
  end

  # Attempt to clean up processes holding onto the catalog lockfile
  #
  # If the runtimeout setting is nonzero, this method attempts to shut
  # down any process which has been holding onto the catalog run lock
  # for longer than the timeout.
  #
  # @return [Boolean] A value indicating whether the timeout was enforced
  #   successfully.
  def enforce_runtimeout
    return false unless Puppet[:runtimeout] > 0

    pid = lockfile.lock_pid
    # Process disappeared.
    return true if pid.nil?

    lockfile_stat = begin
                      File.stat(lockfile_path)
                    rescue Errno::ENOENT
                      # Lockfile is gone, so it's worth trying to acquire it
                      # again.
                      return true
                    end

    # Still time to live.
    return false if (lockfile_stat.mtime + Puppet[:runtimeout]) > Time.now

    # Exception classes returned by Process.kill which indicate the
    # PID specified is no longer present.
    process_gone = [Errno::ESRCH]
    process_gone << SystemCallError if Puppet::Util::Platform.windows?

    if Puppet::Util::Platform.windows?
      Puppet.err(_('Puppet agent PID %{pid} has been holding the catalog lock for longer than %{timeout} seconds. Invoking taskkill.exe.') %
                 {pid: pid,
                  timeout: Puppet[:runtimeout]})

      # taskkill is used as the /T switch will propogate the kill to child
      # processes which may be blocking the Puppet agent.
      ::Kernel.system("taskkill.exe /F /T /PID #{pid}")
    else
      Puppet.err(_('Puppet agent PID %{pid} has been holding the catalog lock for longer than %{timeout} seconds. Sending a TERM signal.') %
                 {pid: pid,
                  timeout: Puppet[:runtimeout]})

      begin
        Process.kill(:TERM, pid)
      rescue *process_gone
        return true
      end
    end

    # Poll for the process to exit.
    5.times do
      begin
        # Sending signal 0 just checks to see if the PID still exists.
        Process.kill(0, pid)
      rescue *process_gone
        return true
      end

      sleep(1)
    end

    Puppet.err(_('Puppet agent PID %{pid} did not exit within 5 seconds of being killed.') %
               {pid: pid})
    false
  end
end
