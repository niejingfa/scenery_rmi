#encoding: utf-8
require 'net/http'
require 'faraday'

module SceneryRmi
  class HttpPool

    def self.logger
      @logger ||= SceneryLogger.allocate('rmi.pool')
    end

    def self.logger=(l)
      @logger = l
    end

    def self.pool
      @pool ||= {}
    end

    def self.allocate_new_pool(uri)
      self.pool["#{uri.host}:#{uri.port}"] ||= new(uri)
    end

    attr_reader :uri

    def initialize(uri, opt = {})
      @size = opt[:size] || 64
      @uri = uri.is_a?(URI) ? uri : URI.parse(uri)
      @pool = []
      @using = []
      @waiting = []
      @count = {}
    end

    # get/head/delete(url, params, headers)
    %w[get head delete post put patch].each do |method|
      class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{method}(url = nil, params = nil, headers = nil)
          exec_request(:#{method}, url, params, headers)
        end
      RUBY
    end

    def exec_request(http_method, url, params, headers)
      url ||= '/'
      params ||= {}
      headers ||= {}
      conn = checkout
      if %w[get head delete].include?(http_method.to_s.downcase)
        conn.run_request(http_method.to_sym, url, nil, headers) { |request|
          request.params.update(params)
        }
      else
        conn.run_request(http_method.to_sym, url, params, headers)
      end
    end

    # post/put/patch(url, body, headers)
    # %w[].each do |method|
    #   class_eval <<-RUBY, __FILE__, __LINE__ + 1
    #     def #{method}(url = nil, body = nil, headers = nil, &block)
    #       conn = checkout
    #       resp = conn.run_request(:#{method}, url, body, headers, &block)
    #       current_fiber = Fiber.current
    #       if under_fiber?
    #         resp.on_complete {
    #           current_fiber.resume
    #         }
    #         Fiber.yield
    #
    #         checkin(conn)
    #       end
    #
    #       resp
    #     end
    #   RUBY
    # end

    def checkin(conn)
      if @waiting.size > 0
        @waiting.shift.resume(conn)
      else
        @using.delete(conn)
        @pool << conn
      end
    end


    def remove_connection(conn)
      conn.conn.close_connection
      @using.delete(conn)

      if @waiting.size > 0
        c = allocate_one_connection
        @using << c
        @waiting.shift.resume(c)
      end
    end


    def checkout
      Faraday.new(:url => uri) do |faraday|
        faraday.adapter  Faraday.default_adapter
      end
    end

    def allocate_one_connection
      EventMachine::HttpRequest.new(@uri)
    end

  end
end