require "rubygems"
require "bundler/setup"
require "json"
require "rest-client"
require "cinch"
require "thread"
require "yaml"

CONFIG = YAML.load_file(File.expand_path("config.yml"))
POOLS_FILE = File.expand_path("pools.yml")

LOCK = Mutex.new

def refresh_pools
  LOCK.synchronize do
    ctime = File.ctime(POOLS_FILE)

    if (@pools_ctime.nil? || (@pools_ctime != ctime))
      @pools = YAML.load_file(POOLS_FILE)
      @pools_ctime = ctime
    end
  end
end

def refresh_price
  LOCK.synchronize do
    @price ||= {}

    if (@last_price_update.nil? || (Time.now - @last_price_update > 180))
      resp = RestClient.get("https://poloniex.com/public?command=returnTicker")
      @price["Poloniex"] = {}
      @price["Poloniex"]["price"] = JSON.parse(resp)["BTC_BTM"]["last"].to_f.round(8)
      @price["Poloniex"]["vol"] = JSON.parse(resp)["BTC_BTM"]["baseVolume"].to_f.round(2)

      @last_price_update = Time.now
    end
  end
end

def refresh_stats
  LOCK.synchronize do
    if (@last_stats_update.nil? || (Time.now - @last_stats_update > 60))
      url = "http://#{CONFIG["daemon"]["rpc_user"]}:#{CONFIG["daemon"]["rpc_password"]}@#{CONFIG["daemon"]["rpc_host"]}:#{CONFIG["daemon"]["rpc_port"]}"
      body = { "jsonrpc" => "2.0", "method" => "getmininginfo" }
      resp = RestClient.post(url, body.to_json)
      @stats = JSON.parse(resp)["result"]

      @last_stats_update = Time.now
    end
  end
end

bot = Cinch::Bot.new do
  configure do |c|
    c.nick = CONFIG["nick"]
    c.password = CONFIG["password"]
    c.server = CONFIG["server"]
    c.channels = CONFIG["channels"]
  end

  on :message, "!help" do |m|
    m.user.msg "Commands: !pools, !worth <amount>, !price, !net, !calc <KH/s>"
  end

  on :message, "!pools" do |m|
    refresh_pools
    reply = "List of Bitmark (BTM) mining pools:\n\n"
    reply << @pools.shuffle.join("\n")
    m.user.msg reply
  end

  on :message, "!net" do |m|
    refresh_stats
    blocks = @stats["blocks"]
    diff = @stats["difficulty"]
    target = (( @stats["difficulty"] * 4294967296 ) / 120 ) / 1000000000.0
    nethash = @stats["networkhashps"] / 1000000000.0
    change = (720 * ((@stats["blocks"] / 720) + 1)).floor - @stats["blocks"]
    minted = @stats["blocks"] * 20
    m.user.msg "Diff: #{diff.round(8)}, Target: #{'%.4f' % target} GH/s, Network: #{'%.4f' % nethash} GH/s, Blocks: #{blocks}, Change: #{change}, Minted: #{minted} BTM"
  end

  on :message, "!price" do |m|
    refresh_price
    m.user.msg "Last: #{'%.8f' % @price["Poloniex"]["price"]} BTC | Volume: #{@price["Poloniex"]["vol"]} BTC | Poloniex | https://poloniex.com/exchange/btc_btm"
  end

  on :message, /^!worth (\d+)/ do |m, amount|
    refresh_price
    total = amount.to_f * @price["Poloniex"]["price"].to_f
    m.user.msg "#{amount} BTM = #{'%.8f' % total} BTC"
  end

  on :message, /^!calc (\d+)/ do |m, hashrate|
    refresh_stats
    diff = @stats["difficulty"]
    total = 1.0 / (diff * 2**32 / (hashrate.to_f * 1000) / 86400) * 20
    m.user.msg "With #{hashrate} KH/s you will mine ~#{'%.8f' % total} BTM per day"
  end
end

bot.start
