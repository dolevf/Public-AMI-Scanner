require 'net/ssh'
require 'pry'
require_relative "./core/utils"

include AMIResearch

amis = AMIResearch::AWSModule.get_images
redis = AMIResearch::RedisModule
config = YAML.load_file('config.yaml')

def run_task(public_ip, ami_id, instance_id)
  AMIResearch::AWSModule.start_instance(instance_id)
  p "EC2_START || ip: #{public_ip} ami_id: #{ami_id} instance_id: #{instance_id}"
  sleep 120
  p "SSH_START || Attempting a Connection. ip: #{public_ip} ami_id: #{ami_id} instance_id: #{instance_id}"
  res, msg = AMIResearch::SSHModule.connect(public_ip, ami_id)
  p "SSH_END || #{msg}, ip: #{public_ip} ami_id: #{ami_id} instance_id: #{instance_id}"
  AMIResearch::AWSModule::terminate_instance(instance_id)
end

count = 0
total_count = amis.keys().length

p "[BEGIN] #{Time.now} - Region: #{config['aws']['region']} - AMI(s): #{total_count}" 

amis.keys().each do |ami_id|
  key = "#{amis[ami_id]['region']}_#{ami_id}"
  if redis.key_exists(key) == true
    next
  end
  count += 1

  while AMIResearch::AWSModule::limit_exceeded
    p "EC2_START || Instance Limit exceeded, sleeping for 30 seconds..."
    sleep 10
  end

  instance_id = AMIResearch::AWSModule.create_instance(ami_id, amis)
  
  redis.set(key, 1)
  
  if instance_id.nil? || !instance_id || !instance_id.start_with?('i-') 
    next
  end

  p "EC2_CREATE || Creating Instance from AMI: #{ami_id}"


  public_ip = AMIResearch::AWSModule.get_instance_ip(instance_id)
  
  while public_ip.nil?
    sleep 10
    public_ip = AMIResearch::AWSModule.get_instance_ip(instance_id)
  end
  
  Thread.start { run_task(public_ip, ami_id, instance_id) }
  
  p "AMI_STATUS || AMI(s) Left: [#{count}/#{total_count}]"
  
end

p "COMPLETE. Waiting 1200 seconds for everything to shut down properly."
sleep 1200
p "[END] #{Time.now}"