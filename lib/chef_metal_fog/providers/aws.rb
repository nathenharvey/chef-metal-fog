require 'chef/log'
require 'fog/aws'
require 'uri'

#   fog:AWS:<account_id>:<region>
#   fog:AWS:<profile_name>
#   fog:AWS:<profile_name>:<region>
module ChefMetalFog
  module Providers
    class AWS < ChefMetalFog::FogDriver

      require_relative 'aws/credentials'

      ChefMetalFog::FogDriver.register_provider_class('AWS', ChefMetalFog::Providers::AWS)

      def creator
        driver_options[:aws_account_info][:aws_username]
      end

      def default_ssh_username
        'ubuntu'
      end

      def allocate_image(action_handler, image_spec, image_options, machine_spec)
        if image_spec.location
          image = compute.images.get(image_spec.location['image_id'])
          if image
            raise "The image already exists, why are you asking me to create it?  I can't do that, Dave."
          end
        end
        action_handler.perform_action "Create image #{image_spec.name} from machine #{machine_spec.name} with options #{image_options.inspect}" do
          opt = image_options.dup
          response = compute.create_image(machine_spec.location['server_id'],
                                       image_spec.name,
                                       opt.delete(:description) || "The image formerly and currently named '#{image_spec.name}'",
                                       opt.delete(:no_reboot) || false,
                                       opt)
          image_spec.location = {
            'driver_url' => driver_url,
            'driver_version' => ChefMetalFog::VERSION,
            'image_id' => response.body['imageId'],
            'creator' => creator,
            'allocated_at' => Time.now.to_i
          }

          image_spec.machine_options ||= {}
          image_spec.machine_options.merge!({
            :bootstrap_options => {
                :image_id => image_spec.location['image_id']
            }
          })

        end
      end

      def ready_image(action_handler, image_spec, image_options)
        if !image_spec.location
          raise "Cannot ready an image that does not exist"
        end
        image = compute.images.get(image_spec.location['image_id'])
        if !image.ready?
          action_handler.report_progress "Waiting for image to be ready ..."
          # TODO timeout
          image.wait_for { ready? }
          action_handler.report_progress "Image is ready!"
        end
      end

      def destroy_image(action_handler, image_spec, image_options)
        if !image_spec.location
          return
        end
        image = compute.images.get(image_spec.location['image_id'])
        if !image
          return
        end
        delete_snapshots = image_options[:delete_snapshots]
        delete_snapshots = true if delete_snapshots.nil?
        image.deregister(delete_snapshots)
      end

      def bootstrap_options_for(action_handler, machine_spec, machine_options)
        bootstrap_options = symbolize_keys(machine_options[:bootstrap_options] || {})

        if !bootstrap_options[:key_name]
          bootstrap_options[:key_name] = overwrite_default_key_willy_nilly(action_handler)
        end
        bootstrap_options.delete(:tags) # we handle these separately for performance reasons
        bootstrap_options
      end

      def create_servers(action_handler, specs_and_options, parallelizer)
        super(action_handler, specs_and_options, parallelizer) do |machine_spec, server|
          yield machine_spec, server if block_given?

          machine_options = specs_and_options[machine_spec]
          bootstrap_options = symbolize_keys(machine_options[:bootstrap_options] || {})
          tags = default_tags(machine_spec, bootstrap_options[:tags] || {})

          # Right now, not doing that in case manual tagging is going on
          server_tags = server.tags || {}
          extra_tags = tags.keys.select { |tag_name| !server_tags.has_key?(tag_name) }.to_a
          different_tags = server_tags.select { |tag_name, tag_value| tags.has_key?(tag_name) && tags[tag_name] != tag_value }.to_a
          if extra_tags.size > 0 || different_tags.size > 0
            tags_description = [ "Update tags for #{machine_spec.name} on #{driver_url}" ]
            tags_description += extra_tags.map { |tag| "  Add #{tag} = #{tags[tag].inspect}" }
            tags_description += different_tags.map { |tag_name, tag_value| "  Update #{tag_name} from #{tag_value.inspect} to #{tags[tag_name].inspect}"}
            action_handler.perform_action tags_description do
              # TODO should we narrow this down to just extra/different tags or
              # is it OK to just pass 'em all?  Certainly easier to do the
              # latter, and I can't think of a consequence for doing so offhand.
              compute.create_tags(server.identity, tags)
            end
          end
        end
      end

      def convergence_strategy_for(machine_spec, machine_options)
        machine_options[:convergence_options][:ohai_hints] = { 'ec2' => ''}
        super(machine_spec, machine_options)
      end

      def self.get_aws_profile(driver_options, aws_account_id)
        aws_credentials = get_aws_credentials(driver_options)
        compute_options = driver_options[:compute_options] || {}

        # Order of operations:
        # compute_options[:aws_access_key_id] / compute_options[:aws_secret_access_key] / compute_options[:aws_security_token] / compute_options[:region]
        # compute_options[:aws_profile]
        # ENV['AWS_ACCESS_KEY_ID'] / ENV['AWS_SECRET_ACCESS_KEY'] / ENV['AWS_SECURITY_TOKEN'] / ENV['AWS_REGION']
        # ENV['AWS_PROFILE']
        # ENV['DEFAULT_PROFILE']
        # 'default'
        if compute_options[:aws_access_key_id]
          Chef::Log.debug("Using AWS driver access key options")
          aws_profile = {
            :aws_access_key_id => compute_options[:aws_access_key_id],
            :aws_secret_access_key => compute_options[:aws_secret_access_key],
            :aws_security_token => compute_options[:aws_session_token],
            :region => compute_options[:region]
          }
        elsif driver_options[:aws_profile]
          Chef::Log.debug("Using AWS profile #{driver_options[:aws_profile]}")
          aws_profile = aws_credentials[driver_options[:aws_profile]]
        elsif ENV['AWS_ACCESS_KEY_ID'] || ENV['AWS_ACCESS_KEY']
          Chef::Log.debug("Using AWS environment variable access keys")
          aws_profile = {
            :aws_access_key_id => ENV['AWS_ACCESS_KEY_ID'] || ENV['AWS_ACCESS_KEY'],
            :aws_secret_access_key => ENV['AWS_SECRET_ACCESS_KEY'] || ENV['AWS_SECRET_KEY'],
            :aws_security_token => ENV['AWS_SECURITY_TOKEN'],
            :region => ENV['AWS_REGION']
          }
        elsif ENV['AWS_PROFILE']
          Chef::Log.debug("Using AWS profile #{ENV['AWS_PROFILE']} from AWS_PROFILE environment variable")
          aws_profile = aws_credentials[ENV['AWS_PROFILE']]
          if !aws_profile
            raise "Environment variable AWS_PROFILE is set to #{ENV['AWS_PROFILE'].inspect} but your AWS config file does not contain that profile!"
          end
        else
          Chef::Log.debug("Using AWS default profile")
          aws_profile = aws_credentials.default
        end

        default_ec2_endpoint = compute_options[:ec2_endpoint] || ENV['EC2_URL']
        default_iam_endpoint = compute_options[:iam_endpoint] || ENV['AWS_IAM_URL']

        # Merge in account info for profile
        if aws_profile
          aws_profile = aws_profile.merge(aws_account_info_for(aws_profile, default_iam_endpoint))
        end

        # If no profile is found (or the profile is not the right account), search
        # for a profile that matches the given account ID
        if aws_account_id && (!aws_profile || aws_profile[:aws_account_id] != aws_account_id)
          aws_profile = find_aws_profile_for_account_id(aws_credentials, aws_account_id, iam_endpoint)
        end

        if !aws_profile
          raise "No AWS profile specified!  Are you missing something in the Chef config or ~/.aws/config?"
        end

        aws_profile[:ec2_endpoint] ||= default_ec2_endpoint
        aws_profile[:iam_endpoint] ||= default_iam_endpoint

        aws_profile.delete_if { |key, value| value.nil? }
        aws_profile
      end

      def self.find_aws_profile_for_account_id(aws_credentials, aws_account_id, default_iam_endpoint=nil)
        aws_profile = nil
        aws_credentials.each do |profile_name, profile|
          begin
            aws_account_info = aws_account_info_for(profile, default_iam_endpoint)
          rescue
            Chef::Log.warn("Could not connect to AWS profile #{aws_credentials[:name]}: #{$!}")
            Chef::Log.debug($!.backtrace.join("\n"))
            next
          end
          if aws_account_info[:aws_account_id] == aws_account_id
            aws_profile = profile
            aws_profile[:name] = profile_name
            aws_profile = aws_profile.merge(aws_account_info)
            break
          end
        end
        if aws_profile
          Chef::Log.info("Discovered AWS profile #{aws_profile[:name]} pointing at account #{aws_account_id}.  Using ...")
        else
          raise "No AWS profile leads to account ##{aws_account_id}.  Do you need to add profiles to ~/.aws/config?"
        end
        aws_profile
      end

      def self.aws_account_info_for(aws_profile, default_iam_endpoint = nil)
        iam_endpoint = aws_profile[:iam_endpoint] || default_iam_endpoint

        @@aws_account_info ||= {}
        @@aws_account_info[aws_profile[:aws_access_key_id]] ||= begin
          options = {
            # Endpoint configuration
            :aws_access_key_id => aws_profile[:aws_access_key_id],
            :aws_secret_access_key => aws_profile[:aws_secret_access_key],
            :aws_session_token => aws_profile[:aws_security_token]
          }
          if iam_endpoint
            options[:host] = URI(iam_endpoint).host
            options[:scheme] = URI(iam_endpoint).scheme
            options[:port] = URI(iam_endpoint).port
            options[:path] = URI(iam_endpoint).path
          end
          options.delete_if { |key, value| value.nil? }

          iam = Fog::AWS::IAM.new(options)
          arn = begin
                  # TODO it would be nice if Fog let you do this normally ...
                  iam.send(:request, {
                    'Action'    => 'GetUser',
                    :parser     => Fog::Parsers::AWS::IAM::GetUser.new
                  }).body['User']['Arn']
                rescue Fog::AWS::IAM::Error
                  # TODO Someone tell me there is a better way to find out your current
                  # user ID than this!  This is what happens when you use an IAM user
                  # with default privileges.
                  if $!.message =~ /AccessDenied.+(arn:aws:iam::\d+:\S+)/
                    arn = $1
                  else
                    raise
                  end
                end
          arn_split = arn.split(':', 6)
          {
            :aws_account_id => arn_split[4],
            :aws_username => arn_split[5],
            :aws_user_arn => arn
          }
        end
      end

      def self.get_aws_credentials(driver_options)
        # Grab the list of possible credentials
        if driver_options[:aws_credentials]
          aws_credentials = driver_options[:aws_credentials]
        else
          aws_credentials = Credentials.new
          if driver_options[:aws_config_file]
            aws_credentials.load_ini(driver_options.delete(:aws_config_file))
          elsif driver_options[:aws_csv_file]
            aws_credentials.load_csv(driver_options.delete(:aws_csv_file))
          else
            aws_credentials.load_default
          end
        end
        aws_credentials
      end

      def self.compute_options_for(provider, id, config)
        new_compute_options = {}
        new_compute_options[:provider] = provider
        new_config = { :driver_options => { :compute_options => new_compute_options }}
        new_defaults = {
          :driver_options => { :compute_options => {} },
          :machine_options => { :bootstrap_options => {} }
        }
        result = Cheffish::MergedConfig.new(new_config, config, new_defaults)

        if id && id != ''
          # AWS canonical URLs are of the form fog:AWS:
          if id =~ /^(\d{12})(:(.+))?$/
            if $2
              id = $1
              new_compute_options[:region] = $3
            else
              Chef::Log.warn("Old-style AWS URL #{id} from an early beta of chef-metal (before 0.11-final) found. If you have servers in multiple regions on this account, you may see odd behavior like servers being recreated. To fix, edit any nodes with attribute metal.location.driver_url to include the region like so: fog:AWS:#{id}:<region> (e.g. us-east-1)")
            end
          else
            # Assume it is a profile name, and set that.
            aws_profile, region = id.split(':', 2)
            new_config[:driver_options][:aws_profile] = aws_profile
            new_compute_options[:region] = region
            id = nil
          end
        end

        aws_profile = get_aws_profile(result[:driver_options], id)
        new_compute_options[:aws_access_key_id] = aws_profile[:aws_access_key_id]
        new_compute_options[:aws_secret_access_key] = aws_profile[:aws_secret_access_key]
        new_compute_options[:aws_session_token] = aws_profile[:aws_security_token]
        new_defaults[:driver_options][:compute_options][:region] = aws_profile[:region]
        new_defaults[:driver_options][:compute_options][:endpoint] = aws_profile[:ec2_endpoint]

        account_info = aws_account_info_for(result[:driver_options][:compute_options])
        new_config[:driver_options][:aws_account_info] = account_info
        id = "#{account_info[:aws_account_id]}:#{result[:driver_options][:compute_options][:region]}"

        # Make sure we're using a reasonable default AMI, for now this is Ubuntu 14.04 LTS
        result[:machine_options][:bootstrap_options][:image_id] ||=
            default_ami_for_region(result[:driver_options][:compute_options][:region])

        [result, id]
      end

      def create_many_servers(num_servers, bootstrap_options, parallelizer)
        # Create all the servers in one request if we have a version of fog that can do that
        if compute.servers.respond_to?(:create_many)
          servers = compute.servers.create_many(num_servers, num_servers, bootstrap_options)
          if block_given?
            parallelizer.parallelize(servers) do |server|
              yield server
            end.to_a
          end
          servers
        else
          super
        end
      end

      def servers_for(machine_specs)
        # Grab all the servers in one request
        instance_ids = machine_specs.map { |machine_spec| (machine_spec.location || {})['server_id'] }.select { |id| !id.nil? }
        servers = compute.servers.all('instance-id' => instance_ids)
        result = {}
        machine_specs.each do |machine_spec|
          if machine_spec.location
            result[machine_spec] = servers.select { |s| s.id == machine_spec.location['server_id'] }.first
          else
            result[machine_spec] = nil
          end
        end
        result
      end

      private
      def self.default_ami_for_region(region)
        Chef::Log.debug("Choosing default AMI for region '#{region}'")

        case region
        when 'ap-northeast-1'
          'ami-c786dcc6'
        when 'ap-southeast-1'
          'ami-eefca7bc'
        when 'ap-southeast-2'
          'ami-996706a3'
        when 'eu-west-1'
          'ami-4ab46b3d'
        when 'sa-east-1'
          'ami-6770d87a'
        when 'us-east-1'
          'ami-d2ff23ba'
        when 'us-west-1'
          'ami-73717d36'
        when 'us-west-2'
          'ami-f1ce8bc1'
        end
      end

    end
  end
end
