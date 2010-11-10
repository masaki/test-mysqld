require "fileutils"
require "mkmf"
require "tmpdir"

module Test
  class Mysqld
    def initialize(options={})
      parse_options options
      raise "mysqld is alread running (#{mycnf["pid-file"]})" if FileTest.exist? mycnf["pid-file"]
      if options[:auto_start]
        setup
        start
      end
      setup
    end

    def dsn(options={})
      options.tap do |option|
        options[:port] ||= mycnf["port"] if mycnf["port"]
        if options[:port]
          options[:host] ||= mycnf["bind-address"] || "127.0.0.1"
        else
          options[:socket] ||= mycnf["socket"]
        end
        options[:username] ||= "root"
        options[:database] ||= "test"
      end
    end

    def setup
      File.open(base_dir + '/etc/my.cnf', 'wb') do |f|
        f.puts "[mysqld]"
        mycnf.each do |key, val|
          if val.nil? or val.empty?
            f.puts "#{val}"
          else
            f.puts "#{key}=#{val}"
          end
        end
      end
      return if FileTest.directory? base_dir + '/var/mysql'

      mysql_base_dir = mysql_install_db.sub(%r'/[^/]+/mysql_install_db','')
      output = nil
      begin
        IO.popen %[#{mysql_install_db} --basedir='#{mysql_base_dir}' --defaults-file='#{base_dir}/etc/my.cnf' 2>&1] do |pipe|
          output = pipe.read
        end
      rescue
        raise "mysql_install_db failed" + (output ||= "")
      end
    end

    def start
      return if pid

      mysqld_log = File.open(base_dir + '/tmp/mysqld.log', 'a')
      @pid = fork do
        $stdout.reopen mysqld_log
        $stderr.reopen mysqld_log
        exec %[#{mysqld} --defaults-file='#{base_dir}/etc/my.cnf' --user=root]
      end
      exit unless @pid
      mysqld_log.close

      output = nil
      begin
        while !FileTest.exist?(mycnf["pid-file"])
          if Process.waitpid pid, Process::WNOHANG
            output = File.open(base_dir + '/tmp/mysqld.log'){ |f| f.read }
          end
          sleep 0.1
        end
      rescue
        raise "mysqld failed" + (output ||= "")
      end
      create_database

      at_exit { stop }
    end

    def stop(signal=nil)
      return unless pid
      if File.exist? mycnf["pid-file"]
        realpid = File.open(mycnf["pid-file"], "rb"){ |f| f.read }.strip.to_i
        Process.kill Signal.list[signal || "TERM"], realpid rescue nil
        Process.waitpid(realpid) rescue nil
      end
      Process.kill Signal.list[signal || "TERM"], pid rescue nil
      Process.waitpid(pid) rescue nil
      FileUtils.rm_f mycnf["pid-file"] if File.exist? mycnf["pid-file"]
      @pid = nil
    end

    attr_reader :base_dir, :mycnf, :mysqld, :mysql_install_db, :pid

    private

    def parse_options(options)
      @base_dir = options[:base_dir] || default_base_dir

      @mycnf = options[:mycnf] || {}
      @mycnf["socket"]   ||= base_dir + '/tmp/mysql.sock'
      @mycnf["datadir"]  ||= base_dir + '/var'
      @mycnf["pid-file"] ||= base_dir + '/tmp/mysql.pid'

      @mysqld           = options[:mysqld] || find_mysqld
      @mysql_install_db = options[:mysql_install_db] || find_mysql_install_db
    end

    def find_mysqld
      suppress_logging
      find_executable 'mysqld'
    end

    def find_mysql_install_db
      suppress_logging
      find_executable 'mysql_install_db'
    end

    def default_base_dir
      Dir.mktmpdir.tap { |dir|
        at_exit { FileUtils.remove_entry_secure dir if FileTest.directory? dir }

        FileUtils.mkdir_p(dir + '/etc')
        FileUtils.mkdir_p(dir + '/var')
        FileUtils.mkdir_p(dir + '/tmp')
      }
    end

    def suppress_logging
      Logging.quiet = true
      Logging.logfile @base_dir + '/tmp/mkmf.log'
    end

    def create_database
      connection = mysql2_or_mysql_connection
      connection.query("CREATE DATABASE IF NOT EXISTS test")
      connection.close
    end

    def mysql2_or_mysql_connection
      mysql2_connection || mysql_connection || raise("LoadError 'mysql2' or 'mysql'")
    end

    def mysql2_connection
      unless defined? ::Mysql2
        begin
          require "rubygems"
          require "mysql2"
        rescue LoadError
        end
      end
      if defined? ::Mysql2
        Mysql2::Client.new(dsn :database => 'mysql')
      else
        nil
      end
    end

    def mysql_connection
      unless defined? ::Mysql
        begin
          require "rubygems"
          require "mysql"
        rescue LoadError
        end
      end
      if defined? ::Mysql
        opts = dsn :database => 'mysql'
        Mysql.new(opts[:username], nil, opts[:host], opts[:port], opts[:database], opts[:socket], opts[:flags])
      else
        nil
      end
    end
  end
end