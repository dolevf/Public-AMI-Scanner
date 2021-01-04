require 'redis'

module RedisModule
  @redis = Redis.new

  def self.set(key, value)
    @redis.set(key, value)
  end

  def self.key_exists(key)
    return @redis.exists?(key)
  end
end

