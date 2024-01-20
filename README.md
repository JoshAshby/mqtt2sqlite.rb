# MQTT2SQLite.rb

### What is this

This is a little tool which subscribes to a set of MQTT topics, extracts some
data from each message and writes it out to a SQLite DB. I wrote it to replace
some Node-Red flows that drive a Grafana dashboard through SQLite databases
with something a little more config driven.

It's not designed to be rock solid, or extensible and is of "hacked together"
quality at best. You've been warned.

### Usage

- Place a TOML config file at `./data/config.toml`
- Run `./mqtt2sqlite.rb` and watch it go!

#### Config reference

There is an example config which I personally run already provided in the
repository for reference.

The config is composed of two array-of-tables constructs: tables and subscriptions.

Tables `[[tables]]` define the SQLite tables that should be created and contain
a name, and an array of columns. Columns have a name, and optionally a
`generated_as` setting which can be used to configure the column into a
[virtual generated column](https://www.sqlite.org/gencol.html).

For example:

```toml
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
```

This defines the following table in SQLite:

```sql
CREATE TABLE `device_batteries` (
    `topic` text,
  , `battery_percent` text
  , `battery_low` text
  , `last_seen_epoch` text
  , `last_seen` text GENERATED ALWAYS AS (datetime(round(last_seen_epoch / 1000), 'unixepoch')) VIRTUAL
  , `timestamp` timestamp DEFAULT (CURRENT_TIMESTAMP)
)
;
```

Subscriptions have an MQTT topic, the destination table in SQLite, an optional
array of filters, and an array of columns.

Filters allow you to reject messages if they don't fit a criteria.
Filters come in two types:
  - `jsonpath` which will reject the message if the JsonPath expression
    evaluates to `nil`
  - `topic_regex` which will reject the message if the regex pattern does not
    match against the topic which the message originated from

Columns configure how a messages data is extracted and shaped for the table and
come in a few types as well:
  - `jsonpath` which sets that column's value to the first value that the
    JsonPath expression evaluates to
  - `topic` which sets the column's value to the topic which the message
    originated from
  - `static` which sets the column's value to a fixed/static value

For example:

```toml
[subscriptions]]
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
```

This subscription will convert a message from the topic
`zigbee/living-room/windows/left/aqara` that looks like:

```json
{
    "battery": 83,
    "contact": true,
    "device_temperature": 23,
    "elapsed": 3048274,
    "last_seen": 1705708799360,
    "linkquality": 119,
    "power_outage_count": 7,
    "temperature": 18,
    "voltage": 2975
}
```

Into the following table row:

| topic                                   | battery_percentage | battery_low | last_seen_epoch |
|-----------------------------------------|--------------------|-------------|-----------------|
| "zigbee/living-room/windows/left/aqara" | `nil`              | 83          | 1705708799360   |
