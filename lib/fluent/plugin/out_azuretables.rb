# coding: utf-8
require 'azure/storage/table'
require 'time'
require 'msgpack'

module Fluent
  class AzuretablesOutput < BufferedOutput
    Plugin.register_output('azuretables', self)

    include DetachMultiProcessMixin

    ENTITY_SIZE_LIMIT = 1024 * 1024 # 1MB
    BATCHWRITE_ENTITY_LIMIT = 100
    BATCHWRITE_SIZE_LIMIT = 4 * 1024 * 1024 # 4MB

    # config_param defines a parameter
    config_param :account_name, :string # your azure storage account
    config_param :access_key, :string, :secret => true # your azure storage access key
    config_param :table, :string # azure storage table name
    config_param :create_table_if_not_exists, :bool, :default => false
    config_param :key_delimiter, :string, :default => '__'
    config_param :partition_keys, :string, :default => nil
    config_param :row_keys, :string, :default => nil
    config_param :add_uuid_to_row_key, :bool, :default => true
    config_param :add_time_to_partition_key, :bool, :default => true
    config_param :add_time_to_row_key, :bool, :default => true

    # This method is called before starting.
    # 'conf' is a Hash that includes configuration parameters.
    # If the configuration is invalid, raise Fluent::ConfigError
    def configure(conf)
      super
      unless @partition_keys.nil?
        @partition_key_array = @partition_keys.split(',')
      end

      unless @row_keys.nil?
        @row_key_array = @row_keys.split(',')
      end

    end

    # connect azure table storage service
    def start
      super
      unless @account_name.nil? || @access_key.nil?
        @table_client = Azure::Storage::Table::TableService.create(storage_account_name: @account_name,storage_access_key:@access_key)
      end

      begin
        @table_client.create_table(@table) if @create_table_if_not_exists && !table_exists?(@table)
      rescue Exception => e
        log.error e
        exit!
      end
    end

    def table_exists?(table_name)
      begin
        @table_client.get_table(table_name)
        true
      rescue Azure::Core::Http::HTTPError => e
        false
      rescue Exception => e
        log.fatal "UnknownError: '#{e}'"
        exit!
      end
    end

    # This method is called when shutting down.
    def shutdown
      super
    end

    #create entity from event record
    def format(tag, time, record)
      partition_keys = []
      row_keys = []
      record.each_pair do |name, val|
        if @partition_key_array && @partition_key_array.include?(name)
          partition_keys << val
          record.delete(name)
        elsif @row_key_array && @row_key_array.include?(name)
          row_keys << val
          record.delete(name)
        end
      end
      if @add_time_to_partition_key
        partition_keys << Time.now.strftime("%Y%m%d")
      end
      if @add_time_to_row_key
        row_keys << Time.now.getutc.to_i
      end
      if @add_uuid_to_row_key
        row_keys << SecureRandom.uuid
      end

      entity = Hash.new
      entity['partition_key'] = partition_keys.join(@key_delimiter)
      entity['row_key'] = row_keys.join(@key_delimiter)
      entity['entity_values'] = record
      entity.to_msgpack
    end

    def format_key(record, keys, key_delimiter)
      ret = []
      record.each_pair do |name, val|
        ret << val if keys.include?(name)
      end
      ret.join(key_delimiter)
    end

    def write(chunk)
      batch_size = 0
      group_entities = Hash.new
      chunk.msgpack_each do |entity|
        partition_key = entity['partition_key']
        group_entities[partition_key] = [] unless group_entities.has_key?(partition_key)
        group_entities[partition_key] << entity
        batch_size += entity.to_json.length
        if group_entities[partition_key].size >= BATCHWRITE_ENTITY_LIMIT || batch_size >= BATCHWRITE_SIZE_LIMIT
          insert_entities(partition_key, group_entities[partition_key])
          group_entities[partition_key] = []
          batch_size = 0
        end
      end
      unless group_entities.empty?
        group_entities.each_pair do |partition_key, entities|
          insert_entities(partition_key, entities)
        end
      end
    end

    def insert_entities(partition_key, entities)
      begin
        batch = Azure::Storage::Table::Batch.new(@table, partition_key) do
          entities.each do |entity|
            insert entity['row_key'], entity['entity_values']
          end
        end
        return @table_client.execute_batch(batch)
      rescue Exception => e
        log.fatal "UnknownError: '#{e}'"
        log.debug partition_key
        log.debug entities.inspect
      end
    end

  end # class
end # module
