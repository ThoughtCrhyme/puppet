require 'beaker/host_prebuilt_steps'

test_name 'enforce runtimeout' do
  extend Beaker::HostPrebuiltSteps

  teardown do
    stop_agent_on(agents)
    on(master, 'rm -f /etc/puppetlabs/code/environments/production/manifests/site.pp')
  end

  step 'set up puppet code for putting agents to sleep' do
    copy_file_to_remote(master, '/etc/puppetlabs/code/environments/production/manifests/site.pp', <<-EOF)
node default {
  notify{'Putting agent to sleep': }

  exec{'ruby -e "sleep 60"':
    path => $facts['path'],
  }
}
EOF

    on(master, 'chmod 0644 /etc/puppetlabs/code/environments/production/manifests/site.pp')
  end

  step 'test that puppet agent -t kills sleeping daemons' do
    with_puppet_running_on(master, {}) do
      agents.each do |agent|
        # Bounce the puppet daemon to kick off a background run,
        # which should hang on exec sleep 60.
        on(agent, puppet('resource service puppet ensure=stopped'))
        on(agent, puppet("config set --section agent server #{master}"))
        on(agent, puppet('resource service puppet ensure=running'))

        # Wait for the daemon to acquire the lockfile.
        lockfile = on(agent, puppet('config print --section agent agent_catalog_run_lockfile')).stdout.strip
        on(agent, <<-EOF)
timeout=30

for i in $(seq $timeout); do
  test -e '#{lockfile}' && exit 0
  sleep 1
  echo "Waiting for: #{lockfile}"
done

echo "Lockfile did not appear after $timeout seconds. This means the daemon failed to start a successful run."
exit 1
EOF

        # Use --noop to prevent the test run from sleeping.
        on(agent, puppet("agent -t --runtimeout=1s --noop")) do
          # Hung daemon run killed.
          assert_match(/has been holding the catalog lock for longer/, result.stderr)
          # Catalog successfully applied.
          assert_match(/Applied catalog in/, result.stdout)
        end
      end
    end
  end
end
