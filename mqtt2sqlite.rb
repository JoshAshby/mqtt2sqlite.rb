#!/usr/bin/env ruby
# frozen_string_literal: true

# require "bundler/inline"

# gemfile do
  # source "https://rubygems.org"

  # gem "sequel", "~> 5.76"
  # gem "sqlite3", "~> 1.7"
  # gem "tomlrb", "~> 2.0", ">= 2.0.3"

  # gem "jsonpath", "~> 1.1", ">= 1.1.5"
  # gem "mqtt", "~> 0.6.0"
# end

require "fileutils"
require "sequel"
require "tomlrb"
require "mqtt"
require "jsonpath"


Configuration = Struct.new(:database, :output_dir, :broker_uri, :tables, :subscriptions) do
  def self.parse_config(data)
    # output_dir = data.dig("output_dir")
    # database = File.join(output_dir, data.dig("database"))

    broker_uri = data.dig("broker")

    tables = data.dig("tables").map do |table|
      Configuration::Table.new(
        table.dig("name"),
        table.dig("columns").map do |column|
          Configuration::Table::Column.new(column.transform_keys(&:to_sym))
        end,
      )
    end

    subscriptions = data.dig("subscriptions").map do |subscription|
      Configuration::Subscription.new(
        subscription.dig("topic"),
        subscription.dig("table"),
        subscription.dig("filters")&.map do |filter|
          Configuration::Subscription::Filter.new(filter.transform_keys(&:to_sym))
        end || [],
        subscription.dig("columns").map do |column|
          Configuration::Subscription::Column.new(column.transform_keys(&:to_sym))
        end,
      )
    end

    # Configuration.new(database, output_dir, broker_uri, tables, subscriptions)
    Configuration.new(broker_uri, tables, subscriptions)
  end
end

Configuration::Table = Struct.new(:name, :columns)
Configuration::Table::Column = Struct.new(:name, :generated_as, keyword_init: true)

Configuration::Subscription = Struct.new(:topic, :table, :filters, :columns) do
  def topic_pattern()= Regexp.new("^" + self.topic.gsub("+", "(.*)").gsub("#", "(.*)") + "$")
end

Configuration::Subscription::Filter = Struct.new(:type, :value, keyword_init: true) do
  def value_as_path()= JsonPath.new(self.value)
  def value_as_pattern()= Regexp.new(self.value)

  def passes?(topic, msg)
    return value_as_path.on(msg).first != nil if type == "jsonpath"
    return (value_as_pattern =~ topic) != nil if type == "topic_regex"

    puts "Unknown `type` configured for filter #{name}"
    return nil
  end
end

Configuration::Subscription::Column = Struct.new(:name, :type, :value, keyword_init: true) do
  def value_as_path()= JsonPath.new(self.value)

  def value_for(topic, msg)
    return topic if type == "topic"
    return value if type == "static"
    return value_as_path.on(msg).first if type == "jsonpath"

    puts "Unknown `type` configured for column #{name}"
    return nil
  end
end

# CONFIG = Configuration.parse_config(Tomlrb.parse(DATA.read))
CONFIG = Configuration.parse_config(Tomlrb.parse(File.read("./data/config.toml")))

# FileUtils.mkdir_p(CONFIG.output_dir)

def setup_db(db)
  db.journal_mode = "wal"
end

# DB = Sequel.sqlite(CONFIG.database, after_connect: method(:setup_db))
DB = Sequel.sqlite("./data/mqtt2sqlite_data.sqlite", after_connect: method(:setup_db))


CONFIG.tables.each do |table|
  DB.create_table? table.name do
    table.columns.each do |col|
      column col.name, :text, generated_always_as: Sequel.lit(col.generated_as), generated_type: :virtual if col.generated_as
      column col.name, :text unless col.generated_as
    end

    Time :timestamp, default: Sequel.lit("CURRENT_TIMESTAMP")
  end
end


MQTT_CLIENT = MQTT::Client.connect(CONFIG.broker_uri)

CONFIG.subscriptions.each do |subscription|
  MQTT_CLIENT.subscribe(subscription.topic)
end

MQTT_CLIENT.get do |topic, msg|
  subscriptions = CONFIG.subscriptions
    .filter { _1.topic_pattern =~ topic }
    .filter { _1.filters.all? { |filter| filter.passes?(topic, msg) } }

  subscriptions.each do |subscription|
    # pp [topic, subscription, msg]
    puts "Processing a message from topic `\e[32m#{topic}\e[0m` ..."
    puts "\t#{msg}"

    data = subscription.columns.reduce({}) do |memo, column|
      memo.merge({ column.name => column.value_for(topic, msg) })
    end

    puts "\tInserting into `\e[31m#{subscription.table}\e[0m`: #{data}"

    DB[subscription.table.to_sym].insert(data)
  end

  puts unless subscriptions.empty?
end

__END__
output_dir = "./outputs/"
database = "mqtt2sqlite_data.sqlite"
broker = "mqtt://boulder.local:1883"

# MARK: Table Definitions

[[tables]]
name = "meeting_signs"
[[tables.columns]]
name = "topic"
[[tables.columns]]
name = "state"

[[tables]]
name = "motion_sensors"
[[tables.columns]]
name = "topic"
[[tables.columns]]
name = "state"

[[tables]]
name = "contact_sensors"
[[tables.columns]]
name = "topic"
[[tables.columns]]
name = "contact"

[[tables]]
name = "climate_sensors"
[[tables.columns]]
name = "topic"
[[tables.columns]]
name = "temperature"
[[tables.columns]]
name = "humidity"
[[tables.columns]]
name = "voc"
[[tables.columns]]
name = "pressure"

[[tables]]
name = "device_batteries"
[[tables.columns]]
name = "topic"
[[tables.columns]]
name = "battery_percent"
[[tables.columns]]
name = "battery_low"
[[tables.columns]]
name = "last_seen_epoch"
[[tables.columns]]
name = "last_seen"
generated_as = "datetime(round(last_seen_epoch / 1000), 'unixepoch')"

[[tables]]
name = "internet_speed_tests"
[[tables.columns]]
name = "upload_bps"
[[tables.columns]]
name = "upload_mbps"
generated_as = "upload_bps / 125000"
[[tables.columns]]
name = "download_bps"
[[tables.columns]]
name = "download_mbps"
generated_as = "download_bps / 125000"
[[tables.columns]]
name = "latency_ms"


# MARK: Subscriptions
# MARK: Subscriptions/Internet speeds table

[[subscriptions]]
topic = "homekit/house/internet/speed-tests"
table = "internet_speed_tests"
[[subscriptions.columns]]
name = "upload_bps"
type = "jsonpath"
value = ".upload.bandwidth"
[[subscriptions.columns]]
name = "download_bps"
type = "jsonpath"
value = ".download.bandwidth"
[[subscriptions.columns]]
name = "latency_ms"
type = "jsonpath"
value = ".ping.latency"


# MARK: Subscriptions/Device battery state table

[[subscriptions]]
topic = "zigbee/#"
table = "device_batteries"

[[subscriptions.filters]]
type = "jsonpath"
value = ".battery"

[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "battery_percent"
type = "jsonpath"
value = ".battery"
[[subscriptions.columns]]
name = "last_seen_epoch"
type = "jsonpath"
value = ".last_seen"

[[subscriptions]]
topic = "zigbee/#"
table = "device_batteries"

[[subscriptions.filters]]
type = "jsonpath"
value = ".battery_low"

# This is a plugged-in sensor but it still reports a "battery_low" status for
# some reason?
[[subscriptions.filters]]
type = "topic_regex"
value = "^(?!zigbee/basement/presence/linptech-1).*$"

[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "battery_low"
type = "jsonpath"
value = ".battery_low"
[[subscriptions.columns]]
name = "last_seen_epoch"
type = "jsonpath"
value = ".last_seen"


# MARK: Motion sensor tables

[[subscriptions]]
topic = "homekit/house/zones/+/motion"
table = "motion_sensors"

[[subscriptions.filters]]
type = "jsonpath"
value = ".state"

[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "state"
type = "jsonpath"
value = "."


# MARK: Subscriptions/Climate sensors

[[subscriptions]]
topic = "zigbee/#"
table = "climate_sensors"

[[subscriptions.filters]]
type = "jsonpath"
value = ".temperature"

# Some devices like the contact sensors also report temperature, so this
# filters them down to just the sensors that I care about.
[[subscriptions.filters]]
type = "topic_regex"
value = "(/temp/)"

[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "temperature"
type = "jsonpath"
value = ".temperature"
[[subscriptions.columns]]
name = "humidity"
type = "jsonpath"
value = ".humidity"
[[subscriptions.columns]]
name = "pressure"
type = "jsonpath"
value = ".pressure"


# MARK: Subscriptions/Contact sensors

[[subscriptions]]
topic = "zigbee/#"
table = "contact_sensors"

[[subscriptions.filters]]
type = "jsonpath"
value = ".contact"
[[subscriptions.filters]]
type = "topic_regex"
value = "(windows|doors)"

[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "contact"
type = "jsonpath"
value = ".contact"


# MARK: Subscriptions/Meeting statuses

[[subscriptions]]
topic = "homekit/people/+/meeting-status"
table = "meeting_signs"
[[subscriptions.columns]]
name = "topic"
type = "topic"
[[subscriptions.columns]]
name = "state"
type = "jsonpath"
value = "."
