# Automate Method: delete_powered_off_vms
begin
  $evm.log(:info, "Starting delete_powered_off_vms")

  # Find all powered off OpenStack VMs
  all_vms = $evm.vmdb('vm').all
  openstack_vms = []
  
  all_vms.each do |vm|
    if vm.try(:type) && vm.type.to_s.include?('Openstack') && vm.power_state.to_s.downcase == 'off'
      openstack_vms << vm
    end
  end
  
  $evm.log(:info, "Found #{openstack_vms.length} powered-off OpenStack VMs")
  deleted_count = 0
  
  # Define OpenStack provider connection details
    # Change the correct Ems id, os_auth_url and password 
  PROVIDERS = {
    '1000000000007' => { 
      os_auth_url: "http://192.168.xxx.xx:5000/v3", #change the correct os_auth_url
      os_username: "admin",
      os_password: "zzzzzzzzzzzzzzz", #change the correct password
      os_domain_name: "Default"
    }
  }
  
  # Process each powered-off VM
  openstack_vms.each do |vm|
    begin
      $evm.log(:info, "Processing powered off VM: <#{vm.name}> (ID: #{vm.id})")
      
      # Check how long the VM has been powered off by looking at state change events
      powered_off_time = nil
      
      # Try to get last power state change event
      if vm.respond_to?(:event_logs)
        power_events = vm.event_logs.select { |event| event.event_type.to_s.include?('power') }
        if power_events.any?
          # Sort by most recent
          power_events = power_events.sort_by { |event| event.created_on }.reverse
          powered_off_time = power_events.first.created_on
        end
      end
      
      # If we couldn't find the event, check the last_scan_on attribute as fallback
      if powered_off_time.nil? && vm.respond_to?(:last_scan_on)
        powered_off_time = vm.last_scan_on
      end
      
      # Another fallback - check if vm has state_changed_on attribute
      if powered_off_time.nil? && vm.respond_to?(:state_changed_on)
        powered_off_time = vm.state_changed_on
      end
      
      # If we still don't have a time, check updated_on
      if powered_off_time.nil? && vm.respond_to?(:updated_on)
        powered_off_time = vm.updated_on
      end
      
      # If we can't determine when VM was powered off, log and skip
      if powered_off_time.nil?
        $evm.log(:warn, "Couldn't determine when VM:<#{vm.name}> was powered off - skipping")
        next
      end
      
      # Calculate time difference
      time_diff_hours = (Time.now - powered_off_time) / 3600
      $evm.log(:info, "VM:<#{vm.name}> has been powered off for #{time_diff_hours.round(2)} hours")
      
      # Only proceed if VM has been powered off for more than 2 hours
      if time_diff_hours < 2
        $evm.log(:info, "VM:<#{vm.name}> has been powered off for less than 2 hours - skipping")
        next
      end
      
      $evm.log(:info, "VM:<#{vm.name}> has been powered off for more than 2 hours - proceeding with deletion")
      
      # [Rest of your existing deletion code remains the same]
      deleted = false
      
      # Try Method 1: raw_destroy if available
      if vm.respond_to?(:raw_destroy)
        begin
          $evm.log(:info, "Trying raw_destroy for VM:<#{vm.name}>")
          vm.raw_destroy
          deleted = true
          $evm.log(:info, "Successfully deleted VM using raw_destroy")
        rescue => err
          $evm.log(:error, "Error using raw_destroy: #{err.message}")
        end
      else
        $evm.log(:info, "VM:<#{vm.name}> does not support raw_destroy")
      end
      
      # Try Method 2: raw_delete_vm if available
      if !deleted && vm.respond_to?(:raw_delete_vm)
        begin
          $evm.log(:info, "Trying raw_delete_vm for VM:<#{vm.name}>")
          vm.raw_delete_vm
          deleted = true
          $evm.log(:info, "Successfully deleted VM using raw_delete_vm")
        rescue => err
          $evm.log(:error, "Error using raw_delete_vm: #{err.message}")
        end
      end
      
      # Try Method 3: destroy if available
      if !deleted && vm.respond_to?(:destroy)
        begin
          $evm.log(:info, "Trying destroy for VM:<#{vm.name}>")
          vm.destroy
          deleted = true
          $evm.log(:info, "Successfully deleted VM using destroy")
        rescue => err
          $evm.log(:error, "Error using destroy: #{err.message}")
        end
      end
      
      # Try Method 4: Direct Fog API as last resort
      if !deleted
        begin
          $evm.log(:info, "Attempting direct deletion via Fog API for VM:<#{vm.name}>")
          
          # Get provider and tenant
          ems = vm.ext_management_system
          if ems.nil?
            $evm.log(:error, "No provider found for VM:<#{vm.name}>")
            next
          end
          
          ems_id = ems.id.to_s
          provider_config = PROVIDERS[ems_id]
          
          if provider_config.nil?
            $evm.log(:error, "Provider configuration not found for ems_id: #{ems_id}")
            $evm.log(:info, "Please add provider configuration to PROVIDERS hash for ems_id: #{ems_id}")
            next
          end
          
          tenant_name = vm.cloud_tenant.name rescue nil
          if tenant_name.nil?
            $evm.log(:error, "Could not determine tenant name for VM:<#{vm.name}>")
            next
          end
          
          # Set up Fog connection
          require 'fog/openstack'
          connection_params = {
            openstack_auth_url: provider_config[:os_auth_url],
            openstack_username: provider_config[:os_username],
            openstack_api_key: provider_config[:os_password],
            openstack_project_name: tenant_name,
            openstack_domain_name: provider_config[:os_domain_name],
            connection_options: { ssl_verify_peer: false }
          }
          
          # Connect to OpenStack and delete VM
          compute = Fog::OpenStack::Compute.new(connection_params)
          openstack_vm = compute.servers.get(vm.uid_ems)
          
          if openstack_vm.nil?
            $evm.log(:error, "Could not find VM in OpenStack with ID: #{vm.uid_ems}")
            next
          end
          
          $evm.log(:info, "Found VM in OpenStack, attempting deletion")
          result = openstack_vm.destroy
          
          if result
            deleted = true
            $evm.log(:info, "Successfully deleted VM using Fog API")
          else
            $evm.log(:error, "Failed to delete VM via Fog API")
          end
        rescue => err
          $evm.log(:error, "Error using Fog API: #{err.message}")
          $evm.log(:error, "#{err.backtrace.join("\n")}")
        end
      end
      
      # If VM was successfully deleted from OpenStack, remove from VMDB
      if deleted
        begin
          # Wait a moment for OpenStack to process the deletion
          sleep(10)
          
          # Refresh the provider to sync state
          provider = vm.ext_management_system
          if provider
            $evm.log(:info, "Refreshing provider: #{provider.name}")
            provider.refresh
          end
          
          # Remove from VMDB
          $evm.log(:info, "Removing VM:<#{vm.name}> from VMDB")
          vm.remove_from_vmdb
          deleted_count += 1
          $evm.log(:info, "Successfully removed VM:<#{vm.name}> from VMDB")
        rescue => err
          $evm.log(:error, "Error removing VM from VMDB: #{err.message}")
        end
      else
        $evm.log(:warn, "Failed to delete VM:<#{vm.name}> from OpenStack - not removing from VMDB")
      end
      
    rescue => err
      $evm.log(:error, "Error processing VM:<#{vm.name}> - #{err.message}")
      $evm.log(:error, "#{err.backtrace.join("\n")}")
    end
  end
  
  $evm.log(:info, "Finished delete_powered_off_vms - Deleted #{deleted_count} VMs")
  
rescue => err
  $evm.log(:error, "Unhandled error in script: #{err.message}")
  $evm.log(:error, "#{err.backtrace.join("\n")}")
end
