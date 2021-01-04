require 'yaml'
require_relative "mysqllib"

module SSHModule
  @config = YAML.load_file('config.yaml')
  
  def self.run_local(cmd)
    return %x( #{cmd} )
  end

  def self.connect(ip, ami_id)
    elevate = nil
    result = false, nil
    extra_args = "2> /dev/null"
    @config['connection']['users'].each do |user|
      begin
        Net::SSH.start(ip, user, keys:@config['connection']['pem'], timeout:75) do |ssh|
          MYSQLModule::sql_insert("INSERT INTO ami_scanner.data (ami_id, aws_region, create_result) 
                                   VALUES (\"#{ami_id}\", 
                                           \"#{@config['aws']['region']}\", 
                                           \"success\")"
                                           )
          pp "[TASK_OK] SSH_AUTH || Successfully authenticated with #{user} to #{ip}"

          pre_test = ssh.exec!("#{elevate} ls")
          if pre_test.include? "Please login as the user"
            next
          end

          elevate = 'sudo' unless user.eql?('root')
          
          @config['assessment']['shell_cmds'].each do |name, cmd|  
            if name.eql?("sts")
              elevate = ''
            end

            if name.eql?("juicy_files")
              target_file = "#{ami_id}.tar"
              cmd = cmd % {:filename => "#{target_file}"}
              
              res = ssh.exec!("#{elevate} #{cmd} #{extra_args}")
              #MYSQLModule::sql_update(name, res, ami_id)
              run_local("#{elevate} scp -i #{@config['connection']['pem']} #{user}@#{ip}:/tmp/#{target_file} /root/data/")
              next
            end

            if name.eql?("collect")
              target_file = "#{ami_id}-collect.tar"
              cmd = cmd % {:filename => "#{target_file}"}
              ssh.exec!("#{elevate} #{cmd} #{extra_args}")
              run_local("#{elevate} scp -i #{@config['connection']['pem']} #{user}@#{ip}:/tmp/#{target_file} /root/data/")
              next
            end
            res = ssh.exec!("#{elevate} #{cmd} #{extra_args}")
            MYSQLModule::sql_update(name, res, ami_id)
          end
        end
        MYSQLModule::sql_update('create_result', 'Authentication Successful', ami_id)
        
      rescue Net::SSH::AuthenticationFailed => e
        MYSQLModule::sql_update('create_result', 'Authentication Failed', ami_id)
        result = false, '[ERROR] SSH_AUTH || Authentication Failed'
      rescue Net::SSH::ConnectionTimeout => e
        MYSQLModule::sql_update('create_result', 'Connection Timeout', ami_id)
        result = false, '[ERROR] SSH_AUTH || Connection Timeout'
      rescue Timeout::Error
        MYSQLModule::sql_update('create_result', 'Connection Timeout', ami_id)
        result = false, '[ERROR] SSH_AUTH || Connection Timeout'
      rescue Errno::ECONNREFUSED
        MYSQLModule::sql_update('create_result', 'Connection Refused', ami_id)
        result = false, '[ERROR] SSH_AUTH || Connection Refused'
      rescue Errno::ECONNRESET => e
        MYSQLModule::sql_update('create_result', 'Connection Reset', ami_id)
        result = false, '[ERROR] SSH_AUTH || Connection Reset'
      rescue => e
        result = false, e.to_s
      end
    end
    return result
  end
end