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

require 'poise_service/providers/base'


module PoiseService
  module Providers
    class Runit < Base
      poise_service_provides(:runit)

      private

      def recipes
        'runit'
      end

      def create_service
        # Enable automatically creates the service with Runit.
        directory "/var/log/#{new_resource.service_name}" do
          owner 'root'
          group 'root'
          mode '700'
        end

        # HAXX: Deal with starting runsvdir under Docker on Ubuntu/Debian. The
        # system packages use Upstart which doesn't run under Docker. Yo dawg.
        if node['platform_family'] == 'debian' && node['virtualization'] && %w{docker lxc}.include?(node['virtualization']['system'])
          poise_service 'runsvdir' do
            command '/usr/sbin/runsvdir-start'
            provider :sysvinit
          end
        end
      end

      def destroy_service
        # Disable automatically destroys the service with Runit.
        directory "/var/log/#{new_resource.service_name}" do
          action :delete
        end
      end

      # @see Base#service_resource
      def service_resource
        @service_resource ||= Chef::Resource::RunitService.new(new_resource.name, run_context).tap do |r|
          r.service_name new_resource.service_name
          r.owner 'root'
          r.group 'root'
          r.sv_timeout options['timeout'] if options['timeout']
          r.options options.merge(new_resource: new_resource)
          r.env new_resource.environment
          r.run_template_name 'template'
          r.log_template_name 'template'
          r.cookbook 'poise-service-runit'
        end
      end
    end
  end
end
