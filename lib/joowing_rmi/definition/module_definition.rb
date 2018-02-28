#encoding: utf-8
module JoowingRmi
  module Definition
    class ModuleDefinition < Struct.new(:namespaces, :name, :backend, :primary_key, :prefix, :description, :children, :load_from_remote)
      def initialize(*args)
        options = args.extract_options!
        super(*args)
        options.each_pair{|k,v| self.send("#{k}=", v)}

        self.namespaces ||= []
        self.children ||= []
      end

      def to_object(container)
        module_name = self.name.to_s.classify
        if container == ::Joowing || container.name.to_s.starts_with?('Joowing::')
          # 老的Joowing访问形态
          const = Module.new do
            # 应用于在特定模块名字空间下, 查找子对象定义的场景
            def self.const_missing(name)
              JoowingRmi::Manager.application.joowing_autoload(self, name)
            end
          end
        else
          # 新的Backend名称开头的访问形态
          const = Module.new
          JoowingRmi::Manager.application.inject_load_from_remote(const, self.backend)
        end
        container.const_set(module_name, const)
        tags = container.name.underscore.split('/')
        tags.unshift 'rmi'
        tags << module_name.to_s
        JoowingLogger.assign_for(const, tags: tags)
        const
      end

      include DSL

      def child_namespaces
        self.namespaces + [self.name]
      end

      def to_s
        if self.backend
          '%s => %s' % [self.name.to_s.camelcase, self.backend]
        else
          self.name.to_s.camelcase
        end
      rescue
        log_error "#{self.name}: #{$!}"
      end
    end
  end
end