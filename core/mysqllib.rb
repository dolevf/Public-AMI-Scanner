
  require 'yaml'
  require 'mysql'

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