#encoding: utf-8

module SceneryRmi
  #
  # =Scenery 跨进程请求扩展机制
  #
  #    # 普通后台服务程序: config.ru
  #      use SceneryRmi::XRequest
  #
  #    # Rails程序: config/application.rb
  #      config.middleware.insert_after ActionDispatch::RequestId, SceneryRmi::XRequest
  #
  # 这个类实现了3个功能:
  #   1. 在线程上下文保存了外部请求env信息
  #   2. 在env中设置了scenery.x_request_id(兼容Rails生成的)
  #   3. 跨进程时，记录了跟踪并保持了用户的会话id
  # 配合SceneryRMI Connection对象,可以将请求id, 用户preference跨服务进程传递
  #
  # 备注:
  #   这2个功能违反了一般的单一职责原则,
  #   但考虑到不要给外部应用太多的配置,以及这2个功能有较强的相关性
  #   所以,暂时将它们合在一个Rack Middleware里
  #
  class XRequest
    unless defined?(X_REQUEST_KEY)
      X_REQUEST_KEY = :x_request_env
    end
    unless defined?(X_REQUEST_ID)
      X_REQUEST_ID = 'scenery.x.request_id'
    end
    unless defined?(X_SESSION_ID)
      X_SESSION_ID = 'scenery.x.session_id'
    end

    attr_reader :app, :key

    def initialize(app, session_key = '_session_id')
      @app = app
      @key = session_key
    end

    def call(env)
      begin
        Thread.current[X_REQUEST_KEY] = env
        # 这一步的获取, 在Rails栈中,会复用 ActionDispatch::RequestId 生成的
        # 在非Rails栈中, 会自动生成
        env[X_REQUEST_ID] ||= external_request_id(env) || internal_request_id
        env[X_SESSION_ID] = env[Rack::RACK_SESSION].id rescue nil
        status, headers, body = app.call(env)
        # 这一步的设置, 在rails 栈中,会被 ActionDispatch::RequestId 覆盖, 但效果一致
        # 在非Rails栈中, 会实际生效
        headers['X-Request-Id'] = env[X_REQUEST_ID]
      ensure
        Thread.current[X_REQUEST_KEY] = nil
      end
      [status, headers, body]
    end

    class << self
      # 其他地方获取当前请求env
      def env
        Thread.current[X_REQUEST_KEY] ||= {}
      end

      def request_id
        self.env[X_REQUEST_ID]
      end

      def session_id
        self.env[X_SESSION_ID]
      end
   end

    private
    def external_request_id(env)
      # 先考虑是不是rails栈已经生成过了
      if env['action_dispatch.request_id'].presence
        env['action_dispatch.request_id']
      elsif (request_id = env['HTTP_X_REQUEST_ID'].presence)
        # 而后再从http请求头里面抽取
        request_id.gsub(/[^\w\-]/, '').first(255)
      end
    end

    def internal_request_id
      SecureRandom.hex(16)
    end

  end # class XRequest
end # module SceneryRmi