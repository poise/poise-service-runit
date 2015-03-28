#
# Copyright 2015, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/mash'

require 'poise_service/providers/base'


module PoiseService
  # Poise-service provider for [Runit](http://smarden.org/runit/index.html).
  #
  # @since 1.0.0
  # @example
  #   poise_service 'myapp' do
  #     command 'myapp --serve'
  #     provider :runit
  #   end
  class Runit < Providers::Base
    poise_service_provides(:runit)

    # A mapping of signal names to sv subcommands.
    RUNIT_SIGNALS = {
      'STOP' => 'pause',
      'CONT' => 'cont',
      'HUP' => 'hup',
      'ALRM' => 'alarm',
      'INT' => 'interrupt',
      'QUIT' => 'quit',
      'USR1' => '1',
      'USR2' => '2',
      'TERM' => 'term',
      'KILL' => 'kill',
    }

    # Reload action for the runit provider. Runs hup on the service resource
    # because upstream's reload action runs sv force-reload which is ~restart.
    def action_reload
      return if options['never_reload']
      notify_if_service do
        service_resource.run_action(:hup)
      end
    end

    # Parse the PID from sv output.
    #
    # @return [Integer]
    def pid
      cmd = shell_out(%w{sv status} + [new_resource.service_name])
      if !cmd.error? && md = cmd.stdout.match(/run: #{new_resource.service_name}: \(pid (\d+)\)/)
        md[1].to_i
      else
        nil
      end
    end

    private

    # Recipes to include for Runit.
    def recipes
      'runit'
    end

    # Set up secondary service files for Runit.
    def create_service
      # Check signals here to be nice and abort early if possible.
      check_signals!
      # Enable automatically creates the service with Runit.
      directory "/var/log/#{new_resource.service_name}" do
        owner 'root'
        group 'root'
        mode '700'
      end
    end

    # Tear down secondary service files for Runit.
    def destroy_service
      # Disable automatically destroys the service with Runit.
      directory "/var/log/#{new_resource.service_name}" do
        action :delete
        recursive true
      end
    end

    # Hack to subclass the upstream provider to override #inside_docker?
    #
    # @return [Class]
    def service_provider
      Class.new(Chef::Provider::Service::Runit) do
        def self.name
          'Chef::Provider::Service::Runit'
        end

        def inside_docker?
          # We account for docker already so just lock it to false.
          false
        end
      end
    end

    # Create the service resource for Runit.
    #
    # @return [Chef::Resource]
    def service_resource
      # Sanity checking
      check_signals!
      check_dummy!
      # Set defaults for sv_bin and sv_dir so we can use them in templates.
      # This follows the same lookup as in resource_runit_service.rb.
      if node['runit']
        options['sv_bin'] ||= node['runit']['sv_bin']
        options['sv_dir'] ||= node['runit']['sv_dir']
      end
      options['sv_bin'] ||= '/usr/bin/sv'
      options['sv_dir'] ||= '/etc/sv'
      # Build the runit_service resource.
      @service_resource ||= Chef::Resource::RunitService.new(new_resource.name, run_context).tap do |r|
        r.provider service_provider
        r.service_name new_resource.service_name
        r.owner 'root'
        r.group 'root'
        r.sv_bin options['sv_bin']
        r.sv_dir options['sv_dir']
        r.sv_timeout options['timeout'] if options['timeout']
        r.options options.merge(new_resource: new_resource, runit_signals: RUNIT_SIGNALS)
        r.env Mash.new(options['environment'] || new_resource.environment)
        r.run_template_name 'template'
        r.log_template_name 'template'
        # Force h and t because those map to stop_signal and reload_signal.
        control = []
        control << 'h' if new_resource.reload_signal != 'HUP'
        control += %w{d t} if new_resource.stop_signal != 'TERM'
        control += options['control'].keys if options['control']
        control.uniq!
        r.control control
        r.control_template_names Hash.new { 'template-control' } # There is no name only Zuul.
        r.cookbook 'poise-service-runit'
        # Runit only supports the equivalent of our 'immediately' mode :-/
        r.restart_on_update new_resource.restart_on_update
      end
    end

    def check_signals!
      %w{reload_signal stop_signal}.each do |sig_type|
        signal = new_resource.send(sig_type)
        unless RUNIT_SIGNALS[signal]
          raise PoiseService::Error.new("Runit does not support sending #{signal}, please change the #{sig_type} on #{new_resource.to_s}")
        end
      end
    end

    # Find the command to run run in dummy mode for testing inside docker.
    # If this returns nil, no dummy service is started.
    #
    # @return [String, nil]
    def dummy_command
      return options['dummy_command'] if options.include?('dummy_command')
      return nil unless node['virtualization'] && %w{docker lxc}.include?(node['virtualization']['system'])
      node.value_for_platform_family(debian: '/usr/sbin/runsvdir-start', rhel: '/sbin/runsvdir -P -H /etc/service')
    end

    # HAXX: Deal with starting runsvdir under Docker on Ubuntu/Debian/RHEL.
    # System packages use Upstart which doesn't run under Docker. Yo dawg.
    def check_dummy!
      if dummy_command
        PoiseService::Resource.new('runsvdir', run_context).tap do |r|
          r.command(dummy_command)
          r.provider(:dummy)
          r.run_action(:enable)
        end
      end
    end

  end
end
