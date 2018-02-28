#encoding: utf-8
require 'active_support/all'
module SceneryRmi::Obj
  module Base
    extend ActiveSupport::Concern

    # noinspection RubyArgCount
    module DSL
      def query_mode
        @query_mode ||= :get
      end

      def query_mode=(new_mode)
        @query_mode = new_mode.to_sym
      end

      def manager
        SceneryRmi::Manager.application
      end

      # @Overload
      def connection(refresh = false)
        @connection ||= SceneryRmi::Connection.new(self, self.site, format)
        # if defined?(@connection) || superclass == Object
        #   @connection =  if refresh || @connection.nil?
        #   @connection.proxy = proxy if proxy
        #   @connection.user = user if user
        #   @connection.password = password if password
        #   @connection.auth_type = auth_type if auth_type
        #   @connection.timeout = timeout if timeout
        #   @connection.ssl_options = ssl_options if ssl_options
        #   @connection
        # else
        #   superclass.connection
        # end
      end

      # TODO Remove it
      # 这个方法被动态增强后的 mattr_accessor (manager.rb:216) 遮盖掉了
      def backend(name = nil)
        if name.nil?
          @backend
        else
          @backend = name
          backend_uri = manager.look_for_backend(name)
          if backend_uri.nil?
            return SceneryRmi::Manager.application.logger.info( "Try to find #{name}, but not found, skip")
          end

          self.site = backend_uri
        end

      end

      def dup_klass
        Class.new(self).tap do |c|
          begin
            c.backend = self.backend
          rescue
            c.backend(self.backend) rescue nil
          end
          yield(c) if block_given?
        end
      end

      def serialize_with_root?
        serialize_with_root
      end

      def where(opt = {})
        find(:all, params: { self.element_name => opt})
      end

      def endless_paginate(opt = {}, params = {})
        paginate_opt = { :page => opt.delete(:page), :per_page => opt.delete(:per_page), order: opt.delete(:order) }
        query_opt = (params[:conditions] || {}).inject({}) do |r, (k,v)|
          unless v.nil? or v.blank?
            r[k] = v
          end

          r
        end

        query_opt.update(opt[:conditions] || {})

        paginate(query_opt, paginate_opt)
      end

      def query(opt = {})
        SceneryRmi::Origin.new(self).query(opt)
      end
      
      def paginate(opt = {}, page_opt = {})
        opt = opt.inject({}) do |r, (k,v)|
          unless v.nil?
            r[k] = v
          end

          r
        end

        page = page_opt[:page] || 1
        per_page = page_opt[:per_page]
        params = { self.element_name => opt, page: page, per_page: per_page, order: page_opt[:order] }
        #设置前缀
        opt.each do |key, value|
          params[key]=value  if prefix_parameters.include?(key.to_sym)
        end
        find_every_for_paginate( params: params)
      end

      def get_by_raw(options)
        case from = options[:from]
          when Symbol
            instantiate_collection(get(from, options[:params]).tap do |resp|
              yield(resp) if block_given?
            end)
          when String
            path = "#{from}#{query_string(options[:params])}"
            instantiate_collection(format.decode(connection.get(path, headers).tap do |resp|
              yield(resp) if block_given?
            end.body) || [])
          else

            # instantiate_collection( (format.decode(connection.get(path, headers).tap do |resp|
            #   #.first.try { |t| total_entries = t.to_i }
            #   yield(resp) if block_given?
            # end.body) || []), prefix_options )
            prefix_options, query_options = split_options(options[:params])

            if self.query_mode == :post
              path = "#{self.send :prefix, prefix_options}#{self.collection_name}/__query.#{self.format.extension}"
              resp_body = connection.post(path, self.format.encode(options[:params]), headers).tap do |resp|
                yield(resp) if block_given?
              end.body
            else
              path = collection_path(prefix_options, query_options)
              response = connection.get(path, headers)
              resp_body = response.tap do |resp|
                yield(resp) if block_given?
              end.body
            end

            instantiate_collection( (format.decode(resp_body) || []), prefix_options )
        end
      end

      def find_every_for_paginate(options)
        page = options[:params][:page] || options[:params]['page']
        per_page = options[:params][:per_page] || options[:params]['per_page']
        order = options[:params][:order] || options[:params]['order']

        WillPaginate::Collection.create(page, per_page) do |pager|
          total_entries = 0
          data = begin
            case from = options[:from]
              when Symbol
                instantiate_collection(get(from, options[:params]).tap do |resp|
                  (resp['total_entries'] || []).first.try { |t| total_entries = t.to_i }
                end)
              when String
                path = "#{from}#{query_string(options[:params])}"
                instantiate_collection(format.decode(connection.get(path, headers).tap do |resp|
                  (resp['total_entries'] || []).first.try { |t| total_entries = t.to_i }
                end.body) || [])
              else
                prefix_options, query_options = split_options(options[:params])
                path = collection_path(prefix_options, query_options)
                if self.query_mode == :post
                  path = "#{self.send :prefix, prefix_options}#{self.collection_name}/__query.#{self.format.extension}"
                  resp_body = connection.post(path, self.format.encode(options[:params]), headers).tap do |resp|
                    total_entries = (resp['total_entries'] || 1).to_i
                  end.body
                else
                  resp_body = connection.get(path, headers).tap do |resp|
                    total_entries = (resp['total_entries'] || 1).to_i
                  end.body
                end

                instantiate_collection( (format.decode(resp_body) || []), prefix_options )
            end
          rescue ActiveResource::ResourceNotFound
            # Swallowing ResourceNotFound exceptions and return nil - as per
            # ActiveRecord.
            nil
          end

          unless data.nil?
            pager.replace data
          end

          pager.total_entries = total_entries
        end


      end

      # 如果Resp中含有total_entries的话, 尝试使用WillPaginate::Collection来封装
      #
      # @param [Array] 需要被封装的数据
      # @return [WillPaginate::Collection, Array] 可能是数组, 也可能是Collection
      def try_to_wrap_to_collection(array, resp)
        headers = resp.headers.inject({}) do |r, (key, value)|
          r[key.downcase.gsub('-', '_')] = value
          r
        end

        if headers['total_entries']
          page = headers['current_page'].to_i
          per_page = headers['per_page'].to_i

          WillPaginate::Collection.create(page, per_page) do |pager|
            pager.replace(array)
            pager.total_entries = headers['total_entries'].to_i
          end
        else
          array
        end
      end
    end

    module SplitOptionExtension
      def split_options(options = {})
        prefix_options, query_options = super
        prefix_options.each_pair do |key, value|
          query_options[key] = value if self.class.columns_hash[key.intern]
        end
        [prefix_options, query_options]
      end
    end

    included do |rmi_obj|
      extend DSL

      class_attribute :serialize_with_root
      self.serialize_with_root = true

      before_save :assign_default_values if self.respond_to? :before_save

      prepend SplitOptionExtension
    end

    def assign_default_values
      self.class.class_definition.assign_default_values_to(self) if self.class.respond_to?(:class_definition)
    end

    def to_json(options={})
      super(serialize_option(options))
    end

    def as_json(opt = {})
      if self.class.serialize_with_root?
        super(opt)
      else
        self.attributes
      end

    end

    def [](key)
      self.attributes[key]
    end

    def as_smart
      self.attributes.as_smart
    end

    #def as_json(opt = {})
    #
    #  super(opt).tap do |r|
    #    opt.tap { puts "#{self.class.name}: #{opt}, #{r}" }
    #  end
    #end

    def to_xml(options={})
      super(serialize_option(options))
    end

    def serialize_option(opt = {})
      if self.class.serialize_with_root?
        #{ root: self.class.element_name }
        opt[:root] = self.class.element_name
      else
        opt.delete(:root)
      end

      opt#.tap { puts "#{self.class.name}: #{opt}" }

    end

    def find_or_create_resource_in_modules(resource_name, module_names)
      receiver = Object
      namespaces = module_names[0, module_names.size-1].map do |module_name|
        receiver = receiver.const_get(module_name)
      end
      const_args = RUBY_VERSION < "1.9" ? [resource_name] : [resource_name, false]
      if namespace = namespaces.reverse.detect { |ns| ns.const_defined?(*const_args) }
        namespace.const_get(*const_args)
      else
        create_resource_for(resource_name)
      end
    end

    # 重载默认的api
    def create_resource_for(resource_name)
      resource = self.class.const_set(resource_name, Class.new(ActiveResource::Base))
      resource.send(:include, SceneryRmi::Obj::Base)
      resource.prefix = self.class.prefix
      resource.site   = self.class.site
      resource.serialize_with_root = false
      resource
    end

    def inspect
      "#{self.class.name}:#{self.attributes.inspect}"
    end


  end
end