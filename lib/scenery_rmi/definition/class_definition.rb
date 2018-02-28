#encoding: utf-8
module SceneryRmi
  module Definition
    class JHash < ::Hash
      def initialize(*args)
        data = args.shift
        super(nil).update(data)
      end
    end

    class ClassDefinition < Struct.new(:namespaces, :name, :backend, :primary_key, :prefix, :description, :element_name, :collection_name, :attributes, :actions, :type, :children, :load_from_remote, :dont_use_element_name)
      cattr_accessor :action_names
      self.action_names = {get: 'query', put: 'update', delete: 'destroy', post: 'create'}


      module LabelSupport
        def label(method_name)
          method_name
        end
      end

      module TypeMapper
        def initialize(*args)
          super(*args)

          # self.class.columns_hash.each do |name, attribute|
          #   if attribute.type == :time
          #     time_value = self.attributes[name.to_s]
          #     self.attributes[name.to_s] = Time.parse(time_value) if time_value
          #   elsif attribute.type == :date
          #     time_value = self.attributes[name.to_s]
          #     self.attributes[name.to_s] = Time.parse(time_value).to_date if time_value
          #   end
          # end
        end

        def _convert(value, type)
          # To compatible with old scenery_rmi,
          #  don't convert string to int/float
          #  treat datetime as string
          case type
            when :time
              converted = (Time.parse(value) rescue nil)
              converted ||= (DateTime.parse(value) rescue nil)
              converted ||= value
            # when :datetime
            #   converted = DateTime.parse(value)
            when :date
              converted = Time.parse(value).to_date
            # when :int, :integer
            #   converted = value.to_i
            # when :float
            #   converted = value.to_f
            else
              converted = value
          end
          converted
        end

        def load(*args)
          super(*args)

          self.class.columns_hash.each do |name, attribute|
            value = self.attributes[name.to_s]
            if value.is_a?(String)
              self.attributes[name.to_s] = _convert(value, attribute.type)
            elsif value.is_a?(Array)
              converted = value.map { |v| _convert(v, attribute.type) }
              self.attributes[name.to_s] = converted
            elsif attribute.type == :hash && value.is_a?(ActiveResource::Base)
              self.attributes[name.to_s] = value.attributes
            end
          end
        end
      end

      module AttributeAccessor
        def method_missing(name, *args)
          if self.class.columns_hash.keys.include?(name.to_sym)
            self.attributes[name.to_sym]
          else
            super(name, *args)
          end
        end
      end

      attr_accessor :query_mode
      attr_accessor :serialize_with_root

      def initialize(*args)
        options = args.extract_options!
        super(*args)
        options.each_pair { |k, v| self.send("#{k}=", v) }
        self.element_name ||= self.name.to_s
        self.primary_key ||= :id
        self.attributes ||= []
        self.actions ||= []
        self.query_mode = :get
        self.serialize_with_root = true
        self.children ||= []
        self.init_default_actions
      end

      def underscore_class_name
        return @underscore_class_name unless @underscore_class_name.nil?
        @underscore_class_name = self.namespaces.dup
        first = @underscore_class_name.first
        # 这个往往只有遗留形态的代码会这样
        if first.to_s == self.backend.to_s
          @underscore_class_name.unshift('scenery')
        else
          @underscore_class_name.unshift(self.backend)
        end
        @underscore_class_name << self.name
        @underscore_class_name.map(&:to_s).join('/')
      end

      # add class methods update and destroy
      # noinspection RubyResolve
      def init_default_actions
        klass = self.type || underscore_class_name.classify
        self.put ':id', type: klass, description: '修改记录'
        self.delete ':id', type: klass, description: '删除记录'
      rescue => e
        log_error(e)
      end

      def collection_action(name, &blk)
        define_action(name, instance: false, type: self.type, &blk)
      end

      def instance_action(name, &blk)
        define_action(name, instance: true, type: self.type, &blk)
      end

      deprecate :collection_action, :instance_action

      def define_action(method, name, hash, &blk)
        action = self.actions.find { |a| a.name.intern == name.intern } || begin
          record = ActionDefinition.new(method.intern, name)
          self.actions << record
          record
        end
        hash.each_pair { |n, v| action.send("#{n}=", v) }
        blk.call(action) unless blk.nil?
      end

      # for action or attribute definition
      def method_missing(method_name, *args, &block)
        action = %w[get gets put puts delete deletes post posts].include? method_name.to_s
        attribute = %w[anything object string int float text integer hash date time datetime boolean].include? method_name.downcase.to_s
        return guess_action(method_name, *args, &block) if action
        return guess_attributes(method_name.to_s.downcase.intern, *args, &block) if attribute
        super
      end

      def guess_action(method_name, *args, &block)
        path = args[0]
        if args.length > 1
          hash = args[1]
        else
          hash = {}
        end
        action_name = hash.delete(:as) || hash.delete('as') || begin
          if path.to_s == ':id'
            ClassDefinition.action_names[method_name]
          elsif path.to_s.include? '/'
            path[path.rindex('/') + 1, path.length]
          else
            path
          end
        end
        type = hash.delete(:type) || hash.delete('type') || self.type
        type ||= :anything
        if method_name.to_s[-1] == 's'
          array = true
          method = method_name.to_s[0, method_name.to_s.length-1]
        else
          array = false
          method = method_name.to_s
        end
        hash[:instance] = false if hash[:instance].nil?
        hash.update path: path, type: type, array: array
        hash[:description] ||= get_description
        define_action(method, action_name, hash, &block)
      end

      def guess_attributes(method_name, *args, &block)
        raise 'You must specify attribute name' if args.blank?
        options = args.extract_options!
        options.update type: method_name
        names = args
        define_attributes names, options, &block
      end

      # add created_at and updated_at to instance
      def timestamps
        [:created_at, :updated_at].each do |attr|
          time attr
        end
      end

      def hash(*args, &block)
        if args.empty?
          super
        else
          guess_attributes :hash, *args, &block
        end
      end

      def assign_default_values_to(obj)
        self.attributes.each do |a|
          a.assign_default_value_to(obj)
        end
      end

      def attribute(name, options = {}, &blk)
        #Ensure the type is symbol
        #options[:type] = options[:type].intern
        if options.empty? and !blk
          self.attributes.find{|attr| attr.name.intern == name.intern}
        else
          a = AttributeDefinition.new(name, options).tap do |a|
            blk.call(a) if blk
          end

          self.attributes << a
        end
      end

      # Define multiple attributes in one line
      def define_attributes(names, options = {}, &blk)
        Array(names).each do |attr|
          attribute(attr, options, &blk)
        end
      end

      # prefix and element name
      def prefix_path
        raise "element_name is nil for #{self.name}" if self.element_name.nil?
        File.join(self.prefix || '', self.element_name.to_s.pluralize) + '/'
      end

      def constantize(string)
        string.constantize
      end

      def to_object(container)
        constant = Class.new(ActiveResource::Base) do
          include SceneryRmi::Obj::Base
          class_attribute :class_definition

          def respond_to?(attr, include_private=false)
            self.class.columns_hash.has_key?(attr.to_sym) || super(attr, include_private)
          end

          class << self
            def columns_hash
              self.class_definition.attributes.inject({}) do |r, a|
                r[a.name.to_sym] = a
                r
              end
            end

            def logger
              @scenery_logger
            end

            def logger=(other)
              @scenery_logger = other
            end

          end
        end

        container.const_set(self.name.to_s.classify, constant).tap do |real_klass|
          ext_name = real_klass.name.gsub(/^(?:Scenery|#{self.backend.to_s.classify})::/, 'SceneryRmi::Ext::')
          begin
            require ext_name.underscore
            real_klass.send :include, ext_name.constantize
            SceneryRmi::Manager.application.logger.debug("Mixin: #{ext_name}")
          rescue LoadError
            # ignore
          rescue NameError
            # ignore
          end
        end

        constant.tap do |klass|
          klass.class_definition = self
          klass.send :element_name=, self.element_name
          klass.send :collection_name=, self.collection_name.to_s if self.collection_name
          begin
            klass.backend self.backend
          rescue Exception #ArgumentError
            klass.backend = self.backend
          end
          klass.send :primary_key=, self.primary_key
          klass.query_mode = self.query_mode

          klass.serialize_with_root = self.serialize_with_root

          if self.prefix
            klass.send :prefix=, self.prefix
          end

          if self.primary_key.to_sym != :id
            klass.class_eval do
              def id
                send(self.class.primary_key)
              end
            end
          end

          klass.extend(LabelSupport)
          klass.send(:include, TypeMapper)
          klass.send(:include, AttributeAccessor)

          self.attributes.each do |attr|
            if attr.type.is_a? String
              begin
                if attr.type.start_with?('Scenery') or
                    attr.type.start_with?('::Scenery') or
                    attr.type.start_with?(self.backend.classify) or
                    attr.type.start_with?('::' + self.backend.classify)
                  one_klass = constantize(attr.type)
                else
                  one_klass = constantize("::#{self.backend.classify}::#{attr.type}")
                end
                inject_name = attr.name.to_s
                if attr.array
                  inject_name = ActiveSupport::Inflector.singularize(inject_name.to_s)
                end

                klass.const_set(inject_name.classify.to_sym,
                                Class.new(one_klass) { |k|
                                  k.serialize_with_root = false if k.respond_to? :serialize_with_root
                                })

              rescue NameError
                #ignore
              end
            elsif attr.type == :hash
              begin
                inject_name = attr.name
                if attr.array
                  inject_name = ActiveSupport::Inflector.singularize(inject_name.to_s)
                end
                silence_warnings do
                  klass.const_set(inject_name.to_s.classify.to_sym, JHash)
                  klass.const_set(inject_name.to_s.camelize(:upper).to_sym, JHash)
                end
              rescue NameError
                #ignore
              end
            end
          end

          self.actions.each do |action|
            action.inject_method klass, self
          end

        end

        tags = container.name.underscore.split('/')
        tags.unshift 'rmi'
        tags << self.name.to_s
        # 不能用AssignFor, 因为继承了ActiveResource::Base, 实际assign到父类上;从而各个子类共享了
        constant.logger = SceneryLogger.allocate(tags)

        constant
      end

      def to_s
        suffix = ''
        unless self.name.to_s == self.element_name
          suffix = "(#{self.element_name})"
        end
        pk = (self.primary_key.blank? ? '' : "(#{self.primary_key})")
        format '%s%s => %s%s', self.name.to_s.camelcase, pk, self.backend, suffix
      rescue
        log_error "#{self.name}: #{$!}"
      end

      include DSL

      def child_namespaces
        self.namespaces + [self.name]
      end
    end
  end
end