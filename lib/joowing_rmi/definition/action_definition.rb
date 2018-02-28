#encoding: utf-8
module JoowingRmi::Definition
  # 
  # == 构建一个动作定义
  # method/name是必须的，其他的属性都是可选的，都有默认值
  # 
  # @param method: HTTP方法 :put, :delete, :get, :post
  # @param name: method name for user to call
  # @param type: :anything(primitive types, hash), or other string(represents UserObject class)
  # @param array: true | false
  # @param instance: true|false, 指定action是否实例方法
  # @param path: default as name
  # @param description: 动作的描述
  #
  # noinspection RubyArgCount
  class ActionDefinition < Struct.new(:method, :name, :type, :instance, :path, :array, :description)
    def initialize(*args)
      super(*args)
      self.type ||= :hash
      self.instance = false if self.instance.nil?
      self.path ||= self.name
      self.array = false if self.array.nil?
    end

=begin
def element_path(id, prefix_options = {}, query_options = nil)
  check_prefix_options(prefix_options)

  prefix_options, query_options = split_options(prefix_options) if query_options.nil?
  "#{prefix(prefix_options)}#{collection_name}/#{URI.parser.escape id.to_s}.#{format.extension}#{query_string(query_options)}"
end

def collection_path(prefix_options = {}, query_options = nil)
  check_prefix_options(prefix_options)
  prefix_options, query_options = split_options(prefix_options) if query_options.nil?
  "#{prefix(prefix_options)}#{collection_name}.#{format.extension}#{query_string(query_options)}"
end
=end

    def inject_method(klass, definition)
      if self.instance
        inject_instance_method(klass, definition)
      else
        inject_class_method(klass, definition)
      end
    end

    def self.hash_in_array?(array)
      return true if array.empty?
      array.first.is_a? Hash
    end

    def inject_class_method(klass, definition)
      this = self
      klass.singleton_class.class_eval do
        define_method this.name do |*_args|
          args = _args.first
          args ||= {}
          if definition.dont_use_element_name
            p = File.join(self.send(:prefix, args), this.path.to_s)
          else
            p = File.join(self.send(:prefix, args), self.collection_name, this.path.to_s)
          end
          p = p[0..-2] if p[-1] == '/'
          p += ('.' + self.format.extension)
          # { |k| key = k.gsub(':', ''); URI.parser.escape((args[key] || args[key.to_sym])/.to_s }
          keys = []
          p = p.gsub(/:\w+/) do |k|
            key = k.gsub(':', '')
            keys << key
            value = (args[key] || args[key.to_sym])

            if value.nil?
              k.to_s
            else
              URI.parser.escape(value.to_s)
            end
          end

          method = this.method.intern
          if method == :get
            prefix = definition.prefix || ''
            keys.concat prefix.scan(/:\w+/).map{|key| key.sub(/:/, '')}
            query_args = args.delete_if {|k, _| keys.include? k.to_s }
            q_str = "#{self.send(:query_string, query_args)}"
            p = "#{p}#{q_str}"
            resp = self.connection.send(method, p, self.headers).tap do |resp|
              # ignore
            end
          elsif method == :delete
            resp = self.connection.send(method, p, self.headers).tap do |resp|
              # ignore
            end
          else
            # post put
            resp = self.connection.send(method, p, self.format.encode(args), self.headers).tap do |resp|
              # ignore
            end
          end

          return nil if resp.nil?

          unless resp.is_a?(Net::HTTPSuccess) || (resp.code >= 200 && resp.code < 300)
            return nil
          end

          if resp.code == 204
            return nil;
          end

          # TODO 愚蠢的变量命名，这个resp可能是数组，可能是其他玩意儿，却被命名为resp_hash，并误导了后继写代码
          # noinspection RubyArgCount
          resp_hash = self.format.decode(resp.body)
          if this.type.is_a? String #自定义类型
            if this.array
              try_to_wrap_to_collection(this.type.classify.constantize.send(:instantiate_collection, resp_hash), resp)
            else
              this.type.classify.constantize.send(:instantiate_record, resp_hash)
            end
          else # 符号类型(anything, object)
            if this.array
              result = resp_hash
              if this.type == :object
                # 原先并没有这段代码， 这种代码，属于基本的防御性编程
                raise "#{this} declared as :object, got value is't a hash array" unless ActionDefinition.hash_in_array?(resp_hash)
                result = self.send(:instantiate_collection, resp_hash)
              elsif this.type == :anything
                # anything里面，只有value为hash时才要构建集合
                result = self.send(:instantiate_collection, resp_hash) if ActionDefinition.hash_in_array?(resp_hash)
              end
              try_to_wrap_to_collection(result, resp)
            elsif this.type == :object
              self.send(:instantiate_record, resp_hash)
            else
              resp_hash
            end
          end

        end
      end
    end



    def inject_instance_method(klass, definition)
      this = self
      klass.class_eval do
        define_method this.name do |*args|
          args ||= []
          args = args[0] || {}

          keys = []
          if definition.dont_use_element_name
            p = File.join(self.class.send(:prefix, self.prefix_options), URI.parser.escape(id.to_s), this.path.to_s)
          else
            p = File.join(self.class.send(:prefix, self.prefix_options), self.class.collection_name, URI.parser.escape(id.to_s), this.path.to_s)
          end
          p = p[0..-2] if p[-1] == '/'
          p += ('.' + self.class.format.extension)

          p = p.gsub(/:\w+/) do |k|
            key = k.gsub(':', '')
            keys << key
            value = (args[key] || args[key.to_sym])

            if value.nil?
              k.to_s
            else
              URI.parser.escape(value.to_s)
            end
          end

          if this.method == :get
            prefix = definition.prefix || ''
            keys.concat prefix.scan(/:\w+/).map{|key| key.sub(/:/, '')}
            query_args = args.delete_if {|k,_| keys.include? k.to_s }
            q_str = "#{self.class.send(:query_string, query_args)}"
            p = "#{p}#{q_str}"

            resp = self.class.connection.send(this.method, p, self.class.headers).tap do |resp|
              # ignore
            end
          elsif this.method == :delete
            resp = self.class.connection.send(this.method, p, self.class.headers).tap do |resp|
              # ignore
            end
          else
            # post put
            resp = self.class.connection.send(this.method, p, self.class.format.encode(args), self.class.headers).tap do |resp|
              # ignore
            end
          end

          return nil if resp.nil?

          unless resp.is_a?(Net::HTTPSuccess) || (resp.code >= 200 && resp.code < 300)
            return nil
          end

          if resp.code == 204
            return nil;
          end

          resp_hash = self.class.format.decode(resp.body)
          if this.type.is_a? String #自定义类型
            if this.array
              self.class.try_to_wrap_to_collection(this.type.classify.constantize.send(:instantiate_collection, resp_hash), resp)
            else
              this.type.classify.constantize.send(:instantiate_record, resp_hash)
            end
          else # 符号类型(anything, object)
            if this.array
              if this.type == :object
                # 原先并没有这段代码， 这种代码，属于基本的防御性编程
                raise "#{this} declared as :object, got value is't a hash array" unless ActionDefinition.hash_in_array?(resp_hash)
                self.class.try_to_wrap_to_collection(self.class.send(:instantiate_collection, resp_hash), resp)
              elsif this.type == :anything
                # anything里面，只有value为hash时才要构建集合
                self.class.try_to_wrap_to_collection(self.class.send(:instantiate_collection, resp_hash), resp) if ActionDefinition.hash_in_array?(resp_hash)
              end
            elsif this.type == :object
              self.class.send(:instantiate_record, resp_hash)
            else
              resp_hash
            end
          end

        end
      end
    end

    def to_s(prefix = '/')
      is = self.instance ? '[*]' : '   '
      format('%s%6s %s (%s)', is, self.method.to_s.upcase, path_of(prefix), self.type_string)
    rescue
      log_error "#{self.name}: #{$!}"
    end

    def type_string
      suffix = self.array ? '[]' : ''
      self.name.to_s + '=>' + (self.type || :anything).to_s + suffix
    end

    def path_of(prefix = '')
      array = [prefix.to_s]
      array << ':id' if self.instance
      array << self.path.to_s
      value = File.join array
      value.gsub!(/\/$/,'')
      value
    end


  end
end