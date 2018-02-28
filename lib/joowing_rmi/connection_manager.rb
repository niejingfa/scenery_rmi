#encoding: utf-8
module JoowingRmi
  class ConnectionManager
    def self.manager
      @manager ||= new
    end

    def initialize
      @mapper = {}
    end

    # 当Require Fiber之后,线程想下文变量就变成了Fiber上下文
    # 每个Fiber下的Thread.current的值都是独特的
    def connection_pool(name)
      uri = URI.parser.parse(rmi_application.look_for_backend(name))
      http_pool = Thread.current[thread_key_for_name(name)]

      if http_pool.nil?
        @mapper[name] ||= allocate_http_pool(uri)
      else
        http_pool
      end
    end

    def overload_connection_pool(name, uri)
      uri = URI.parse(uri) unless uri.is_a?(URI)

      if block_given?
        Thread.current[thread_key_for_name(name)] = allocate_http_pool(uri)
        yield
        Thread.current[thread_key_for_name(name)] = nil
      end

    end


    def thread_key_for_name(name)
      "joowing_rmi_#{name}"
    end

    def key_for_uri(uri)
      "#{uri.host}:#{uri.port}"
    end

    def allocate_http_pool(uri)
      HttpPool.allocate_new_pool(uri)
    end

    def rmi_application
      @rmi_application ||= JoowingRmi::Manager.application
    end
  end
end