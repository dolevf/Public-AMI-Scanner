require 'yaml'
require 'aws-sdk'
require 'redis'
require 'pry'
require 'mysql'

module AMIResearch
  module RedisModule
    @redis = Redis.new

    def self.set(key, value)
      @redis.set(key, value)
    end

    def self.key_exists(key)
      return @redis.exists?(key)
    end
  end

  module MYSQLModule 
    @config = YAML.load_file('config.yaml')
    def self.sql_insert(query)
      begin
        con = Mysql.new  @config['db']['host'], @config['db']['user'], @config['db']['passw'], @config['db']['name']
        rs = con.query(query)  
        
      rescue Mysql::Error => e
        nil
        
      ensure
        con.close if con
      end
    end

    def self.sql_update(name, res, ami_id)
      begin
        
        if res.strip.empty?
          res = nil
        end
        
        con = Mysql.new 'localhost', 'root', '', 'ami_scanner'
        prep = con.prepare("UPDATE ami_scanner.data SET #{name} = ? WHERE ami_id = ?")
        prep.execute(res, ami_id)  
        
      rescue Mysql::Error => e
        puts e.errno
        puts e.error
        
      ensure
        con.close if con
      end
    end
  end

  module AWSModule
    include RedisModule
    @config = YAML.load_file('config.yaml')
    Aws.config.update(
      region: @config['aws']['region'],
      credentials: Aws::Credentials.new(@config['aws']['access_key'], @config['aws']['access_secret'],)
    )
    @ec2 = Aws::EC2::Client.new
      
    def self.get_images
      exclusions = ['bitnami', 'xtract', 'tensorflow', 'pytorch']
      data = Hash.new
      res =  @ec2.describe_images({
        filters: [
          {
            name: "name",
            values: ["*prod*", "*backup*", "*staging*", "*Testing*", "uat", "*internal*", "*private*", "*confidential*", "*live*", "*webserver*", "*redis*", 
                    "*mysql*", "*jenkins*", "*QA*", "*monitoring*", "*nginx*", "*apache*", "*pentest*", "*securitytest*", "*database*", "*datastore*", "*fileserver*"],
          },
          {
            name: "is-public", 
            values: ['true']
          },
        ],
      })
      
      res.images.each do |img|
        if RedisModule::key_exists("#{@config['aws']['region']}_#{img.image_id}")
          next
        end

        if (img.platform.eql?("Windows") || img.platform_details.eql?("Windows"))
          next
        end
        
        if img.owner_id.downcase == 'amazon'
          next
        end
        
        if exclusions.any? { |exc| img.name.include?(exc)}
          next
        end
        
        data[img.image_id] = Hash.new
        data[img.image_id]['name'] = img.name
        data[img.image_id]['region'] = @config['aws']['region']
        data[img.image_id]['image_id'] = img.image_id
        data[img.image_id]['owner_id'] = img.owner_id
        data[img.image_id]['creation_date'] = img.creation_date
      end
      
      return data

    end


    def self.create_instance(ami_id, amis)      
      resource = Aws::EC2::Resource.new
      begin
        res = resource.create_instances(
          image_id: ami_id,
          min_count: 1,
          max_count: 1,
          key_name: @config['connection']['pem_name'],
          instance_type: 't2.small',
          block_device_mappings:[
            {
              device_name:"/dev/sda1",
              ebs:{
                delete_on_termination: true,
                volume_size: 100
              }
            }
          ]
        )
        instance_id = res[0].data.instance_id
        MYSQLModule::sql_insert("INSERT INTO ami_scanner.data (ami_id, aws_region, ami_create_date, account_id, create_result)
                                 VALUES (\"#{ami_id}\", 
                                         \"#{@config['aws']['region']}\",
                                         \"#{amis[ami_id]['creation_date']}\",
                                         \"#{amis[ami_id]['owner_id']}\",
                                         \"success\")"
                                 )
        return instance_id
      rescue => e
        MYSQLModule::sql_insert("INSERT INTO ami_scanner.data (ami_id, aws_region, create_result)
                                 VALUES (\"#{ami_id}\", 
                                         \"#{@config['aws']['region']}\",
                                         \"#{e}\")"
                                )
        p "[ERROR] AMI_CREATE || #{ami_id} #{e}"
      end
      return nil
    end

    def self.start_instance(id)
      @ec2.start_instances(instance_ids: [id])
    end
    
    def self.terminate_instance(id)
      p "[TASK_INFO] EC2_TERMINATE || #{id}..."
      res = @ec2.terminate_instances(instance_ids:[id])
    end

    def self.describe_instance(id)
      return @ec2.describe_instances({
        instance_ids: [id],
      })
    end

    def self.get_instance_ip(id)
      begin
        resp = self.describe_instance(id)
        return resp[0][0].instances[0].network_interfaces[0].association.public_ip
      rescue
        nil
      else
        return nil
      end
    end

    def self.limit_exceeded
      total_count = @ec2.describe_instances.reservations.length
      running_count = 0
      @ec2.describe_instances.reservations.each do |i|
        i.instances.each do |instance|
          running_count +=1 unless instance.state.name == "terminated" || instance.state.name == "stopped"  || instance.state.name == "stopping"
        end
      end
    
      if running_count < @config['aws']['spawn_limit']
        return false
      end

      return true
      end
    end

  module SSHModule
    include MYSQLModule

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
end