require 'xmlrpc/client'
Puppet::Type.type(:cobblersystem).provide(:system) do
  # this code is based on code grabbed from:
  #    https://bitbucket.org/jsosic/puppet-cobbler/
  #    thanks to jsosic for writing these types.
  #
  desc 'Support for managing the Cobbler systems'

  optional_commands :cobbler => '/usr/bin/cobbler'

  mk_resource_methods

  def self.instances
    keys = []
    # connect to cobbler server on localhost
    cobblerserver = XMLRPC::Client.new2('http://127.0.0.1/cobbler_api')
    # make the query (get all systems)
    xmlrpcresult = cobblerserver.call('get_systems')

    # get properties of current system to @property_hash
    xmlrpcresult.each do |member|
      # put only keys with values in interfaces hash
      inet_hash = {}
      member['interfaces'].each do |iface_name,iface_settings|
        inet_hash["#{iface_name}"] = {}
        iface_settings.each do |key,val|
          inet_hash["#{iface_name}"]["#{key}"] = val unless val == '' or val == []
        end
      end
      keys << new(
        :name           => member['name'],
        :ensure         => :present,
        :profile        => member['profile'],
        :interfaces     => inet_hash,
        :hostname       => member['hostname'],
        :gateway        => member['gateway'],
        :netboot        => member['netboot_enabled'].to_s,
        :comment        => member['comment'],
        :power_user     => member['power_user'],
        :power_address  => member['power_address'],
        :power_password => member['power_pass'],
        :power_id       => member['power_id'],
        :power_type     => member['power_type'],
        :kickstart      => member['kickstart'],
        :kernel_options => member['kernel_options']
      )
    end
    keys
  end

  def self.prefetch(resources)
    instances.each do |prov|
      if resource = resources[prov.name]
        resource.provider = prov
      end
    end
  end

  # sets interfaces
  def interfaces=(value)
    # name argument for cobbler
    namearg='--name=' + @resource[:name]

    # cobbler limitation: cannot delete all interfaces from system :(
    # so we must complicate interface sync by first adding temp
    # interface, then deleting/recreating all other interfaces
    # and finally deleting temp

    # connect to cobbler server on localhost
    cobblerserver = XMLRPC::Client.new2('http://127.0.0.1/cobbler_api')
    # make the query (get all systems)
    xmlrpcresult = cobblerserver.call('get_systems')
    # get properties of current system to variable
    currentsystem = {}
    xmlrpcresult.each do |member|
      currentsystem = member if member['name'] == @resource[:name]
    end
    # add temp interface
    cobbler('system', 'edit', namearg, '--interface=tmp_puppet', '--static=true')
    # delete all other intefraces
    currentsystem['interfaces'].each do |iface_name,iface_settings|
      cobbler('system', 'edit', namearg, '--interface=' + iface_name, '--delete-interface')
    end

    # recreate interfaces according to resource in puppet
    value.each do |iface, settings|
      ifacearg = '--interface=' + iface

      settings.each do |key,val|
        # substitute _ for -
        setting = key.gsub(/_/,'-')
        # finally construct command and edit system properties
        unless val.nil?
          val = val.join(' ') if val.is_a?(Array)
          valuearg = "--#{setting}=" + val.to_s
          cobbler('system', 'edit', namearg, ifacearg, valuearg)
        else
          cobbler('system', 'edit', namearg, ifacearg, "--#{setting}=''")
        end
      end
    end

    # remove temp interface
    cobbler('system', 'edit', namearg, '--interface=tmp_puppet', '--delete-interface')

    @property_hash[:interfaces]=(value)
  end

  # this code dynamically creates setter methods for properties
  # b/c the implementation code is exactly the same
  [
    :power_user     => 'power_user',
    :power_address  => 'power_address',
    :power_password => 'power_pass',
    :power_id       => 'power_id',
    :power_type     => 'power_type',
    :kickstart      => 'kickstart'
  ].each do |attr, id|
     define_method(attr.to_s + "=") do |value|
       @property_hash[attr] = value
     end
  end

  def kernel_options=(value)
    new_value = "'"
    value.each do |k, v|
      new_value << "#{k}=#{v} "
    end
    new_value << "'"
    cobbler('system', 'edit', '--name=' + @resource[:name], '--kopts=' + new_value)
    @property_hash[:kernel_options] = value
  end

  def create
    @action = 'add'
    @property_hash[:ensure] = :absent
  end

  def destroy
    # remove system from cobbler
    cobbler('system', 'remove', '--name=' + @resource[:name])
    cobbler('sync')
    # update @property_hash
    @property_hash[:ensure] = :absent
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  # flush does all of the real work
  def flush
    args = ''
    # first build out the argument list
    {
      :profile        => 'profile',
      :hostname       => 'hostname',
      :gateway        => 'gateway',
      :comment        => 'comment',
      :kickstart      => 'kickstart',
      :power_user     => 'power-user',
      :power_address  => 'power-address',
      :power_password => 'power-pass',
      :power_id       => 'power-id',
      :power_type     => 'power-type',
    }.each do |attr, id|
      args << " --#{id}=#{resource[attr]} "
    end
    # netboot is a little special
    if resource[:netboot]
      args << " --netboot-enabled=1 "
    else
      args << " --netboot-enabled=0 "
    end
    # do nothing if we were destroying the resource
    unless @action == 'destroy'
      if @action != 'add'
        @action = 'edit'
      end
      begin
        output = cobbler('system', @action, "--name=#{resource[:name]}", args)
      rescue Puppet::ExecutionFailure => e
        fail("Call to cobbler system #{@action} failed with output: #{output}")
      end
      interfaces = resource[:interfaces] if resource[:interfaces]
      begin
        output = cobbler('sync')
      rescue Puppet::ExecutionFailure => e
        fail("Call to cobbler sync failed with output: #{output}")
      end
    end
  end
end
