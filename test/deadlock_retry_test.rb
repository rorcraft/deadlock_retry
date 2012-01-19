require 'rubygems'

# Change the version if you want to test a different version of ActiveRecord
gem 'activerecord', ' ~>3.0'
require 'active_record'
require 'active_record/version'
puts "Testing ActiveRecord #{ActiveRecord::VERSION::STRING}"

require 'test/unit'
require 'mocha'
require 'ruby-debug'
require 'logger'
require "deadlock_retry"

class MockModel
  @@open_transactions = 0

  def self.transaction(*objects)
    @@open_transactions += 1
    yield
  ensure
    @@open_transactions -= 1
  end

  def self.open_transactions
    @@open_transactions
  end

  def self.connection
    self
  end

  def self.logger
    @logger ||= Logger.new(nil)
  end

  def self.show_innodb_status
    []
  end

  def self.select_rows(sql)
    [['version', '5.1.45']]
  end

  def self.select_value(sql)
    true
  end

  include DeadlockRetry
end

class DeadlockModel < ActiveRecord::Base
  after_create :deadlock_on_first_try

  def deadlock_on_first_try
    raise ActiveRecord::StatementInvalid.new("Lock wait timeout exceeded") if @deadlocked.nil?
  ensure
    @deadlocked = true
  end
end

class DeadlockRetryHelper
  def self.setup_mysql
    config    = YAML.load(File.open("#{File.dirname(__FILE__)}/db/database.yml"))
    @host     = config['host']
    @username = config['username']
    @password = config['password']
    @socket   = config['socket']

    ActiveRecord::Base.establish_connection(
      :adapter  => 'mysql2',
      :database => 'deadlock_retry',
      :username => @username,
      :password => @password,
      :host     => @host,
      :socket   => @socket
    )
    FileUtils.mkdir_p "tmp"
    ActiveRecord::Base.logger = Logger.new(File.open('tmp/mysql.log', 'a'))

    structure = File.open("#{File.dirname(__FILE__)}/db/structure.sql") { |f| f.read.chomp }
    structure.split(';').each { |table|
      ActiveRecord::Base.connection.execute table
    }
  end
end

class DeadlockRetryTest < Test::Unit::TestCase
  DEADLOCK_ERROR = "MySQL::Error: Deadlock found when trying to get lock"
  TIMEOUT_ERROR = "MySQL::Error: Lock wait timeout exceeded"

  def setup
    MockModel.stubs(:exponential_pause)
    DeadlockRetryHelper.setup_mysql
  end

  def test_no_errors
    assert_equal :success, MockModel.transaction { :success }
  end

  def test_no_errors_with_deadlock
    errors = [ DEADLOCK_ERROR ] * 3
    assert_equal :success, MockModel.transaction { raise ActiveRecord::StatementInvalid, errors.shift unless errors.empty?; :success }
    assert errors.empty?
  end

  def test_no_errors_with_lock_timeout
    errors = [ TIMEOUT_ERROR ] * 3
    assert_equal :success, MockModel.transaction { raise ActiveRecord::StatementInvalid, errors.shift unless errors.empty?; :success }
    assert errors.empty?
  end

  def test_error_if_limit_exceeded
    assert_raise(ActiveRecord::StatementInvalid) do
      MockModel.transaction { raise ActiveRecord::StatementInvalid, DEADLOCK_ERROR }
    end
  end

  def test_error_if_unrecognized_error
    assert_raise(ActiveRecord::StatementInvalid) do
      MockModel.transaction { raise ActiveRecord::StatementInvalid, "Something else" }
    end
  end

  def test_included_by_default
    assert ActiveRecord::Base.respond_to?(:transaction_with_deadlock_handling)
  end

  def test_innodb_status_availability
    DeadlockRetry.innodb_status_cmd = nil
    MockModel.transaction {}
    assert_equal "show innodb status", DeadlockRetry.innodb_status_cmd
  end


  def test_error_in_nested_transaction_should_retry_outermost_transaction
    tries = 0
    errors = 0

    MockModel.transaction do
      tries += 1
      MockModel.transaction do
        MockModel.transaction do
          errors += 1
          raise ActiveRecord::StatementInvalid, "MySQL::Error: Lock wait timeout exceeded" unless errors > 3
        end
      end
    end

    assert_equal 4, tries
  end

  def test_deadlock_retry_on_create
    @model = DeadlockModel.new do |m|
      m.name = "testing"
    end
    DeadlockModel.transaction do
      @model.save
    end
    assert DeadlockModel.find(@model.id).present?
  end
end
