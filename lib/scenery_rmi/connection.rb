#encoding: utf-8
module SceneryRmi
  module ConnectionExtension

    mattr_accessor :call_entries
    self.call_entries = %w[inject_class_method inject_instance_method where]

    def build_request_headers(headers, http_method, uri)
      headers = super(headers, http_method, uri)
      # XRequest 记录了当前线程上下文的外部请求信息(env)
      if XRequest.env
        # 跨scenery rmi传递唯一性请求id, 便于跨多个服务进程追踪用户请求
        headers['X-Request-Id'] = XRequest.request_id || ''
        # 跨scenery rmi传递Accept-Language,便于后台直接输出前台需要的国际化信息（如错误）
        headers['Accept-Language'] = XRequest.env['HTTP_ACCEPT_LANGUAGE'] || 'zh'
        # 跨进程追踪用户会话
        # 用户a向系统X发起请求，系统X通过scenery rmi向系统Y发起请求
        # 此时，系统X将用户的session_id也在这个scenery rmi的请求头里面传递
        headers['Cookie'] = "_session_id=#{XRequest.session_id}" if XRequest.session_id
      end
      begin
        backend = SceneryRmi::Manager.backend || 'unknown'
        locations = caller_locations
        index = locations.find_index do |cl|
          ConnectionExtension.call_entries.include?(cl.base_label)
        end
        unless index
          index = locations.find_index{|cl| cl.base_label == 'fetch_data'}
          return headers unless index
          location = locations[index + 3]
        else
          location = locations[index + 1]
        end
        headers['HTTP-REFERER'] = "#{backend}://#{location}"
      rescue Exception => e
        SceneryRmi::Manager.application.logger.warn(e)
      end
      headers
    end

    def handle_response(response)
      status = response.code.to_i
      if status == 450
        raise CustomException.new(response)
      elsif status == 451
        raise BuzException.new(response)
      elsif status > 400
        begin
          error = JSON.parse response.body
          if error.is_a?(Hash)
            if  error['class'] && error['ancestors']
              # 这是scenery rmi 原先的机制
              ancestors = error['ancestors']
              error_class = Scenery::Error
              # 生成或者访问到动态错误类
              ancestors.split(',').each { |const_name| error_class = error_class.const_get(const_name) }
              exception = error_class.new(error['message'], error['code'], error['args'])
              exception.status = (error['status'] || response.code).to_i
              exception.class_name = error['class']
              raise exception
            elsif error['status'] && error['error'] && error['exception']
              # 这是Rails 5的新机制
              msg = '%s occurred while call `%s` to "%s"' % [error['exception'], self.klass.backend, self.site.to_s]
              exception = Scenery::Error.new(msg, error['error'], status: error['status'])
              traces = error['traces']
              if traces and traces['Full Trace']
                backtrace = traces['Full Trace'].map{|item| item['trace']}
                exception.set_backtrace backtrace
              end
              raise exception
            end
          end
        end
      end
      super(response)
    end

  end

  class Connection < ActiveResource::Connection
    class CustomException < RuntimeError
      attr_reader :remote_backtrace, :response
      def initialize(response)
        begin
          @response = response
          resp = MultiJson.load(response.body, symbolize_keys: true)
          super(resp[:error])
          @remote_backtrace = resp[:backtrace]
        rescue
          @remote_backtrace = []
          super('无法解析的远程异常')
        end
      end
    end

    class BuzException < RuntimeError
      attr_reader :context
      def initialize(response)
        begin
          @context = MultiJson.load(response.body, symbolize_keys: true)
          super('BuzException')
        rescue
          @context = {}
          super('无法解析的远程异常')
        end
      end
    end

    # 对http请求失败后, 日志需要一个result进行输出描述
    class ErrorResponse
      attr_reader :error
      def initialize(exception)
        @error = exception
      end

      def code
        500
      end

      def message
        error.message
      end

      def body
        error.backtrace.join('\n')
      end
    end

    module StatusProxy
      def code
        self.status
      end
    end

    prepend ConnectionExtension

    attr_reader :klass

    def initialize(klass, site, format =  ActiveResource::Formats::JsonFormat)
      @klass = klass
      super(site, format)
    end

    def with_auth
      # simple skip all auth
      yield if block_given?
    end

    def build_uri(path)
      if self.site.path.blank?
        self.site.merge(path)
      else
        path = path.to_s
        # 直接find的接口，其计算element path时，就会自动加上site的path
        if path.start_with?(self.site.path)
          full_path = path
        else
          full_path = self.site.path + path
        end
        self.site.merge(full_path)
      end
    end

    def get(path, headers = {})
      with_auth { request(:get, path, nil,  build_request_headers(headers, :get, build_uri(path))) }
    end

    # Executes a DELETE request (see HTTP protocol documentation if unfamiliar).
    # Used to delete resources.
    def delete(path, headers = {})
      with_auth { request(:delete, path, nil,  build_request_headers(headers, :delete, build_uri(path))) }
    end

    # Executes a PUT request (see HTTP protocol documentation if unfamiliar).
    # Used to update resources.
    def put(path, body = '', headers = {})
      with_auth { request(:put, path, body.to_s, build_request_headers(headers, :put, build_uri(path))) }
    end

    # Executes a POST request.
    # Used to create new resources.
    def post(path, body = '', headers = {})
      with_auth { request(:post, path, body.to_s, build_request_headers(headers, :post, build_uri(path))) }
    end

    # Executes a HEAD request.
    # Used to obtain meta-information about resources, such as whether they exist and their size (via response headers).
    def head(path, headers = {})
      with_auth { request(:head, path, nil, build_request_headers(headers, :head, build_uri(path))) }
    end

    def request(method, path, *arguments)
      request_uri = build_uri(path)
      result = ActiveSupport::Notifications.instrument('request.active_resource') do |payload|
        http = SceneryRmi::ConnectionManager.manager.connection_pool(@klass.backend)
        payload[:method]      = method
        payload[:request_uri] = request_uri.to_s
        begin
          payload[:result]      = http.send(method, request_uri.path, *arguments)
        rescue Exception=>e
          payload[:result]      = ErrorResponse.new(e)
          raise e
        end
      end

      result.singleton_class.send(:include, StatusProxy)

      handle_response(result)
    rescue OpenSSL::SSL::SSLError => e
      raise ActiveResource::SSLError.new(e.message)
    rescue CustomException, BuzException, Scenery::Error => e
      SceneryRmi::Manager.application.logger.error(e.backtrace.join('\n'))
      raise e
    rescue StandardError => e
      begin
        message = e.response.body
        status = e.response.status
      rescue
        message = e.message
        status = 500
      end
      message = e.to_s if message.blank?
      args = {status:status, request_uri: request_uri, collection_name: @klass.collection_name}
      raise Scenery::RemoteError.new(message, @klass.backend.to_s.upcase, args, e.backtrace)
    end

    # Handles response and error codes from the remote service.

    public :handle_response
  end
end
