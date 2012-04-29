require 'blimpy/helpers/state'
require 'blimpy/livery'
require 'blimpy/keys'

module Blimpy
  class Box
    include Blimpy::Helpers::State

    # Default to US West (Oregon)
    DEFAULT_REGION = 'us-west-2'
    # Default to 10.04 64-bit
    DEFAULT_IMAGE_ID = 'ami-ec0b86dc'

    attr_reader :allowed_regions, :region
    attr_accessor :image_id, :livery, :group
    attr_accessor :name, :tags, :fleet_id, :username

    def self.from_instance_id(an_id, data)
      region = data['region'] || DEFAULT_REGION
      fog = Fog::Compute.new(:provider => 'AWS', :region => region)
      server = fog.servers.get(an_id)
      if server.nil?
        return nil
      end
      box = self.new(server)
      box.name = data['name']
      box
    end

    def initialize(server=nil)
      @allowed_regions = ['us-west-1', 'us-west-2', 'us-east-1']
      @region = DEFAULT_REGION
      @image_id = DEFAULT_IMAGE_ID
      @livery = nil
      @group = nil
      @name = 'Unnamed Box'
      @username = 'ubuntu'
      @tags = {}
      @server = server
      @fleet_id = 0
      @ssh_connected = false
      @exec_commands = true
    end

    def region=(newRegion)
      unless @allowed_regions.include? newRegion
        raise InvalidRegionError
      end
      @region = newRegion
    end

    def validate!
      if Fog::Compute[:aws].security_groups.get(@group).nil?
        raise BoxValidationError
      end
    end

    def online!
      File.open(state_file, 'a') do |f|
        f.write("dns: #{@server.dns_name}\n")
        f.write("internal_dns: #{@server.private_dns_name}\n")
      end
    end

    def start
      ensure_state_folder
      @server = create_host
      write_state_file
    end

    def bootstrap
      @exec_commands = false
      unless livery.nil?
        wait_for_sshd
        bootstrap_livery
      end
    end

    def stop
      unless @server.nil?
        @server.stop
      end
    end

    def resume
      unless @server.nil?
        @server.start
      end
    end

    def destroy
      unless @server.nil?
        @server.destroy
        File.unlink(state_file)
      end
    end

    def write_state_file
      File.open(state_file, 'w') do |f|
        f.write("name: #{@name}\n")
        f.write("region: #{@region}\n")
      end
    end

    def state_file
      if @server.nil?
        raise Exception, "I can't make a state file without a @server!"
      end
      File.join(state_folder, "#{@server.id}.blimp")
    end

    def wait_for_state(until_state, &block)
      if @server.nil?
        return
      end

      @server.wait_for do
        block.call
        state == until_state
      end
    end

    def dns_name
      return @server.dns_name unless @server.nil?
      'no name'
    end

    def internal_dns_name
      return @server.private_dns_name unless @server.nil?
      'no name'
    end

    def run_command(*args)
      if @exec_commands
        ::Kernel.exec(*args)
      else
        ::Kernel.system(*args)
      end
    end

    def ssh_into(*args)
      # Support using #ssh_into within our own code as well to pass arguments
      # to the ssh(1) binary
      args = args || ARGV[2 .. -1]
      run_command('ssh', '-o', 'StrictHostKeyChecking=no',
                  '-l', username, dns_name, *args)
    end

    def scp_file(filename)
      filename = File.expand_path(filename)
      run_command('scp', '-o', 'StrictHostKeyChecking=no',
                  filename, "#{username}@#{dns_name}:", *ARGV[3..-1])
    end

    def bootstrap_livery
      tarball = nil
      if livery == :cwd
        tarball = Blimpy::Livery.tarball_directory(Dir.pwd)
        scp_file(tarball)
        # HAXX
        basename = File.basename(tarball)
        puts 'Bootstrapping the livery'
        ssh_into("tar -zxf #{basename} && cd #{File.basename(tarball, '.tar.gz')} && sudo ./bootstrap.sh")
      end
    end

    def wait_for_sshd
      return if @ssh_connected
      start = Time.now.to_i
      use_exec = @exec_commands
      # Even if we are supposed to use #exec here, we wait to disable it until
      # after sshd(8) comes online
      @exec_commands = false

      print "..waiting for sshd on #{@name} to come online"
      until @ssh_connected
        # Run the `true` command and exit
        @ssh_connected = ssh_into('-q', 'true')

        unless @ssh_connected
          if (Time.now.to_i - start) < 30
            print '.'
            sleep 1
          end
        end
      end
      puts
      @exec_commands = use_exec
    end

    private

    def create_host
      tags = @tags.merge({:Name => @name, :CreatedBy => 'Blimpy', :BlimpyFleetId => @fleet_id})
      if @fog.nil?
        @fog = Fog::Compute.new(:provider => 'AWS', :region => @region)
      end

      Blimpy::Keys.import_key(@fog)
      @fog.servers.create(:image_id => @image_id,
                          :key_name => Blimpy::Keys.key_name,
                          :groups => [@group],
                          :tags => tags)
    end
  end
end
