# Copyright 2011 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package "mongodb" do
  action :install
end

service "mongodb" do
  supports :status => true, :restart => true
  action :enable
end

template "/etc/mongodb.conf" do
  mode 0644
  source "mongodb.conf.erb"
  notifies :restart, resources(:service => "mongodb"), :immediately
end

unless node[:ceilometer][:use_gitrepo]
  unless node.platform == "suse"
    package "ceilometer-common"
    package "ceilometer-collector"
    package "ceilometer-api"
  else
    package "openstack-ceilometer-collector"
    package "openstack-ceilometer-api"
  end
else
  ceilometer_path = "/opt/ceilometer"
  pfs_and_install_deps("ceilometer")
  link_service "ceilometer-collector"
  link_service "ceilometer-api"
  create_user_and_dirs("ceilometer") 
  execute "cp_policy.json" do
    command "cp #{ceilometer_path}/etc/ceilometer/policy.json /etc/ceilometer"
    creates "/etc/ceilometer/policy.json"
  end
  execute "cp_pipeline.yaml" do
    command "cp #{ceilometer_path}/etc/ceilometer/pipeline.yaml /etc/ceilometer"
    creates "/etc/ceilometer/pipeline.yaml"
  end
end

include_recipe "#{@cookbook_name}::common"

directory "/var/cache/ceilometer" do
  owner node[:ceilometer][:user]
  group "root"
  mode 00755
  action :create
end unless node.platform == "suse"

env_filter = " AND keystone_config_environment:keystone-config-#{node[:ceilometer][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_host = keystone[:fqdn]
keystone_protocol = keystone["keystone"]["api"]["protocol"]
keystone_token = keystone["keystone"]["service"]["token"]
keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
keystone_service_port = keystone["keystone"]["api"]["service_port"]
keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
keystone_service_user = node["ceilometer"]["keystone_service_user"]
keystone_service_password = node["ceilometer"]["keystone_service_password"]
Chef::Log.info("Keystone server found at #{keystone_host}")

my_admin_host = node[:fqdn]
# For the public endpoint, we prefer the public name. If not set, then we
# use the IP address except for SSL, where we always prefer a hostname
# (for certificate validation).
my_public_host = node[:crowbar][:public_name]
if my_public_host.nil? or my_public_host.empty?
  unless node[:ceilometer][:api][:protocol] == "https"
    my_public_host = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public").address
  else
    my_public_host = 'public.'+node[:fqdn]
  end
end

service "ceilometer-collector" do
  service_name "openstack-ceilometer-collector" if node.platform == "suse"
  supports :status => true, :restart => true
  action :enable
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
end

service "ceilometer-api" do
  service_name "openstack-ceilometer-api" if node.platform == "suse"
  supports :status => true, :restart => true
  action :enable
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
end

keystone_register "register ceilometer user" do
  protocol keystone_protocol
  host keystone_host
  port keystone_admin_port
  token keystone_token
  user_name keystone_service_user
  user_password keystone_service_password
  tenant_name keystone_service_tenant
  action :add_user
end

keystone_register "give ceilometer user access" do
  protocol keystone_protocol
  host keystone_host
  port keystone_admin_port
  token keystone_token
  user_name keystone_service_user
  tenant_name keystone_service_tenant
  role_name "admin"
  action :add_access
end

# Create ceilometer service
keystone_register "register ceilometer service" do
  protocol keystone_protocol
  host keystone_host
  port keystone_admin_port
  token keystone_token
  service_name "ceilometer"
  service_type "metering"
  service_description "Openstack Collector Service"
  action :add_service
end

keystone_register "register ceilometer endpoint" do
  protocol keystone_protocol
  host keystone_host
  port keystone_admin_port
  token keystone_token
  endpoint_service "ceilometer"
  endpoint_region "RegionOne"
  endpoint_publicURL "#{node[:ceilometer][:api][:port]}://#{my_public_host}:#{node[:ceilometer][:api][:port]}/"
  endpoint_adminURL "#{node[:ceilometer][:api][:port]}://#{my_admin_host}:#{node[:ceilometer][:api][:port]}/"
  endpoint_internalURL "#{node[:ceilometer][:api][:port]}://#{my_admin_host}:#{node[:ceilometer][:api][:port]}/"
#  endpoint_global true
#  endpoint_enabled true
  action :add_endpoint_template
end
