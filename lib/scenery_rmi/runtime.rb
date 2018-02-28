#encoding: utf-8

module SceneryRmi
  #
  # = Scenery 远程API自动加载机制
  #
  # 应用开发者不需要在Bundle里面显性依赖特定的API Gem
  # 服务的API信息,由服务的提供者提供, 由使用者在运行态加载
  # 暂时没有支持服务API的自动更新（backend更新后, 使用者,也需要重启,才能获得更新,以后可能支持）
  # 例如 PomeloBackend 定义了 Promotion Module下有Promotion, PromotionGroup, PromotionItem三个API对象
  # 使用其的 Pomelo, 不需要依赖 pomelo_backend_api,
  # 而是 通过 PomeloBackend::Promotion::Promotion 直接访问其
  class Runtime

    def initialize(app, backend = nil)
      @app = app
      # 考虑到nginx代理作用, 可能以多种形态加载dsl
      # /api/meta.dsl -> /api/meta.dsl             # 老的方式
      # /api/cmdb/meta.dsl -> /meta.dsl            # 新的方式，nginx做了url rewrite
      # /api/cmdb/meta.dsl -> /api/cmdb/meta.dsl   # 新的方式，nginx没有rewrite url，直接透传
      @uris = %w[/api/meta.dsl /meta.dsl]
      @uris << "/api/#{backend}/meta.dsl" if backend
    end

    def call(env)
      req_path = env['REQUEST_PATH'] || env['PATH_INFO']
      if env['REQUEST_METHOD'] == 'GET' and @uris.include?(req_path)
        env['QUERY_STRING'] =~ /name=([a-z|A-Z|0-9|_|.]+)/
        key = $1
        raise 'You should pass dsl name' unless key
        # 虽然这里支持了
        key = key.tableize.singularize
        name = key.gsub('.', '/')
        path = "lib/dsl/#{name}.rb"
        unless File.exist?(path)
          backend = SceneryRmi::Manager.application.backend
          message = "Current subsystem has't configure SceneryRmi correctly"
          return [404, {'content-type' => 'text/plain', 'content-length' => message.bytesize.to_s}, [message] ] if backend.blank?
          path2 = "lib/dsl/#{backend}.rb"
          unless File.exist?(path2)
            message = "There is no DSL defined for #{key} in #{path} or #{path2}"
            return [404, {'content-type' => 'text/plain', 'content-length' => message.bytesize.to_s}, [message] ]
          end
          path = path2
        end
        body = IO.read(path)
        [200, {'content-type' => 'text/plain', 'content-length' => body.bytesize.to_s}, [body]]
      else
        @app.call(env)
      end
    end

    class << self
      # 对不同后台的调用模式
      attr_accessor :modes
      def load_dsl(name)
        self.modes ||= {}
        keys = name.split('.')
        backend = keys.shift
        name = keys.join('.')
        http = SceneryRmi::ConnectionManager.manager.connection_pool(backend)
        # 根据实际情况，动态通过两种模式获取api
        begin
          with_backend = self.modes[backend]
          uri = with_backend ? "/api/#{backend}/meta.dsl?name=#{name}" : "/api/meta.dsl?name=#{name}"
          resp = http.send(:get, uri)
          raise if resp.status == 404
          resp
        rescue
          self.modes[backend] = !with_backend
          retry
        end
      end
    end
  end
end