# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/http_client"
require "socket" # for Socket.gethostname
require "manticore"
require "rufus/scheduler"
require "date"

class LogStash::Inputs::HTTP_Poller < LogStash::Inputs::Base
  include LogStash::PluginMixins::HttpClient

  config_name "http_poller"

  default :codec, "json"

  # A Hash of urls in this format : `"name" => "url"`.
  # The name and the url will be passed in the outputed event
  config :urls, :validate => :hash, :required => true

  # Schedule of when to periodically poll from the urls
  # Format: A hash with
  #   + key: "cron" | "every" | "in" | "at"
  #   + value: string
  # Examples:
  #   a) { "every" => "1h" }
  #   b) { "cron" => "* * * * * UTC" }
  # See: rufus/scheduler for details about different schedule options and value string format
  config :schedule, :validate => :hash, :required => true

  # Define the target field for placing the received data. If this setting is omitted, the data will be stored at the root (top level) of the event.
  config :target, :validate => :string

  # If you'd like to work with the request/response metadata.
  # Set this value to the name of the field you'd like to store a nested
  # hash of metadata.
  config :metadata_target, :validate => :string, :default => '@metadata'

  # The name of a variable to use in string replacement for time based calls in the past
  # making available as a variable to work around hard-coded string substition issues
  config :time_back_buffer_string, :validate => :string, :default => 'time_back_buffer'

  # The amount of time in seconds to poll backwards
  config :time_back_buffer, :validate => :number

  # The name of a variable to use in string replacement for time based calls in the past
  # making available as a variable to work around hard-coded string substition issues
  config :time_forward_buffer_string, :validate => :string, :default => 'time_forward_buffer'

  # The amount of time in seconds to poll forwards
  config :time_forward_buffer, :validate => :number, :default => 0

  # get the timeformat, to support seconds and milliseconds
  # Common time formats and codes
  # %FT%R     - 2007-11-19T08:37          Calendar date and local time (extended)
  # %FT%T%:z  - 2007-11-19T08:37:48-06:00 Date and time of day for calendar date (extended)
  # %s      - Number of seconds since 1970-01-01 00:00:00 UTC.
  # %Q      - Number of milliseconds since 1970-01-01 00:00:00 UTC.
  config :time_format, :validate => :string, :default => '%s'

  public
  Schedule_types = %w(cron every at in)
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)

    @logger.info("Registering http_poller Input", :type => @type, :schedule => @schedule, :timeout => @timeout)

    setup_requests!
  end

  def stop
    Stud.stop!(@interval_thread) if @interval_thread
    @scheduler.stop if @scheduler
  end

  private
  def setup_requests!
    @requests = Hash[@urls.map {|name, url| [name, normalize_request(url)] }]
  end

  private
  def normalize_request(url_or_spec)
    if url_or_spec.is_a?(String)
      res = [:get, url_or_spec]
    elsif url_or_spec.is_a?(Hash)
      # The client will expect keys / values
      spec = Hash[url_or_spec.clone.map {|k,v| [k.to_sym, v] }] # symbolize keys

      # method and url aren't really part of the options, so we pull them out
      method = (spec.delete(:method) || :get).to_sym.downcase
      url = spec.delete(:url)

      # Manticore wants auth options that are like {:auth => {:user => u, :pass => p}}
      # We allow that because earlier versions of this plugin documented that as the main way to
      # to do things, but now prefer top level "user", and "password" options
      # So, if the top level user/password are defined they are moved to the :auth key for manticore
      # if those attributes are already in :auth they still need to be transformed to symbols
      auth = spec[:auth]
      user = spec.delete(:user) || (auth && auth["user"])
      password = spec.delete(:password) || (auth && auth["password"])
      
      if user.nil? ^ password.nil?
        raise LogStash::ConfigurationError, "'user' and 'password' must both be specified for input HTTP poller!"
      end

      if user && password
        spec[:auth] = {
          user: user, 
          pass: password,
          eager: true
        } 
      end
      res = [method, url, spec]
    else
      raise LogStash::ConfigurationError, "Invalid URL or request spec: '#{url_or_spec}', expected a String or Hash!"
    end

    validate_request!(url_or_spec, res)
    res
  end

  private
  def validate_request!(url_or_spec, request)
    method, url, spec = request

    raise LogStash::ConfigurationError, "Invalid URL #{url}" unless URI::DEFAULT_PARSER.regexp[:ABS_URI].match(url)

    raise LogStash::ConfigurationError, "No URL provided for request! #{url_or_spec}" unless url
    if spec && spec[:auth]
      if !spec[:auth][:user]
        raise LogStash::ConfigurationError, "Auth was specified, but 'user' was not!"
      end
      if !spec[:auth][:pass]
        raise LogStash::ConfigurationError, "Auth was specified, but 'password' was not!"
      end
    end

    request
  end

  public
  def run(queue)
    setup_schedule(queue)
  end

  def setup_schedule(queue)
    #schedule hash must contain exactly one of the allowed keys
    msg_invalid_schedule = "Invalid config. schedule hash must contain " +
      "exactly one of the following keys - cron, at, every or in"
    raise Logstash::ConfigurationError, msg_invalid_schedule if @schedule.keys.length !=1
    schedule_type = @schedule.keys.first
    schedule_value = @schedule[schedule_type]
    raise LogStash::ConfigurationError, msg_invalid_schedule unless Schedule_types.include?(schedule_type)

    @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
    #as of v3.0.9, :first_in => :now doesn't work. Use the following workaround instead
    opts = schedule_type == "every" ? { :first_in => 0.01 } : {} 
    @scheduler.send(schedule_type, schedule_value, opts) { run_once(queue) }
    @scheduler.join
  end

  def run_once(queue)
    @requests.each do |name, request|
      request_async(queue, name, request)
    end

    client.execute!
  end

  private
  def request_async(queue, name, request)
    @logger.debug? && @logger.debug("Fetching URL", :name => name, :url => request)
    @logger.debug? && @logger.debug("Forward Buffer", :buffer => @time_forward_buffer)
    @logger.debug? && @logger.debug("Backward Buffer", :buffer => @time_back_buffer)
    @logger.debug? && @logger.debug("Time Format", :format => @time_format)
    # Grab the current time
    started = Time.now

    # this needs to be a DateTime to deal with subtractions
    currenttime = DateTime.now
    @logger.debug? && @logger.debug("Current Time", :currenttime => currenttime)
    # If we have the @time_back_buffer set, we modify the URL with a calculated timestamp
    back_buffer = @time_back_buffer
    forward_buffer = @time_forward_buffer

    # To support multiple formats
    # https://apidock.com/ruby/DateTime/strftime
    if @time_format
      time_format_code = @time_format
    end

    # Deal with buffers going backwards
    if @time_back_buffer && @time_back_buffer > 0
      # Rational is fractions, and the second number is the number of seconds in a day
      # Datetime is the time since the unix epoch, and it works using rational numbers
      # https://stackoverflow.com/a/10056201 has more info
      buffer = currenttime - Rational(back_buffer,86400)
      @logger.debug? && @logger.debug("Back Buffer", :buffer => buffer)
      # Turns out I don't need to handle arrays, as each request is processed separately   
      # but I'll keep the loop here, for reference
      if request[1].include?("#{time_back_buffer_string}")
        @logger.debug? && @logger.debug("URL timestamp - backwards - pre:", :url => request[1])
        request[1] = request[1].gsub(/#{time_back_buffer_string}/,buffer.strftime(time_format_code))
        # Store the timestamp as a variable to swap it back after the URL has been fetched
        @buffer_time_back = buffer.strftime(time_format_code)
        @logger.debug? && @logger.debug("URL timestamp - backwards - post:", :url => request[1])
      end
      #request.each_with_index do |entry, i| 
      #  # We need to verify we're working with a string, otherwise we run in to method not found errors 
      #  if request[i].is_a? String 
      #    # And lets only modify strings that actually include our text
      #    if request[i].include?("#{time_back_buffer_string}")
      #      # Originally request[1] = request[1].gsub(/#{time_back_buffer_string}/,buffer.strftime(time_format_code))
      #      @logger.debug? && @logger.debug("URL timestamp - backwards - pre:", :url => request[i])
      #      request[i] = request[i].gsub(/#{time_back_buffer_string}/,buffer.strftime(time_format_code))
      #      # Store the timestamp as a variable to swap it back after the URL has been fetched
      #      @buffer_time_back = buffer.strftime(time_format_code)
      #      @logger.debug? && @logger.debug("URL timestamp - backwards - post:", :url => request[i])
      #      @logger.debug? && @logger.debug("URL timestamp - backwards - string:", :time => buffer_time_back)
      #    end
      #  end
      #end
    end

    # deal with forward buffers, if we need to
    # We can tolerate a zero here because it would indicate 'now'
    if @time_forward_buffer && @time_forward_buffer >= 0
      # Rational is fractions, and the second number is the number of seconds in a day
      # Datetime is the time since the unix epoch, and it works using rational numbers
      # https://stackoverflow.com/a/10056201 has more info
      buffer = currenttime + Rational(forward_buffer,86400)
      @logger.debug? && @logger.debug("Forward Buffer", :buffer => buffer)
      if request[1].include?("#{time_forward_buffer_string}")
        @logger.debug? && @logger.debug("URL timestamp - forward - pre:", :url => request[1])
        request[1] = request[1].gsub(/#{time_forward_buffer_string}/,buffer.strftime(time_format_code))
        # Store the timestamp as a variable to swap it back after the URL has been fetched
        @buffer_time_forward = buffer.strftime(time_format_code)
        @logger.debug? && @logger.debug("URL timestamp - forward - post:", :url => request[1])
      end
      #  request.each_with_index do |entry, i| 
      #  # We need to verify we're working with a string, otherwise we run in to method not found errors 
      #  if request[i].is_a? String 
      #    # And lets only modify strings that actually include our text
      #    if request[i].include?("#{time_forward_buffer_string}")
      #      # Originally request[1] = request[1].gsub(/#{time_forward_buffer_string}/,buffer.strftime(time_format_code))
      #      @logger.debug? && @logger.debug("URL timestamp - forwards - pre:", :url => request[i])
      #      request[i] = request[i].gsub(/#{time_forward_buffer_string}/,buffer.strftime(time_format_code))
      #      # Store the timestamp as a variable to swap it back after the URL has been fetched
      #      @buffer_time_forward = buffer.strftime(time_format_code)
      #      @logger.debug? && @logger.debug("URL timestamp - forwards - post:", :url => request[i])
      #      @logger.debug? && @logger.debug("URL timestamp - forwards - string:", :time => buffer_time_forward)
      #    end
      #  end
      #end
    end

    method, *request_opts = request
    client.async.send(method, *request_opts).
      on_success {|response| 
      @logger.debug? && @logger.debug("URL timestamp - success - pre:", :url => request[1])
      handle_success(queue, name, request, response, Time.now - started)
      # If either of out buffers were set, replace the contents of the URL back to our string
      # It has been observed that the URL wasn't being set back, hence this workaround
      if @buffer_time_back
        request[1] = request[1].gsub(@buffer_time_back,time_back_buffer_string)
      end
      if @buffer_time_forward
        request[1] = request[1].gsub(@buffer_time_forward,time_forward_buffer_string)
      end
      @logger.debug? && @logger.debug("URL timestamp - success - post:", :url => request[1])}.
      on_failure {|exception|
      @logger.debug? && @logger.debug("URL timestamp - failure - pre:", :url => request[1])
      handle_failure(queue, name, request, exception, Time.now - started)
      # If either of out buffers were set, replace the contents of the URL back to our string
      # It has been observed that the URL wasn't being set back, hence this workaround
      if @buffer_time_back
        request[1] = request[1].gsub(@buffer_time_back,time_back_buffer_string)
      end
      if @buffer_time_forward
        request[1] = request[1].gsub(@buffer_time_forward,time_forward_buffer_string)
      end
      @logger.debug? && @logger.debug("URL timestamp - failure - post:", :url => request[1])
    }
  end

  private
  def handle_success(queue, name, request, response, execution_time)
    body = response.body
    # If there is a usable response. HEAD requests are `nil` and empty get
    # responses come up as "" which will cause the codec to not yield anything
    if body && body.size > 0
      decode_and_flush(@codec, body) do |decoded|
        event = @target ? LogStash::Event.new(@target => decoded.to_hash) : decoded
        handle_decoded_event(queue, name, request, response, event, execution_time)
      end
    else
      event = ::LogStash::Event.new
      handle_decoded_event(queue, name, request, response, event, execution_time)
    end
  end

  private
  def decode_and_flush(codec, body, &yielder)
    codec.decode(body, &yielder)
    codec.flush(&yielder)
  end

  private
  def handle_decoded_event(queue, name, request, response, event, execution_time)
    apply_metadata(event, name, request, response, execution_time)
    decorate(event)
    queue << event
  rescue StandardError, java.lang.Exception => e
    @logger.error? && @logger.error("Error eventifying response!",
                                    :exception => e,
                                    :exception_message => e.message,
                                    :name => name,
                                    :url => request,
                                    :response => response
    )
  end

  private
  # Beware, on old versions of manticore some uncommon failures are not handled
  def handle_failure(queue, name, request, exception, execution_time)
    event = LogStash::Event.new
    apply_metadata(event, name, request)

    event.tag("_http_request_failure")

    # This is also in the metadata, but we send it anyone because we want this
    # persisted by default, whereas metadata isn't. People don't like mysterious errors
    event.set("http_request_failure", {
      "request" => structure_request(request),
      "name" => name,
      "error" => exception.to_s,
      "backtrace" => exception.backtrace,
      "runtime_seconds" => execution_time
   })

    queue << event
  rescue StandardError, java.lang.Exception => e
      @logger.error? && @logger.error("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name)

      # If we are running in debug mode we can display more information about the
      # specific request which could give more details about the connection.
      @logger.debug? && @logger.debug("Cannot read URL or send the error as an event!",
                                      :exception => e,
                                      :exception_message => e.message,
                                      :exception_backtrace => e.backtrace,
                                      :name => name,
                                      :url => request)
  end

  private
  def apply_metadata(event, name, request, response=nil, execution_time=nil)
    return unless @metadata_target
    event.set(@metadata_target, event_metadata(name, request, response, execution_time))
  end

  private
  def event_metadata(name, request, response=nil, execution_time=nil)
    m = {
        "name" => name,
        "host" => @host,
        "request" => structure_request(request),
      }

    m["runtime_seconds"] = execution_time

    if response
      m["code"] = response.code
      m["response_headers"] = response.headers
      m["response_message"] = response.message
      m["times_retried"] = response.times_retried
    end

    m
  end

  private
  # Turn [method, url, spec] requests into a hash for friendlier logging / ES indexing
  def structure_request(request)
    method, url, spec = request
    # Flatten everything into the 'spec' hash, also stringify any keys to normalize
    Hash[(spec||{}).merge({
      "method" => method.to_s,
      "url" => url,
    }).map {|k,v| [k.to_s,v] }]
  end
end
