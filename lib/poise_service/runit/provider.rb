#
# Copyright 2015-2016, Noah Kantrowitz
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

require 'poise_service/error'
require 'poise_service/service_providers/base'


module PoiseService
  module Runit
    # Poise-service provider for [Runit](http://smarden.org/runit/index.html).
    #
    # @since 1.0.0
    # @example
    #   poise_service 'myapp' do
    #     command 'myapp --serve'
    #     provider :runit
    #   end
    class Provider < PoiseService::ServiceProviders::Base
      provides(:runit)

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
        ['runit', proc {
          begin
            if node['virtualization'] && %w{docker lxc}.include?(node['virtualization']['system'])
              resources('service[runsvdir-start]').action(:nothing)
            end
          rescue Chef::Exceptions::ResourceNotFound
          end
        }]
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

      # Hack the enable action for the runit provider. This forces it to wait
      # until runsv recognizes the new service. This is tracked upstream in
      # https://github.com/hw-cookbooks/runit/issues/136
      #
      # @api private
      # @todo Remove once the upstream bug is fixed.
      def enable_service
        super
        sleep 1 until ::FileTest.pipe?("#{service_resource.service_dir}/#{service_resource.service_name}/supervise/ok")
        if service_resource.log
          sleep 1 until ::FileTest.pipe?("#{service_resource.service_dir}/#{service_resource.service_name}/log/supervise/ok")
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
        base_class = if defined?(Chef::Provider::RunitService)
          Chef::Provider::RunitService
        elsif defined?(Chef::Provider::Service::Runit)
          Chef::Provider::Service::Runit
        else
          raise PoiseService::Error.new('Unable to find runit_service provider class.')
        end
        Class.new(base_class) do
          # Lie about the name.
          def self.name
            superclass.name
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
        run_dummy!
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
          if options['template']
            cookbook, template = options['template'].split(':')
            r.cookbook cookbook
            r.run_template_name  template
          else
            r.cookbook cookbook 'poise-service-runit'
            r.run_template_name 'template'
          end
          r.log_template_name 'template'
          # Force h and t because those map to stop_signal and reload_signal.
          control = []
          control << 'h' if new_resource.reload_signal != 'HUP'
          control += %w{d t} if new_resource.stop_signal != 'TERM'
          control += options['control'].keys if options['control']
          control.uniq!
          r.control control
          r.control_template_names Hash.new { 'template-control' } # There is no name only Zuul.
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
      #
      # @return [void]
      def run_dummy!
        if dummy_command
          Chef::Resource.resource_for_node(:poise_service, node).new('runsvdir', run_context).tap do |r|
            r.command(dummy_command)
            r.provider(:dummy)
            r.run_action(:enable)
          end
        end
      end

    end
  end
end
