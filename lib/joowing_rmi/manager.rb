#encoding: utf-8
require 'joowing_logger'

module JoowingRmi

  class Manager
    cattr_accessor :application, :last_description, :backend
    # 当前绑定的后端, 根据该属性, 过滤掉自身发出的api事件
    attr_accessor :backend, :after_model_blks, :logger
    attr_reader :config, :definitions, :backends, :regexp
    attr_accessor :listener_thread

    def initialize(config = {})
      @config = config.symbolize_keys
      @definitions = {}
      @logger = JoowingLogger.allocate('rmi')
      @backends = {} # backend class name to enhanced BackendModule(or class, such as PomeloBackend)
      @regexp = /^(joowing)\./
      @after_model_blks = {}
    end

    def look_for_module_or_class(name, namespaces = [])
      full_name = (namespaces + [name]).join('.')
      self.get(full_name)
    end

    def save(module_or_class)
      type_name = module_or_class.class.name.split('::').last.sub('Definition', '').downcase
      full_name = (module_or_class.namespaces + [module_or_class.name]).join('.')
      if module_or_class.load_from_remote
        # 从远端加载的, 肯定有明确的backend
        prefix = module_or_class.backend.to_s + '.'
      else
        prefix = 'joowing.'
      end
      full_name = prefix + full_name unless full_name.starts_with?(prefix)
      self.logger.debug "Store #{type_name} config for #{full_name}"
      self.definitions[full_name] = module_or_class
    end

    def get(name, container = nil)
      name = name.to_s
      key = nil
      if container && container.respond_to?(:load_from_remote)
        backend = container.backend.to_s
        if not backend.blank? and not name.starts_with?(backend + '.')
          key = backend + '.' + name
        end
      else
        key = 'joowing.' + name
      end
      key ||= name
      definition = self.definitions[key]
      raise ConfigNotFoundError, name unless definition
      definition
    end

    def initialize_backend_constants
      # 防止重复初始化
      return if self.backends['Joowing']
      self.backends['Joowing'] = ::Joowing
      (self.config[:backend] || {}).keys.each do |backend|
        # nebula 被命名为 mango_portal
        next if backend.to_s == 'nebula'
        # 自身不应该被增强
        next if backend.to_s == self.class.backend.to_s
        class_name = backend.to_s.classify
        self.backends[class_name] ||= enhance_backend_const(class_name, backend)
      end
      keys = self.backends.keys.map(&:tableize).map(&:singularize)
      @regexp = /^(#{keys.join('|')})\./
      self.start_redis_subscription
    end

    # fork 子进程之后, 不需要重新调用本方法, 只要touch一下listener thread
    #  JoowingRmi::Manager.application.listener_thread
    # 子进程一旦touch该变量, 就会在子进程中重新执行相应的代码
    # 而redis连接也会被自动建立/维护
    def start_redis_subscription
      # 如果已经有一个线程,先停掉
      # 实际部署模式下, 会重新调用本方法, 以便fork出来的子进程, 都会有一个独立的redis socket连接
      listener_thread.terminate if listener_thread
      # 初始化一个线程,负责接收redis的那边广播过来的API变更
      self.listener_thread = Thread.start do
        # 这个线程里面, 必须使用单独用于接收callback的redis对象, 因为该对象会被subscription独占
        client_name = "joowing_rmi_listener_of_#{$$}"
        begin
          subscribe_to_redis client_name
        rescue Redis::BaseConnectionError => e
          self.logger.info "Subscription to joowing_rmi.* as #{client_name} is broken by: #{e.message}"
          sleep 60 # 休息1分钟,而后尝试重新建立链接
          retry
        end
      end
      self.logger.info("#{listener_thread} is response for joowing_rmi api changed event with a separate redis connection")
    end

    def subscribe_to_redis(client_name)
      self.logger.info 'Subscribing joowing_rmi.* as ' + client_name
      redis_listener = Redis.new(config[:redis].symbolize_keys)
      redis_listener.call 'client', 'setname', client_name rescue nil
      redis_listener.psubscribe 'joowing_rmi.*' do |subscription|
        subscription.pmessage do |_, channel, version|
          config_name = channel['joowing_rmi.'.length..-1]
          # self.logger.debug "Got #{config_name} changed to #{version}"
          self.reload_api_if_necessary(config_name, version)
        end
      end
    end

    # 在接收到redis发布过来的消息后,核对相应的api对象的版本
    def reload_api_if_necessary(config_key, version)
      keys = config_key.split('.')
      backend = keys.shift
      return if backend == self.backend.to_s
      begin
        self.get config_key
      rescue ConfigNotFoundError
        return
      end
      backend_class = backend.classify
      api = Object.const_get backend_class
      parent = api
      keys.each do |key|
        parent = api
        api = api.const_get key.classify
      end
      if api.respond_to?(:md5_version)
        old_version = api.md5_version
        if old_version != version
          api_name = api.name.split('::').last.intern
          # 从配置中删除
          self.definitions.delete(config_key)
          # 再从上级常量中删除常量
          parent.send :remove_const, api_name
          self.logger.info "#{parent}::#{api_name} is changed from #{old_version} to #{version}, remove it from #{parent}"
        else
          # self.logger.debug "#{api.name} is not changed, no need to reload api #{config_key}: #{version}"
        end
      else
        self.logger.debug "#{api.name} without md5 version, do not reload from remote #{backend}"
      end
    rescue NameError=>e
      self.logger.debug "Previous API object is not loaded, no need to reload api #{config_key}: #{e.message}"
    rescue Exception=>e
      message = "Failed to reload api #{config_key}, #{e.message}"
      self.logger.warn e.backtrace.unshift(message)
    end

    def config_name(container, name, backend_prefix = false)
      container_name = (self.backends[container.name] ? nil : container.name.tableize.singularize.gsub('/', '.'))
      full_name = container_name.nil? ? name.to_s.tableize.singularize : "#{container_name}.#{name.to_s.tableize.singularize}"
      full_name.gsub!(self.regexp, '')
      if backend_prefix
        container.backend.to_s + '.' + full_name
      else
        'joowing.' + full_name
      end
    end

    def joowing_autoload(container, name, backend_prefix = false)
      full_name = config_name(container, name, backend_prefix)
      self.logger.debug "Lookup #{name} in #{container.name} by #{full_name}"

      config = self.definitions[full_name]
      raise ConfigNotFoundError, "Can't find declared api for #{full_name} in #{container}" unless config
      const = config.to_object(container)
      if container == ::Joowing
        warn <<-WARN
          !!! You should access Joowing::#{full_name.classify} by #{config.backend.to_s.classify}::#{full_name.classify} to improve maintainability and code readability !!!
          !!! And you just need to remove all gem dependencies for #{config.backend}_api and don't use Joowing::Xxx !!!
        WARN
      end
      const
    end

    #
    # == 增强特定的backend, 让外部,甚至是其自己,可以通过
    #  PomeloBackend::Promotion 这样来访问自己的定义的API对象
    #  而不仅仅是通过无差异,无个性的 Joowing::Promotion这样访问远程API对象
    #  这样可以使业务代码更加易读,易理解,易维护;
    #
    # 否则, 开发人员在review代码的时候, 看到Joowing::Xxx对象的调用时, 总要通过其他手段来Review是否已经定义过
    #
    # @param class_name: 类似于 PomeloBackend 这样的字符串
    # @param backend: 类似于 :pomelo_backend 这样的符号
    # @return 相应被增强过的常量
    #   如果系统没有定义过该常量, 应该首先尝试 require 相应的文件, 而后增强
    #   如果系统已经定义过该常量, 则直接对齐进行增强
    def enhance_backend_const(class_name, backend)
      begin
        # 尝试通过Autoload机制, 获取或者加载相应的backend对应的常量
        # 一般在本系统中,有相应的常量存在, 如 PomeloBackend系统中, 在 lib下有pomelo_backend.rb
        # 其定义了本系统的一些全局机制
        target = class_name.constantize
        verb = 'Reuse'
        # TODO 对于Reuse的变量, 其可能会被ActiveSupport Auto Dependency reload掉
        # 应该注册一个ActiveSupport的回调, 当其被Reload之后, 继续执行enhance
      rescue NameError
        # 一般, 对外部系统, 并没有相应的常量, 我们默认将其定义为module
        # 如果外部有需求, 不为module, 则应该在应用层自行先定义
        # 而且, 还要确保在JoowingRMI相应的API加载之前加载
        # 或者, 应用层应该取一个另外的名字
        target = Object.const_set class_name, Module.new
        verb = 'Define'
      end
      self.inject_load_from_remote(target, backend)
      self.logger.info "#{verb} API #{target.class} #{target.name}"
      target
    end

    # == 增强从远端获取的常量
    def inject_load_from_remote(target, backend)
      # 定义几个静态变量, 分别用来记录远端, dsl文件的md5值,logger
      target.class_eval do
        mattr_accessor :backend, :md5_version, :rmi_logger, :load_from_remote
        self.backend = backend
        self.load_from_remote = true
      end
      # 将backend变量与target对象绑定, 以便其const_missing里面使用
      target.rmi_logger = self.logger
      # 重写Target这个类的const_missing方法
      # 更好的写法, 应该用 alias method chain的方式增强 const_missing
      def target.const_missing(name)
        app = JoowingRmi::Manager.application
        begin
          # 先尝试在本地查找, 因为可能在上级模块定义时, 已经把子对象的定义也加载了
          const = app.joowing_autoload(self, name, true)
          app.notify_observers(const)
          const
        rescue ConfigNotFoundError
          # 如果没有,说明要从远程加载
          config_name = app.config_name(self, name, true)
          self.rmi_logger.info("Loading #{name} DSL from #{self.backend} by #{config_name}")
          # 采用动态API的技术, 向远程发起加载API定义的请求
          response = JoowingRmi::Runtime.load_dsl(config_name)
          message = response.body.to_s
          if response.success?
            begin
              # 用 instance_eval 的目的是, 让其 self.backend 作为默认值生效
              self.instance_eval do
                eval(message)
              end
            rescue Exception => e
              raise NameError, "#{e.message} occurred from #{self.backend}.#{config_name} by eval:\n #{message}"
            end
            begin
              const = app.joowing_autoload(self, name, true)
              raise NameError, "No corresponding API object defined by:\n#{message}" unless const # 远程获取的dsl内容可能名不符实
              # 再次对衍生加载出来的常量进行增强
              app.inject_load_from_remote(const, self.backend)
              const.md5_version = Digest::MD5.hexdigest(message)
              self.rmi_logger.info("Loaded  #{name} DSL from #{self.backend} by #{config_name}, version: #{const.md5_version}")
              app.notify_observers(const)
              const
            rescue ConfigNotFoundError => e # 或者存在配置缺失, 定义错地方等
              raise NameError, e.message #, [name, self.name]
            end
          else
            self.rmi_logger.warn("Load failed #{name} from #{self.backend}: #{message}")
            # API server not support remote loading, just raise name error, not fallback to old solution
            raise NameError, message #, [name, self.name]
          end
        end
      end

    end

    def notify_observers(const)
      # Send callback to observers
      callbacks = self.after_model_blks[const.to_s]
      callbacks.each do |callback|
        callback.call(const)
      end if callbacks
    end

    def look_for_backend(name)
      name = name.to_s
      # 移除nebula这个joowing rmi配置项
      name = 'mango_portal' if name == 'nebula'
      name.split('.').inject(@config[:backend]) do |tree_config, one|
        return nil if tree_config.nil?

        tree_config.symbolize_keys[one.to_sym]
      end
    end

    alias_method :look_for_api_backend, :look_for_backend
  end

end