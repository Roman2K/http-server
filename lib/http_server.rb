require 'eventmachine'
require 'strscan'
require 'rack'

module HTTPServer
  def self.run(*args, &block)
    EventMachine.run do
      start(*args, &block)
    end
  end
   
  def self.start(application, options={})
    iface = InterfaceDetails.new(*options.values_at(:Host, :Port))
    handler = Session.derive(iface, application)
    yield handler if block_given?
    EventMachine.start_server(iface.host, iface.port, handler)
  end

  def self.status_message_from_code(code)
    Rack::Utils::HTTP_STATUS_CODES[code] or
      raise "unknown response status code: #{code}"
  end

  class ExceptionCatching
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue Exception
      env['rack.exception'] = $!
      [500, {}, []]
    end
  end

  class DefaultBodyFromStatusMessage
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      unless Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.include? status
        headers = Rack::Utils::HeaderHash.new(headers)
        if (headers['Content-Length'] || body.length).to_i <= 0
          headers['Content-Type'] = "text/plain"
          body = ["#{status} #{HTTPServer.status_message_from_code(status)}\n"]
        end
      end
      [status, headers, body]
    end
  end

  class InterfaceDetails < Struct.new(:host, :port)
    def initialize(host=nil, port=nil)
      super(host || "0.0.0.0", port || 8080)
    end

    def to_s
      "#{host}:#{port}"
    end
  end

  class Session < EventMachine::Connection
    class << self
      attr_reader :interface
      attr_reader :application

      def derive(*args, &block)
        Class.new(self).set_up!(*args, &block)
      end

      def set_up!(interface, application)
        @interface = interface
        @application = Rack::Chunked.new(Rack::ContentLength.new(application))
        return self
      end
    end

    def post_init
      @scan = StringScanner.new("")
    end

    def receive_data(data)
      if !@body
        @scan << data
        try_parsing_request_line
        if @headers
          try_collecting_headers
          if @scan.skip_until(/\r\n/)
            env, data = build_rack_environment!
            EventMachine.defer do
              respond(env)
            end
          end
        end
      end
      if @body
        @body << data
      end
    end

  private

    def try_parsing_request_line
      if !@method && @scan.scan_until(/\A([A-Z]+) (.+?) HTTP\/\d+\.\d+\r\n/)
        @method = @scan[1]
        @uri = @scan[2]
        @headers = {}
      end
    end

    def try_collecting_headers
      while @scan.scan_until(/^([^\0-\31\127:]+):[ \t]*(.+?)[ \t]*\r\n/)
        @headers[@scan[1]] = @scan[2]
      end
    end

    def build_rack_environment!
      # URI
      path, qs = @uri.split('?', 2)
      remove_instance_variable(:@uri)

      # CGI environment
      env = {
        'REQUEST_METHOD'  => @method,
        'SCRIPT_NAME'     => path == '/' ? "" : path,
        'PATH_INFO'       => path,
        'QUERY_STRING'    => qs || "",
      }
      remove_instance_variable(:@method)

      # Headers
      @headers.each do |key, value|
        env["HTTP_#{key.gsub(/\W+/, '_').upcase}"] = value
      end
      remove_instance_variable(:@headers)

      # Hostname and port number
      env['SERVER_NAME'], env['SERVER_PORT'] =
        self.class.interface.to_a.
          zip((env['HTTP_HOST'] || "").split(':', 2)).
          map { |default, actual| actual || default.to_s }

      # Rack specifics
      env.update \
        'rack.version'    => [1,0],
        'rack.url_scheme' => "http",
        'rack.errors'     => $stderr

      # Body
      @body = env['rack.input'] = Body.new(env['HTTP_CONTENT_LENGTH'])
      data = @scan.post_match
      remove_instance_variable(:@scan)

      return env, data
    end

    def respond(env)
      response = self.class.application.call(env)
    rescue Exception
      # Exceptions should be handled in middlewares.
      close_connection
    else
      send_response *response
    end

    def send_response(status, headers, body)
      message = HTTPServer.status_message_from_code(status)
      send_data "HTTP/1.0 #{status} #{message}\r\n"
      headers.each do |key, value|
        send_data "#{key}: #{value}\r\n"
      end
      send_data "\r\n"
      body.each do |part|
        send_data(part)
      end
      close_connection_after_writing
    end

    # Unbuffered. As a consequence, the following doesn't comply with the Rack specification:
    # * +gets+ is left unimplemented.
    # * +rewind+ is only partially implemented.
    class Body
      include Enumerable

      def initialize(length)
        @queue = EventMachine::Queue.new
        @length = length.to_i
        @yielded = 0
      end

      def <<(part)
        @queue.push(part) unless part.empty?
        return self
      end

      def rewind
        unless @yielded <= 0
          raise "request body not rewindable"
        end
        return 0
      end

      def each
        if @length <= 0
          return
        end
        if eof?
          raise EOFError, "end of request body stream already reached"
        end
        yield_next = lambda do
          @queue.pop do |part|
            yield part
            @yielded += part.length
            yield_next.call unless eof?
          end
        end
        yield_next.call
      end

      def eof?
        @yielded >= @length
      end

      def read
        inject("") { |str, part| str << part }
      end
    end
  end
end
